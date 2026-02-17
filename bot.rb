
require 'telegram/bot'
require 'dotenv/load'
require 'net/http'
require 'json'
      # If this message is a reply from WebApp (sendData), handle it first
      if message.web_app_data && message.web_app_data.data
        data = JSON.parse(message.web_app_data.data) rescue {}
        can_share = data['can_share']
        source_url = data['url']
        if can_share && source_url
          bot.api.send_message(chat_id: chat_id, text: "Права подтверждены — запускаю обработку...")
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
              bot.api.send_message(chat_id: chat_id, text: "Готово — нажмите кнопку для публикации:", reply_markup: kb.to_json)
            else
              bot.api.send_message(chat_id: chat_id, text: "Не удалось отправить ссылку на обработку (#{res.code}). Попробуйте позже.")
            end
          rescue => e
            puts "Ошибка при отправке на обработку: #{e.class}: #{e}" 
            bot.api.send_message(chat_id: chat_id, text: "Ошибка при запуске обработки: #{e.message}")
          end
        else
          bot.api.send_message(chat_id: chat_id, text: "К сожалению, ваш аккаунт не поддерживает публикацию историй. Ссылки не обрабатываются.")
        end
        next
      end

      case text
      when '/start'
# Отключение буферизации вывода для логирования
$stdout.sync = true
$stderr.sync = true
      when /https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be)\//i
        puts "📨 Получена YouTube ссылка от #{message.from.first_name}: #{text}"
        # Вместо немедленной обработки — отправляем WebApp кнопку для проверки прав и подтверждения
        check_url = "#{WEBAPP_ORIGIN}/check_publish?url=#{URI.encode_www_form_component(text)}"
        kb = { inline_keyboard: [[{ text: 'Проверить и открыть редактор', web_app: { url: check_url } }]] }
        bot.api.send_message(chat_id: chat_id, text: "Нажмите кнопку, чтобы проверить возможность публикации и открыть редактор:", reply_markup: kb.to_json)
      when /https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be)\//i
        puts "📨 Получена YouTube ссылка от #{message.from.first_name}: #{text}"
        bot.api.send_message(chat_id: chat_id, text: "Получил ссылку, запускаю обработку... Это может занять некоторое время.")
        begin
          uri = URI.parse(WEBAPP_ORIGIN + '/process')
          req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
          req.body = { url: text }.to_json
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
            bot.api.send_message(chat_id: chat_id, text: "Готово — нажмите кнопку для публикации:", reply_markup: kb.to_json)
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