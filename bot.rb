
require 'telegram/bot'
require 'dotenv/load'

TOKEN = ENV['TELEGRAM_BOT_TOKEN']

puts "🤖 Бот запущен с polling..."

Telegram::Bot::Client.run(TOKEN) do |bot|
  bot.listen do |message|
    case message
    when Telegram::Bot::Types::Message
      chat_id = message.chat.id
      text = message.text
      
      puts "📨 Получено сообщение от #{message.from.first_name}: #{text}"
      
      bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}")
    end
  end
end