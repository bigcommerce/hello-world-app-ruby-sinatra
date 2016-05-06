source 'https://rubygems.org'

ruby ENV['CUSTOM_RUBY_VERSION'] || '2.2.5'

gem 'bigcommerce'
gem 'omniauth-bigcommerce', '~> 0.3.0'

gem 'sinatra', '~> 1.4.7'
gem 'datamapper'
gem 'thin'
gem 'dotenv'

group :production do
  gem "pg"
  gem "dm-postgres-adapter"
end

group :development do
  gem "sqlite3"
  gem "dm-sqlite-adapter"
end
