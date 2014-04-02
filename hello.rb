require 'sinatra'
require 'data_mapper'
require 'omniauth-bigcommerce'
require 'json'
require 'base64'
require 'rest_client'
require 'openssl'
require 'bigcommerce'
require 'logger'

configure do

  set :run, true
  set :environment, :development

  # Actually need to disable frame protection because our app
  # lives inside an iframe.
  #
  set :protection, :except => [:http_origin, :frame_options]
  enable :sessions

  use Rack::Session::Cookie
  use Rack::Logger

  use OmniAuth::Builder do
    provider :bigcommerce, bc_client_id, bc_client_secret, scope: 'store_v2'
    OmniAuth.config.full_host = ENV['APP_URL'] || nil
  end

end

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite3://#{Dir.pwd}/dev.db")

# User model representation
#
class User

  include DataMapper::Resource

  property :id,             Serial
  property :email,          String, :required => true
  property :access_token,   String, :required => true
  property :store_hash,     String, :required => true

  validates_presence_of :email, :access_token, :store_hash
  validates_uniqueness_of :store_hash, :email

  def bc_api
    config = {:api_endpoint => bc_api_url,
              :store_hash => self.store_hash,
              :client_id => bc_client_id,
              :access_token => self.access_token
             }
    Bigcommerce::Api.new(config)
  end

  def self.validate(user)
    api = user.bc_api
    time = api.get_time
  if time.nil?
    return false
  elsif time.key?("time")
    return true
  end
  false
  end

end

DataMapper.finalize.auto_upgrade!

# Index
#
get '/' do

  @user = current_user
  unless @user
    @error = 'Unauthorized user'
    return erb :error
  end

  @bc_api_url = bc_api_url
  @client_id = bc_client_id
  @products = JSON.pretty_generate(@user.bc_api.get_products)

  erb :index
end

# Load endpoint
#
get '/load' do
  signed_payload = params[:signed_payload]

  unless verify(signed_payload, bc_client_secret)
    @error = 'Invalid signature on payload!'
    return erb :error
  end

  parts = signed_payload.split('.')
  payload = JSON.parse(Base64.decode64(parts[0]), {:symbolize_names => true})

  user = User.first(:email => payload[:user][:email], :store_hash => payload[:store_hash])

  unless user
    @error = 'Invalid User!'
    return erb :error
  end

  session[:user_id] = user.id
  redirect '/'

end

# Callback endpoint
#
get '/auth/:name/callback' do

  auth = request.env['omniauth.auth']
  if auth && auth[:extra][:raw_info][:context]

    store_hash = auth[:extra][:raw_info][:context].split('/')[1]

    user = User.all(:email => auth[:info][:email], :store_hash => store_hash).first
    unless user
      user = User.new({ :email => auth[:info][:email],
                        :store_hash => store_hash
                      })
    end
    user.access_token = auth[:credentials][:token].token
    user.save!
    session[:user_id] = user.id
    return redirect '/'
  end
  @error = 'Invalid credentials! Got: '+JSON.pretty_generate(auth[:extra])
  return erb :error

end

# Gets the current user in session
#
def current_user
  unless session[:user_id].nil?
    return User.get(session[:user_id])
  end
  nil
end

# Verify given signed_payload string and return the data if valid.
#
def verify(signed_payload, client_secret)
  message_parts = signed_payload.split('.')

  encoded_json_payload = message_parts[0]
  encoded_hmac_signature = message_parts[1]

  payload_object = Base64.decode64(encoded_json_payload)
  provided_signature = Base64.decode64(encoded_hmac_signature)

  expected_signature = sign(client_secret, payload_object)

  return false unless secure_compare(expected_signature, provided_signature)

  payload_object
end

# Sign payload string using HMAC-SHA256 with given secret
#
def sign(secret, payload)
  OpenSSL::HMAC::hexdigest('sha256', secret, payload)
end

# Time consistent string comparison.
# Most library implementation will fail fast allowing timing attacks.
#
#
def secure_compare(a, b)
  return false if a.blank? || b.blank? || a.bytesize != b.bytesize
  l = a.unpack "C#{a.bytesize}"

  res = 0
  b.each_byte { |byte| res |= byte ^ l.shift }
  res == 0
end

# Get client id from env
#
def bc_client_id
  ENV['BC_CLIENT_ID']
end

# Get client secret from env
#
def bc_client_secret
  ENV['BC_CLIENT_SECRET']
end

# Get the API url from env
#
def bc_api_url
  ENV['BC_API_URL']
end


