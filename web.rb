require "webrick"
require "json"
require "uri"
require "open3"
require "tmpdir"
require "securerandom"
require "fileutils"
require "openssl"

require "webrick/https"
require 'sidekiq'
require_relative 'workers/process_worker'

# Публичный URL приложения (для формирования processed_url)
HOST = ENV['WEBAPP_HOST'] || 'https://youtube.gimadev.win'
# По умолчанию backend слушает локально на порту 8080 (nginx терминирует TLS)
PORT = ENV['PORT'] ? ENV['PORT'].to_i : 8080

OUTPUT_DIR = File.join(Dir.pwd, 'web_public', 'outputs')
FileUtils.mkdir_p(OUTPUT_DIR)

server_opts = { Port: PORT }

# TLS теперь терминруется на nginx. Запускаем простой HTTP backend.
server = WEBrick::HTTPServer.new(server_opts)

# Статика: логируем заголовки для '/' и '/app.js' чтобы понять, что отправляет Telegram WebView
server.mount_proc '/' do |req, res|
  begin
    server.logger.info "REQ / from #{req.remote_ip} headers=#{req.header.inspect}"
    path = File.join(Dir.pwd, 'web_public', 'index.html')
    body = File.read(path)
    res.status = 200
    res['Content-Type'] = 'text/html'
    res.body = body
  rescue => e
    server.logger.error "ERR_SERVE_INDEX #{e.message}"
    res.status = 500
    res.body = 'error'
  end
end

server.mount_proc '/app.js' do |req, res|
  begin
    server.logger.info "REQ /app.js from #{req.remote_ip} headers=#{req.header.inspect}"
    path = File.join(Dir.pwd, 'web_public', 'app.js')
    body = File.read(path)
    res.status = 200
    res['Content-Type'] = 'application/javascript'
    res.body = body
  rescue => e
    server.logger.error "ERR_SERVE_APPJS #{e.message}"
    res.status = 500
    res.body = ''
  end
end

# Serve other static assets (outputs etc.) via file handler
server.mount '/outputs', WEBrick::HTTPServlet::FileHandler, File.join(Dir.pwd, 'web_public', 'outputs')

def command_exists?(name)
  system("which #{name} > /dev/null 2>&1")
end

def run_cmd(cmd, timeout: 3600)
  stdout, stderr, status = Open3.capture3(*cmd)
  return { ok: status.success?, out: stdout, err: stderr, status: status.exitstatus }
end

server.mount_proc "/process" do |req, res|
  begin
    if req.request_method != 'POST'
      res.status = 405
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'Method Not Allowed' }.to_json)
      next
    end

    body = req.body || ''
    data = JSON.parse(body) rescue {}
    youtube_url = data['url']

    unless youtube_url && youtube_url.start_with?('http')
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'invalid url' }.to_json)
      next
    end

    unless command_exists?('yt-dlp') && command_exists?('ffmpeg')
      res.status = 500
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'yt-dlp or ffmpeg not installed on host' }.to_json)
      next
    end

    jid = ProcessWorker.perform_async(youtube_url)
    res.status = 202
    res['Content-Type'] = 'application/json'
    res.body =({ job_id: jid, status: 'queued' }.to_json)
  rescue => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ error: e.message, backtrace: e.backtrace[0..5] }.to_json)
  end
end

server.mount_proc "/__ping" do |req, res|
  begin
    body = req.body || ''
    server.logger.info "CLIENT_PING #{req.remote_ip} #{Time.now} #{body}"
    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ ok: true }.to_json)
  rescue => e
    server.logger.error "PING_ERR #{e.message}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false }.to_json)
  end
end

server.mount_proc "/__error" do |req, res|
  begin
    body = req.body || ''
    server.logger.error "CLIENT_ERROR #{req.remote_ip} #{Time.now} #{body}"
    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ ok: true }.to_json)
  rescue => e
    server.logger.error "ERROR_LOG_ERR #{e.message}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false }.to_json)
  end
end

trap("INT") { server.shutdown }

server.start
