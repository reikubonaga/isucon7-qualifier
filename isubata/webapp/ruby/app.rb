require 'digest/sha1'
require 'mysql2'
require 'sinatra/base'
require 'redis'
require 'pry'

require 'redis'

class App < Sinatra::Base
  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :avatar_max_size, 1 * 1024 * 1024

    enable :sessions

    redis = Redis.new(host: ENV["REDIS_HOST"])
    Redis.current = redis
  end

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = db_get_user(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end

    def image_file_path(filename)
      "#{public_path}/icons/#{filename}"
    end

    def public_path
      File.expand_path('../../public', __FILE__)
    end

    def redis
      @redis ||= Redis.current
    end

    def all_channel_ids_key
      "all_channel_ids"
    end

    def get_all_channel_ids
      ids_json = redis.get(all_channel_ids_key)
      if ids_json
        JSON.parse(ids_json)
      else
        set_all_channel_ids
      end
    end

    def set_all_channel_ids
      ids = db.query('SELECT id FROM channel').to_a.map{|row| row['id'] }
      redis.set(all_channel_ids_key, ids.to_json)
      ids
    end

    def all_channels_order_by_id_key
      "all_channels_order_by_id"
    end

    def get_all_channels_order_by_id
      rows = redis.zrange(all_channels_order_by_id_key, 0, -1)
      if rows.length == 0
        set_all_channels_order_by_id
      else
        rows.map {|row| JSON.parse(row) }
      end
    end

    def set_all_channels_order_by_id
      channels = db.query('SELECT * FROM channel ORDER BY id').to_a
      redis.zadd(all_channels_order_by_id_key, channels.map{ |c| [c['id'], c.to_json] })
      channels
    end
  end

  get '/initialize' do
    db.query("DELETE FROM user WHERE id > 1000")
    db.query("DELETE FROM image WHERE id > 1001")
    db.query("DELETE FROM channel WHERE id > 10")
    db.query("DELETE FROM message WHERE id > 10000")
    db.query("DELETE FROM haveread")

    redis.flushall

    initialize_channel_message_count
    initialize_user
    initialize_message

    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue => e
      return 409 if e.message == "register"
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    name = params[:name]
    row = get_user_by_name(name)
    if row.nil? || row['password'] != Digest::SHA1.hexdigest(row['salt'] + params[:password])
      return 403
    end
    session[:user_id] = row['id']
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    db_add_message(channel_id.to_i, user_id, message)
    204
  end

  get '/message' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i

    rows = get_message_by_channel_id_and_last_message_id(channel_id, last_message_id: last_message_id)

    user_ids = rows.map{|h| h['user_id']}
    users = get_users_by_ids(user_ids)

    response = []
    rows.each_with_index do |row, index|
      r = {}
      r['id'] = row['id']
      r['user'] = users[index]
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      response << r
    end
    response.reverse!

    set_user_channel_message_count(user_id, channel_id)

    content_type :json
    response.to_json
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    sleep 1.0

    channel_ids = get_all_channel_ids

    channel_message_counts = get_channel_message_counts(channel_ids)
    user_channel_message_counts = get_user_channel_message_counts(user_id, channel_ids)

    res = []
    channel_ids.each_with_index do |channel_id, index|
      r = {}
      r['channel_id'] = channel_id
      r['unread'] = user_channel_message_counts[index] != 0 ? channel_message_counts[index] - user_channel_message_counts[index] : channel_message_counts[index]
      res << r
    end

    content_type :json
    res.to_json
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end
    if @page !~ /\A\d+\Z/ || @page == '0'
      return 400
    end
    @page = @page.to_i

    n = 20
    rows = get_message_by_channel_id_and_last_message_id(@channel_id, offset: (@page - 1) * n, limit: n)

    user_ids = rows.map{|h| h['user_id']}
    users = get_users_by_ids(user_ids)

    @messages = []
    rows.each_with_index do |row, index|
      r = {}
      r['id'] = row['id']

      r['user'] = users[index]
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      @messages << r
    end
    @messages.reverse!

    cnt = get_channel_messge_count(@channel_id).to_f
    @max_page = cnt == 0 ? 1 :(cnt / n).ceil

    return 400 if @page > @max_page

    @channels, @description = get_channel_list_info(@channel_id)
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info

    user_name = params[:user_name]
    @user = get_user_by_name(user_name)

    if @user.nil?
      return 404
    end

    @self_profile = user['id'] == @user['id']
    erb :profile
  end

  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    # statement = db.prepare('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())')
    # statement.execute(name, description)
    # channel_id = db.last_id
    # statement.close

    # Save channel
    _channel, id = redis.zrange(all_channels_order_by_id_key, -1, -1, with_scores: true).last # get max id
    new_id = id.to_i + 1
    now = Time.now
    attributes = {
      'id': new_id,
      'name': name,
      'description': description,
      'updated_at': now.to_s,
      'created_at': now.to_s,
    }
    redis.zadd(all_channels_order_by_id_key, [new_id, attributes.to_json])

    # Refresh all_channel_ids
    ids = get_all_channel_ids << new_id
    redis.set(all_channel_ids_key, ids)

    redirect "/channel/#{new_id}", 303
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = "#{digest}#{Time.now.to_i}#{ext}"
        avatar_data = data
      end
    end

    if !avatar_name.nil? && !avatar_data.nil?
      File.write(image_file_path(avatar_name), avatar_data)

      user["avatar_icon"] = avatar_name
    end

    if !display_name.nil? || !display_name.empty?
      user["display_name"] = display_name
    end

    set_user(user)

    redirect '/', 303
  end

  # Deprecated
  # get '/icons/:file_name' do
  #   file_name = params[:file_name]
  #   statement = db.prepare('SELECT * FROM image WHERE name = ?')
  #   row = statement.execute(file_name).first
  #   statement.close
  #   ext = file_name.include?('.') ? File.extname(file_name) : ''
  #   mime = ext2mime(ext)
  #   if !row.nil? && !mime.empty?
  #     content_type mime
  #     return row['data']
  #   end
  #   404
  # end

  private

  def db
    return @db_client if defined?(@db_client)

    @db_client = Mysql2::Client.new(
      host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
      port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
      username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
      password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
      database: 'isubata',
      encoding: 'utf8mb4'
    )
    @db_client.query('SET SESSION sql_mode=\'TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY\'')
    @db_client
  end

  def db_get_user(user_id)
    user_data = redis.get "users:#{user_id}"
    if user_data
      JSON.load(user_data)
    else
      nil
    end
  end

  def initialize_user
    users = db.prepare('SELECT * FROM user').execute
    redis.set "user_key", users.size
    redis.mset users.map{|h| ["users:#{h['id']}", h.to_json]}.flatten
    redis.mset users.map{|h| ["user_name:#{h['name']}", h['id']]}.flatten
  end

  def get_user_by_name(name)
    id = redis.get "user_name:#{name}"
    JSON.load(redis.get("users:#{id}"))
  end

  def get_users_by_ids(ids)
    return [] if ids.size == 0
    redis.mget(*ids.map{|id| "users:#{id}"}).map{|d| JSON.load(d)}
  end

  def set_user(user)
    redis.set "users:#{user['id']}", user.to_json
  end

  def initialize_message
    messages = db.prepare('SELECT * FROM message').execute
    messages.group_by{|h| h['channel_id']}.each do |channel_id, messages|
      messages.each do |h|
        redis.zadd *["messages:#{channel_id}", h['id'], h.to_json]
      end
    end
  end

  def initialize_channel_message_count
    channel_count = db.prepare('SELECT channel_id, COUNT(*) AS cnt FROM message GROUP BY channel_id').execute
    redis.mset *channel_count.map{|h| ["channel_message_count:#{h['channel_id']}", h['cnt']]}.flatten
  end

  def db_add_message(channel_id, user_id, content)

    id = redis.incr "message_key"
    data = {
      id: id,
      user_id: user_id,
      channel_id: channel_id,
      content: content,
      created_at: Time.now,
    }
    redis.zadd "messages:#{channel_id}", data.to_json

    redis.incr "channel_message_count:#{channel_id}"

    messages
  end

  def get_message_by_channel_id_and_last_message_id(channel_id, last_message_id: 0, limit: 100, offset: 0)
    data = redis.zrevrangebyscore("messages:#{channel_id}", 100_000_000, (last_message_id.to_i + 1), :limit => [offset, limit])

    if data
      data.map{|d| d=JSON.load(d);d['created_at'] = Time.parse(d['created_at']);d}
    else
      nil
    end
  end

  def channel_message_count(channel_id)
    redis.get "channel_message_count:#{channel_id}"
  end

  def set_user_channel_message_count(user_id, channel_id)
    count = channel_message_count(channel_id)
    redis.set "user_channel_message_count:#{user_id}:#{channel_id}", count
  end

  def get_channel_messge_count(channel_id)
    redis.get("channel_message_count:#{channel_id}").to_i
  end

  def get_channel_message_counts(channel_ids)
    redis.mget(*channel_ids.map{|id| "channel_message_count:#{id}"}).map(&:to_i)
  end

  def get_user_channel_message_counts(user_id, channel_ids)
    redis.mget(*channel_ids.map{|id| "user_channel_message_count:#{user_id}:#{id}"}).map(&:to_i)
  end

  def random_string(n)
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)

    # 文字数
    if user.length > 191
      raise "register"
    end

    id = redis.get "user_name:#{user}"
    if id
      raise "register"
    end

    id = redis.incr "user_key"
    data = {
      id: id,
      name: user,
      salt: salt,
      password: pass_digest,
      display_name: user,
      avatar_icon: 'default.png',
    }
    redis.set "users:#{id}", data.to_json
    redis.set "user_name:#{user}", id

    id
  end

  def get_channel_list_info(focus_channel_id = nil)
    channels = get_all_channels_order_by_id
    description = ''
    channels.each do |channel|
      if channel['id'] == focus_channel_id
        description = channel['description']
        break
      end
    end
    [channels, description]
  end

  def ext2mime(ext)
    if ['.jpg', '.jpeg'].include?(ext)
      return 'image/jpeg'
    end
    if ext == '.png'
      return 'image/png'
    end
    if ext == '.gif'
      return 'image/gif'
    end
    ''
  end
end
