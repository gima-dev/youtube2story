
require 'telegram/bot'
require 'dotenv/load'

# Отключение буферизации вывода для логирования
$stdout.sync = true
$stderr.sync = true

TOKEN = ENV['TELEGRAM_BOT_TOKEN']
WEBAPP_URL = ENV['WEBAPP_URL'] || 'https://gima.dedyn.io/app'

puts "🤖 Бот запущен с polling..."
puts "📅 Время запуска: #{Time.now}"

Telegram::Bot::Client.run(TOKEN) do |bot|
  bot.listen do |message|
    case message
    when Telegram::Bot::Types::Message
      chat_id = message.chat.id
      text = message.text
      
      case text
      when '/start'
        puts "📨 Получено сообщение от #{message.from.first_name}: /start"
        # Отправим кнопку, открывающую Web App с временным параметром, чтобы избежать кэширования
        sep = WEBAPP_URL.include?('?') ? '&' : '?'
        ts = (Time.now.to_f * 1000).to_i
        url = "#{WEBAPP_URL}#{sep}t=#{ts}"
        web_app_info = Telegram::Bot::Types::WebAppInfo.new(url: url)
        puts "🔗 Отправляем WebApp URL: #{url}"
        keyboard_button = Telegram::Bot::Types::KeyboardButton.new(text: 'Открыть загрузчик', web_app: web_app_info)
        keyboard = Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: [[keyboard_button]], resize_keyboard: true)

        bot.api.send_message(chat_id: chat_id, text: "Нажмите кнопку, чтобы открыть загрузчик видео в Web App, или просто пришлите ссылку:", reply_markup: keyboard)
      else
        puts "📨 Получено сообщение от #{message.from.first_name}: #{text}"
        # На случай если пользователь напрямую прислал ссылку — можно подсказать открыть Web App
        bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}\nЕсли хотите редактировать и опубликовать в историях, откройте загрузчик через кнопку.")
      end
    end
  end
end