
require 'telegram/bot'
require 'dotenv/load'
require 'net/http'
require 'json'
require 'uri'

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
      when /https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be)\//i
        puts "📨 Получена YouTube ссылка от #{message.from.first_name}: #{text}"
        bot.api.send_message(chat_id: chat_id, text: "Получил ссылку, запускаю обработку... Это может занять некоторое время.")
        begin
          uri = URI.parse(WEBAPP_URL + '/process')
          req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
          req.body = { url: text }.to_json
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(req)
          end
          if res.is_a?(Net::HTTPSuccess)
            body = JSON.parse(res.body) rescue {}
            job_id = body['job_id'] || body['id'] || nil
            publish_url = if job_id
              "#{WEBAPP_URL}/publish?job_id=#{URI.encode_www_form_component(job_id)}"
            else
              # fallback: open generic publish page
              "#{WEBAPP_URL}/publish"
            end
            kb = { inline_keyboard: [[{ text: 'Опубликовать историю', web_app: { url: publish_url } }]] }
            bot.api.send_message(chat_id: chat_id, text: "Готово — нажмите кнопку для публикации:", reply_markup: kb)
          else
            bot.api.send_message(chat_id: chat_id, text: "Не удалось отправить ссылку на обработку (#{res.code}). Попробуйте позже.")
          end
        rescue => e
          puts "Ошибка при отправке на обработку: #{e.class}: #{e}" 
          bot.api.send_message(chat_id: chat_id, text: "Ошибка при запуске обработки: #{e.message}")
        end
      else
        puts "📨 Получено сообщение от #{message.from.first_name}: #{text}"
        # На случай если пользователь напрямую прислал ссылку — можно подсказать открыть Web App
        bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}\nЕсли хотите редактировать и опубликовать в историях, откройте загрузчик через кнопку.")
      end
    end
  end
end