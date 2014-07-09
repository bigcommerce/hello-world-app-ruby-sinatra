require 'sinatra'
require 'data_mapper'
require 'omniauth-bigcommerce'
require 'json'
require 'base64'
require 'rest_client'
require 'openssl'
require 'bigcommerce'
require 'logger'

class AuthorizationError < StandardError
end

configure do
  set :run, true
  set :environment, :development

  # Actually need to disable frame protection because our app
  # lives inside an iframe.
  set :protection, except: [:http_origin, :frame_options]

  use Rack::Session::Cookie, secret: ENV['SESSION_SECRET']
  use Rack::Logger

  use OmniAuth::Builder do
    provider :bigcommerce, bc_client_id, bc_client_secret, scope: scopes
    OmniAuth.config.full_host = app_url || nil
  end
end

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite3://#{Dir.pwd}/dev.db")

# User model representation
class User
  include DataMapper::Resource

  property :id,           Serial
  property :email,        String, required: true
  property :access_token, String, required: true
  property :store_hash,   String, required: true

  validates_presence_of :email, :access_token, :store_hash
  validates_uniqueness_of :store_hash, :email

  def bc_api
    config = {
      store_hash: self.store_hash,
      client_id: bc_client_id,
      access_token: self.access_token
    }
    Bigcommerce::Api.new(config)
  end

  def self.validate(user)
    api = user.bc_api
    time = api.time
    time && time.key?("time")
  end
end

DataMapper.finalize.auto_upgrade!

# Home Page
get '/' do
  @user = current_user
  unless @user
    @error = 'Unauthorized user'
    return erb :error
  end

  @bc_api_url = bc_api_url
  @client_id = bc_client_id
  @products = JSON.pretty_generate(@user.bc_api.products)

  erb :index
end

# Auth callback
get '/auth/:name/callback' do
  auth = request.env['omniauth.auth']
  if auth && auth[:extra][:raw_info][:context]
    logger.info "[install] Installing app for user '#{auth[:info][:email]}'"

    store_hash = auth[:extra][:raw_info][:context].split('/')[1]

    user = User.first(email: auth[:info][:email], store_hash: store_hash)
    user ||= User.new(email: auth[:info][:email], store_hash: store_hash)
    user.access_token = auth[:credentials][:token].token
    user.save!

    session[:user_id] = user.id
    return redirect '/'
  end

  @error = "Invalid credentials: #{JSON.pretty_generate(auth[:extra])}"
  logger.info "[install] ERROR: #{@error}"
  return erb :error
end

# Load endpoint
get '/load' do
  # Decode payload
  signed_payload = params[:signed_payload]
  payload = parse_signed_payload(signed_payload, bc_client_secret)
  if payload.nil?
    @error = 'Invalid signature on payload!'
    logger.info "[load] ERROR: #{@error}"
    return erb :error
  end

  email = payload[:user][:email]
  store_hash = payload[:store_hash]
  logger.info "[load] Loading app for user '#{email}'"

  # Get user
  user = User.first(email: email, store_hash: store_hash)
  if user.nil?
    @error = 'Invalid User!'
    logger.info "[load] ERROR: #{@error}"
    return erb :error
  end

  # Login and redirect to home page
  session[:user_id] = user.id
  redirect '/'
end

# Events endpoint
get '/events' do
  # Decode payload
  signed_payload = params[:signed_payload]
  payload = parse_signed_payload(signed_payload, bc_client_secret)
  if payload.nil?
    @error = 'Invalid signature on payload!'
    logger.info "[events] ERROR: #{@error}"
    return erb :error
  end

  email = payload[:user][:email]
  store_hash = payload[:store_hash]
  event = payload[:event]
  logger.info "[events] event '#{event}' for user '#{email}'"

  case event
  when 'add-user'
    # The add-user event gives us a temporary oauth code that we need to exchange
    # for a full token. We also need to provision the user and redirect them to
    # our welcome page.
    user = User.first(email: email, store_hash: store_hash)
    if user.nil?
      token = bc_token_exchange payload[:oauth_code], payload[:context]
      logger.info "[events] token = #{token}"
      unless token.nil?
        user = User.new(email: email, store_hash: store_hash)
        user.access_token = token[:access_token]
        user.save!
      end
    end

    session[:user_id] = user.id
    return redirect '/'
  when 'remove-user'
    # Deprovision user
    user = User.first(email: email, store_hash: store_hash)
    user.destroy if user
    return 204
  end

  @error = 'Invalid event!'
  logger.info "[events] ERROR: #{@error}"
  return erb :error
end

# Gets the current user in session
def current_user
  session[:user_id] ? User.get(session[:user_id]) : nil
end

# Verify given signed_payload string and return the data if valid.
def parse_signed_payload(signed_payload, client_secret)
  message_parts = signed_payload.split('.')

  encoded_json_payload = message_parts[0]
  encoded_hmac_signature = message_parts[1]

  payload = Base64.decode64(encoded_json_payload)
  provided_signature = Base64.decode64(encoded_hmac_signature)

  expected_signature = sign(client_secret, payload)

  if secure_compare(expected_signature, provided_signature)
    return JSON.parse(payload, symbolize_names: true)
  end

  nil
end

# Sign payload string using HMAC-SHA256 with given secret
def sign(secret, payload)
  OpenSSL::HMAC::hexdigest('sha256', secret, payload)
end

# Time consistent string comparison. Most library implementations
# will fail fast allowing timing attacks.
def secure_compare(a, b)
  return false if a.blank? || b.blank? || a.bytesize != b.bytesize
  l = a.unpack "C#{a.bytesize}"

  res = 0
  b.each_byte { |byte| res |= byte ^ l.shift }
  res == 0
end

# Get client id from env
def bc_client_id
  ENV['BC_CLIENT_ID']
end

# Get client secret from env
def bc_client_secret
  ENV['BC_CLIENT_SECRET']
end

# Get the API url from env
def bc_api_url
  ENV['BC_API_ENDPOINT'] || 'https://api.bigcommerceapp.com'
end

# Full url to this app
def app_url
  ENV['APP_URL']
end

# The scopes we are requesting (must match what we entered when
# we registered the app)
def scopes
  'store_v2_products'
end

# The auth callback url for this app (must match what we entered
# when we registered the app)
def callback_uri
  "#{app_url}/auth/bigcommerce/callback"
end

# Exchange oauth code for long-expiry token
def bc_token_exchange(code, context)
  service_url = ENV['BC_AUTH_SERVICE'] || 'https://login.bigcommerce.com'
  service_url = "#{service_url}/oauth2/token"

  params = {
    client_id: bc_client_id,
    client_secret: bc_client_secret,
    code: code,
    scope: scopes,
    grant_type: 'authorization_code',
    redirect_uri: callback_uri,
    context: context
  }

  begin
    resp = RestClient.post service_url, params
    return JSON.parse(resp.body, symbolize_names: true)
  rescue RestClient::Exception => e
    raise AuthorizationError, "Error from auth service: #{e.response.body}"
  end

  nil
end
