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

Важно: в этом репозитории Monit теперь настроен в режиме *alert‑only* — Monit выполняет health‑checks и отправляет оповещения, но не пытается напрямую запускать сервисы. За автоперсистентность и перезапуск отвечает `launchd` (LaunchAgents/KeepAlive).

Ключевые команды:

```bash
# Проверить синтаксис конфигурации Monit
sudo monit -t

# Перезагрузить Monit после правок
sudo monit reload

# Посмотреть статус/сводку
sudo monit status
sudo monit summary
```

Файл `scripts/write_monit_files.sh` генерирует alert‑only проверки (`/usr/local/etc/monit.d/*.mon`). Если хотите вернуть поведение, при котором Monit управляет запуском/остановкой через `launchctl`, это можно сделать вручную в соответствующих `.mon` файлах.

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

## Текущая архитектура TLS / проксирования (nginx + web.rb)

Кратко: TLS теперь терминруется в `nginx`, а `web.rb` работает как локальный HTTP‑бекенд.

  затем проксирует запросы на `http://127.0.0.1:8080`.

Практические команды и заметки:

```bash
# Перезагрузить nginx (требуется, если меняли конфиг или сертификаты)
sudo nginx -t
sudo brew services restart nginx

# Перезапустить локальный web агент (LaunchAgent)
launchctl kickstart -k gui/$(id -u)/com.y2s.web || launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.y2s.web.plist

# Проверки
curl -I https://127.0.0.1/      # локальная проверка nginx:443 (может требовать --insecure при Origin CA)
curl -I http://127.0.0.1:8080/   # проверка backend (web.rb)

# Монит: проверяет и nginx:443 и публичный endpoint через Cloudflare
sudo monit -t && sudo monit reload
sudo monit status nginx
sudo monit status youtube_public
```

Background jobs (Sidekiq)
--------------------------------
I added optional Sidekiq/Redis support to run `yt-dlp`/`ffmpeg` asynchronously: see `workers/process_worker.rb` and `README_SIDEKIQ.md` for setup commands. Flow:

- Client POSTs to `/process` → `web.rb` enqueues `ProcessWorker` and returns 202 + job_id.
- Run `redis` and `sidekiq` to process jobs and write outputs into `web_public/outputs` (served by nginx).

See `README_SIDEKIQ.md` for quick start commands.

Если хотите, чтобы `web.rb` снова обслуживал TLS напрямую — можно вернуть SSL переменные `SSL_CERT`/`SSL_KEY` в `~/Library/LaunchAgents/com.y2s.web.plist`, но текущая конфигурация с `nginx` предпочтительнее для кэширования, HTTP/2 и централизованного управления сертификатами.


Для теста можно остановить сервис вручную и посмотреть срабатывание:

```bash
sudo monit stop cloudflared
# потом вернуть
sudo monit start cloudflared
```

