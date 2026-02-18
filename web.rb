require "webrick"
require "json"
require "uri"
require "open3"
require "tmpdir"
require "securerandom"
require "fileutils"
require "openssl"
require 'dotenv/load'
require 'pg'

require "webrick/https"
require 'sidekiq'
require_relative 'workers/process_worker'

# Публичный URL приложения (для формирования processed_url)
HOST = ENV['WEBAPP_HOST'] || 'https://youtube.gimadev.win'
# По умолчанию backend слушает локально на порту 8080 (nginx терминирует TLS)
PORT = ENV['PORT'] ? ENV['PORT'].to_i : 8080

APP_ROOT = File.expand_path(__dir__)
OUTPUT_DIR = File.join(APP_ROOT, 'web_public', 'outputs')
FileUtils.mkdir_p(OUTPUT_DIR)

server_opts = { Port: PORT }

# TLS теперь терминруется на nginx. Запускаем простой HTTP backend.
log_dir = File.join(Dir.pwd, 'tmp')
FileUtils.mkdir_p(log_dir)
log_path = File.join(log_dir, 'y2s_web.log')
access_log_path = File.join(log_dir, 'y2s_web_access.log')
log_file = File.open(log_path, 'a+')
access_log_file = File.open(access_log_path, 'a+')
logger = WEBrick::Log.new(log_file)
access_log_format = '%h %l %u %t \"%r\" %>s %b'
server = WEBrick::HTTPServer.new(server_opts.merge(Logger: logger, AccessLog: [[access_log_file, access_log_format]]))

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
    server.logger.info "REQ /check_publish from #{req.remote_ip} headers=#{req.header.inspect}"
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

# Lightweight probe page to auto-send diagnostics for WebView injection debugging
server.mount_proc '/probe' do |req, res|
  begin
    server.logger.info "REQ /probe from #{req.remote_ip} headers=#{req.header.inspect}"
    path = File.join(Dir.pwd, 'web_public', 'probe.html')
    body = File.read(path)
    res.status = 200
    res['Content-Type'] = 'text/html'
    res.body = body
  rescue => e
    server.logger.error "ERR_SERVE_PROBE #{e.message}"
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

server.mount_proc '/health' do |req, res|
  begin
    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ ok: true, service: 'y2s_web' }.to_json)
  rescue => e
    server.logger.error "HEALTH_ERR #{e.class}: #{e.message}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false, error: e.message }.to_json)
  end
end

server.mount_proc '/db_health' do |req, res|
  begin
    db_url = ENV['DATABASE_URL']
    if db_url.nil? || db_url.empty?
      res.status = 500
      res['Content-Type'] = 'application/json'
      res.body =({ ok: false, error: 'DATABASE_URL is missing' }.to_json)
      next
    end

    row = nil
    PG.connect(db_url) do |conn|
      row = conn.exec("SELECT current_database() AS db, current_user AS user_name, NOW() AS server_time").first
    end

    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ ok: true, db: row['db'], user: row['user_name'], server_time: row['server_time'] }.to_json)
  rescue => e
    server.logger.error "DB_HEALTH_ERR #{e.class}: #{e.message}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false, error: e.message }.to_json)
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
    progress_path = File.join(OUTPUT_DIR, "#{job_id}.progress.json")
    progress_data = File.exist?(progress_path) ? (JSON.parse(File.read(progress_path)) rescue {}) : {}
    progress_percent = progress_data['percent']
    progress_stage = progress_data['stage']

    if File.exist?(mapping_path)
      data = JSON.parse(File.read(mapping_path)) rescue {}
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body =({ status: 'done', output: data['output'], progress: 100, stage: 'done' }.to_json)
    else
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body =({ status: 'processing', progress: progress_percent, stage: progress_stage }.to_json)
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
      <html lang="ru">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Публикация истории</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:opsz@8..144&family=Space+Grotesk:wght@400;500;600&display=swap" rel="stylesheet">
        <style>
          :root {
            --ink: #111210;
            --muted: rgba(17, 18, 16, 0.7);
            --paper: #f7f3ec;
            --accent: #f65c37;
            --accent-dark: #e14f2b;
            --line: rgba(17, 18, 16, 0.12);
          }

          * { box-sizing: border-box; }

          body {
            margin: 0;
            min-height: 100vh;
            font-family: "Space Grotesk", "Trebuchet MS", sans-serif;
            color: var(--ink);
            background: radial-gradient(120% 120% at 10% 0%, #fde7d8 0%, var(--paper) 50%, #f5f1ea 100%);
          }

          body::before,
          body::after {
            content: "";
            position: fixed;
            width: 38vw;
            height: 38vw;
            max-width: 460px;
            max-height: 460px;
            border-radius: 50%;
            opacity: 0.22;
            z-index: 0;
            pointer-events: none;
            animation: drift 14s ease-in-out infinite;
          }

          body::before {
            background: radial-gradient(circle, rgba(246, 92, 55, 0.5), rgba(246, 92, 55, 0));
            top: -140px;
            right: -140px;
          }

          body::after {
            background: radial-gradient(circle, rgba(255, 196, 88, 0.45), rgba(255, 196, 88, 0));
            bottom: -160px;
            left: -140px;
            animation-delay: -5s;
          }

          .shell {
            position: relative;
            z-index: 1;
            max-width: 760px;
            margin: 0 auto;
            padding: 46px 20px 64px;
            display: grid;
            gap: 24px;
          }

          .hero {
            display: grid;
            gap: 10px;
            animation: rise 0.8s ease both;
          }

          .eyebrow {
            text-transform: uppercase;
            letter-spacing: 0.18em;
            font-size: 12px;
            color: var(--muted);
          }

          h1 {
            margin: 0;
            font-family: "Instrument Serif", "Times New Roman", serif;
            font-weight: 400;
            font-size: clamp(28px, 4.6vw, 46px);
            line-height: 1.05;
          }

          .hero p {
            margin: 0;
            color: var(--muted);
            font-size: 14px;
            max-width: 560px;
          }

          .card {
            background: rgba(255, 255, 255, 0.75);
            border: 1px solid var(--line);
            border-radius: 24px;
            padding: 24px;
            display: grid;
            gap: 16px;
            backdrop-filter: blur(10px);
            box-shadow: 0 20px 60px rgba(17, 18, 16, 0.08);
            animation: rise 0.8s ease both;
            animation-delay: 0.1s;
          }

          .status-row {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 16px;
            flex-wrap: wrap;
          }

          .label {
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.16em;
            color: var(--muted);
          }

          #status {
            font-size: 20px;
            font-weight: 600;
            margin-top: 6px;
          }

          .job-id {
            font-size: 12px;
            color: var(--muted);
          }

          #progressWrap {
            display: none;
          }

          .progress-track {
            height: 10px;
            background: rgba(17, 18, 16, 0.08);
            border-radius: 999px;
            overflow: hidden;
          }

          .progress-bar {
            height: 100%;
            width: 0%;
            background: linear-gradient(90deg, #f65c37, #ff9448);
          }

          .progress-text {
            margin-top: 8px;
            font-size: 13px;
            color: var(--muted);
          }

          .preview video {
            width: 100%;
            max-height: 70vh;
            border-radius: 18px;
            background: #0c0c0c;
            box-shadow: 0 18px 40px rgba(17, 18, 16, 0.2);
          }

          .note {
            color: var(--muted);
            font-size: 13px;
          }

          .actions {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
          }

          .btn {
            border-radius: 999px;
            padding: 11px 18px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            border: 1px solid transparent;
            font-family: inherit;
            transition: transform 0.2s ease, box-shadow 0.2s ease, background 0.2s ease;
          }

          .btn.primary {
            background: var(--accent);
            color: #fff;
            box-shadow: 0 16px 30px rgba(246, 92, 55, 0.25);
          }

          .btn.primary:hover {
            background: var(--accent-dark);
            transform: translateY(-1px);
          }

          .btn.ghost {
            background: transparent;
            border-color: var(--line);
            color: var(--ink);
          }

          .foot {
            font-size: 12px;
            color: var(--muted);
          }

          @keyframes rise {
            from { opacity: 0; transform: translateY(12px); }
            to { opacity: 1; transform: translateY(0); }
          }

          @keyframes drift {
            0%, 100% { transform: translate(0, 0); }
            50% { transform: translate(-14px, 10px); }
          }
        </style>
        <script src="https://telegram.org/js/telegram-web-app.js?59"></script>
      </head>
      <body>
        <main class="shell">
          <header class="hero">
            <div class="eyebrow">YouTube to Story</div>
            <h1>История готовится</h1>
            <p>Мы проверим статус обработки и откроем редактор в Telegram, когда файл будет готов.</p>
          </header>

          <section class="card">
            <div class="status-row">
              <div>
                <div class="label">Статус</div>
                <div id="status">Загрузка...</div>
              </div>
              <div id="jobId" class="job-id"></div>
            </div>

            <div id="progressWrap" class="progress">
              <div class="progress-track">
                <div id="progressBar" class="progress-bar"></div>
              </div>
              <div id="progressText" class="progress-text"></div>
            </div>

            <div id="preview" class="preview"></div>
            <div id="note" class="note"></div>

            <div class="actions">
              <a id="downloadLink" class="btn ghost" href="#" style="display:none">Скачать видео</a>
              <button id="copyLink" class="btn ghost" style="display:none">Скопировать ссылку</button>
              <button id="publishBtn" class="btn primary" style="display:none">Открыть редактор историй</button>
            </div>
          </section>

          <div class="foot">Если редактор не открылся автоматически, нажмите кнопку вручную.</div>
        </main>
        <script>
          const jobId = "#{job_id}";
          const statusEl = document.getElementById('status');
          const previewEl = document.getElementById('preview');
          const jobIdEl = document.getElementById('jobId');
          const publishBtn = document.getElementById('publishBtn');
          const progressWrap = document.getElementById('progressWrap');
          const progressBar = document.getElementById('progressBar');
          const progressText = document.getElementById('progressText');
          let progressPct = 0;
          let startedAt = Date.now();

          if (jobId) {
            jobIdEl.innerText = 'Job ID: ' + jobId;
          }

          try {
            if (window.Telegram && Telegram.WebApp && typeof Telegram.WebApp.ready === 'function') {
              Telegram.WebApp.ready();
              if (typeof Telegram.WebApp.expand === 'function') {
                Telegram.WebApp.expand();
              }
            }
          } catch (e) {}

          function showProgress(){
            progressWrap.style.display = 'block';
          }

          function updateProgress(done, pct, stage){
            if(done){
              progressPct = 100;
            } else if (typeof pct === 'number' && !isNaN(pct)) {
              progressPct = Math.max(progressPct, Math.min(Math.floor(pct), 99));
            } else {
              progressPct = Math.min(progressPct + 7, 90);
            }
            progressBar.style.width = progressPct + '%';
            const elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
            const stageLabel = stage ? (' ' + stage) : '';
            progressText.innerText = done ? 'Готово' : ('Обработка... ' + progressPct + '% (' + elapsed + 's)' + stageLabel);
          }

          function check() {
            fetch('/job_status?job_id=' + encodeURIComponent(jobId)).then(r=>r.json()).then(j=>{
              if (j.status === 'done') {
                statusEl.innerText = 'Готово';
                updateProgress(true, 100, 'done');
                const src = '#{HOST}' + '/' + j.output;
                previewEl.innerHTML = '<video controls playsinline src="'+src+'"></video>';
                publishBtn.style.display = 'inline-block';
                // Авто-вызов публикации в Telegram WebApp, если доступен
                function tryAutoPublish(){
                  try{
                    if (window.Telegram && Telegram.WebApp && typeof Telegram.WebApp.shareToStory === 'function'){
                      Telegram.WebApp.shareToStory(src);
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
                showProgress();
                updateProgress(false, j.progress, j.stage);
                setTimeout(check, 2000);
              }
            }).catch(e=>{statusEl.innerText='Ошибка'; console.error(e)});
          }
          publishBtn.addEventListener('click', ()=>{
            try {
              if (window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.shareToStory) {
                const el = document.querySelector('video');
                const videoUrl = el ? el.src : null;
                if (videoUrl) {
                  window.Telegram.WebApp.shareToStory(videoUrl);
                }
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
