#!/usr/bin/env ruby

require 'telegram/bot'
require 'dotenv/load'

TOKEN = ENV['TELEGRAM_BOT_TOKEN'] || ENV['TELEGRAM_TOKEN'] || ENV['BOT_TOKEN']

raise 'Missing TELEGRAM token' unless TOKEN

begin
  Telegram::Bot::Client.run(TOKEN) do |bot|
    puts "Registering bot commands..."
    
    result = bot.api.set_my_commands(commands: [
      { command: 'start', description: 'Начать работу' },
      { command: 'reset', description: 'Очистить мои данные (разработчик)' }
    ])
    
    puts "Register result: #{result}"
    
    if result
      puts "✅ Bot commands registered successfully!"
    else
      puts "❌ Failed to register bot commands"
      exit 1
    end
  end
rescue => e
  puts "❌ Error: #{e.class}: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
