source 'https://rubygems.org'

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
