require 'sidekiq'
require 'dotenv/load'
require 'open3'
require 'json'
require 'securerandom'
require 'fileutils'
require 'tmpdir'
require 'time'
require 'pg'
require 'net/http'
require 'uri'

class ProcessWorker
  include Sidekiq::Worker
  sidekiq_options retry: 3

  APP_ROOT = File.expand_path('..', __dir__)
  OUTPUT_DIR = File.join(APP_ROOT, 'web_public', 'outputs')
  STORY_MAX_SECONDS = begin
    value = ENV['STORY_MAX_SECONDS'].to_i
    value > 0 ? value : 60
  end
  FileUtils.mkdir_p(OUTPUT_DIR)

  def db_available?
    db_url = ENV['DATABASE_URL']
    !db_url.nil? && !db_url.empty?
  end

  def with_db
    return unless db_available?

    PG.connect(ENV['DATABASE_URL']) do |conn|
      yield conn
    end
  end

  def update_job_progress(percent, stage)
    return unless respond_to?(:jid) && jid

    with_db do |conn|
      conn.exec_params(
        <<~SQL,
          UPDATE jobs
          SET progress_percent = $1,
              stage = $2,
              status = 'processing',
              started_at = COALESCE(started_at, NOW()),
              updated_at = NOW()
          WHERE sidekiq_jid = $3
        SQL
        [percent.to_i, stage.to_s, jid]
      )
    end
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to update db progress for jid=#{jid}: #{e}")
  end

  def mark_job_done(output_rel, video_id = nil)
    return unless respond_to?(:jid) && jid

    with_db do |conn|
      metadata_expr = "COALESCE(metadata, '{}'::jsonb)"
      params = []
      idx = 1

      if output_rel
        metadata_expr = "jsonb_set(#{metadata_expr}, '{output}', to_jsonb($#{idx}::text), true)"
        params << output_rel
        idx += 1
      end

      if video_id
        metadata_expr = "jsonb_set(#{metadata_expr}, '{video_id}', to_jsonb($#{idx}::text), true)"
        params << video_id
        idx += 1
      end

      if block_given?
        parts_json = yield
        if parts_json
          metadata_expr = "jsonb_set(#{metadata_expr}, '{parts}', to_jsonb($#{idx}::text), true)"
          params << parts_json
          idx += 1
        end
      end

      params << jid
      jid_idx = idx

      conn.exec_params(
        <<~SQL,
          UPDATE jobs
          SET status = 'done',
              stage = 'done',
              progress_percent = 100,
              finished_at = NOW(),
              metadata = #{metadata_expr},
              updated_at = NOW()
          WHERE sidekiq_jid = $#{jid_idx}
        SQL
        params
      )
    end
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to mark db job done for jid=#{jid}: #{e}")
  end

  def mark_job_failed(error_message)
    return unless respond_to?(:jid) && jid

    with_db do |conn|
      conn.exec_params(
        <<~SQL,
          UPDATE jobs
          SET status = 'failed',
              stage = 'failed',
              finished_at = NOW(),
              error_message = $1,
              updated_at = NOW()
          WHERE sidekiq_jid = $2
        SQL
        [error_message.to_s[0, 4000], jid]
      )
    end
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to mark db job failed for jid=#{jid}: #{e}")
  end

  def store_video_id(video_id)
    return unless respond_to?(:jid) && jid
    return if video_id.nil? || video_id.to_s.empty?

    with_db do |conn|
      conn.exec_params(
        <<~SQL,
          UPDATE jobs
          SET metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{video_id}', to_jsonb($1::text), true),
              updated_at = NOW()
          WHERE sidekiq_jid = $2
        SQL
        [video_id.to_s, jid]
      )
    end
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to store video_id for jid=#{jid}: #{e}")
  end

  def write_progress(percent, stage)
    return unless respond_to?(:jid) && jid
    update_job_progress(percent, stage)
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to update progress for jid=#{jid}: #{e}")
  end

  def self.command_exists?(name)
    system("which #{name} > /dev/null 2>&1")
  end

  def probe_duration_seconds(file_path)
    return nil unless self.class.command_exists?('ffprobe')

    cmd = [
      'ffprobe', '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nokey=1:noprint_wrappers=1',
      file_path
    ]
    stdout, _stderr, status = Open3.capture3(*cmd)
    return nil unless status && status.success?

    duration = stdout.to_s.strip.to_f
    return nil unless duration.positive?

    duration
  rescue => e
    Sidekiq.logger.warn("ProcessWorker: ffprobe failed: #{e}")
    nil
  end

  def parse_iso8601_duration(iso_duration)
    return nil unless iso_duration && iso_duration.start_with?('PT')

    duration_str = iso_duration[2..-1]
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
    Sidekiq.logger.warn("ProcessWorker: parse_iso8601_duration failed: #{e}")
    nil
  end

  def probe_youtube_duration_via_api(video_id)
    api_key = ENV['YOUTUBE_API_KEY']
    return nil unless api_key && !api_key.empty?

    uri = URI("https://www.googleapis.com/youtube/v3/videos?id=#{video_id}&part=contentDetails&key=#{api_key}")
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    return nil unless data['items'] && data['items'].any?

    iso_duration = data.dig('items', 0, 'contentDetails', 'duration')
    parse_iso8601_duration(iso_duration)
  rescue => e
    Sidekiq.logger.warn("ProcessWorker: probe_youtube_duration_via_api failed: #{e}")
    nil
  end

  def probe_youtube_duration_yt_dlp(youtube_url)
    return nil unless self.class.command_exists?('yt-dlp')

    cmd = ['yt-dlp', '--no-playlist', '--skip-download', '--print', 'duration', youtube_url]
    stdout, _stderr, status = Open3.capture3(*cmd)
    return nil unless status && status.success?

    line = stdout.to_s.each_line.map(&:strip).find { |value| !value.empty? }
    return nil unless line

    duration = line.to_f
    return nil unless duration.positive?

    duration
  rescue => e
    Sidekiq.logger.warn("ProcessWorker: yt-dlp metadata duration probe failed: #{e}")
    nil
  end

  def probe_youtube_duration_seconds(youtube_url)
    video_id = extract_youtube_id(youtube_url)
    
    # Try API first (faster and more reliable)
    if video_id
      duration = probe_youtube_duration_via_api(video_id)
      return duration if duration
    end

    # Fallback to yt-dlp
    probe_youtube_duration_yt_dlp(youtube_url)
  end

  def build_segments(detected_duration, segment_length)
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

  def update_job_parts(parts)
    return unless respond_to?(:jid) && jid

    parts_json = JSON.generate(parts)
    with_db do |conn|
      conn.exec_params(
        <<~SQL,
          UPDATE jobs
          SET metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{parts}', to_jsonb($1::text), true),
              updated_at = NOW()
          WHERE sidekiq_jid = $2
        SQL
        [parts_json, jid]
      )
    end
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to update parts for jid=#{jid}: #{e}")
  end

  def extract_youtube_id(url)
    # Handle various YouTube URL formats
    case url
    when /(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/
      $1
    when /youtube\.com\/embed\/([a-zA-Z0-9_-]{11})/
      $1
    else
      nil
    end
  end

  def perform(youtube_url, _tg_user_id = nil)
    tmpdir = File.join(Dir.tmpdir || '/tmp', "y2s-#{SecureRandom.hex(6)}")
    Dir.mkdir(tmpdir) unless Dir.exist?(tmpdir)

    unless self.class.command_exists?('yt-dlp') && self.class.command_exists?('ffmpeg')
      raise "yt-dlp or ffmpeg not installed on host"
    end

    # Extract YouTube video ID for thumbnail
    video_id = extract_youtube_id(youtube_url)
    store_video_id(video_id) if video_id
    segment_length = STORY_MAX_SECONDS.to_f

    begin
      write_progress(5, 'downloading')

      prefetched_duration = probe_youtube_duration_seconds(youtube_url)
      segments = build_segments(prefetched_duration, segment_length)
      update_job_parts(segments)

      out_template = File.join(tmpdir, 'input.%(ext)s')
      cmd = ['yt-dlp', '--no-playlist', '-f', 'best', '-o', out_template, youtube_url]
      Sidekiq.logger.info("ProcessWorker: running yt-dlp: #{cmd.join(' ')}")
      begin
        stdout, stderr, status = Open3.capture3(*cmd)
      rescue Errno::ENOENT => e
        raise "yt-dlp not found: #{e.message}"
      end
      if status.nil?
        raise "yt-dlp failed to run: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      elsif !status.success?
        raise "yt-dlp failed: #{stderr} (exit=#{status.exitstatus})"
      end

      write_progress(25, 'downloaded')

      input_files = Dir.glob(File.join(tmpdir, '*'))
      input_file = input_files.first
      raise "downloaded file not found" unless input_file && File.exist?(input_file)

      detected_duration = probe_duration_seconds(input_file)
      if prefetched_duration.nil? && detected_duration && detected_duration > 0
        segments = build_segments(detected_duration, segment_length)
        update_job_parts(segments)
      end

      write_progress(30, 'segmenting')

      vf = 'scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2,format=yuv420p'
      first_output_rel = nil
      total_parts = segments.length
      last_parts_update_at = Time.now.to_f

      segments.each_with_index do |segment, part_idx|
        segment['status'] = 'processing'
        segment['progress'] = 0
        update_job_parts(segments)

        uuid = SecureRandom.uuid
        final_name = "#{uuid}-p#{(part_idx + 1).to_s.rjust(2, '0')}.mp4"
        final_path = File.join(OUTPUT_DIR, final_name)

        ff_cmd = [
          'ffmpeg', '-y', '-i', input_file,
          '-ss', segment['start_sec'].to_s,
          '-t', segment['duration_sec'].to_s,
          '-vf', vf,
          '-r', '30',
          '-c:v', 'libx264', '-profile:v', 'baseline', '-level', '3.1', '-preset', 'fast', '-crf', '28',
          '-movflags', '+faststart',
          '-c:a', 'aac', '-b:a', '96k',
          '-progress', 'pipe:1', '-nostats',
          final_path
        ]
        Sidekiq.logger.info("ProcessWorker: running ffmpeg part #{part_idx + 1}/#{total_parts}: #{ff_cmd.join(' ')}")

        part_ms = [1, (segment['duration_sec'].to_f * 1000).to_i].max
        last_report_at = Time.now.to_f
        fferr_lines = []
        ffstatus = nil

        begin
          Open3.popen3(*ff_cmd) do |stdin, stdout, stderr, wait_thr|
            stdin.close
            err_thread = Thread.new do
              stderr.each_line do |line|
                fferr_lines << line
                fferr_lines.shift if fferr_lines.size > 50
              end
            end

            stdout.each_line do |line|
              line = line.strip
              next unless line.start_with?('out_time_ms=')

              out_time_ms = line.split('=', 2)[1].to_i
              part_ratio = [[out_time_ms.to_f / part_ms, 0.0].max, 1.0].min
              part_progress = (part_ratio * 100).floor
              segment['progress'] = [segment['progress'].to_i, part_progress].max
              overall_ratio = (part_idx + part_ratio) / total_parts.to_f
              pct = 30 + (overall_ratio * 60).floor
              pct = [[pct, 30].max, 95].min

              now = Time.now.to_f
              if now - last_report_at >= 0.5
                write_progress(pct, 'transcoding')
                last_report_at = now
              end
              if now - last_parts_update_at >= 0.5
                update_job_parts(segments)
                last_parts_update_at = now
              end
            end

            ffstatus = wait_thr.value
            err_thread.join
          end
        rescue Errno::ENOENT => e
          raise "ffmpeg not found: #{e.message}"
        end

        if ffstatus.nil?
          raise "ffmpeg failed to run: stderr=#{fferr_lines.join}"
        elsif !ffstatus.success?
          segment['status'] = 'failed'
          segment['progress'] = 0
          update_job_parts(segments)
          raise "ffmpeg failed: #{fferr_lines.join} (exit=#{ffstatus.exitstatus})"
        end

        output_rel = "outputs/#{final_name}"
        segment['output'] = output_rel
        segment['status'] = 'done'
        segment['progress'] = 100
        first_output_rel ||= output_rel
        update_job_parts(segments)
      end

      write_progress(90, 'finalizing')

      output_rel = first_output_rel
      write_progress(100, 'done')
      mark_job_done(output_rel, video_id) { JSON.generate(segments) }

      output_rel
    rescue => e
      mark_job_failed(e.message)
      raise
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir && Dir.exist?(tmpdir)
    end
  end
end
