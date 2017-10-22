require 'digest/sha1'
require 'mysql2'
require 'sinatra/base'
require 'redis'

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

    def redis
      @redis ||= Redis.current
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
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
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
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    row = statement.execute(name).first
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
    statement = db.prepare('SELECT * FROM message WHERE id > ? AND channel_id = ? ORDER BY id DESC LIMIT 100')
    rows = statement.execute(last_message_id, channel_id).to_a
    response = []
    rows.each do |row|
      r = {}
      r['id'] = row['id']
      statement = db.prepare('SELECT name, display_name, avatar_icon FROM user WHERE id = ?')
      r['user'] = statement.execute(row['user_id']).first
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      response << r
      statement.close
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

    rows = db.query('SELECT id FROM channel').to_a
    channel_ids = rows.map { |row| row['id'] }

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
    statement = db.prepare('SELECT * FROM message WHERE channel_id = ? ORDER BY id DESC LIMIT ? OFFSET ?')
    rows = statement.execute(@channel_id, n, (@page - 1) * n).to_a
    statement.close
    @messages = []
    rows.each do |row|
      r = {}
      r['id'] = row['id']
      statement = db.prepare('SELECT name, display_name, avatar_icon FROM user WHERE id = ?')
      r['user'] = statement.execute(row['user_id']).first
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      @messages << r
      statement.close
    end
    @messages.reverse!

    statement = db.prepare('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?')
    cnt = statement.execute(@channel_id).first['cnt'].to_f
    statement.close
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
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    @user = statement.execute(user_name).first
    statement.close

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
    statement = db.prepare('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())')
    statement.execute(name, description)
    channel_id = db.last_id
    statement.close
    redirect "/channel/#{channel_id}", 303
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

        avatar_name = digest + ext
        avatar_data = data
      end
    end

    if !avatar_name.nil? && !avatar_data.nil?
      statement = db.prepare('INSERT INTO image (name, data) VALUES (?, ?)')
      statement.execute(avatar_name, avatar_data)
      statement.close
      statement = db.prepare('UPDATE user SET avatar_icon = ? WHERE id = ?')
      statement.execute(avatar_name, user['id'])
      statement.close
    end

    if !display_name.nil? || !display_name.empty?
      statement = db.prepare('UPDATE user SET display_name = ? WHERE id = ?')
      statement.execute(display_name, user['id'])
      statement.close
    end

    redirect '/', 303
  end

  get '/icons/:file_name' do
    file_name = params[:file_name]
    statement = db.prepare('SELECT * FROM image WHERE name = ?')
    row = statement.execute(file_name).first
    statement.close
    ext = file_name.include?('.') ? File.extname(file_name) : ''
    mime = ext2mime(ext)
    if !row.nil? && !mime.empty?
      content_type mime
      return row['data']
    end
    404
  end

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
    statement = db.prepare('SELECT * FROM user WHERE id = ?')
    user = statement.execute(user_id).first
    statement.close
    user
  end

  def initialize_channel_message_count
    channel_count = db.prepare('SELECT channel_id, COUNT(*) AS cnt FROM message GROUP BY channel_id').execute
    puts channel_count.map{|h| ["channel_message_count:#{h['channel_id']}", h['cnt']]}.flatten
    redis.mset channel_count.map{|h| ["channel_message_count:#{h['channel_id']}", h['cnt']]}.flatten
  end

  def db_add_message(channel_id, user_id, content)
    statement = db.prepare('INSERT INTO message (channel_id, user_id, content, created_at) VALUES (?, ?, ?, NOW())')
    messages = statement.execute(channel_id, user_id, content)
    statement.close

    redis.incr "channel_message_count:#{channel_id}"

    messages
  end

  def channel_message_count(channel_id)
    redis.get "channel_message_count:#{channel_id}"
  end

  def set_user_channel_message_count(user_id, channel_id)
    count = channel_message_count(channel_id)
    redis.set "user_channel_message_count:#{user_id}:#{channel_id}", count
  end

  def get_channel_message_counts(channel_ids)
    redis.mget(channel_ids.map{|id| "channel_message_count:#{id}"}).map(&:to_i)
  end

  def get_user_channel_message_counts(user_id, channel_ids)
    redis.mget(channel_ids.map{|id| "user_channel_message_count:#{user_id}:#{id}"}).map(&:to_i)
  end

  def random_string(n)
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    statement = db.prepare('INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())')
    statement.execute(user, salt, pass_digest, user, 'default.png')
    row = db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first
    statement.close
    row['last_insert_id']
  end

  def get_channel_list_info(focus_channel_id = nil)
    channels = db.query('SELECT * FROM channel ORDER BY id').to_a
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
