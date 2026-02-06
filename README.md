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
- реализовать реальную обработку в `/process` (yt-dlp + ffmpeg), сохранять результат в публичную директорию `web_public/outputs/` или S3 и возвращать URL
- оптимизировать кодеки/параметры для сторис (720x1280 H.265, <=60s)
- добавить проверку размера/времени и прогресс загрузки
