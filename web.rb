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

server.mount_proc '/publish_app.js' do |req, res|
  begin
    server.logger.info "REQ /publish_app.js from #{req.remote_ip} headers=#{req.header.inspect}"
    path = File.join(Dir.pwd, 'web_public', 'publish_app.js')
    body = File.read(path)
    res.status = 200
    res['Content-Type'] = 'application/javascript'
    res['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    res['Pragma'] = 'no-cache'
    res['Expires'] = '0'
    res.body = body
  rescue => e
    server.logger.error "ERR_SERVE_PUBLISH_APPJS #{e.message}"
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

    target = '/publish?url=' + URI.encode_www_form_component(source_url)
    target += '&tg_user_id=' + URI.encode_www_form_component(tg_user_id.to_s) if tg_user_id

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
          end
        end
      end
    end

    res.status = 302
    res['Location'] = target
    res.body = ''
  rescue => e
    server.logger.error("RESUME_ERR #{e.class}: #{e.message}")
    fallback = '/publish?url=' + URI.encode_www_form_component(req.query['url'].to_s)
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

def parse_iso8601_duration(iso_duration)
  return nil unless iso_duration && iso_duration.start_with?('PT')

  # Parse ISO 8601 duration like PT4M13S or PT1H2M3S
  duration_str = iso_duration[2..-1] # Remove PT prefix
  hours = 0
  minutes = 0
  seconds = 0

  if duration_str =~ /(\d+)H/
    hours = $1.to_i
    duration_str = duration_str.sub(/\d+H/, '')
  end

  if duration_str =~ /(\d+)M/
    minutes = $1.to_i
    duration_str = duration_str.sub(/\d+M/, '')
  end

  if duration_str =~ /(\d+(?:\.\d+)?)S/
    seconds = $1.to_f
  end

  total = hours * 3600 + minutes * 60 + seconds
  total > 0 ? total : nil
rescue => e
  server.logger.warn("parse_iso8601_duration failed: #{e}")
  nil
end

def probe_youtube_duration_via_api(video_id)
  api_key = ENV['YOUTUBE_API_KEY']
  return nil unless api_key && !api_key.empty?

  uri = URI("https://www.googleapis.com/youtube/v3/videos?id=#{video_id}&part=contentDetails,snippet&key=#{api_key}")
  response = Net::HTTP.get_response(uri)
  return nil unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  return nil unless data['items'] && data['items'].any?

  item = data['items'][0]
  iso_duration = item.dig('contentDetails', 'duration')
  title = item.dig('snippet', 'title')
  { duration: parse_iso8601_duration(iso_duration), title: title }
rescue => e
  server.logger.warn("probe_youtube_duration_via_api failed: #{e}")
  nil
end

def probe_youtube_duration_yt_dlp(youtube_url)
  return nil unless command_exists?('yt-dlp')

  cmd = ['yt-dlp', '--no-playlist', '--skip-download', '--print', 'duration', youtube_url]
  stdout, _stderr, status = Open3.capture3(*cmd)
  return nil unless status && status.success?

  line = stdout.to_s.each_line.map(&:strip).find { |value| !value.empty? }
  return nil unless line

  duration = line.to_f
  return nil unless duration.positive?

  duration
rescue => e
  server.logger.warn("probe_youtube_duration_yt_dlp failed: #{e}")
  nil
end

def probe_youtube_duration(youtube_url)
  video_id = extract_youtube_id(youtube_url)
  
  # Try API first (faster and more reliable)
  if video_id
    info = probe_youtube_duration_via_api(video_id)
    return info if info
  end

  # Fallback to yt-dlp
  dur = probe_youtube_duration_yt_dlp(youtube_url)
  return { duration: dur, title: nil } if dur
  nil
end

def extract_youtube_id(url)
  case url
  when /(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/
    $1
  when /youtube\.com\/embed\/([a-zA-Z0-9_-]{11})/
    $1
  else
    nil
  end
end

def build_segments_from_duration(detected_duration, segment_length)
  segments = []

  if detected_duration && detected_duration > 0
    cursor = 0.0
    index = 1
    while cursor < detected_duration
      duration_sec = [segment_length, detected_duration - cursor].min
      segments << {
        'index' => index,
        'start_sec' => cursor.round(3),
        'duration_sec' => duration_sec.round(3),
        'status' => 'queued',
        'progress' => 0
      }
      cursor += segment_length
      index += 1
    end
  end

  if segments.empty?
    segments << {
      'index' => 1,
      'start_sec' => 0.0,
      'duration_sec' => segment_length,
      'status' => 'queued',
      'progress' => 0
    }
  end

  segments
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

    unless can_share == true
      res.status = 403
      res['Content-Type'] = 'application/json'
      res.body =({ error: 'story publish permission required' }.to_json)
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

    # Probe video info (duration + title) and pre-compute parts before job starts
    prefetched = probe_youtube_duration(youtube_url)
    # normalize prefetched into duration and title
    prefetched_duration = nil
    prefetched_title = nil
    if prefetched.is_a?(Hash)
      prefetched_duration = prefetched[:duration] || prefetched['duration']
      prefetched_title = prefetched[:title] || prefetched['title']
    else
      prefetched_duration = prefetched
    end

    video_id = extract_youtube_id(youtube_url)
    segment_length = ENV['STORY_MAX_SECONDS'].to_i
    segment_length = 60 if segment_length <= 0
    segments = build_segments_from_duration(prefetched_duration, segment_length.to_f)

    initial_metadata = {}
    initial_metadata['parts'] = JSON.generate(segments) if segments && segments.any?
    initial_metadata['video_id'] = video_id if video_id
    initial_metadata['title'] = prefetched_title if prefetched_title
    metadata_json = JSON.generate(initial_metadata)

    if db_available?
      begin
        with_db do |conn|
          user_id ||= upsert_user(conn, tg_user_id, data, can_share: can_share) if tg_user_id
          if user_id
            conn.exec_params(
              <<~SQL,
                INSERT INTO jobs (user_id, sidekiq_jid, source_url, status, stage, progress_percent, metadata, created_at, updated_at)
                VALUES ($1, $2, $3, 'queued', 'queued', 0, $4::jsonb, NOW(), NOW())
                ON CONFLICT (sidekiq_jid)
                DO NOTHING
              SQL
              [user_id, jid, youtube_url, metadata_json]
            )
          end
        end
      rescue => e
        server.logger.error("PROCESS_DB_WRITE_ERR #{e.class}: #{e.message}")
      end
    end

    res.status = 202
    res['Content-Type'] = 'application/json'
    resp_body = { job_id: jid, status: 'queued' }
    resp_body[:title] = prefetched_title if prefetched_title
    res.body = resp_body.to_json
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
            "SELECT jobs.status, jobs.progress_percent, jobs.stage, jobs.metadata->>'output' AS output, jobs.metadata->>'video_id' AS video_id, jobs.metadata->>'parts' AS parts, jobs.metadata->'bot_message' AS bot_message, jobs.metadata->>'title' AS title, jobs.error_message, jobs.started_at, users.telegram_user_id AS tg_user_id FROM jobs JOIN users ON users.id = jobs.user_id WHERE jobs.sidekiq_jid = $1 LIMIT 1",
            [job_id]
          ).first
        end

        if db_row
          parts = nil
          begin
            parts = JSON.parse(db_row['parts']) if db_row['parts']
          rescue
            parts = nil
          end

          bot_message = nil
          begin
            bot_message = JSON.parse(db_row['bot_message']) if db_row['bot_message']
          rescue
            bot_message = nil
          end

          payload = {
            status: db_row['status'],
            progress: db_row['progress_percent']&.to_i,
            stage: db_row['stage'],
            output: db_row['output'],
            video_id: db_row['video_id'],
              title: db_row['title'],
            parts: parts,
            error: db_row['error_message'],
            started_at: db_row['started_at'],
            tg_user_id: db_row['tg_user_id'],
            bot_message: bot_message
          }
          payload[:progress] = 100 if payload[:status] == 'done'

          # Try to notify/edit bot message with progress if job metadata has bot_message mapping
          begin
            if payload[:bot_message] && payload[:bot_message].is_a?(Hash) && payload[:progress]
              mapping = payload[:bot_message]
              if mapping['chat_id'] && mapping['message_id']
                token = ENV['TELEGRAM_BOT_TOKEN'] || ENV['TELEGRAM_TOKEN'] || ENV['BOT_TOKEN']
                if token
                  api_base = "https://api.telegram.org/bot#{token}"
                  caption = "🎬 Готово к публикации #{payload[:progress]}%"
                  begin
                    uri = URI.parse(api_base + "/editMessageCaption")
                    req = Net::HTTP::Post.new(uri)
                    req.set_form_data({ chat_id: mapping['chat_id'], message_id: mapping['message_id'], caption: caption })
                    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
                      resp = http.request(req)
                      begin
                        body = resp.body.to_s
                        parsed = JSON.parse(body) rescue nil
                        unless resp.is_a?(Net::HTTPSuccess) && parsed && parsed['ok']
                          server.logger.error("TELEGRAM_EDIT_RESPONSE editMessageCaption code=#{resp.code} body=#{body}")
                        end
                      rescue => e
                        server.logger.error("TELEGRAM_EDIT_LOG_ERR #{e.class}: #{e.message}")
                      end
                    end
                  rescue => e
                    begin
                      uri2 = URI.parse(api_base + "/editMessageText")
                      req2 = Net::HTTP::Post.new(uri2)
                      req2.set_form_data({ chat_id: mapping['chat_id'], message_id: mapping['message_id'], text: caption })
                      Net::HTTP.start(uri2.hostname, uri2.port, use_ssl: uri2.scheme == 'https') do |http|
                        resp2 = http.request(req2)
                        begin
                          body2 = resp2.body.to_s
                          parsed2 = JSON.parse(body2) rescue nil
                          unless resp2.is_a?(Net::HTTPSuccess) && parsed2 && parsed2['ok']
                            server.logger.error("TELEGRAM_EDIT_RESPONSE editMessageText code=#{resp2.code} body=#{body2}")
                          end
                        rescue => e2
                          server.logger.error("TELEGRAM_EDIT_LOG_ERR #{e2.class}: #{e2.message}")
                        end
                      end
                    rescue => e2
                      server.logger.error("TELEGRAM_EDIT_ERR #{e2.class}: #{e2.message}")
                    end
                  end
                end
              end
            end
          rescue => e
            server.logger.error("NOTIFY_BOT_ERR #{e.class}: #{e.message}")
          end

          res.status = 200
          res['Content-Type'] = 'application/json'
          res.body = payload.to_json
          next
        end
      rescue => e
        server.logger.error("JOB_STATUS_DB_READ_ERR #{e.class}: #{e.message}")
      end
    end

    # If not found in DB, return processing state
    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ status: 'processing', progress: nil, stage: nil }.to_json)
  rescue => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ error: e.message }.to_json)
  end
end

server.mount_proc '/publish' do |req, res|
  begin
    job_id = req.query['job_id']
    source_url = req.query['url'].to_s
    tg_user_id = normalize_tg_user_id(req.query['tg_user_id'])
    trusted = req.query['trusted'].to_s == '1'

    job_id_js = (job_id || '').to_json
    source_url_js = source_url.to_json
    tg_user_id_js = (tg_user_id || '').to_json
    chat_id_js = (req.query['chat_id'] || '').to_json
    message_id_js = (req.query['message_id'] || '').to_json
    chat_id_from_query_js = (req.query['chat_id'] || '').to_json
    message_id_from_query_js = (req.query['message_id'] || '').to_json
    trusted_js = trusted.to_json
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
            --paper: #fffaf9;
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
            background: linear-gradient(180deg, #fff4f2 0%, var(--paper) 100%);
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
            background: radial-gradient(circle, rgba(246,92,55,0.35), rgba(246,92,55,0));
            top: -140px;
            right: -140px;
          }

          body::after {
            background: radial-gradient(circle, rgba(226,111,86,0.28), rgba(226,111,86,0));
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
            background: linear-gradient(90deg, #f65c37 0%, #fbbf7c 60%, #ffd8be 100%);
            border-radius: 999px;
            box-shadow: 0 1px 4px rgba(246,92,55,0.08);
            transition: width 280ms cubic-bezier(.4,1,.7,1);
          }

          .progress-text {
            margin-top: 8px;
            font-size: 13px;
            color: var(--muted);
          }

          .preview {
            display: block;
          }

          .part-list {
            display: grid;
            gap: 14px;
          }

          .part-card {
            border: 1px solid var(--line);
            border-radius: 16px;
            padding: 12px;
            background: rgba(255,255,255,0.8);
            display: grid;
            gap: 10px;
          }

          .part-head {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 8px;
          }

          .part-title {
            font-size: 14px;
            font-weight: 600;
          }

          .part-status {
            font-size: 12px;
            color: var(--muted);
          }

          .part-video {
            width: 100%;
            border-radius: 14px;
            background: #0c0c0c;
            max-height: 320px;
            object-fit: cover;
          }

          .part-progress-track {
            height: 8px;
            background: rgba(17, 18, 16, 0.08);
            border-radius: 999px;
            overflow: hidden;
          }

          .part-progress-bar {
            height: 100%;
            width: 0%;
            background: linear-gradient(90deg, #f65c37 0%, #fbbf7c 60%, #ffd8be 100%);
            border-radius: 999px;
            box-shadow: 0 1px 4px rgba(246,92,55,0.08);
            transition: width 280ms cubic-bezier(.4,1,.7,1);
          }

          .part-actions {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
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
            box-shadow: 0 16px 30px rgba(46,164,230,0.18);
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

          .gate-wrap {
            min-height: 180px;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            gap: 12px;
            text-align: center;
          }

          .spinner {
            width: 34px;
            height: 34px;
            border-radius: 50%;
            border: 3px solid rgba(46,164,230,0.14);
            border-top-color: var(--accent);
            animation: spin 0.8s linear infinite;
          }

          .gate-text {
            font-size: 14px;
            color: var(--muted);
          }

          .denied-wrap {
            min-height: 180px;
            display: none;
            align-items: center;
            justify-content: center;
            text-align: center;
            font-size: 16px;
            font-weight: 600;
            color: #c65b5b;
          }

          #publishContent {
            display: none;
          }

          @keyframes rise {
            from { opacity: 0; transform: translateY(12px); }
            to { opacity: 1; transform: translateY(0); }
          }

          @keyframes drift {
            0%, 100% { transform: translate(0, 0); }
            50% { transform: translate(-14px, 10px); }
          }

          @keyframes spin {
            to { transform: rotate(360deg); }
          }
        </style>
        <script src="https://telegram.org/js/telegram-web-app.js?59"></script>
      </head>
      <body>
        <main class="shell">
          <header class="hero">
            <div class="eyebrow" id="videoTitle">YOUTUBE TO STORY</div>
            <h1>История готовится</h1>
            <p>Мы проверим статус обработки и откроем редактор в Telegram, когда файл будет готов.</p>
          </header>
          <section class="card">
            <div id="gateWrap" class="gate-wrap">
              <div class="spinner"></div>
              <div id="gateText" class="gate-text">Загрузка</div>
            </div>

            <div id="denyWrap" class="denied-wrap"></div>

              <div id="publishContent">
              <div class="status-row">
                <div>
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
              <div id="note" class="note"></div>
            </div>
          </section>
        </main>
          <script type="text/plain" id="publish-inline-legacy">
          let jobId = #{job_id_js};
          const sourceUrl = #{source_url_js};
          const tgUserIdFromQuery = #{tg_user_id_js};
          const chatIdFromQuery = #{chat_id_js};
          const messageIdFromQuery = #{message_id_js};
          const trustedFromQuery = #{trusted_js};
          const host = "#{HOST}";
          const gateWrapEl = document.getElementById('gateWrap');
          const gateTextEl = document.getElementById('gateText');
          const denyWrapEl = document.getElementById('denyWrap');
          const publishContentEl = document.getElementById('publishContent');
          const statusEl = document.getElementById('status');
          const previewEl = document.getElementById('preview');
          const noteEl = document.getElementById('note');
          const progressWrap = document.getElementById('progressWrap');
          const progressBar = document.getElementById('progressBar');
          const progressText = document.getElementById('progressText');
          let gateFailsafeTimer = null;
          let progressPct = 0;
          let startedAt = Date.now();
          let startedAtSynced = false;
          let lastPartsSignature = null;

          try {
            if (window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.ready === 'function') {
              window.Telegram.WebApp.ready();
              if (typeof window.Telegram.WebApp.expand === 'function') {
                window.Telegram.WebApp.expand();
              }
            }
          } catch (e) {}

          function armGateFailsafe(){
            if (gateFailsafeTimer) clearTimeout(gateFailsafeTimer);
            gateFailsafeTimer = setTimeout(() => {
              try {
                const gateVisible = gateWrapEl && window.getComputedStyle(gateWrapEl).display !== 'none';
                const denyVisible = denyWrapEl && window.getComputedStyle(denyWrapEl).display !== 'none';
                const contentVisible = publishContentEl && window.getComputedStyle(publishContentEl).display !== 'none';
                if (gateVisible && !denyVisible && !contentVisible) {
                  showDenied('Не удалось инициализировать экран. Попробуйте открыть заново.');
                }
              } catch (e) {}
            }, 20000);
          }

          function clearGateFailsafe(){
            if (gateFailsafeTimer) {
              clearTimeout(gateFailsafeTimer);
              gateFailsafeTimer = null;
            }
          }

          function showGate(text){
            gateWrapEl.style.display = 'flex';
            gateTextEl.innerText = text || 'Загрузка';
            denyWrapEl.style.display = 'none';
            publishContentEl.style.display = 'none';
          }

          function showContent(){
            clearGateFailsafe();
            gateWrapEl.style.display = 'none';
            denyWrapEl.style.display = 'none';
            publishContentEl.style.display = 'block';
          }

          function showDenied(text){
            clearGateFailsafe();
            gateWrapEl.style.display = 'none';
            publishContentEl.style.display = 'none';
            denyWrapEl.style.display = 'flex';
            denyWrapEl.innerText = text || 'Публикация историй недоступна.';
          }

          function parseTelegramProfile(){
            try {
              if (!(window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.initDataUnsafe && window.Telegram.WebApp.initDataUnsafe.user)) {
                return {};
              }
              const user = window.Telegram.WebApp.initDataUnsafe.user || {};
              return {
                tg_user_id: user.id || null,
                username: user.username || null,
                first_name: user.first_name || null,
                last_name: user.last_name || null,
                language_code: user.language_code || null
              };
            } catch (e) {
              return {};
            }
          }

          function normalizeTgUserId(value){
            if (value === null || value === undefined) return null;
            const asString = String(value).trim();
            if (!asString) return null;
            const asNumber = Number(asString);
            if (!Number.isFinite(asNumber) || asNumber <= 0) return null;
            return String(Math.trunc(asNumber));
          }

          function startProcessing(tgProfile){
            try {
              if (!sourceUrl) {
                showDenied('Не найдена ссылка на YouTube.');
                return;
              }

              showGate('Запускаем обработку...');
              const payload = {
                url: sourceUrl,
                can_share: true,
                tg_user_id: normalizeTgUserId((tgProfile && tgProfile.tg_user_id) || tgUserIdFromQuery)
              };
              if (tgProfile && tgProfile.username) payload.username = tgProfile.username;
              if (tgProfile && tgProfile.first_name) payload.first_name = tgProfile.first_name;
              if (tgProfile && tgProfile.last_name) payload.last_name = tgProfile.last_name;
              if (tgProfile && tgProfile.language_code) payload.language_code = tgProfile.language_code;

              const fetchOptions = {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
              };

              let processTimeout = null;
              let processRequest = null;

              if (typeof AbortController === 'function') {
                const abortController = new AbortController();
                processTimeout = setTimeout(() => abortController.abort(), 15000);
                fetchOptions.signal = abortController.signal;
                processRequest = fetch('/process', fetchOptions);
              } else {
                processRequest = Promise.race([
                  fetch('/process', fetchOptions),
                  new Promise((_, reject) => {
                    processTimeout = setTimeout(() => reject(new Error('timeout')), 15000);
                  })
                ]);
              }

              processRequest
                .then(r=>r.json().then(data => ({ ok: r.ok, data })))
                .then(({ ok, data }) => {
                  if (processTimeout) clearTimeout(processTimeout);
                  if (!ok || !data || data.error) {
                    showDenied('Не удалось запустить обработку.');
                    return;
                  }

                  const nextJobId = data.job_id || data.id;
                  if (!nextJobId) {
                    showDenied('Сервер вернул неполный ответ.');
                    return;
                  }

                  jobId = String(nextJobId);
                  // If the embed was opened from a bot message and contains chat/message id,
                  // attach the bot message mapping to the job so the server can edit it.
                  try {
                    if (chatIdFromQuery && messageIdFromQuery) {
                      fetch('/admin/attach_bot_message', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ job_id: jobId, chat_id: chatIdFromQuery, message_id: messageIdFromQuery })
                      }).catch(e=>{console.error('attach_bot_message failed', e)});
                    }
                  } catch (e) { console.error(e) }

                  showContent();
                  check();
                })
                .catch((e) => {
                  if (processTimeout) clearTimeout(processTimeout);
                  console.error(e);
                  showDenied('Ошибка сети при запуске обработки.');
                });
            } catch (e) {
              console.error(e);
              showDenied('Ошибка запуска обработки.');
            }
          }

          function waitForTelegramWebApp(timeoutMs){
            return new Promise((resolve) => {
              const start = Date.now();
              function tick(){
                try {
                  if (window.Telegram && window.Telegram.WebApp) {
                    resolve(true);
                    return;
                  }
                  if (Date.now() - start >= timeoutMs) {
                    resolve(false);
                    return;
                  }
                } catch (e) {
                  // Ignore errors, continue polling
                }
                setTimeout(tick, 120);
              }
              tick();
            });
          }

          async function runPublishFlow(){
            const hasWebApp = await waitForTelegramWebApp(4500);
            if (!hasWebApp) {
              showDenied('Откройте эту страницу внутри Telegram.');
              return;
            }

            let canShare = !!(window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.shareToStory === 'function');
            if (!canShare) {
              showGate('Загрузка');
              await new Promise(resolve => setTimeout(resolve, 2000));
              canShare = !!(window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.shareToStory === 'function');
            }

            if (!canShare) {
              showDenied('Публикация историй недоступна для этого аккаунта.');
              return;
            }

            if (jobId) {
              showContent();
              check();
              return;
            }

            const tgProfile = parseTelegramProfile();
            startProcessing(tgProfile);
          }

          function showProgress(){
            progressWrap.style.display = 'block';
          }

          function topStageLabel(stage, done){
            if (done) return 'Готово';
            switch(stage){
              case 'starting':
              case 'downloading':
              case 'downloaded':
                return 'Подготовка (скачивание видео)';
              case 'segmenting':
                return 'Подготовка (нарезка на ролики)';
              case 'transcoding':
                return 'Обработка роликов';
              case 'finalizing':
                return 'Финализация';
              case 'failed':
                return 'Ошибка обработки';
              default:
                return 'Обработка';
            }
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
            const stageText = topStageLabel(stage, done);
            progressText.innerText = stageText + ' · ' + progressPct + '% (' + elapsed + 's)';
          }

          function setPreviewFromVideoId(videoId){
            if (!videoId) return;
            if (previewEl.dataset.previewSet === '1' && previewEl.children.length > 0) return;
            const posterSrc = 'https://img.youtube.com/vi/' + videoId + '/maxresdefault.jpg';
            const posterFallback = 'https://img.youtube.com/vi/' + videoId + '/hqdefault.jpg';
            previewEl.innerHTML = '<img src="'+posterSrc+'" alt="preview" onerror="this.onerror=null;this.src=\'' + posterFallback + '\'" style="width:100%;border-radius:18px;background:#0c0c0c">';
            previewEl.dataset.previewSet = '1';
          }

          function shareStory(url){
            try {
              if (window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.shareToStory) {
                window.Telegram.WebApp.shareToStory(url);
                statusEl.innerText = 'Открыт редактор историй.';
              } else {
                alert('Publishing via Telegram WebApp is available only inside Telegram.');
              }
            } catch(e){ console.error(e); alert('Ошибка публикации: ' + e.message) }
          }

          function normalizeParts(parts, fallbackOutput){
            if (Array.isArray(parts) && parts.length > 0) {
              return parts
                .map((part, idx) => {
                  const normalizedIndex = Number(part && part.index);
                  return Object.assign({}, part || {}, {
                    index: Number.isFinite(normalizedIndex) ? normalizedIndex : (idx + 1)
                  });
                })
                .sort((a, b) => {
                  const indexA = Number(a.index) || 0;
                  const indexB = Number(b.index) || 0;
                  if (indexA !== indexB) return indexA - indexB;
                  const startA = Number(a.start_sec);
                  const startB = Number(b.start_sec);
                  if (Number.isFinite(startA) && Number.isFinite(startB)) return startA - startB;
                  return 0;
                });
            }
            if (fallbackOutput) return [{ index: 1, status: 'done', output: fallbackOutput }];
            return [];
          }

          function formatClock(totalSeconds){
            const sec = Math.max(0, Math.floor(Number(totalSeconds) || 0));
            const h = Math.floor(sec / 3600);
            const m = Math.floor((sec % 3600) / 60);
            const s = sec % 60;
            if (h > 0) {
              return String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
            }
            return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
          }

          function partRangeLabel(part){
            const start = Number(part.start_sec);
            const duration = Number(part.duration_sec);
            if (!Number.isFinite(start) || !Number.isFinite(duration) || duration <= 0) return '';
            const from = formatClock(start);
            const to = formatClock(start + duration);
            return from + '–' + to;
          }

          function renderParts(parts, videoId, fallbackOutput){
            const normalized = normalizeParts(parts, fallbackOutput);
            if (normalized.length === 0) {
              noteEl.innerText = '';
              setPreviewFromVideoId(videoId);
              return;
            }

            const signature = JSON.stringify(normalized.map(part => [part.index, part.status, part.output, part.progress]));
            if (signature === lastPartsSignature) return;
            lastPartsSignature = signature;

            const thumb = videoId ? ('https://img.youtube.com/vi/' + videoId + '/maxresdefault.jpg') : '';
            const thumbFallback = videoId ? ('https://img.youtube.com/vi/' + videoId + '/hqdefault.jpg') : '';
            previewEl.innerHTML = '<div class="part-list">' + normalized.map((part, idx) => {
              const partIndex = part.index || (idx + 1);
              const hasOutput = !!part.output;
              const status = part.status || (hasOutput ? 'done' : 'processing');
              const progress = Math.max(0, Math.min(100, Number(part.progress || (hasOutput ? 100 : 0))));
              const statusText = status === 'done'
                ? 'готово'
                : (status === 'failed' ? 'ошибка' : (status === 'queued' ? 'в очереди' : ('обработка ' + progress + '%')));
              const timeRange = partRangeLabel(part);
              const media = thumb ? '<img class="part-video" src="' + thumb + '" alt="preview" onerror="this.onerror=null;this.src=\'' + thumbFallback + '\'">' : '<div class="part-video"></div>';
              const action = hasOutput
                ? '<button class="btn primary publish-part" data-url="' + host + '/' + part.output + '">Опубликовать</button>'
                : '<button class="btn ghost" disabled>Готовится</button>';
              return '<div class="part-card">'
                + '<div class="part-head"><div class="part-title">Ролик #' + partIndex + (timeRange ? ' · ' + timeRange : '') + '</div><div class="part-status">' + statusText + '</div></div>'
                + '<div class="part-progress-track"><div class="part-progress-bar" style="width:' + progress + '%"></div></div>'
                + media
                + '<div class="part-actions">' + action + '</div>'
                + '</div>';
            }).join('') + '</div>';

            previewEl.querySelectorAll('.publish-part').forEach(btn => {
              btn.addEventListener('click', () => shareStory(btn.dataset.url));
            });

            const readyCount = normalized.filter(part => part.status === 'done' && !!part.output).length;
            noteEl.innerText = 'Частей: ' + normalized.length + ' · готово: ' + readyCount;
          }

          function check() {
            fetch('/job_status?job_id=' + encodeURIComponent(jobId)).then(r=>r.json()).then(j=>{
              if (!startedAtSynced && j.started_at) {
                const parsedStartedAt = Date.parse(j.started_at);
                if (!Number.isNaN(parsedStartedAt)) {
                  startedAt = parsedStartedAt;
                  startedAtSynced = true;
                }
              }
              renderParts(j.parts, j.video_id, j.output);
              if (j.status === 'done') {
                statusEl.innerText = 'Готово';
                updateProgress(true, 100, 'done');
                renderParts(j.parts, j.video_id, j.output);
              } else if (j.status === 'failed') {
                statusEl.innerText = 'Ошибка обработки';
                showProgress();
                updateProgress(false, j.progress, 'failed');
                if (j.error) {
                  noteEl.innerText = 'Ошибка: ' + j.error;
                }
              } else {
                const preparingStage = j.stage === 'starting' || j.stage === 'downloading' || j.stage === 'downloaded' || j.stage === 'segmenting';
                statusEl.innerText = preparingStage ? 'Подготовка...' : 'Обработка...';
                showProgress();
                updateProgress(false, j.progress, j.stage);
                setTimeout(check, 2000);
              }
            }).catch(e=>{statusEl.innerText='Ошибка'; console.error(e)});
          }

          if (trustedFromQuery) {
            if (jobId) {
              showContent();
              check();
            } else {
              armGateFailsafe();
              const tgProfile = parseTelegramProfile();
              startProcessing(tgProfile);
            }
          } else {
            showGate('Проверяем Telegram...');
            armGateFailsafe();
            runPublishFlow().catch((e) => {
              console.error(e);
              showDenied('Ошибка инициализации Telegram.');
            });
          }
        </script>
        <script>
          window.__Y2S_PUBLISH__ = {
            jobId: #{job_id_js},
            sourceUrl: #{source_url_js},
            tgUserIdFromQuery: #{tg_user_id_js},
            chatIdFromQuery: #{chat_id_from_query_js},
            messageIdFromQuery: #{message_id_from_query_js},
            trustedFromQuery: #{trusted_js},
            host: "#{HOST}"
          };
        </script>
        <script src="/publish_app.js?v=20260219_2208"></script>
      </body>
      </html>
    HTML

    res.status = 200
    res['Content-Type'] = 'text/html'
    res['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    res['Pragma'] = 'no-cache'
    res['Expires'] = '0'
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

server.mount_proc "/admin/attach_bot_message" do |req, res|
  begin
    body = req.body.to_s
    data = JSON.parse(body) rescue {}
    job_id = data['job_id']
    chat_id = data['chat_id']
    message_id = data['message_id']

    if job_id.nil? || chat_id.nil? || message_id.nil?
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body =({ ok: false, error: 'missing job_id/chat_id/message_id' }.to_json)
      next
    end

    if db_available?
      with_db do |conn|
        # Attach bot message mapping into jobs.metadata.bot_message
        begin
          mapping_json = { bot_message: { chat_id: chat_id, message_id: message_id } }.to_json
          updated = conn.exec_params("UPDATE jobs SET metadata = COALESCE(metadata, '{}'::jsonb) || $1::jsonb WHERE sidekiq_jid = $2", [mapping_json, job_id])
          if updated.cmd_tuples == 0
            res.status = 404
            res['Content-Type'] = 'application/json'
            res.body =({ ok: false, error: 'job not found' }.to_json)
            next
          end
        rescue => e
          server.logger.error("ATTACH_BOT_MSG_ERR #{e.class}: #{e.message}")
        end
      end
    end

    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ ok: true }.to_json)
  rescue => e
    server.logger.error "ADMIN_ATTACH_ERR #{e.class}: #{e.message}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false, error: e.message }.to_json)
  end
end

server.mount_proc "/admin/reset_user" do |req, res|
  begin
    body_str = req.body.to_s
    data = JSON.parse(body_str) if body_str.length > 0
    tg_user_id = data && data['tg_user_id'] ? normalize_tg_user_id(data['tg_user_id']) : nil
    username = data && data['username'] ? data['username'].to_s.strip.downcase : nil
    username = username[1..] if username && username.start_with?('@')
    username = nil if username && username.empty?

    if tg_user_id.nil? && username.nil?
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body =({ ok: false, error: 'missing tg_user_id or username' }.to_json)
      next
    end

    if db_available?
      with_db do |conn|
        # Fetch user by tg_user_id or username
        user_row = if tg_user_id
          conn.exec_params(
            'SELECT id, telegram_user_id, username FROM users WHERE telegram_user_id = $1 LIMIT 1',
            [tg_user_id]
          ).first
        else
          conn.exec_params(
            'SELECT id, telegram_user_id, username FROM users WHERE LOWER(username) = $1 LIMIT 1',
            [username]
          ).first
        end

        unless user_row
          res.status = 404
          res['Content-Type'] = 'application/json'
          target = tg_user_id ? "tg_user_id=#{tg_user_id}" : "username=#{username}"
          res.body =({ ok: false, error: "user not found (#{target})" }.to_json)
          next
        end

        user_id = user_row['id'].to_i
        effective_tg_user_id = user_row['telegram_user_id']
        effective_username = user_row['username']

        # Get all artifact paths for this user to delete files
        artifact_rows = conn.exec_params(
          'SELECT path FROM artifacts WHERE job_id IN (SELECT id FROM jobs WHERE user_id = $1)',
          [user_id]
        )

        # Delete all events for this user
        conn.exec_params('DELETE FROM events WHERE user_id = $1', [user_id])

        # Delete all artifacts for this user's jobs
        conn.exec_params('DELETE FROM artifacts WHERE job_id IN (SELECT id FROM jobs WHERE user_id = $1)', [user_id])

        # Delete all quotas for this user
        conn.exec_params('DELETE FROM quotas WHERE user_id = $1', [user_id])

        # Delete all jobs for this user
        conn.exec_params('DELETE FROM jobs WHERE user_id = $1', [user_id])

        # Update user but keep the record
        conn.exec_params(
          'UPDATE users SET has_story_access = NULL, story_access_checked_at = NULL, last_webapp_seen_at = NULL, updated_at = NOW() WHERE id = $1',
          [user_id]
        )

        # Delete artifact files from disk
        artifact_rows.each do |row|
          file_path = row['path']
          full_path = File.join(OUTPUT_DIR, file_path) if file_path
          if full_path && File.exist?(full_path)
            begin
              File.delete(full_path)
              server.logger.info("Deleted artifact file: #{full_path}")
            rescue => e
              server.logger.error("Failed to delete artifact file #{full_path}: #{e.message}")
            end
          end
        end

        server.logger.info("Reset user data: tg_user_id=#{effective_tg_user_id}, username=#{effective_username}, user_id=#{user_id}")
      end
    end

    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body =({ ok: true }.to_json)
  rescue => e
    server.logger.error "ADMIN_RESET_ERR #{e.class}: #{e.message}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body =({ ok: false, error: e.message }.to_json)
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
