source 'https://rubygems.org'

ruby ENV['CUSTOM_RUBY_VERSION'] || '2.2.5'

gem 'bigcommerce', '~> 1.0'
gem 'omniauth-bigcommerce', '~> 0.3.0'

gem 'sinatra', '~> 2.2.3'
gem 'datamapper'
gem 'thin'
gem 'dotenv'

# For JWT example:
gem 'jwt'
gem 'money'
gem 'cachy'
gem 'redis'

group :production do
  gem 'pg', '>= 0.15'
  gem 'dm-postgres-adapter'
  gem 'do_postgres', '>= 0.10.17'
end

group :development do
  gem 'sqlite3'
  gem 'dm-sqlite-adapter'
end
