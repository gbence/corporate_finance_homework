# This file goes in domain.com/config.ru
%w( rubygems dm-core dm-serializer sinatra sinatras-hat ).each { |lib| require lib }

Sinatra::Application.default_options.merge!(
  :run => false,
  :env => :production,
  :raise_errors => true
)

require 'hf'

log = File.new(File.dirname(__FILE__) + "/sinatra.log", "a")
STDOUT.reopen(log)
STDERR.reopen(log)

run Sinatra.application
