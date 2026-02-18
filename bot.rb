
require 'telegram/bot'
require 'dotenv/load'
require 'net/http'
require 'json'
require 'uri'

TOKEN = ENV['TELEGRAM_TOKEN'] || ENV['BOT_TOKEN']
WEBAPP_ORIGIN = ENV['WEBAPP_ORIGIN'] || 'https://youtube.gimadev.win'

raise 'Missing TELEGRAM token' unless TOKEN

Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "bot started"
  bot.listen do |message|
    begin
      chat_id = message.chat.id
      text = message.respond_to?(:text) ? message.text.to_s : ''

      # If this message is a reply from WebApp (sendData), handle it first
      if message.respond_to?(:web_app_data) && message.web_app_data && message.web_app_data.data
        data = JSON.parse(message.web_app_data.data) rescue {}
        can_share = data['can_share']
        source_url = data['url']
        if can_share && source_url
          bot.api.send_message(
            chat_id: chat_id,
            text: 'Права подтверждены — запускаю обработку...',
            reply_markup: { remove_keyboard: true }.to_json
          )
          begin
            uri = URI.parse(WEBAPP_ORIGIN + '/process')
            req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
            req.body = { url: source_url }.to_json
            res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
              http.request(req)
            end
            if res.is_a?(Net::HTTPSuccess)
              body = JSON.parse(res.body) rescue {}
              job_id = body['job_id'] || body['id'] || nil
              publish_url = if job_id
                "#{WEBAPP_ORIGIN}/publish?job_id=#{URI.encode_www_form_component(job_id)}"
              else
                "#{WEBAPP_ORIGIN}/publish"
              end
              kb = {
                inline_keyboard: [[
                  { text: 'Опубликовать (WebApp)', web_app: { url: publish_url } },
                  { text: 'Открыть в браузере', url: publish_url }
                ]]
              }
              bot.api.send_message(chat_id: chat_id, text: 'Готово — нажмите кнопку для публикации:', reply_markup: kb.to_json)
            else
              bot.api.send_message(chat_id: chat_id, text: "Не удалось отправить ссылку на обработку (#{res.code}). Попробуйте позже.")
            end
          rescue => e
            puts "Ошибка при отправке на обработку: #{e.class}: #{e}"
            bot.api.send_message(chat_id: chat_id, text: "Ошибка при запуске обработки: #{e.message}")
          end
        else
          bot.api.send_message(
            chat_id: chat_id,
            text: 'К сожалению, ваш аккаунт не поддерживает публикацию историй. Ссылки не обрабатываются.',
            reply_markup: { remove_keyboard: true }.to_json
          )
        end
        next
      end

      case text
      when '/start'
        $stdout.sync = true
        $stderr.sync = true
        bot.api.send_message(chat_id: chat_id, text: "Вставьте ссылку YouTube сюда или откройте редактор через кнопку.")

      when '/reset'
        # Developer command - reset all user data
        tg_user_id = message.from && message.from.id
        begin
          uri = URI.parse(WEBAPP_ORIGIN + '/admin/reset_user')
          req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
          req.body = { tg_user_id: tg_user_id }.to_json
          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(req)
          end
          if res.is_a?(Net::HTTPSuccess)
            body = JSON.parse(res.body) rescue {}
            if body['ok']
              bot.api.send_message(chat_id: chat_id, text: "✅ Все данные пользователя удалены, БД очищена, файлы удалены. Пользователь остался в таблице users.")
            else
              bot.api.send_message(chat_id: chat_id, text: "❌ Ошибка: #{body['error']}")
            end
          else
            bot.api.send_message(chat_id: chat_id, text: "❌ Ошибка сервера при сбросе данных (#{res.code})")
          end
        rescue => e
          puts "Ошибка при сбросе данных: #{e.class}: #{e}"
          bot.api.send_message(chat_id: chat_id, text: "❌ Ошибка при сбросе: #{e.message}")
        end

      when /https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be)\//i
        puts "📨 Получена YouTube ссылка от #{message.from && message.from.first_name}: #{text}"
        # Send WebApp button to resume existing state first (or fallback to check)
        tg_user_id = message.from && message.from.id
        open_url = "#{WEBAPP_ORIGIN}/resume?url=#{URI.encode_www_form_component(text)}"
        open_url += "&tg_user_id=#{URI.encode_www_form_component(tg_user_id.to_s)}" if tg_user_id
        kb = { inline_keyboard: [[{ text: 'Опубликовать', web_app: { url: open_url } }]] }
        bot.api.send_message(chat_id: chat_id, text: 'Опубликовать', reply_markup: kb.to_json)

      else
        puts "📨 Получено сообщение от #{message.from && message.from.first_name}: #{text}"
        bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}\nЕсли хотите редактировать и опубликовать в историях, отправьте ссылку YouTube.")
      end

    rescue => e
      puts "Handler error: #{e.class}: #{e}\n#{e.backtrace.join("\n")}" rescue nil
    end
  end
end