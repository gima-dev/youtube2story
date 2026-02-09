#!/bin/bash
set -euo pipefail
UIDVAR="${SUDO_UID:-$(id -u)}"

cat > /tmp/y2s_web.mon <<EOF
check process y2s_web matching "web.rb"
  if failed port 443 protocol https for 2 cycles then alert
  group y2s
EOF

cat > /tmp/y2s_bot.mon <<EOF
check process y2s_bot matching "bot.rb"
  group y2s
EOF

cat > /tmp/nginx.mon <<EOF
check process nginx with pidfile /usr/local/var/run/nginx.pid
  if failed port 80 protocol http with timeout 10 seconds then alert
  if failed port 443 protocol https with timeout 10 seconds then alert
  group web
EOF

sudo mv /tmp/y2s_web.mon /usr/local/etc/monit.d/y2s_web.mon
sudo mv /tmp/y2s_bot.mon /usr/local/etc/monit.d/y2s_bot.mon
sudo mv /tmp/nginx.mon /usr/local/etc/monit.d/nginx.mon || true
cat > /tmp/cloudflared.mon <<EOF
check process cloudflared matching "cloudflared"
  if does not exist for 2 cycles then alert
  group cloudflared
EOF

sudo mv /tmp/cloudflared.mon /usr/local/etc/monit.d/cloudflared.mon || true
sudo chmod 0644 /usr/local/etc/monit.d/y2s_web.mon /usr/local/etc/monit.d/y2s_bot.mon /usr/local/etc/monit.d/nginx.mon 2>/dev/null || true
sudo chmod 0644 /usr/local/etc/monit.d/cloudflared.mon 2>/dev/null || true

# Public HTTPS check via Cloudflare edge
cat > /tmp/youtube_public.mon <<EOF
check host youtube_public with address youtube.gimadev.win
  if failed port 443 protocol https with timeout 10 seconds for 3 cycles then alert
  group web
EOF

sudo mv /tmp/youtube_public.mon /usr/local/etc/monit.d/youtube_public.mon || true
sudo chmod 0644 /usr/local/etc/monit.d/youtube_public.mon 2>/dev/null || true

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

