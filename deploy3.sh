#!/bin/bash

echo 'Update config file...'
  # sudo cp "$HOME/my.conf" /etc/mysql/my.cnf
echo 'Updateed config file!'

if [ "$1" = "--bundle" ]; then
  echo 'Start bundle install...'
  cd /home/isucon/isubata/webapp/ruby
  /home/isucon/local/ruby/bin/bundle install
  cd "$HOME"
  echo 'bundle install finished!'
fi

echo 'Restart services...'
  # Save cache
  # sudo systemctl restart mysql.service
  sudo systemctl restart isubata.ruby.service
echo 'Restarted!'
