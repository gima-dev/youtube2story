# youtube2story — прототип Web App для публикации YouTube в Stories

Коротко: этот репозиторий содержит бот (`bot.rb`) и простой Web App (`web_public/`) + сервер (`web.rb`), который демонстрирует поток:


Текущий статус: заглушка — `/process` возвращает фиктивный URL `outputs/demo.mp4`. Не реализована реальная обработка (yt-dlp/ffmpeg/upload).

Запуск локально (macOS):

1) Установите зависимости (если нужно):
```bash
brew install yt-dlp ffmpeg
gem install bundler
bundle install
```

2) Установите переменные окружения в `.env`:
```
TELEGRAM_BOT_TOKEN=ваш_токен
WEBAPP_URL=https://gima.dedyn.io/app
WEBAPP_HOST=https://gima.dedyn.io
```

3) Запустите веб‑сервер (нужен корректный SSL/сертификат для хоста):
```bash
ruby web.rb
```

4) Запустите бота:
```bash
ruby bot.rb
```

Дальнейшие шаги:

## V2RayTun: защита правил Split‑Tunnel (Cloudflare)

Если на системе используется `v2RayTun` (или похожий прокси), он может перехватывать весь исходящий трафик и мешать `cloudflared` регистрировать туннель у Cloudflare (ошибки TLS / 530). Чтобы это предотвратить, в репозитории есть скрипт и LaunchAgent, которые автоматически добавляют правило split‑tunnel для диапазонов Cloudflare.

- Скрипт (в репозитории): `scripts/ensure_v2ray_split.py` — находит конфиги `v2RayTun` и добавляет/обновляет блок `routing` с правилом, которое отправляет диапазоны Cloudflare через `outbound` с тегом `direct`. Перед изменением создаётся резервная копия `*.bak.TIMESTAMP`.

- Вручную выполнить проверку/применение:
```bash
# выполнить скрипт сразу
/Users/gima/ruby_projects/youtube2story/scripts/ensure_v2ray_split.py '/Users/gima/Library/Group Containers/**/Configs/*.json'
```

- Автоматически (рекомендуется): установлен LaunchAgent, который запускает скрипт каждые 15 минут и при логине пользователя. Файл LaunchAgent: `~/Library/LaunchAgents/com.gima.v2ray.ensure.plist`.

- Управление и логи:
```bash
# загрузить/перезагрузить агент
launchctl unload ~/Library/LaunchAgents/com.gima.v2ray.ensure.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.gima.v2ray.ensure.plist

# выполнить скрипт вручную
/Users/gima/ruby_projects/youtube2story/scripts/ensure_v2ray_split.py '/Users/gima/Library/Group Containers/**/Configs/*.json'

# посмотреть вывод
tail -n 200 /tmp/ensure_v2ray_split.out
tail -n 200 /tmp/ensure_v2ray_split.err
```

Примечания:
- Если `v2RayTun` хранит конфиг в другом месте, передайте путь скрипту как аргумент (см. выше).
- Скрипт делает backup перед правками — при ошибке можно восстановить из `*.bak.TIMESTAMP`.
