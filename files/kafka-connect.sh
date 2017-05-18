#!/bin/bash
set -e

# Common configuration

# Functions

usage() {
    cat <<EOF
Usage:

  kafka-connect.sh
    [ --servercfg <server.cfg> ]
    name <name_1> | file <connector_cfg_1>
    [ name <name_2> | file <connector_cfg_2> ... name <name_n> | file <connector_cfg_n> ]
    [ --config-props <property=value_1> [<property=value_2> ... <property=value_n> ]
    [ --config-props-over-name <name_1> <property=value_1> [<property=value_2> ... <property=value_n> ]]
    ...
    [ --config-props-over-name <name_n> <property=value_1> [<property=value_2> ... <property=value_n> ]]
    [ --config-props-over-file <file_1> <property=value_1> [<property=value_2> ... <property=value_n> ]]
    ...
    [ --config-props-over-file <file_n> <property=value_1> [<property=value_2> ... <property=value_n> ]]

  name : set that <name_n> is a name that will be used to load
    configuration from /etc/kafka-connect/<name_n>.properties

  file : set that <connector_cfg> is a path to a file with connector config
  <server.cfg> path to kafka connect server.
    By default is /etc/kafka-connect/connect.properties

  --config-props define propeties to be added/override "on-fly" over all
    connector names/files,

    <propperty=value_n> is the property to be added or override in configuration file.
    property=value_n will be directly append to a configuration file just after remove
    all properties that matchs with '^property[ \t]*=' regular expression.

  --config-props-over-name Similar to --config-props but is appliend only on connector
    name configuration.

    <name_n>. It is the name of connector when use "name <name_X>"

  --config-props-over-file Similar to --config-props-over-name but is applided on
    file configuration of connector, server.cfg file can be set too.

    <file_n>. It is the path file of connector (file <connector_cfg_n>) or value of
    <server.cfg>

  NOTE: For simplification of the algorithm --config-props, --config-props-over-name,
  and --config-props-over-file options must be set at end of command line.

EOF

}


start_server() {
  connect-standalone.sh $@
}

edit_file() {
  local file_name="$1"
  local propertiesApplided=0
  shift
  while [[ "$1" =~ ([^= ]+)=.* ]]; do

    # Extract property name
    local property_name=${BASH_REMATCH[1]}

    # Remove exisitng property in file if exists
    local tempFile=$(mktemp)
    egrep -ve "^[[:space:]]*${property_name}[[:space:]]*=" $file_name > "$tempFile"
    mv -f "$tempFile" "$file_name"

    #Append to end
    echo "" >> "$file_name"
    echo "#ON-FLY configurration maybe original value was removed above" >> "$file_name"
    echo "$1" >> "$file_name"

    shift
    propertiesApplided=$((propertiesApplided + 1))
  done

  echo -n "$propertiesApplided"
}

rm_temp_path() {
  echo "Removing temporal path $1"
  rm -fr "$1"
}


# Main

if [ -z "$1" ]
then
  usage
  exit 1
fi

# Default config
server_cfg_file="/etc/kafka-connect/connect.properties"

# Creating TEMP_PATH
WORKINGPATH=$(mktemp -d --suffix="-kafka-connect-sh")
echo "Working configuration path set to $WORKINGPATH"
if [ -f "$server_cfg_file" ]; then
  server_cfg_file_basename="$(basename $server_cfg_file)"
  cp "$server_cfg_file" "$WORKINGPATH/"
  server_cfg_file="$WORKINGPATH/$server_cfg_file_basename"
fi

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
        server_cfg_file_basename="$(basename $server_cfg_file)"
        cp "$server_cfg_file" "$WORKINGPATH/"
        server_cfg_file="$WORKINGPATH/$server_cfg_file_basename"
        shift 2
      fi
      ;;
    name)
      if [ -f "/etc/kafka-connect/${2}.properties" ]; then
        cp "/etc/kafka-connect/${2}.properties" "$WORKINGPATH/${2}.properties"
        connectors_cfg+=("$WORKINGPATH/${2}.properties")
      else
        echo "/etc/kafka-connect/${2}.properties did not find. Ignored"
      fi
      shift 2
      ;;
    file)
      if [ -f "${2}" ]; then
        cfg_file_base_name="$(basename $2)"
        cp "${2}" "$WORKINGPATH/"
        connectors_cfg+=("$WORKINGPATH/${cfg_file_base_name}")
      else
        echo "${2} did not find. Ignored"
      fi
      shift 2
      ;;
    --config-props)
      if [ -z "$2" ]; then
        echo "--config-props without any option"
        usage
        exit 1
      fi
      shift
      paramstToShift=0
      for f in $WORKINGPATH/*; do
        if [ "$f" != "$server_cfg_file" ]; then
          echo "Editing on-fly configuration file $f"
          paramstToShift=$(edit_file "$f" "$@")
        fi
      done

      # Shift parameters applied on edit_file
      shift $paramstToShift
      ;;
    --config-props-over-name)
      if [ -z "$2" ]; then
        echo "--config-props-over-name without name"
        usage
        exit 1
      fi
      name="$2"
      shift 2
      if [ -z "$1" ]; then
        echo "--config-props-over-name without any option"
        usage
        exit 1
      fi
      if [ ! -f $WORKINGPATH/$name.properties ]; then
        echo "--config-props-over-name $name set does not exist. Ignoring"
        # Clean current --config-props-over-name
        while [[ "$1" =~ ..*=.* ]]; do
          shift
        done
      else
        echo "Editing on-fly connector $name file $WORKINGPATH/$name.properties"
        paramstToShift=$(edit_file "$WORKINGPATH/$name.properties" "$@")

        # Shift parameters applied on edit_file
        shift $paramstToShift
      fi
      ;;
    --config-props-over-file)
      if [ -z "$2" ]; then
        echo "--config-props-over-file without file-name"
        usage
        exit 1
      fi
      fullName=$2
      name="$(basename $2)"
      shift 2
      if [ -z "$1" ]; then
        echo "--config-props-over-file without any option"
        usage
        exit 1
      fi
      if [ ! -f $WORKINGPATH/$name ]; then
        echo "--config-props-over-file file set does not exist. Ignoring"
        # Clean current --config-props-over-name
        while [[ "$1" =~ ..*=.* ]]; do
          shift
        done
      else
        echo "Editing on-fly cofiguration file $fullName (working file $WORKINGPATH/$name)"
        paramstToShift=$(edit_file "$WORKINGPATH/$name" "$@")

        # Shift parameters applied on edit_file
        shift $paramstToShift
      fi
      ;;
    *)
      echo "Unknown option $1"
      usage
      exit 1
      ;;
  esac
done

if [ -z ${connectors_cfg} ]; then
  rm_temp_path $WORKINGPATH
  echo "Connectors list empty"
  usage
  exit 1
fi

echo "launhing servers start_server "${server_cfg_file}" ${connectors_cfg[@]}"
start_server "${server_cfg_file}" ${connectors_cfg[@]}
