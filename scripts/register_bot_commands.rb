#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'dotenv/load'

TOKEN = ENV['TELEGRAM_BOT_TOKEN'] || ENV['TELEGRAM_TOKEN'] || ENV['BOT_TOKEN']
raise 'Missing TELEGRAM token' unless TOKEN

def send_command(method, params)
  uri = URI("https://api.telegram.org/bot#{TOKEN}/#{method}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  
  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request.body = JSON.generate(params)
  
  response = http.request(request)
  JSON.parse(response.body)
end

begin
  puts "🔧 Configuring Telegram bot commands..."
  
  # 1. Set default menu button to show commands
  menu_result = send_command('setChatMenuButton', {
    menu_button: { type: 'commands' }
  })
  
  if menu_result['ok']
    puts "✅ Menu button set to show commands"
  else
    puts "⚠️ Menu button warning: #{menu_result['description']}"
  end
  
  # 2. Clear all commands for all scopes
  delete_result = send_command('deleteMyCommands', {
    scope: { type: 'default' }
  })
  puts "Cleared old commands: #{delete_result['ok']}"
  
  # 3. Register new commands with default scope (no language restriction)
  commands_result = send_command('setMyCommands', {
    commands: [
      { command: 'start', description: 'Начать работу' },
      { command: 'reset', description: 'Очистить мои данные' }
    ],
    scope: { type: 'default' }
  })
  
  if commands_result['ok']
    puts "✅ Commands registered successfully!"
    puts "   Available: /start, /reset"
  else
    puts "❌ Failed to register commands: #{commands_result['description']}"
    exit 1
  end
  
rescue => e
  puts "❌ Error: #{e.class}: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
