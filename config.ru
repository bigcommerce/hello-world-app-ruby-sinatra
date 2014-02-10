require 'sinatra'
require 'dotenv'

Dotenv.load
$stdout.sync = true

require './hello'
run Sinatra::Application
