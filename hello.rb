require 'sinatra'
require 'data_mapper'
require 'omniauth-bigcommerce'
require 'json'
require 'base64'
require 'openssl'
require 'bigcommerce'
require 'logger'

configure do
  set :run, true
  set :environment, :development

  # We need to disable frame protection because our app lives inside an iframe.
  set :protection, except: [:http_origin, :frame_options]

  use Rack::Session::Cookie, secret: ENV['SESSION_SECRET']
  use Rack::Logger

  use OmniAuth::Builder do
    provider :bigcommerce, bc_client_id, bc_client_secret, scope: scopes
    OmniAuth.config.full_host = app_url || nil
  end
end

DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite3://#{Dir.pwd}/data/dev.db")

# User model
class User
  include DataMapper::Resource

  property :id,    Serial
  property :email, String, required: true, unique: [:store_id]

  belongs_to :store
end

# Bigcommerce store model
class Store
  include DataMapper::Resource

  property :id,           Serial
  property :store_hash,   String, required: true
  property :access_token, String, required: true

  has n, :users

  # Since we support multiple users per store, we keep track of
  # which user installed the app and treat them as the admin for
  # this store.
  belongs_to :admin_user, model: User, required: false

  validates_presence_of :access_token, :store_hash
  validates_uniqueness_of :store_hash

  def bc_api
    config = {
      store_hash: self.store_hash,
      client_id: bc_client_id,
      access_token: self.access_token
    }
    Bigcommerce::Api.new(config)
  end

  def bc_api_working?
    time = bc_api.time
    time && time.key?("time")
  end
end

DataMapper.finalize.auto_upgrade!

# App interface
get '/' do
  @user = current_user
  return render_error('[home] Unauthorized!') unless @user

  @bc_api_url = bc_api_url
  @client_id = bc_client_id
  @products = JSON.pretty_generate(@user.store.bc_api.products)

  erb :index
end

# Auth callback
get '/auth/:name/callback' do
  auth = request.env['omniauth.auth']
  unless auth && auth[:extra][:raw_info][:context]
    return render_error("[install] Invalid credentials: #{JSON.pretty_generate(auth[:extra])}")
  end

  email = auth[:info][:email]
  store_hash = auth[:extra][:raw_info][:context].split('/')[1]
  token = auth[:credentials][:token].token

  # Lookup store
  store = Store.first(store_hash: store_hash)
  return render_error("[install] Already installed!") if store

  # Create store record
  logger.info "[install] Installing app for store '#{store_hash}' with admin '#{email}'"
  store = Store.create(store_hash: store_hash, access_token: token)

  # Create admin user
  user = User.first_or_create(email: email, store_id: store.id)
  store.admin_user_id = user.id
  store.save!

  # Other one-time installation provisioning goes here.

  session[:user_id] = user.id
  redirect '/'
end

# Load endpoint. This sample app supports multiple users, in which case
# the load endpoint is used to provision additional users.
get '/load' do
  # Decode payload
  payload = parse_signed_payload
  return render_error('[load] Invalid payload signature!') unless payload

  email = payload[:user][:email]
  store_hash = payload[:store_hash]

  # Lookup store
  store = Store.first(store_hash: store_hash)
  return render_error("[load] Store not found!") unless store

  # Find/create user
  user = User.first_or_create(email: email, store_id: store.id)
  return render_error('[load] Invalid user!') unless user

  # Login and redirect to home page
  logger.info "[load] Loading app for user '#{email}'"
  session[:user_id] = user.id
  redirect '/'
end

# Uninstall endpoint
get '/uninstall' do
  # Decode payload
  payload = parse_signed_payload
  return render_error('[uninstall] Invalid payload signature!') unless payload

  email = payload[:user][:email]
  store_hash = payload[:store_hash]

  # Lookup store
  store = Store.first(store_hash: store_hash)
  return render_error("[uninstall] Store not found!") unless store

  # Verify that the user performing the operation exists and is the admin
  user = User.first(email: email, store_id: store.id)
  return render_error('[uninstall] Unauthorized!') unless user && user.id == store.admin_user_id

  # They are uninstalling our app from the store, so deprovision
  # store and all its users
  logger.info "[uninstall] Uninstalling app for store '#{store_hash}'"
  store.users.destroy
  store.destroy

  # Return 204
  session.clear
  return 204
end

# Remove user endpoint; used when multi-user support is enabled.
# Note that you should accept user ids that you may not have seen
# yet. This is possible when Bigcommerce store owners enable access
# for one of their users, but then revokes access before they 
# actually load the app.
get '/remove-user' do
  # Decode payload
  payload = parse_signed_payload
  return render_error('[remove-user] Invalid payload signature!') unless payload

  email = payload[:user][:email]
  store_hash = payload[:store_hash]

  # Lookup store
  store = Store.first(store_hash: store_hash)
  return render_error("[remove-user] Store not found!") unless store

  # Deprovision user if it exists
  logger.info "[remove-user] Removing user '#{email}' from store '#{store_hash}'"
  user = User.first(email: email, store_id: store.id)
  user.destroy if user

  # Return 204
  return 204
end

# Gets the current user in session
def current_user
  session[:user_id] ? User.get(session[:user_id]) : nil
end

# Verify given signed_payload string and return the data if valid.
def parse_signed_payload
  signed_payload = params[:signed_payload]
  message_parts = signed_payload.split('.')

  encoded_json_payload = message_parts[0]
  encoded_hmac_signature = message_parts[1]

  payload = Base64.decode64(encoded_json_payload)
  provided_signature = Base64.decode64(encoded_hmac_signature)

  expected_signature = sign_payload(bc_client_secret, payload)

  if secure_compare(expected_signature, provided_signature)
    return JSON.parse(payload, symbolize_names: true)
  end

  nil
end

# Sign payload string using HMAC-SHA256 with given secret
def sign_payload(secret, payload)
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

def render_error(e)
  logger.warn "ERROR: #{e}"
  @error = e
  erb :error
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

