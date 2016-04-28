#!/bin/bash

cd "$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
. "$(pwd)/shared.sh"

if [ ! -f "$(pwd)/app.js" ]; then
  echo "Error: Lisk installation was not found. Aborting."
  exit 1
fi

NETWORK="test"
DB_SUPER="postgres"
DB_USER=$USER
DB_NAME="lisk_test"
DB_PASS="password"

PATH="$(pwd)/bin:/usr/bin:/bin:/usr/local/bin"
LOG_FILE="$(pwd)/app.log"
PID_FILE="$(pwd)/app.pid"

CMDS=("curl" "forever" "node" "sudo" "tar")
check_cmds CMDS[@]

if [ "$1" != "coldstart" ]; then
  CMDS=("psql" "createdb" "createuser" "dropdb" "dropuser")
  check_cmds CMDS[@]
fi

################################################################################

install_psql() {
  if [ $(command -v "psql") ]; then
    echo "Existing postgres installation found."
    echo ""
  else
    local uname=`uname`
    echo "Installing postgres..."
    echo "Using: https://downloads.lisk.io/scripts/setup_postgres.$uname"
    echo ""
    curl -sL "https://downloads.lisk.io/scripts/setup_postgres.$uname" | sudo -E bash - &> /dev/null
    if [ $? -eq 1 ]; then
      echo "X Failed to install postgres."
      exit 0
    else
      echo "√ Postgres installed successfully."
    fi
  fi
}

create_user() {
  stop_lisk &> /dev/null
  drop_database &> /dev/null
  sudo -u $DB_SUPER dropuser --if-exists "$DB_USER" &> /dev/null
  if [ $? -eq 1 ]; then
    echo "X Failed to drop postgres user."
    exit 0
  fi
  sudo -u $DB_SUPER createuser --createdb "$DB_USER" &> /dev/null
  if [ $? -eq 1 ]; then
    echo "X Failed to create postgres user."
    exit 0
  fi
  sudo -u $DB_SUPER psql -c "ALTER USER "$DB_USER" WITH PASSWORD '$DB_PASS';" &> /dev/null
  if [ $? -eq 1 ]; then
    echo "X Failed to set postgres user password."
    exit 0
  else
    echo "√ Postgres user created successfully."
  fi
}

drop_database() {
  dropdb --if-exists "$DB_NAME" &> /dev/null
}

create_database() {
  drop_database
  createdb "$DB_NAME" &> /dev/null
  if [ $? -eq 1 ]; then
    echo "X Failed to create postgres database."
    exit 0
  else
    echo "√ Postgres database created successfully."
  fi
}

populate_database() {
  psql -ltAq | grep -q "^$DB_NAME|" &> /dev/null
  if [ $? -eq 1 ]; then
    download_blockchain
    restore_blockchain
  fi
}

download_blockchain() {
  echo "Downloading blockchain snapshot..."
  curl -o blockchain.tar.gz "https://downloads.lisk.io/lisk/$NETWORK/blockchain.tar.gz"
  if [ $? -eq 1 ] && [ -f blockchain.tar.gz ]; then
    tar -zxf blockchain.tar.gz
  fi
  if [ $? -eq 0 ]; then
    rm -f blockchain.*
    echo "X Failed to download blockchain snapshot."
    exit 0
  else
    echo "√ Blockchain snapshot downloaded successfully."
  fi
}

restore_blockchain() {
  echo "Restoring blockchain..."
  if [ -f blockchain.db ]; then
    psql -q -U "$DB_USER" -d "$DB_NAME" < blockchain.db
  fi
  rm -f blockchain.*
  if [ $? -eq 0 ]; then
    echo "X Failed to restore blockchain."
    exit 0
  else
    echo "√ Blockchain restored successfully."
  fi
}

autostart_cron() {
  local cmd="crontab"

  command -v "$cmd" &> /dev/null

  if [ $? -eq 1 ]; then
    echo "X Failed to execute crontab."
    return 1
  fi

  crontab=$($cmd -l 2> /dev/null | sed '/lisk\.sh start/d' 2> /dev/null)

  crontab=$(cat <<-EOF
	$crontab
	@reboot $(command -v "bash") $(pwd)/lisk.sh start > $(pwd)/cron.log 2>&1
	EOF
  )

  printf "$crontab\n" | $cmd - 2> /dev/null

  if [ $? -eq 0 ]; then
    echo "√ Crontab updated successfully."
    return 0
  else
    echo "X Failed to update crontab."
    return 1
  fi
}

coldstart_lisk() {
  install_psql
  create_user
  create_database
  populate_database
  autostart_cron
  start_lisk
}

start_lisk() {
  forever start -u lisk -a -l $LOG_FILE --pidFile $PID_FILE -m 1 app.js &> /dev/null
  if [ $? -eq 0 ]; then
    echo "√ Lisk started successfully."
  else
    echo "X Failed to start lisk."
  fi
}

stop_lisk() {
  forever stop lisk &> /dev/null
  if [ $? -eq 0 ]; then
    echo "√ Lisk stopped successfully."
  else
    echo "X Failed to stop lisk."
  fi
}

rebuild_lisk() {
  create_database
  download_blockchain
  restore_blockchain
}

check_status() {
  if [ -f "$PID_FILE" ]; then
    local PID=$(cat "$PID_FILE")
  fi
  if [ ! -z "$PID" ]; then
    ps -p "$PID" > /dev/null 2>&1
    local STATUS=$?
  else
    local STATUS=1
  fi
  if [ -f $PID_FILE ] && [ ! -z "$PID" ] && [ $STATUS -eq 0 ]; then
    echo "√ Lisk is running (as process $PID)."
  else
    echo "X Lisk is not running."
  fi
}

tail_logs() {
  if [ -f "$LOG_FILE" ]; then
    tail -f "$LOG_FILE"
  fi
}

case $1 in
"coldstart")
  coldstart_lisk
  ;;
"start")
  start_lisk
  ;;
"stop")
  stop_lisk
  ;;
"restart")
  stop_lisk
  start_lisk
  ;;
"rebuild")
  stop_lisk
  rebuild_lisk
  start_lisk
  ;;
"status")
  check_status
  ;;
"logs")
  tail_logs
  ;;
*)
  echo "Error: Unrecognized command."
  echo ""
  echo "Available commands are: coldstart start stop restart rebuild status logs"
  ;;
esac
