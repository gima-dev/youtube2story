require 'sidekiq'
require 'open3'
require 'securerandom'
require 'fileutils'
require 'tmpdir'

class ProcessWorker
  include Sidekiq::Worker
  sidekiq_options retry: 3

  OUTPUT_DIR = File.join(Dir.pwd, 'web_public', 'outputs')
  FileUtils.mkdir_p(OUTPUT_DIR)

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

      input_files = Dir.glob(File.join(tmpdir, '*'))
      input_file = input_files.first
      raise "downloaded file not found" unless input_file && File.exist?(input_file)

      uuid = SecureRandom.uuid
      final_name = "#{uuid}.mp4"
      final_path = File.join(OUTPUT_DIR, final_name)

      ff_cmd = ['ffmpeg', '-y', '-i', input_file, '-ss', '0', '-t', '30', '-vf', 'scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2', '-c:v', 'libx264', '-preset', 'fast', '-crf', '36', '-c:a', 'aac', '-b:a', '96k', final_path]
      Sidekiq.logger.info("ProcessWorker: running ffmpeg: #{ff_cmd.join(' ')}")
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

      "outputs/#{final_name}"
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir && Dir.exist?(tmpdir)
    end
  end
end
