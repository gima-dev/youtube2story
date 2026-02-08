#!/usr/bin/env ruby
# monit.rb — удобный просмотр и управление процессами/агентами для проекта
#
# Короткий пример использования (также доступна команда `monitrb`, если вы
# сделали символьную ссылку в /usr/local/bin):
#
#   monitrb list
#   sudo monitrb monit-summary
#   monitrb monit-status cloudflared
#   monitrb enable-monit-check cloudflared --plist ~/Library/LaunchAgents/com.gima.cloudflared.plist
#   monitrb tail ~/Library/Logs/com.gima.cloudflared/cloudflared.err.log
#
require 'optparse'

def run(cmd)
  puts "$ #{cmd}"
  out = `#{cmd} 2>&1`
  puts out
  $?.exitstatus
end

def capture(cmd)
  `#{cmd} 2>&1`
end

def header(title)
  puts "\n=== #{title} ==="
end

def pretty_monit_summary
  out = capture('monit summary')
  if system('which column > /dev/null 2>&1')
    table_in = out.gsub(/\s{2,}/, "\t")
    formatted = IO.popen(['column','-t','-s','\t'], 'r+') do |io|
      io.write(table_in)
      io.close_write
      io.read
    end
    # colorize statuses for tty
    if $stdout.tty?
      formatted.lines.each do |line|
        l = line.dup
        l.gsub!(/\bOK\b/, colorize('OK', :green))
        l.gsub!(/\bRunning\b/, colorize('Running', :green))
        l.gsub!(/\bMonitored\b/, colorize('Monitored', :green))
        l.gsub!(/\bStopped\b/, colorize('Stopped', :yellow))
        l.gsub!(/\bFailed\b/, colorize('Failed', :red))
        l.gsub!(/\bNot monitored\b/i, colorize('Not monitored', :red))
        l.gsub!(/\bWarning\b/i, colorize('Warning', :yellow))
        puts l
      end
    else
      puts formatted
    end
  else
    puts out
  end
end

def colorize(text, color)
  codes = { red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36 }
  code = codes[color] || 0
  "\e[#{code}m#{text}\e[0m"
end

def pretty_monit_status(name)
  out = capture("monit status #{name}")
  # try simple key: value alignment
  lines = out.lines
  pairs = lines.map do |l|
    if l.include?(':')
      k,v = l.split(':',2)
      [k.strip, v.strip]
    else
      [l.rstrip, nil]
    end
  end
  key_width = pairs.map{|k,v| k ? k.length : 0}.max || 0
  pairs.each do |k,v|
    if v
      puts sprintf("%-#{key_width}s : %s", k, v)
    else
      puts k
    end
  end
end

def help
  puts <<~HELP
    Usage: monit.rb <command> [options]

    Commands:
      list                 — show Monit summary, LaunchAgents and relevant processes
      monit-summary        — run `monit summary` (may require sudo)
      monit-status NAME    — run `monit status NAME` (may require sudo)
      launchctl-list       — list loaded LaunchAgents related to project (com.gima.*)
      ps PATTERN           — show processes matching PATTERN
      start NAME [--via=monit|launchctl] [--plist PATH]
      stop  NAME [--via=monit|launchctl] [--plist PATH]
      restart NAME [--via=monit|launchctl] [--plist PATH]
      tail FILE            — tail -f a logfile
      help                 — show this help

    Examples:
      ruby monit.rb list
      ruby monit.rb monit-status cloudflared
      ruby monit.rb start cloudflared --via=launchctl --plist ~/Library/LaunchAgents/com.gima.cloudflared.plist
      ruby monit.rb tail ~/Library/Logs/com.gima.cloudflared/cloudflared.err.log
      ruby monit.rb enable-monit-check cloudflared --plist ~/Library/LaunchAgents/com.gima.cloudflared.plist
      ruby monit.rb disable-monit-check cloudflared
  HELP
end

cmd = ARGV.shift
unless cmd
  help
  exit 1
end

opts = {}
OptionParser.new do |o|
  o.on('--via VIA', 'via monit or launchctl (default monit)') { |v| opts[:via] = v }
  o.on('--plist PATH', 'path to plist for launchctl bootstrap/bootout') { |p| opts[:plist] = p }
end.parse!(ARGV) rescue nil

case cmd
when 'help'
  help

when 'list'
  header('Monit summary')
  if system('which monit > /dev/null 2>&1')
    puts capture('monit summary')
  else
    puts 'monit not found on PATH'
  end

  header('LaunchAgents (com.gima.*)')
  puts capture("launchctl list | grep com.gima || true")

  header('Relevant processes (cloudflared, ruby, web.rb, nginx)')
  # compact process listing: show USER PID %CPU %MEM COMMAND (no long env prefixes)
  # macOS ps doesn't support user:20 width specifier in some environments; use simple columns
  puts capture("ps -axo user,pid,pcpu,pmem,comm | egrep 'cloudflared|ruby|web.rb|nginx' || true")

when 'monit-summary'
  unless system('which monit > /dev/null 2>&1')
    puts 'monit not installed or not in PATH'
    exit 1
  end
  header('monit summary')
  pretty_monit_summary

when 'monit-status'
  name = ARGV.shift
  if name.nil?
    puts 'Specify monit service name'
    exit 1
  end
  header("monit status #{name}")
  pretty_monit_status(name)

when 'launchctl-list'
  header('launchctl list (com.gima.*)')
  puts capture("launchctl list | grep com.gima || true")

when 'ps'
  pattern = ARGV.shift || 'cloudflared'
  header("ps matching #{pattern}")
  out = capture("pgrep -af #{pattern} 2>/dev/null || true")
  if out.strip.empty?
    out = capture("ps aux | grep -i #{pattern} | grep -v grep || true")
  end
  puts out

when 'start','stop','restart'
  name = ARGV.shift
  if name.nil?
    puts 'Specify a service name'
    exit 1
  end
  via = opts[:via] || 'monit'
  case via
  when 'monit'
    header("monit #{cmd} #{name}")
    system("sudo monit #{cmd} #{name}")
  when 'launchctl'
    plist = opts[:plist]
    if plist.nil?
      puts 'For launchctl control provide --plist PATH'
      exit 1
    end
    case cmd
    when 'start'
      header("launchctl bootstrap gui/$(id -u) #{plist}")
      system("launchctl bootstrap gui/$(id -u) #{plist}")
    when 'stop'
      header("launchctl bootout gui/$(id -u) #{plist}")
      system("launchctl bootout gui/$(id -u) #{plist}")
    when 'restart'
      header('launchctl restart via bootout/bootstrap')
      system("launchctl bootout gui/$(id -u) #{plist} 2>/dev/null || true")
      sleep 1
      system("launchctl bootstrap gui/$(id -u) #{plist}")
    end
  else
    puts "Unknown via: #{via} (choose monit or launchctl)"
    exit 1
  end

when 'tail'
  file = ARGV.shift
  if file.nil?
    puts 'Specify file to tail'
    exit 1
  end
  exec('tail', '-f', file)

when 'enable-monit-check'
  name = ARGV.shift || 'cloudflared'
  plist = opts[:plist] || File.expand_path("~/Library/LaunchAgents/com.gima.#{name}.plist")
  uid = `id -u`.strip
  monit_path = '/usr/local/etc/monit.d'
  conf_file = "#{monit_path}/#{name}.mon"
  conf = <<~MONIT
    check process #{name} matching "/usr/local/bin/#{name} --edge-bind-address 192.168.0.11"
      start program = "/bin/launchctl bootstrap gui/#{uid} #{plist}"
      stop program  = "/bin/launchctl bootout  gui/#{uid} #{plist}"
      if does not exist for 2 cycles then restart
      if 5 restarts within 5 cycles then timeout
      group #{name}
  MONIT

  header("Write monit config to #{conf_file} (requires sudo)")
  begin
    IO.popen(['sudo','tee',conf_file], 'w') do |io|
      io.write(conf)
    end
    puts capture('sudo monit -t')
    puts capture('sudo monit reload')
    puts "wrote #{conf_file} and reloaded monit"
  rescue => e
    puts "failed to write #{conf_file}: #{e}"
  end

when 'disable-monit-check'
  name = ARGV.shift || 'cloudflared'
  conf_file = "/usr/local/etc/monit.d/#{name}.mon"
  header("Removing #{conf_file} (requires sudo)")
  system("sudo rm -f #{conf_file}")
  puts capture('sudo monit -t')
  puts capture('sudo monit reload')
  puts "removed #{conf_file} and reloaded monit"

else
  puts "Unknown command: #{cmd}\n"
  help
  exit 2
end
