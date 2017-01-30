#!/bin/sh
set -e

# Common configuration

# Functions

use() {
    echo "kafka-connect.sh name|file connector_cfg [server.cfg]"
    echo "  name : set that connector_cfg is a name that will be used to load"
    echo "    configuration from /etc/kafka-connect/connector_cfg.properties"
    echo "  file : set that connector_cfg is a path to a file with connector config"
    echo "    name test is the same like file /etc/kafka-connect/test.properties"
    echo "  server.cfg path to kafka connect server."
    echo "    By default is /etc/kafka-connect/connect.properties"
}


start_server() {
  connect-standalone.sh "$1" "$2"
}

# Main

if [ -z "$2" ]
then
  use
  exit 1
fi

connector_cfg=""
case $1 in
  name)
    connector_cfg="/etc/kafka-connect/${2}.properties"
    ;;
  file)
    connector_cfg="$2"
    ;;
  *)
    use
    exit 1
    ;;
esac

server_cfg_file="/etc/kafka-connect/connect.properties"
if [ ! -z "$3" ]
then
  server_cfg_file="$3"
fi

start_server "${server_cfg_file}" "${connector_cfg}"
