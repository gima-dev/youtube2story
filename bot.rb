
require 'telegram/bot'
require 'dotenv/load'

# Отключение буферизации вывода для логирования
$stdout.sync = true
$stderr.sync = true

TOKEN = ENV['TELEGRAM_BOT_TOKEN']

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
        bot.api.send_message(chat_id: chat_id, text: "Закиньте сюда ссылку Youtube видео")
      else
        puts "📨 Получено сообщение от #{message.from.first_name}: #{text}"
        bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}")
      end
    end
  end
end