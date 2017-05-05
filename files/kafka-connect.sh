#!/bin/bash
set -e

# Common configuration

# Functions

usage() {
    echo "kafka-connect.sh [--servercfg server.cfg] name name_1|file connector_cfg_1 [name name_2|file connector_cfg_2 .. name name_n|file connector_cfg_n] "
    echo "  name : set that connector_cfg is a name that will be used to load"
    echo "    configuration from /etc/kafka-connect/connector_cfg.properties"
    echo "  file : set that connector_cfg is a path to a file with connector config"
    echo "    name test is the same like file /etc/kafka-connect/test.properties"
    echo "  server.cfg path to kafka connect server."
    echo "    By default is /etc/kafka-connect/connect.properties"
}


start_server() {
  connect-standalone.sh $@
}

# Main

if [ -z "$1" ]
then
  usage
  exit 1
fi

# Default config
server_cfg_file="/etc/kafka-connect/connect.properties"

connectors_cfg=()
while [ -n "$1" ]; do
  case $1 in
    --server)
      if [ "$2" == "" ]
      then
        usage
        exit 1
      else
        server_cfg_file="$2"
        shift
      fi
      ;;
    name)
      connectors_cfg+=("/etc/kafka-connect/${2}.properties")
      shift
      ;;
    file)
      connectors_cfg+=("$2")
      shift
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

start_server "${server_cfg_file}" ${connectors_cfg[@]}
