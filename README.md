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
# выполнить скрипт сразу
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
```

Примечания:
- Если `v2RayTun` хранит конфиг в другом месте, передайте путь скрипту как аргумент (см. выше).
- Скрипт делает backup перед правками — при ошибке можно восстановить из `*.bak.TIMESTAMP`.

## Примечание по Monit

Утилита `monit.rb` удалена — используйте Monit напрямую (`monit` / `monitrc` / `/usr/local/etc/monit.d`) и `launchctl`/`brew services` для управления агентов.

## Оповещения при падении туннеля

Примеры настройки уведомлений для Monit — два варианта: Email (SMTP) и Webhook (Slack/Discord/HTTP).

- Email (Monit -> SMTP): добавьте в `/usr/local/etc/monitrc` (требуется указать рабочий SMTP-сервер):

```monit
set mailserver smtp.example.com port 587
	username "user" password "secret" using tls
set alert you@example.com
```

Monit сам пришлёт письма при срабатывании проверки (например, при `if failed ... then alert`).

- Webhook (curl): если хотите отправлять HTTP-запросы, добавьте в проверку `cloudflared.mon` строку `then exec`:

```monit
check process cloudflared matching "cloudflared"
	start program = "/bin/launchctl bootstrap gui/504 ~/Library/LaunchAgents/com.gima.cloudflared.plist"
	stop program  = "/bin/launchctl bootout gui/504 ~/Library/LaunchAgents/com.gima.cloudflared.plist"
	if failed host 127.0.0.1 port 20241 for 2 cycles then exec "/usr/bin/env bash -c 'curl -fsS -X POST -H "Content-Type: application/json" -d \"{\\\"text\\\":\\\"cloudflared tunnel down on $(hostname)\\\"}\" \"$MONIT_WEBHOOK_URL\"'"
	group cloudflared
```

Удобно задать `MONIT_WEBHOOK_URL` в окружении `/etc/monitrc` или в wrapper-скрипте, который запускает Monit.

Проверка конфигурации и перезагрузка Monit:

```bash
sudo monit -t
sudo monit reload
sudo monit status cloudflared
```

Для теста можно остановить сервис вручную и посмотреть срабатывание:

```bash
sudo monit stop cloudflared
# потом вернуть
sudo monit start cloudflared
```

