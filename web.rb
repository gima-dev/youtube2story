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

def db_available?
  db_url = ENV['DATABASE_URL']
  !db_url.nil? && !db_url.empty?
end

def with_db
  raise 'DATABASE_URL is missing' unless db_available?
  PG.connect(ENV['DATABASE_URL']) do |conn|
    yield conn
  end
end

def ensure_runtime_schema
  return unless db_available?

  with_db do |conn|
    conn.exec "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    conn.exec <<~SQL
      CREATE TABLE IF NOT EXISTS users (
        id BIGSERIAL PRIMARY KEY,
        telegram_user_id BIGINT NOT NULL UNIQUE,
        username TEXT,
        first_name TEXT,
        last_name TEXT,
        language_code TEXT,
        is_premium BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
    SQL

    conn.exec <<~SQL
      CREATE TABLE IF NOT EXISTS jobs (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id BIGINT REFERENCES users(id) ON DELETE CASCADE,
        sidekiq_jid TEXT UNIQUE,
        source_platform TEXT NOT NULL DEFAULT 'youtube',
        source_url TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        stage TEXT,
        progress_percent SMALLINT NOT NULL DEFAULT 0,
        error_message TEXT,
        metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
        started_at TIMESTAMPTZ,
        finished_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
    SQL

    conn.exec "ALTER TABLE users ADD COLUMN IF NOT EXISTS has_story_access BOOLEAN"
    conn.exec "ALTER TABLE users ADD COLUMN IF NOT EXISTS story_access_checked_at TIMESTAMPTZ"
    conn.exec "ALTER TABLE users ADD COLUMN IF NOT EXISTS last_webapp_seen_at TIMESTAMPTZ"
    conn.exec "CREATE INDEX IF NOT EXISTS idx_jobs_sidekiq_jid ON jobs(sidekiq_jid)"
    conn.exec "CREATE INDEX IF NOT EXISTS idx_jobs_user_source_created_at ON jobs(user_id, source_url, created_at DESC)"
  end
rescue => e
  warn("DB schema bootstrap warning: #{e.class}: #{e.message}")
end

def normalize_tg_user_id(value)
  return nil if value.nil?
  numeric = value.to_s.strip
  return nil if numeric.empty?
  number = numeric.to_i
  number > 0 ? number : nil
end

def upsert_user(conn, tg_user_id, profile = {}, can_share: nil)
  return nil if tg_user_id.nil?

  now_checked = can_share.nil? ? nil : Time.now.utc
  result = conn.exec_params(
    <<~SQL,
      INSERT INTO users (
        telegram_user_id,
        username,
        first_name,
        last_name,
        language_code,
        has_story_access,
        story_access_checked_at,
        last_webapp_seen_at,
        updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW())
      ON CONFLICT (telegram_user_id)
      DO UPDATE SET
        username = COALESCE(EXCLUDED.username, users.username),
        first_name = COALESCE(EXCLUDED.first_name, users.first_name),
        last_name = COALESCE(EXCLUDED.last_name, users.last_name),
        language_code = COALESCE(EXCLUDED.language_code, users.language_code),
        has_story_access = COALESCE(EXCLUDED.has_story_access, users.has_story_access),
        story_access_checked_at = COALESCE(EXCLUDED.story_access_checked_at, users.story_access_checked_at),
        last_webapp_seen_at = NOW(),
        updated_at = NOW()
      RETURNING id
    SQL
    [
      tg_user_id,
      profile['username'],
      profile['first_name'],
      profile['last_name'],
      profile['language_code'],
      can_share,
      now_checked
    ]
  )
  row = result.first
  row && row['id'] ? row['id'].to_i : nil
rescue => _e
  nil
end

def find_latest_user_job(conn, user_id, source_url)
  return nil if user_id.nil? || source_url.nil? || source_url.empty?

  conn.exec_params(
    <<~SQL,
      SELECT sidekiq_jid, status, stage, progress_percent, metadata->>'output' AS output
      FROM jobs
      WHERE user_id = $1
        AND source_url = $2
        AND status IN ('queued', 'processing', 'done')
      ORDER BY created_at DESC
      LIMIT 1
    SQL
    [user_id, source_url]
  ).first
end

ensure_runtime_schema

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

server.mount_proc '/user_state' do |req, res|
  begin
    tg_user_id = normalize_tg_user_id(req.query['tg_user_id'])
    source_url = req.query['url'].to_s
    if tg_user_id.nil?
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'missing tg_user_id' }.to_json)
      next
    end

    payload = { ok: true, can_share: false, job_id: nil, status: nil, progress: nil, stage: nil }

    if db_available?
      with_db do |conn|
        user_row = conn.exec_params(
          'SELECT id, COALESCE(has_story_access, FALSE) AS has_story_access FROM users WHERE telegram_user_id = $1 LIMIT 1',
          [tg_user_id]
        ).first

        if user_row
          payload[:can_share] = (user_row['has_story_access'] == 't')
          latest = find_latest_user_job(conn, user_row['id'].to_i, source_url)
          if latest
            payload[:job_id] = latest['sidekiq_jid']
            payload[:status] = latest['status']
            payload[:progress] = latest['progress_percent']&.to_i
            payload[:stage] = latest['stage']
            payload[:output] = latest['output']
          end
        end
      end
    end

    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body = payload.to_json
  rescue => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false, error: e.message }.to_json)
  end
end

server.mount_proc '/resume' do |req, res|
  begin
    source_url = req.query['url'].to_s
    tg_user_id = normalize_tg_user_id(req.query['tg_user_id'])

    base_check = '/check_publish?url=' + URI.encode_www_form_component(source_url)
    base_check += '&tg_user_id=' + URI.encode_www_form_component(tg_user_id.to_s) if tg_user_id
    target = base_check

    if db_available? && tg_user_id && !source_url.empty?
      with_db do |conn|
        user_row = conn.exec_params(
          'SELECT id, COALESCE(has_story_access, FALSE) AS has_story_access FROM users WHERE telegram_user_id = $1 LIMIT 1',
          [tg_user_id]
        ).first

        if user_row
          latest = find_latest_user_job(conn, user_row['id'].to_i, source_url)
          if latest && latest['sidekiq_jid']
            target = '/publish?job_id=' + URI.encode_www_form_component(latest['sidekiq_jid'])
          elsif user_row['has_story_access'] == 't'
            target = base_check + '&trusted=1'
          end
        end
      end
    end

    res.status = 302
    res['Location'] = target
    res.body = ''
  rescue => e
    server.logger.error("RESUME_ERR #{e.class}: #{e.message}")
    fallback = '/check_publish?url=' + URI.encode_www_form_component(req.query['url'].to_s)
    res.status = 302
    res['Location'] = fallback
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
    tg_user_id = normalize_tg_user_id(data['tg_user_id'])
    can_share = if data.key?('can_share')
      data['can_share'] == true
    else
      nil
    end

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

    reused_job = nil
    user_id = nil
    if db_available? && tg_user_id
      with_db do |conn|
        user_id = upsert_user(conn, tg_user_id, data, can_share: can_share)
        reused_job = find_latest_user_job(conn, user_id, youtube_url)
      end
    end

    if reused_job
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body =({
        job_id: reused_job['sidekiq_jid'],
        status: reused_job['status'],
        reused: true,
        progress: reused_job['progress_percent']&.to_i,
        stage: reused_job['stage']
      }.to_json)
      next
    end

    jid = ProcessWorker.perform_async(youtube_url, tg_user_id)

    if db_available?
      begin
        with_db do |conn|
          user_id ||= upsert_user(conn, tg_user_id, data, can_share: can_share) if tg_user_id
          if user_id
            conn.exec_params(
              <<~SQL,
                INSERT INTO jobs (user_id, sidekiq_jid, source_url, status, stage, progress_percent, metadata, created_at, updated_at)
                VALUES ($1, $2, $3, 'queued', 'queued', 0, '{}'::jsonb, NOW(), NOW())
                ON CONFLICT (sidekiq_jid)
                DO NOTHING
              SQL
              [user_id, jid, youtube_url]
            )
          end
        end
      rescue => e
        server.logger.error("PROCESS_DB_WRITE_ERR #{e.class}: #{e.message}")
      end
    end

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

    if db_available?
      begin
        db_row = nil
        with_db do |conn|
          db_row = conn.exec_params(
            "SELECT status, progress_percent, stage, metadata->>'output' AS output, error_message FROM jobs WHERE sidekiq_jid = $1 LIMIT 1",
            [job_id]
          ).first
        end

        if db_row
          payload = {
            status: db_row['status'],
            progress: db_row['progress_percent']&.to_i,
            stage: db_row['stage'],
            output: db_row['output'],
            error: db_row['error_message']
          }
          payload[:progress] = 100 if payload[:status] == 'done'
          res.status = 200
          res['Content-Type'] = 'application/json'
          res.body = payload.to_json
          next
        end
      rescue => e
        server.logger.error("JOB_STATUS_DB_READ_ERR #{e.class}: #{e.message}")
      end
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

          .preview {
            display: flex;
            align-items: center;
            gap: 16px;
          }

          .preview video {
            width: 280px;
            height: 280px;
            flex-shrink: 0;
            border-radius: 18px;
            background: #0c0c0c;
            box-shadow: 0 18px 40px rgba(17, 18, 16, 0.2);
          }

          .preview-controls {
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: 12px;
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

          @media (max-width: 680px) {
            .preview {
              flex-direction: column;
              align-items: stretch;
            }
            .preview video {
              width: 100%;
              height: auto;
              max-height: 320px;
            }
            .preview-controls {
              flex: none;
            }
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
            </div>

            <div id="progressWrap" class="progress">
              <div class="progress-track">
                <div id="progressBar" class="progress-bar"></div>
              </div>
              <div id="progressText" class="progress-text"></div>
            </div>

            <div id="preview" class="preview"></div>

            <div class="preview-controls">
              <div id="note" class="note"></div>
              <div class="actions">
                <a id="downloadLink" class="btn ghost" href="#" style="display:none">Скачать видео</a>
                <button id="copyLink" class="btn ghost" style="display:none">Скопировать ссылку</button>
                <button id="publishBtn" class="btn primary" style="display:none">Опубликовать</button>
              </div>
            </div>
          </section>

          <div class="foot">Если редактор не открылся автоматически, нажмите кнопку вручную.</div>
        </main>
        <script>
          const jobId = "#{job_id}";
          const statusEl = document.getElementById('status');
          const previewEl = document.getElementById('preview');
          const publishBtn = document.getElementById('publishBtn');
          const progressWrap = document.getElementById('progressWrap');
          const progressBar = document.getElementById('progressBar');
          const progressText = document.getElementById('progressText');
          let progressPct = 0;
          let startedAt = Date.now();
          let videoUrl = null;

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
                videoUrl = src;
                previewEl.innerHTML = '';
                publishBtn.style.display = 'inline-block';
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
