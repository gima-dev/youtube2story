require "webrick"
require "webrick/https"
require "json"
require "uri"
require "open3"
require "tmpdir"
require "securerandom"
require "fileutils"
require "openssl"

HOST = ENV['WEBAPP_HOST'] || 'https://gima.dedyn.io'
PORT = ENV['PORT'] ? ENV['PORT'].to_i : 8443

# TLS files (optional) - если заданы, включаем HTTPS
SSL_CERT = ENV['SSL_CERT']
SSL_KEY  = ENV['SSL_KEY']

OUTPUT_DIR = File.join(Dir.pwd, 'web_public', 'outputs')
FileUtils.mkdir_p(OUTPUT_DIR)

server_opts = {
  Port: PORT,
}

if SSL_CERT && SSL_KEY && File.exist?(SSL_CERT) && File.exist?(SSL_KEY)
  cert = OpenSSL::X509::Certificate.new(File.read(SSL_CERT))
  key  = OpenSSL::PKey.read(File.read(SSL_KEY))
  server_opts.merge!(
    SSLEnable: true,
    SSLCertificate: cert,
    SSLPrivateKey: key,
    SSLCertName: [["CN", "gima.dedyn.io"]]
  )
else
  server_opts[:SSLEnable] = false
end

server = WEBrick::HTTPServer.new(server_opts)

# Статика из папки web_public
server.mount "/", WEBrick::HTTPServlet::FileHandler, File.join(Dir.pwd, 'web_public')

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

    unless command_exists?('yt-dlp')
      res.status = 500
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'yt-dlp not installed. Install via brew install yt-dlp or pip.' }.to_json)
      next
    end

    unless command_exists?('ffmpeg')
      res.status = 500
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'ffmpeg not installed. Install via brew install ffmpeg.' }.to_json)
      next
    end

    Dir.mktmpdir('y2s') do |tmpdir|
      # скачиваем исходное видео
      out_template = File.join(tmpdir, 'input.%(ext)s')
      cmd = ['yt-dlp', '--no-playlist', '-f', 'best', '-o', out_template, youtube_url]
      res_write = run_cmd(cmd)
      unless res_write[:ok]
        res.status = 500
        res['Content-Type'] = 'application/json'
        res.body =({ error: 'yt-dlp failed', details: res_write[:err] }.to_json)
        next
      end

      input_files = Dir.glob(File.join(tmpdir, '*'))
      input_file = input_files.first
      unless input_file && File.exist?(input_file)
        res.status = 500
        res['Content-Type'] = 'application/json'
        res.body =({ error: 'downloaded file not found' }.to_json)
        next
      end

      # Подготовка выходного файла
      uuid = SecureRandom.uuid
      final_name = "#{uuid}.mp4"
      final_path = File.join(OUTPUT_DIR, final_name)

      # Функция кодирования с попытками
      def transcode(input, output)
        crfs = [28, 32, 36]
        durations = [60, 45, 30]
        codecs = ['libx265', 'libx264']

        codecs.each do |codec|
          crfs.each do |crf|
            durations.each do |dur|
              cmd = [
                'ffmpeg', '-y', '-i', input,
                '-ss', '0', '-t', dur.to_s,
                '-vf', "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2",
                '-c:v', codec, '-preset', 'fast', '-crf', crf.to_s,
                '-c:a', 'aac', '-b:a', '96k', output
              ]
              res = Open3.capture3(*cmd)
              ok = $?.success?
              if ok
                size = File.size(output) rescue 0
                # допустимый максимум 30MB
                return { ok: true, size: size, codec: codec, crf: crf, dur: dur } if size > 0 && size <= 30 * 1024 * 1024
                # если слишком большой, пробуем следующую комбинацию
              end
            end
          end
        end
        { ok: false }
      end

      trans_res = transcode(input_file, final_path)
      unless trans_res[:ok]
        # если не получилось - попробуем простую копию-conversion с более высоким crf и 30s
        cmd = ['ffmpeg', '-y', '-i', input_file, '-ss', '0', '-t', '30', '-vf', 'scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2', '-c:v', 'libx264', '-preset', 'fast', '-crf', '36', '-c:a', 'aac', '-b:a', '96k', final_path]
        Open3.capture3(*cmd)
      end

      unless File.exist?(final_path)
        res.status = 500
        res['Content-Type'] = 'application/json'
        res.body =({ error: 'transcoding failed' }.to_json)
        next
      end

      processed_url = URI.join(HOST + '/', "outputs/#{final_name}").to_s

      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body =({ processed_url: processed_url }.to_json)
    end
  rescue => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ error: e.message, backtrace: e.backtrace[0..5] }.to_json)
  end
end

trap("INT") { server.shutdown }

server.start
