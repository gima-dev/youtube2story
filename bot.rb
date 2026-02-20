
require 'telegram/bot'
require 'dotenv/load'
require 'net/http'
require 'json'
require 'uri'
require 'time'

TOKEN = ENV['TELEGRAM_BOT_TOKEN'] || ENV['TELEGRAM_TOKEN'] || ENV['BOT_TOKEN']
WEBAPP_ORIGIN = ENV['WEBAPP_ORIGIN'] || 'https://youtube.gimadev.win'

raise 'Missing TELEGRAM token' unless TOKEN

$stdout.sync = true
$stderr.sync = true

SEEN_MESSAGES = {}
SEEN_TTL_SECONDS = 600
RECENT_TEXT_EVENTS = {}
RECENT_TEXT_TTL_SECONDS = 2

def message_key(message)
  return nil unless message && message.respond_to?(:chat) && message.chat && message.respond_to?(:message_id)
  "#{message.chat.id}:#{message.message_id}"
end

def duplicate_message?(message)
  key = message_key(message)
  return false if key.nil?

  now = Time.now.to_i
  SEEN_MESSAGES.delete_if { |_k, ts| now - ts > SEEN_TTL_SECONDS }
  return true if SEEN_MESSAGES.key?(key)

  SEEN_MESSAGES[key] = now
  false
end

def duplicate_text_bounce?(chat_id:, from_id:, text:)
  return false if chat_id.nil? || from_id.nil? || text.to_s.empty?

  key = "#{chat_id}:#{from_id}:#{text}"
  now = Time.now.to_i
  RECENT_TEXT_EVENTS.delete_if { |_k, ts| now - ts > RECENT_TEXT_TTL_SECONDS }
  return true if RECENT_TEXT_EVENTS.key?(key)

  RECENT_TEXT_EVENTS[key] = now
  false
end

Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "bot started"
  bot.listen do |message|
    begin
      if duplicate_message?(message)
        puts "skip duplicate message chat_id=#{message.chat.id} message_id=#{message.message_id}" rescue nil
        next
      end

      chat_id = message.chat.id
      text = message.respond_to?(:text) ? message.text.to_s : ''
      from_id = message.respond_to?(:from) && message.from ? message.from.id : nil
      msg_id = message.respond_to?(:message_id) ? message.message_id : nil
      puts "incoming message chat_id=#{chat_id} message_id=#{msg_id} from_id=#{from_id} text=#{text.inspect}" rescue nil

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
        if duplicate_text_bounce?(chat_id: chat_id, from_id: from_id, text: text)
          if msg_id
            begin
              bot.api.delete_message(chat_id: chat_id, message_id: msg_id)
            rescue => e
              puts "failed to delete duplicate /start chat_id=#{chat_id} message_id=#{msg_id}: #{e.class}: #{e}" rescue nil
            end
          end
          puts "skip start bounce chat_id=#{chat_id} from_id=#{from_id} message_id=#{msg_id}" rescue nil
          next
        end

        bot.api.send_message(chat_id: chat_id, text: "Вставьте ссылку YouTube сюда или откройте редактор через кнопку.")

      when %r{\A/reset\b}i
        bot.api.send_message(chat_id: chat_id, text: 'Команда reset выполняется только через CLI (clamp).')

      when /https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be)\//i
        puts "📨 Получена YouTube ссылка от #{message.from && message.from.first_name}: #{text}"
        
        # Extract video ID and build thumbnail URL
        video_id = nil
        if text =~ /(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/
          video_id = $1
        end
        
        tg_user_id = message.from && message.from.id
        open_url = "#{WEBAPP_ORIGIN}/resume?url=#{URI.encode_www_form_component(text)}"
        open_url += "&tg_user_id=#{URI.encode_www_form_component(tg_user_id.to_s)}" if tg_user_id
        kb = { inline_keyboard: [[{ text: 'Опубликовать', web_app: { url: open_url } }]] }
        
        if video_id
          thumbnail_candidates = [
            "https://img.youtube.com/vi/#{video_id}/maxresdefault.jpg",
            "https://img.youtube.com/vi/#{video_id}/hqdefault.jpg"
          ]

          sent_photo = false
          thumbnail_candidates.each do |thumbnail_url|
            begin
              bot.api.send_photo(
                chat_id: chat_id,
                photo: thumbnail_url,
                caption: '🎬 Готово к публикации',
                reply_markup: kb.to_json
              )
              sent_photo = true
              break
            rescue => e
              puts "Failed to send thumbnail #{thumbnail_url}: #{e.class}: #{e}" rescue nil
            end
          end

          unless sent_photo
            bot.api.send_message(chat_id: chat_id, text: '🎬 Готово к публикации', reply_markup: kb.to_json)
          end
        else
          bot.api.send_message(chat_id: chat_id, text: '🎬 Готово к публикации', reply_markup: kb.to_json)
        end

      else
        puts "📨 Получено сообщение от #{message.from && message.from.first_name}: #{text}"
        bot.api.send_message(chat_id: chat_id, text: "Вы написали: #{text}\nЕсли хотите редактировать и опубликовать в историях, отправьте ссылку YouTube.")
      end

    rescue => e
      puts "Handler error: #{e.class}: #{e}\n#{e.backtrace.join("\n")}" rescue nil
    end
  end
end