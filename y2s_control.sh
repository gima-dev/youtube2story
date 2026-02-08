#!/usr/bin/env bash
set -e

# Контроллер для web.rb (start|stop|restart|status)
# Настройка: при необходимости установите Y2S_PROJECT_DIR или измените DEFAULT_PROJECT_DIR
DEFAULT_PROJECT_DIR="/Users/gima/ruby_projects/youtube2story"
PROJECT_DIR="${Y2S_PROJECT_DIR:-$DEFAULT_PROJECT_DIR}"
LOG="/tmp/y2s_web.log"
PIDFILE="/tmp/y2s_web.pid"

# Переменные окружения для web.rb
export WEBAPP_HOST="${WEBAPP_HOST:-https://gima.dedyn.io}"
export PORT="${PORT:-443}"
# Пути к SSL сертификату от acme.sh
export SSL_CERT="$HOME/.acme.sh/gima.dedyn.io_ecc/fullchain.cer"
export SSL_KEY="$HOME/.acme.sh/gima.dedyn.io_ecc/gima.dedyn.io.key"

start() {
  if pgrep -f "ruby.*web.rb" > /dev/null; then
    echo "web.rb already running"
    exit 0
  fi
  cd "$PROJECT_DIR"
  nohup ruby web.rb > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 0.5
  echo "Started web.rb, pid=$(cat $PIDFILE)"
}

stop() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat $PIDFILE)" || true
    rm -f "$PIDFILE"
    echo "Stopped (pid file)"
    exit 0
  fi
  pkill -f "ruby.*web.rb" || true
  echo "Stopped (fallback)"
}

status() {
  if pgrep -f "ruby.*web.rb" > /dev/null; then
    echo "running"
  else
    echo "stopped"
  fi
}

case "$1" in
  start) start ;;
  stop) stop ;;
  restart) stop; sleep 0.5; start ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|restart|status}" ; exit 2 ;;
esac
