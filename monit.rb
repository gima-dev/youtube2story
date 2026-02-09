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

def parse_monit_summary(output)
  # returns array of hashes: {type: 'Process'|'System'.., name: 'cloudflared', status: 'Running'}
  arr = []
  output.lines.each do |line|
    # normalize multiple spaces
    l = line.rstrip
    # skip header/separator lines
    next if l =~ /^Service Name/i
    next if l =~ /^-+$/

    # match patterns like: Process 'cloudflared'              Running
    if m = l.match(/^([A-Za-z]+)\s+'([^']+)'\s+(.*)$/)
      arr << { type: m[1], name: m[2], status: m[3].strip }
    elsif m = l.match(/^([A-Za-z]+)\s+"([^"]+)"\s+(.*)$/)
      arr << { type: m[1], name: m[2], status: m[3].strip }
    # match tabular output: Name <spaces> Status <spaces> Type
    elsif m = l.match(/^(.+?)\s{2,}(.+?)\s{2,}(.+)$/)
      name = m[1].strip
      status = m[2].strip
      type = m[3].strip
      arr << { type: type, name: name, status: status }
    elsif l.strip != ''
      # fallback: keep raw
      arr << { type: 'Unknown', name: l.strip, status: '' }
    end
  end
  arr
end

def monit_view
  out = capture('monit summary')
  # if monit control file is root-only, try with sudo (interactive)
  if out =~ /Permission denied|Cannot open the control file|monit exiting/i
    puts 'Monit requires elevated permissions; retrying with sudo...'
    out = capture('sudo monit summary')
  end
  rows = parse_monit_summary(out)
  # filter only processes for clarity
  procs = rows.select { |r| r[:type].downcase == 'process' }
  # fallback: if Monit doesn't have our expected checks (or they are missing),
  # try to discover running processes by name (web.rb, bot.rb) and add them
  # as unmonitored entries so the view can still show PID/CPU/MEM. Include
  # both `y2s_` and `v2s_` prefixes because some LaunchAgents use `v2s_`.
  expected = %w[y2s_web v2s_web y2s_bot v2s_bot]
  expected.each do |ename|
    next if procs.any? { |p| p[:name] == ename }
    # try common binary/script names
    pattern = case ename
              when 'y2s_web' then 'web.rb'
              when 'y2s_bot' then 'bot.rb'
              else ename
              end
    pg = capture("pgrep -af #{pattern} 2>/dev/null || true").lines.find { |l| l && l.strip != '' }
    if pg
      # parse pid from pgrep line
      pid = nil
      if pg.strip =~ /^(\d+)\s+/ 
        pid = $1
      elsif pg.strip =~ /^(\d+)$/
        pid = $1
      end
      # we found a matching process; add a placeholder Monit-like entry
      procs << { type: 'Process', name: ename, status: 'Not monitored (found via pgrep)', fallback_pid: pid, pg_pattern: pattern }
    end
  end
  if procs.empty?
    puts out
    return
  end
  # gather additional info (pid, cpu, mem, etime, rss, vsz, user, threads, fds, ports, command)
  enriched = procs.map do |p|
    name = p[:name]
    status = p[:status]
    pid = nil
    # allow pre-populated fallback pid from the discovery step
    if p[:fallback_pid] && p[:fallback_pid].to_s =~ /^\d+$/
      pid = p[:fallback_pid].to_s
    end
    # try to get PID from monit status
    st = capture("monit status #{name} 2>/dev/null || true")
    if m = st.match(/PID\s*[:=]\s*(\d+)/i)
      pid = m[1]
    else
      # fallback to pgrep -af (may return either 'PID CMD' or just PID)
      # if we had a more specific pattern from discovery, use it
      pg_search = p[:pg_pattern] || name
      pg_line = capture("pgrep -af #{pg_search} 2>/dev/null || true").lines.find { |l| l && l.strip != '' }
      if pg_line
        # if output is just a number, use it; otherwise parse PID from start
        if pg_line.strip =~ /^\d+$/
          pid = pg_line.strip
        elsif m2 = pg_line.match(/^(\d+)\s+(.*)$/)
          pid = m2[1]
        end
      end
    end

    cpu = mem = etime = rss = vsz = user = threads = openfds = listening = command = restarts = last_restart = last_check = '-'
    if pid && pid =~ /^(\d+)$/
      ps = capture("ps -p #{pid} -o %cpu= -o %mem= -o rss= -o vsz= -o etime= -o user= -o comm= 2>/dev/null || true").strip
      th = capture("ps -p #{pid} -o thcount= 2>/dev/null || true").strip
      threads = th unless th.strip == ''
      command = capture("ps -p #{pid} -o command= 2>/dev/null || true").strip
      if ps && ps != ''
        parts = ps.split
        cpu = parts[0] || cpu
        mem = parts[1] || mem
        rss = parts[2] || rss
        vsz = parts[3] || vsz
        etime = parts[4] || parts[4..-1]&.join(' ') || etime
        user = parts[5] || user
      end
      # open fds and listening ports (costly) if full requested
      if $MONIT_OPTS && $MONIT_OPTS[:full]
        of = capture("lsof -p #{pid} 2>/dev/null | wc -l  || true").strip
        openfds = of unless of == ''
        lp = capture("lsof -Pan -p #{pid} -iTCP -sTCP:LISTEN -n -P 2>/dev/null || true").lines.map{|l| l.split.last}.uniq.join(',')
        listening = lp.strip == '' ? '-' : lp
      end
    end

    # attempt to parse restart/last check from monit status
    if m = st.match(/restarts?\s*:\s*(\d+)/i)
      restarts = m[1]
    end
    if m = st.match(/Last restart\s*:\s*(.*)/i)
      last_restart = m[1].strip
    elsif m = st.match(/Last restart time\s*:\s*(.*)/i)
      last_restart = m[1].strip
    end
    if m = st.match(/Last check\s*:\s*(.*)/i)
      last_check = m[1].strip
    end

    { name: name, status: status, pid: pid || '-', user: user, cpu: cpu, mem: mem, rss: rss, vsz: vsz, threads: threads || '-', openfds: openfds || '-', listening: listening || '-', command: command || '-', restarts: restarts, last_restart: last_restart, last_check: last_check, etime: etime }
  end

  # print table
  if $MONIT_OPTS && $MONIT_OPTS[:full]
    name_w = [enriched.map{|r| r[:name].length}.max, 8].max
    status_w = 12
    pid_w = 6
    user_w = 8
    cpu_w = 6
    mem_w = 6
    rss_w = 6
    vsz_w = 6
    fds_w = 12
    rest_w = 40
    header_fmt = "%-#{name_w}s | %-#{status_w}s | %#{pid_w}s | %-#{user_w}s | %#{cpu_w}s | %#{mem_w}s | %#{rss_w}s | %#{vsz_w}s | %-#{fds_w}s | %s\n"
    printf(header_fmt, 'Name', 'Status', 'PID', 'User', '%CPU', '%MEM', 'RSS', 'VSZ', 'FDs', 'Ports / Uptime / Command')
    sep = [name_w, status_w, pid_w, user_w, cpu_w, mem_w, rss_w, vsz_w, fds_w, rest_w].map{|w| '-' * w}.join('-+-')
    puts sep
    enriched.each do |r|
      status = r[:status]
      if $stdout.tty?
        status = status.gsub(/Running/i, colorize('Running', :green))
        status = status.gsub(/OK/i, colorize('OK', :green))
        status = status.gsub(/Monitored/i, colorize('Monitored', :green))
        status = status.gsub(/Stopped/i, colorize('Stopped', :yellow))
        status = status.gsub(/Failed|Not monitored/i, colorize('Not monitored', :red))
        status = status.gsub(/Warning/i, colorize('Warning', :yellow))
      end
      cmd = r[:command] || '-'
      cmd = cmd.length > 80 ? cmd[0..76] + '...' : cmd
      printf(header_fmt, r[:name], status, r[:pid], r[:user], r[:cpu], r[:mem], r[:rss], r[:vsz], r[:openfds], (r[:listening] == '-' ? "#{r[:etime]}  #{cmd}" : "#{r[:listening]}  #{r[:etime]}  #{cmd}"))
    end
  else
    name_w = [enriched.map{|r| r[:name].length}.max, 8].max
    status_w = 12
    pid_w = 6
    cpu_w = 6
    mem_w = 6
    uptime_w = 24
    header_fmt = "%-#{name_w}s | %-#{status_w}s | %#{pid_w}s | %#{cpu_w}s | %#{mem_w}s | %s\n"
    printf(header_fmt, 'Name', 'Status', 'PID', '%CPU', '%MEM', 'Uptime')
    sep = [name_w, status_w, pid_w, cpu_w, mem_w, uptime_w].map{|w| '-' * w}.join('-+-')
    puts sep
    enriched.each do |r|
      status = r[:status]
      if $stdout.tty?
        status = status.gsub(/Running/i, colorize('Running', :green))
        status = status.gsub(/OK/i, colorize('OK', :green))
        status = status.gsub(/Monitored/i, colorize('Monitored', :green))
        status = status.gsub(/Stopped/i, colorize('Stopped', :yellow))
        status = status.gsub(/Failed|Not monitored/i, colorize('Not monitored', :red))
        status = status.gsub(/Warning/i, colorize('Warning', :yellow))
      end
      printf(header_fmt, r[:name], status, r[:pid], r[:cpu], r[:mem], r[:etime])
    end
  end
end

def help
  puts <<~HELP
    Usage: monit.rb <command> [options]

    Commands:
      list                 — show Monit summary, LaunchAgents and relevant processes
      monit-view           — pretty, colorized summary with PID/CPU/MEM/uptime (console)
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
  o.on('--full', 'show extended columns (open fds, ports, threads, command)') { opts[:full] = true }
end.parse!(ARGV) rescue nil

$MONIT_OPTS = opts

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

when 'monit-view'
  unless system('which monit > /dev/null 2>&1')
    puts 'monit not installed or not in PATH'
    exit 1
  end
  header('monit view (pretty)')
  monit_view

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
