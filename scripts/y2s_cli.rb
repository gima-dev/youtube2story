#!/usr/bin/env ruby

require 'bundler/setup'
require 'net/http'
require 'uri'
require 'json'
require 'dotenv/load'
require 'clamp'

module Y2S
  class BaseCommand < Clamp::Command
    option ['-o', '--origin'], 'ORIGIN', 'Web backend origin', default: (ENV['WEBAPP_ORIGIN'] || 'https://youtube.gimadev.win')

    def bot_token
      token = ENV['TELEGRAM_BOT_TOKEN'] || ENV['TELEGRAM_TOKEN'] || ENV['BOT_TOKEN']
      raise 'Missing TELEGRAM token' if token.nil? || token.strip.empty?

      token
    end

    def post_json(url, payload)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(payload)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        response = http.request(request)
        body = response.body.to_s.strip
        parsed = body.empty? ? {} : JSON.parse(body)
        [response, parsed]
      end
    end

    def bot_api(method, payload)
      url = "https://api.telegram.org/bot#{bot_token}/#{method}"
      _response, data = post_json(url, payload)
      data
    end

    def normalize_username(value)
      username = value.to_s.strip
      username = username[1..] if username.start_with?('@')
      username.downcase
    end
  end

  class RegisterBotCommandsCommand < BaseCommand
    def execute
      puts '🔧 Configuring Telegram bot commands...'

      menu_result = bot_api('setChatMenuButton', {
        menu_button: { type: 'commands' }
      })

      if menu_result['ok']
        puts '✅ Menu button set to show commands'
      else
        puts "⚠️ Menu button warning: #{menu_result['description']}"
      end

      delete_result = bot_api('deleteMyCommands', {
        scope: { type: 'default' }
      })
      puts "Cleared old commands: #{delete_result['ok']}"

      commands_result = bot_api('setMyCommands', {
        commands: [
          { command: 'start', description: 'Начать работу' }
        ],
        scope: { type: 'default' }
      })

      if commands_result['ok']
        puts '✅ Commands registered successfully!'
        puts '   Available: /start'
      else
        raise "Failed to register commands: #{commands_result['description']}"
      end
    end
  end

  class ResetUserCommand < BaseCommand
    option '--username', 'USERNAME', 'Telegram username (with or without @)'
    option '--tg-user-id', 'TG_USER_ID', 'Telegram user id'

    def execute
      payload = {}

      if !tg_user_id.to_s.strip.empty?
        payload[:tg_user_id] = tg_user_id.to_i
      elsif !username.to_s.strip.empty?
        payload[:username] = normalize_username(username)
      else
        raise 'Provide --tg-user-id or --username'
      end

      _response, data = post_json("#{origin}/admin/reset_user", payload)

      if data['ok']
        target = payload[:tg_user_id] ? "tg_user_id=#{payload[:tg_user_id]}" : "username=#{payload[:username]}"
        puts "✅ Reset completed for #{target}"
      else
        raise "Reset failed: #{data['error'] || data['description'] || 'unknown error'}"
      end
    end
  end

  class CLI < Clamp::Command
    subcommand 'register-bot-commands', 'Register Telegram command menu', RegisterBotCommandsCommand
    subcommand 'reset-user', 'Reset user data in backend', ResetUserCommand
  end
end

Y2S::CLI.run
