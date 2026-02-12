#!/usr/bin/env bash
# Скрипт для отката системных изменений, сделанных при экспериментах с tun2socks/PF.
# Требует запуска от имени root (sudo).

set -euo pipefail

echo "== Откат изменений tun2socks / PF для проекта youtube2story =="

echo "1) Остановить и убить helper (hev-socks5-tunnel) если запущен"
pkill -f hev-socks5-tunnel || true

echo "2) Очистить PF anchor com.y2s.cloudflared"
if sudo pfctl -s all | grep -q "com.y2s.cloudflared"; then
  sudo pfctl -a com.y2s.cloudflared -F all || true
  echo "  - Anchor очищен"
else
  echo "  - Anchor не найден, пропускаю"
fi

echo "3) Перезагрузить основные PF правила (вернуть системный pf.conf)"
if [ -f /etc/pf.conf ]; then
  sudo pfctl -f /etc/pf.conf || true
  echo "  - pf конфигурация перезагружена"
else
  echo "  - /etc/pf.conf не найден, пропускаю"
fi

echo "4) Попытаться отключить/удалить интерфейс utun5 (если он остался)"
if ifconfig utun5 >/dev/null 2>&1; then
  sudo ifconfig utun5 down || true
  sudo ifconfig utun5 destroy || true
  echo "  - utun5 остановлен/удален"
else
  echo "  - utun5 не найден, пропускаю"
fi

echo "5) Удалить временные файлы в /tmp, созданные при тестах (безопасно)"
sudo rm -f /tmp/cloudflared_udp_to_utun5*.pf /tmp/hev-*.yml /tmp/hev-*.log /tmp/hev-*.pcap || true
sudo rm -rf /tmp/tun2socks-rust || true

echo "6) Рекомендация: перезапустить cloudflared и V2RayTun после отката"
echo "   Примеры (поменяйте на ваши команды/plist):"
echo "     sudo launchctl kickstart -k system/org.cloudflare.cloudflared"
echo "     # или если cloudflared запускается через monit: sudo monit restart cloudflared"
echo "     # перезапуск V2RayTun: используйте вашу команду запуска (launchd/monit/systemctl)"

echo "Готово. Пожалуйста, проверьте состояние PF: sudo pfctl -s info"

exit 0
