#!/bin/bash
set -euo pipefail
UIDVAR="${SUDO_UID:-$(id -u)}"

cat > /tmp/y2s_web.mon <<EOF
check process y2s_web matching "/usr/local/opt/ruby/bin/ruby /Users/gima/ruby_projects/youtube2story/web.rb"
  start program = "/bin/launchctl bootstrap gui/${UIDVAR} /Users/gima/Library/LaunchAgents/com.y2s.web.plist"
  stop  program = "/bin/launchctl bootout gui/${UIDVAR} /Users/gima/Library/LaunchAgents/com.y2s.web.plist"
  if not running then restart
  if 5 restarts within 5 cycles then alert
  group y2s
EOF

cat > /tmp/y2s_bot.mon <<EOF
check process y2s_bot matching "/usr/local/opt/ruby/bin/ruby /Users/gima/ruby_projects/youtube2story/bot.rb"
  start program = "/bin/launchctl bootstrap gui/${UIDVAR} /Users/gima/Library/LaunchAgents/com.y2s.bot.plist"
  stop  program = "/bin/launchctl bootout gui/${UIDVAR} /Users/gima/Library/LaunchAgents/com.y2s.bot.plist"
  if not running then restart
  if 5 restarts within 5 cycles then alert
  group y2s
EOF

sudo mv /tmp/y2s_web.mon /usr/local/etc/monit.d/y2s_web.mon
sudo mv /tmp/y2s_bot.mon /usr/local/etc/monit.d/y2s_bot.mon
sudo chmod 0644 /usr/local/etc/monit.d/y2s_web.mon /usr/local/etc/monit.d/y2s_bot.mon

echo '=== monit -t ==='
sudo monit -t || true

echo '=== monit reload ==='
sudo monit reload || true

echo '=== monit summary ==='
sudo monit summary || true

echo '=== monit status y2s_web ==='
sudo monit status y2s_web || true

echo '=== monit status y2s_bot ==='
sudo monit status y2s_bot || true

