#!/bin/bash
# Start script for y2s bot, run as user 'gima'
cd /Users/gima/ruby_projects/youtube2story || exit 1

# Dump environment for debugging
# Dump environment for debugging
env > /tmp/y2s_bot.env.log

# Start the bot in background, write pid
/usr/local/opt/ruby/bin/bundle exec /usr/local/opt/ruby/bin/ruby bot.rb >> /tmp/y2s_bot.log 2>&1 &
echo $! > /tmp/y2s_bot.pid

# detach
disown 2>/dev/null || true

exit 0
