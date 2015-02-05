source 'https://rubygems.org'

gem 'omniauth-bigcommerce', git: 'https://github.com/bigcommerce/omniauth-bigcommerce.git'
gem 'sinatra'
gem 'thin'
gem 'rest-client'
gem 'dotenv'
gem 'bigcommerce'
gem 'datamapper'

group :production do
  gem "pg"
  gem "dm-postgres-adapter"
end

group :development do
  gem "sqlite3"
  gem "dm-sqlite-adapter"
end
