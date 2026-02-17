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

# Serve check_publish page for WebApp to verify shareToStory availability
server.mount_proc '/check_publish' do |req, res|
  begin
    path = File.join(Dir.pwd, 'web_public', 'check_publish.html')
    body = File.read(path)
    res.status = 200
    res['Content-Type'] = 'text/html'
    res.body = body
  rescue => e
    server.logger.error "ERR_SERVE_CHECK #{e.message}"
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

server.mount_proc "/job_status" do |req, res|
  begin
    job_id = req.query['job_id']
    if job_id.nil? || job_id.empty?
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'missing job_id' }.to_json)
      next
    end

    mapping_path = File.join(OUTPUT_DIR, "#{job_id}.json")
    if File.exist?(mapping_path)
      data = JSON.parse(File.read(mapping_path)) rescue {}
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body =({ status: 'done', output: data['output'] }.to_json)
    else
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body =({ status: 'processing' }.to_json)
    end
  rescue => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ error: e.message }.to_json)
  end
end

server.mount_proc '/publish' do |req, res|
  begin
    job_id = req.query['job_id']
    # simple HTML page that shows processed video if ready
    html = <<~HTML
      <!doctype html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Publish Story</title>
        <style>body{font-family:Helvetica,Arial,sans-serif;padding:16px}video{max-width:100%;height:auto}</style>
      </head>
      <body>
        <h3>Publish Story</h3>
        <div id="status">Loading...</div>
        <div id="preview"></div>
        <div id="note" style="color:#666;margin-top:12px"></div>
        <a id="downloadLink" href="#" style="display:none;margin-top:8px;display:inline-block">Скачать видео</a>
        <button id="copyLink" style="display:none;margin-left:8px">Скопировать ссылку</button>
        <button id="publishBtn" style="display:none;margin-left:8px">Опубликовать историю</button>
        <script>
          const jobId = "#{job_id}";
          const statusEl = document.getElementById('status');
          const previewEl = document.getElementById('preview');
          const publishBtn = document.getElementById('publishBtn');

          function check() {
            fetch('/job_status?job_id=' + encodeURIComponent(jobId)).then(r=>r.json()).then(j=>{
              if (j.status === 'done') {
                statusEl.innerText = 'Готово';
                const src = '#{HOST}' + '/' + j.output;
                previewEl.innerHTML = '<video controls playsinline src="'+src+'"></video>';
                publishBtn.style.display = 'inline-block';
                // Авто-вызов публикации в Telegram WebApp, если доступен
                function tryAutoPublish(){
                  try{
                    if (window.Telegram && Telegram.WebApp && typeof Telegram.WebApp.shareToStory === 'function'){
                      Telegram.WebApp.shareToStory({ url: src });
                      statusEl.innerText = 'Открыт редактор историй.';
                      return true;
                    }
                  }catch(e){ console.error('autoPublish err', e) }
                  return false;
                }
                // Попробуем авто-вызвать несколько раз с интервалом — иногда WebApp API появляется чуть позже
                if (!tryAutoPublish()){
                  let tries=0; const tInt = setInterval(()=>{ tries++; if(tryAutoPublish()||tries>5) { if(tries>5){
                      // После нескольких неудачных попыток покажем пользователю понятную подсказку и ссылки
                      const note = document.getElementById('note');
                      note.innerText = 'Похоже, ваш аккаунт не поддерживает публикацию историй напрямую из WebApp (возможно нет доступа). Вы можете скачать видео и опубликовать вручную.';
                      const downloadLink = document.getElementById('downloadLink');
                      downloadLink.href = src; downloadLink.style.display='inline-block';
                      const copyBtn = document.getElementById('copyLink'); copyBtn.style.display='inline-block';
                      copyBtn.addEventListener('click', ()=>{ navigator.clipboard.writeText(src).then(()=>{ alert('Ссылка скопирована'); }).catch(()=>{ alert('Не удалось скопировать ссылку'); }); });
                    } clearInterval(tInt); } }, 500);
                }
              } else {
                statusEl.innerText = 'Обработка...';
                setTimeout(check, 2000);
              }
            }).catch(e=>{statusEl.innerText='Ошибка'; console.error(e)});
          }
          publishBtn.addEventListener('click', ()=>{
            try {
              if (window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.shareToStory) {
                const el = document.querySelector('video');
                const videoUrl = el ? el.src : null;
                window.Telegram.WebApp.shareToStory({ url: videoUrl });
              } else {
                alert('Publishing via Telegram WebApp is available only inside Telegram.');
              }
            } catch(e){ console.error(e); alert('Ошибка публикации: '+e.message) }
          });
          if (jobId) check(); else statusEl.innerText='No job_id provided';
        </script>
      </body>
      </html>
    HTML

    res.status = 200
    res['Content-Type'] = 'text/html'
    res.body = html
  rescue => e
    server.logger.error "PUBLISH_ERR #{e.message}"
    res.status = 500
    res.body = 'error'
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
