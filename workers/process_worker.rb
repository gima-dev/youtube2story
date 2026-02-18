require 'sidekiq'
require 'dotenv/load'
require 'open3'
require 'json'
require 'securerandom'
require 'fileutils'
require 'tmpdir'
require 'time'

class ProcessWorker
  include Sidekiq::Worker
  sidekiq_options retry: 3

  APP_ROOT = File.expand_path('..', __dir__)
  OUTPUT_DIR = File.join(APP_ROOT, 'web_public', 'outputs')
  FileUtils.mkdir_p(OUTPUT_DIR)

  def write_progress(percent, stage)
    return unless respond_to?(:jid) && jid
    payload = {
      percent: percent,
      stage: stage,
      updated_at: Time.now.utc.iso8601
    }
    File.write(File.join(OUTPUT_DIR, "#{jid}.progress.json"), payload.to_json)
  rescue => e
    Sidekiq.logger.error("ProcessWorker: failed to write progress for jid=#{jid}: #{e}")
  end

  def self.command_exists?(name)
    system("which #{name} > /dev/null 2>&1")
  end

  def perform(youtube_url)
    tmpdir = File.join(Dir.tmpdir || '/tmp', "y2s-#{SecureRandom.hex(6)}")
    Dir.mkdir(tmpdir) unless Dir.exist?(tmpdir)

    unless self.class.command_exists?('yt-dlp') && self.class.command_exists?('ffmpeg')
      raise "yt-dlp or ffmpeg not installed on host"
    end

    begin
      write_progress(5, 'starting')
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

      write_progress(40, 'downloaded')

      input_files = Dir.glob(File.join(tmpdir, '*'))
      input_file = input_files.first
      raise "downloaded file not found" unless input_file && File.exist?(input_file)

      uuid = SecureRandom.uuid
      final_name = "#{uuid}.mp4"
      final_path = File.join(OUTPUT_DIR, final_name)

      vf = 'scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2,format=yuv420p'
      ff_cmd = [
        'ffmpeg', '-y', '-i', input_file, '-ss', '0', '-t', '30',
        '-vf', vf,
        '-r', '30',
        '-c:v', 'libx264', '-profile:v', 'baseline', '-level', '3.1', '-preset', 'fast', '-crf', '28',
        '-movflags', '+faststart',
        '-c:a', 'aac', '-b:a', '96k',
        final_path
      ]
      Sidekiq.logger.info("ProcessWorker: running ffmpeg: #{ff_cmd.join(' ')}")
      write_progress(60, 'transcoding')
      begin
        ffout, fferr, ffstatus = Open3.capture3(*ff_cmd)
      rescue Errno::ENOENT => e
        raise "ffmpeg not found: #{e.message}"
      end
      if ffstatus.nil?
        raise "ffmpeg failed to run: stdout=#{ffout.inspect} stderr=#{fferr.inspect}"
      elsif !ffstatus.success?
        raise "ffmpeg failed: #{fferr} (exit=#{ffstatus.exitstatus})"
      end

      write_progress(90, 'finalizing')

      output_rel = "outputs/#{final_name}"
      # write mapping for this job id so web can lookup by job_id
      begin
        if respond_to?(:jid) && jid
          mapping = { output: output_rel }
          File.write(File.join(OUTPUT_DIR, "#{jid}.json"), mapping.to_json)
        end
      rescue => e
        Sidekiq.logger.error("ProcessWorker: failed to write mapping for jid=#{jid}: #{e}")
      end

      write_progress(100, 'done')

      output_rel
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir && Dir.exist?(tmpdir)
    end
  end
end
