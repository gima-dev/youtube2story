require "webrick"
require "webrick/https"
require "json"
require "uri"

HOST = ENV['WEBAPP_HOST'] || 'https://gima.dedyn.io'
PORT = ENV['PORT'] ? ENV['PORT'].to_i : 443

server = WEBrick::HTTPServer.new(
  Port: PORT,
  SSLEnable: true,
  SSLCertName: [["CN", URI(HOST).host]]
)

# Статика из папки web_public
server.mount "/", WEBrick::HTTPServlet::FileHandler, File.join(Dir.pwd, 'web_public')

# Простой API: принимает POST {"url":"https://youtube..."} и возвращает JSON с processed_url
server.mount_proc "/process" do |req, res|
  begin
    if req.request_method != 'POST'
      res.status = 405
      res.body = 'Method Not Allowed'
      next
    end

    body = req.body || ''
    data = JSON.parse(body) rescue {}
    youtube_url = data['url']

    unless youtube_url && youtube_url.start_with?('http')
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body = { error: 'invalid url' }.to_json
      next
    end

    # Здесь должна быть логика: yt-dlp -> ffmpeg -> выгрузка файла и получение публичного URL.
    # Пока — возвращаем заглушку. Замените на фактический путь после реализации бэкенда обработки.
    processed_url = "#{HOST}/outputs/demo.mp4"

    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body = { processed_url: processed_url }.to_json
  rescue => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ error: e.message }.to_json)
  end
end

trap("INT") { server.shutdown }

server.start
