require 'mysql2'

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

def public_folder
  File.expand_path('../../public', __FILE__)
end

def image_path(image)
  "#{public_folder}/image/#{image['name']}"
end

def main
  images = db.prepare('SELECT id, name, data FROM image').execute
  images.each do |image|
    puts "#{image['id']}: Creating... #{image_path(image)}"
    File.write(image_path(image), image[:data])
    puts "#{image['id']}: Created!"
  end
end

main
