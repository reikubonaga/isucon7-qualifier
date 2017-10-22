#!/bin/bash

echo 'Rotate log file...'
  ./rotate.sh
echo 'Rotated log file!'

echo 'Update config file...'
  sudo cp "$HOME/nginx.conf" /etc/nginx/nginx.conf
  # sudo cp "$HOME/redis.conf" /etc/redis/redis.conf
  # sudo cp "$HOME/my.conf" /etc/mysql/my.cnf
echo 'Updateed config file!'

echo 'Update service unit file...'
  # -rw-r--r-- 1 root root 382 Oct 22 17:02 /etc/systemd/system/isubata.ruby.service
  sudo cp "$HOME/isubata.ruby.service" /etc/systemd/system/isubata.ruby.service
echo 'Updated service unit file!'

if [ "$1" = "--bundle" ]; then
  echo 'Start bundle install...'
  cd /home/isucon/isubata/webapp/ruby
  /home/isucon/local/ruby/bin/bundle install
  cd "$HOME"
  echo 'bundle install finished!'
fi

# TODO(south37) Only in host1 and host2
echo 'Restart services...'
  sudo systemctl restart nginx.service
  # sudo systemctl restart redis.service
  # Save cache
  # sudo systemctl restart mysql.service
  sudo systemctl restart isubata.ruby.service
echo 'Restarted!'
