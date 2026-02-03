
require 'sinatra'
require 'telegram/bot'
require 'dotenv/load'

TOKEN = ENV['TELEGRAM_BOT_TOKEN']

post '/webhook' do
  request.body.rewind
  payload = JSON.parse(request.body.read)
  Telegram::Bot::Client.run(TOKEN) do |bot|
    message = Telegram::Bot::Types::Update.new(payload).message
    chat_id = message.chat.id
    text = message.text

    bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}")
  end
  status 200
end

get '/' do
  'Бот работает!'
end