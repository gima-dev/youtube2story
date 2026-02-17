
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
        # Попросим пользователя вставить ссылку — без открытия WebApp в отдельной вкладке
        bot.api.send_message(chat_id: chat_id, text: "Вставьте ссылку youtube видео сюда...")
      else
        puts "📨 Получено сообщение от #{message.from.first_name}: #{text}"
        # На случай если пользователь напрямую прислал ссылку — можно подсказать открыть Web App
        bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}\nЕсли хотите редактировать и опубликовать в историях, откройте загрузчик через кнопку.")
      end
    end
  end
end