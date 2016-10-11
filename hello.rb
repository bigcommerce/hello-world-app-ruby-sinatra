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
  property :email, String, required: true, unique: true

  has n, :stores, :through => Resource
end

# Bigcommerce store model
class Store
  include DataMapper::Resource

  property :id,           Serial
  property :store_hash,   String, required: true
  property :access_token, String, required: true
  property :scope,        Text

  has n, :users, :through => Resource

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
  @store = current_store
  return render_error('[home] Unauthorized!') unless @user && @store

  @bc_api_url = bc_api_url
  @client_id = bc_client_id
  @products = JSON.pretty_generate(@store.bc_api.products)

  erb :index
end

get '/instructions' do
  erb :instructions
end

# Auth callback
get '/auth/:name/callback' do
  auth = request.env['omniauth.auth']
  unless auth && auth[:extra][:raw_info][:context]
    return render_error("[install] Invalid credentials: #{JSON.pretty_generate(auth[:extra])}")
  end

  email = auth[:info][:email]
  store_hash = auth[:extra][:context].split('/')[1]
  token = auth[:credentials][:token].token
  scope = auth[:extra][:scopes]

  # Lookup store
  store = Store.first(store_hash: store_hash)
  if store
    logger.info "[install] Updating token for store '#{store_hash}' with scope '#{scope}'"
    store.update(access_token: token, scope: scope)
    user = store.admin_user
  else
    # Create store record
    logger.info "[install] Installing app for store '#{store_hash}' with admin '#{email}'"
    store = Store.create(store_hash: store_hash, access_token: token, scope: scope)

    # Create admin user and associate with store
    user = User.first_or_create(email: email)
    user.stores << store
    user.save

    # Set admin user in Store record
    store.admin_user_id = user.id
    store.save
  end

  # Other one-time installation provisioning goes here.

  # Login and redirect to home page
  session[:store_id] = store.id
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
  user = User.first_or_create(email: email)
  return render_error('[load] User not found!') unless user

  # Add store association if it doesn't exist
  unless StoreUser.first(store_id: store.id, user_id: user.id)
    user.stores << store
    user.save
  end

  # Login and redirect to home page
  logger.info "[load] Loading app for user '#{email}' on store '#{store_hash}'"
  session[:store_id] = store.id
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
  user = User.first(email: email)
  unless user && user.id == store.admin_user_id
    return render_error('[uninstall] Unauthorized!')
  end

  # They are uninstalling our app from the store, so deprovision store
  logger.info "[uninstall] Uninstalling app for store '#{store_hash}'"
  StoreUser.all(store_id: store.id).destroy
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

  # Remove StoreUser association
  logger.info "[remove-user] Removing user '#{email}' from store '#{store_hash}'"
  user = User.first(email: email)
  if user
    StoreUser.first(store_id: store.id, user_id: user.id).destroy
  end

  # Return 204
  return 204
end

# Gets the current user from session
def current_user
  return nil unless session[:user_id]
  User.get(session[:user_id])
end

# Gets the current user's store from session
def current_store
  user = current_user
  return nil unless user
  return nil unless session[:store_id]
  user.stores.get(session[:store_id])
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
  ENV['BC_API_ENDPOINT'] || 'https://api.bigcommerce.com'
end

# Full url to this app
def app_url
  ENV['APP_URL']
end

# The scopes we are requesting (must match what is requested in
# Developer Portal).
def scopes
  ENV.fetch('SCOPES', 'store_v2_products')
end
