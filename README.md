# youtube2story — прототип Web App для публикации YouTube в Stories

Коротко: этот репозиторий содержит бот (`bot.rb`) и простой Web App (`web_public/`) + сервер (`web.rb`), который демонстрирует поток:

- бот отправляет кнопку Web App; пользователь открывает Web App в Telegram
- Web App отправляет ссылку YouTube на `/process`
- сервер должен скачать видео (yt-dlp), обрезать (ffmpeg), выгрузить и вернуть `processed_url`
- Web App вызывает `Telegram.WebApp.shareToStory({url: processed_url})` (редактор историй откроется у пользователя)

Текущий статус: заглушка — `/process` возвращает фиктивный URL `outputs/demo.mp4`. Не реализована реальная обработка (yt-dlp/ffmpeg/upload).

Запуск локально (macOS):

1) Установите зависимости (если нужно):
```bash
brew install yt-dlp ffmpeg
gem install bundler
````markdown
# youtube2story — прототип Web App для публикации YouTube в Stories

Коротко: этот репозиторий содержит бот (`bot.rb`) и простой Web App (`web_public/`) + сервер (`web.rb`), который демонстрирует поток:

- бот отправляет кнопку Web App; пользователь открывает Web App в Telegram
- Web App отправляет ссылку YouTube на `/process`
- сервер должен скачать видео (yt-dlp), обрезать (ffmpeg), выгрузить и вернуть `processed_url`
- Web App вызывает `Telegram.WebApp.shareToStory({url: processed_url})` (редактор историй откроется у пользователя)

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
DATABASE_URL=postgresql://y2s_app:пароль@127.0.0.1:5432/youtube2story
```

3) Запустите веб‑сервер (нужен корректный SSL/сертификат для хоста):
```bash
ruby web.rb
```

4) Запустите бота:
```bash
ruby bot.rb
```

5) Проверка подключения приложения к Postgres:
```bash
curl -sS http://127.0.0.1:8080/db_health
```

Ожидаемый ответ: JSON с `ok: true`, именем БД и пользователем.

6) Применение минимальной схемы БД (users/jobs/artifacts/quotas/events):
```bash
psql -d youtube2story -f db/schema.sql
```

7) Персистентный WebApp flow (не теряет состояние при закрытии вкладки):
- `GET /user_state?tg_user_id=...&url=...` — возвращает сохранённый `can_share` и последний `job_id` для ссылки.
- `POST /process` теперь принимает `tg_user_id` и профиль Telegram, сохраняет пользователя и связывает задачу с ним.
- `GET /job_status?job_id=...` читает прогресс из Postgres (fallback на файлы сохранён).

Идея: при повторном открытии кнопки `Опубликовать` WebApp восстанавливает последний `job_id` и показывает актуальный прогресс/результат, а проверка прав публикации повторно не выполняется, если уже сохранена в БД.

Дальнейшие шаги:
- реализовать реальную обработку в `/process` (yt-dlp + ffmpeg), сохранять результат в публичную директорию `web_public/outputs/` или S3 и возвращать URL
- оптимизировать кодеки/параметры для сторис (720x1280 H.265, <=60s)
- добавить проверку размера/времени и прогресс загрузки

## Команды

### CLI (Clamp)

Сброс данных пользователя выполняется только через CLI-команду (не через Telegram-бота):

```bash
ruby scripts/y2s_cli.rb reset-user --tg-user-id 123456789
```

```bash
ruby scripts/y2s_cli.rb reset-user --username someuser
```

Проверить доступные подкоманды:

```bash
ruby scripts/y2s_cli.rb --help
```

- Посмотреть статус Monit для `y2s_web`:
```bash
sudo monit status y2s_web
```
- Перезапустить через Monit:
```bash
sudo monit restart y2s_web
```
- Быстрая проверка логов после перезапуска:
```bash
tail -n 200 /tmp/y2s_web.log /tmp/y2s_web.err
```

## Примечание

В текущей конфигурации `/usr/local/etc/monit.d/y2s_web.mon` нет явных `start/stop program` для `web.rb`. При `monit restart` Monit остановит процесс, а затем `launchd` (есть LaunchAgent `com.y2s.web` с `KeepAlive`) автоматически запустит `web.rb` заново. Если нужно более явное управление — можно добавить в конфиг Monit директивы `start program` и `stop program`, которые будут вызывать `launchctl load/unload ~/Library/LaunchAgents/com.y2s.web.plist`.

````


## Запуск и конфигурация LaunchAgent (`com.y2s.bot`)

Если вы используете `LaunchAgent` для автозапуска `bot.rb` (файл `~/Library/LaunchAgents/com.y2s.bot.plist`), нужно передать в среду выполнения токен бота — `launchd` не читает `.env` автоматически.

Рекомендуемые варианты:

- Временно (только для текущей сессии):

```bash
launchctl setenv TELEGRAM_TOKEN "ВАШ_ТОКЕН_ЗДЕСЬ"
launchctl setenv WEBAPP_ORIGIN "https://youtube.gimadev.win"
launchctl kickstart -k gui/$(id -u)/com.y2s.bot
```

- Постоянно (правка plist): добавьте секцию `EnvironmentVariables` в `~/Library/LaunchAgents/com.y2s.bot.plist`:

```xml
	<key>EnvironmentVariables</key>
	<dict>
		<key>TELEGRAM_TOKEN</key>
		<string>ВАШ_ТОКЕН</string>
		<key>WEBAPP_ORIGIN</key>
		<string>https://youtube.gimadev.win</string>
	</dict>
```

После правки перезагрузите агента:

```bash
launchctl unload ~/Library/LaunchAgents/com.y2s.bot.plist 2>/dev/null || true
launchctl load   ~/Library/LaunchAgents/com.y2s.bot.plist
launchctl print gui/$(id -u)/com.y2s.bot
```

Безопасность и примечания:
- Не сохраняйте токен в публичных репозиториях. Если вы добавили реальный токен в `plist` временно для отладки — замените его на placeholder или используйте защищённое хранилище.
- Более безопасный подход: хранить токен в macOS Keychain и запускать wrapper-скрипт, который извлекает токен и экспортирует в окружение перед запуском `ruby bot.rb`.
- `launchctl setenv` полезен для быстрой проверки — значения не сохраняются между сессиями.

Проверка статуса после старта:

```bash
launchctl print gui/$(id -u)/com.y2s.bot
sudo monit summary
tail -n 200 /tmp/y2s_bot.log /tmp/y2s_bot.err
```
