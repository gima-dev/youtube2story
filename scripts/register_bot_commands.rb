#!/usr/bin/env ruby

require 'rbconfig'

exec(RbConfig.ruby, File.join(__dir__, 'y2s_cli.rb'), 'register-bot-commands')
