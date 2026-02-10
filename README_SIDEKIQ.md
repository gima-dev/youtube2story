# Sidekiq — запуск и проверка

Короткие инструкции для запуска очереди и проверки задач.

Требования
- Redis (Homebrew): `brew install redis`
- Bundler + gems: в корне проекта выполните `bundle install`
- Опционально: `yt-dlp` и `ffmpeg` для реальной обработки (`brew install yt-dlp ffmpeg`)

Запуск (рекомендуемый — как фоновая служба)

1) Запустить Redis:

```bash
brew services start redis
```

2) Установить gems (в корне проекта):

```bash
bundle install
```

3) Есть два варианта запуска Sidekiq:

- Автозапуск через LaunchAgent (создан в `~/Library/LaunchAgents/com.y2s.sidekiq.plist`):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.y2s.sidekiq.plist
# или
launchctl kickstart -k gui/$(id -u)/com.y2s.sidekiq
```

- Ручной (в терминале, в проекте):

```bash
cd /path/to/youtube2story
# в фоне, логи в log/
bundle exec sidekiq -r ./workers/process_worker.rb >> log/sidekiq.log 2>> log/sidekiq.err.log &
```

Проверка очереди и логов

- Посмотреть длину очереди:

```bash
redis-cli LLEN queue:default
```

- Смотреть лог Sidekiq:

```bash
tail -f log/sidekiq.log
tail -f log/sidekiq.err.log
```

Отправка тестовой задачи

Если nginx настроен и проксирует на backend (127.0.0.1:8080):

```bash
curl -X POST -H "Content-Type: application/json" -d '{"url":"https://www.youtube.com/watch?v=VIDEO_ID"}' https://youtube.gimadev.win/process
```

Или напрямую в бекенд (обходит Cloudflare):

```bash
curl -X POST -H "Content-Type: application/json" -d '{"url":"https://www.youtube.com/watch?v=VIDEO_ID"}' http://127.0.0.1:8080/process
```

Примечания
- Если `yt-dlp` или `ffmpeg` не установлены, `web.rb` вернёт 500 и задача не будет отправлена через API — можно принудительно поставить задачу в Redis (cli Ruby) для теста.
- LaunchAgent в текущем виде использует системный `bundle` — если при автозапуске возникают ошибки о `bundler` версии, запускайте Sidekiq вручную из среды, где вы выполнили `bundle install`, либо обновите системный bundler.Sidekiq setup (local)

Requirements:
- Redis installed and running (brew install redis)
- `bundle install` to install gems (sidekiq, redis)

Start Redis:

```bash
brew services start redis
```

Start Sidekiq (from project dir):

```bash
bundle exec sidekiq -r ./workers/process_worker.rb
```

API behavior:
- POST /process accepts JSON { "url": "https://..." }
- Returns 202 and { job_id: "...", status: "queued" }
- Worker will process and place output in `web_public/outputs`.

Notes:
- For long-running jobs prefer to run Sidekiq with multiple concurrency and monitor memory.
- Consider adding a status endpoint and persistence for job results or notifications (webhook/email).
