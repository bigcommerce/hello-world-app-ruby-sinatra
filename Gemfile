source 'https://rubygems.org'

ruby ENV['CUSTOM_RUBY_VERSION'] || '2.0.0'

gem 'bigcommerce'
gem 'omniauth-bigcommerce', git: 'https://github.com/bigcommerce/omniauth-bigcommerce.git'

gem 'sinatra'
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
