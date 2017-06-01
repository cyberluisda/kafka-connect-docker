#!/bin/bash
set -e

# Common configuration

# Functions

usage() {
    cat <<EOF
Usage:

  kafka-connect.sh
    [ --servercfg <server.cfg> ]
    start-distributed-worker | name <name_1> | file <connector_cfg_1>
    [ name <name_2> | file <connector_cfg_2> ... name <name_n> | file <connector_cfg_n> ]
    [ --config-props <property_1=value_1> [<property_2=value_2> ... <property_n=value_n> ]
    [ --config-props-over-name <name_1> <property_1=value_1> [<property_2=value_2> ... <property_n=value_n> ]]
    ...
    [ --config-props-over-name <name_n> <property_1=value_1> [<property_2=value_2> ... <property_n=value_n> ]]
    [ --config-props-over-file <file_1> <property_1=value_1> [<property_2=value_2> ... <property_n=value_n> ]]
    ...
    [ --config-props-over-file <file_n> <property_1=value_1> [<property_2=value_2> ... <property_n=value_n> ]]
    [ --config-props-from-env-var env_var_name ]
    [ --config-props-over-name-from-env-var env_var_name_1 ]
    ...
    [ --config-props-over-name-from-env-var env_var_name_n ]
    [ --config-props-over-file-from-env-var env_var_name_1 ]
    ...
    [ --config-props-over-file-from-env-var env_var_name_n ]

    start-distributed-worker: Stars worker node based on configuration of server.cfg
      In this case any connector will be launched, only a worker node.

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

  --config-props*-from-env-var are similart to config-props* but we expecta a
    environment variables names while extract the same values like if we use directly
    in command line

    For exmaple: next options are totally equivalent:

    kafka-connect.sh --config-props property_one=value_of_property_one property_two=value_of_property_two

    export GLOBAL_PROPS="property_one=value_of_property_one property_two=value_of_property_two" &&
    kafka-connect.sh --config-props-from-env-var GLOBAL_PROPS

  NOTE: For simplification of the algorithm --config-props, --config-props-over-name,
  --config-props-over-file --config-props-from-env-var,
  --config-props-over-name-from-env-var,  and --config-props-over-file-from-env-var
  options must be set at end of command line.

EOF

}

start_server_standalone() {
  connect-standalone.sh $@
}

start_server_worker() {
  connect-distributed.sh $1
}

##
# PARAMS
##
#  $1 endpoint (i.e http://localhost:8083) of distributed worker cluster.
launch_over_distributed_worker() {
  local end_point="${1}/connectors"
  shift
  while [ -n "$1" ]; do
    echo "Launching job with file $1 to worker cluster ${end_point}"
    wrapp_with_json "$1" | curl \
      -X POST \
      -H "Content-Type: application/json" \
      --data @- \
      "${end_point}"
    shift
  done
}

##
# Wrap properties file of connector configuration into a JSON file.
# and push to sdout
##
# PARAMS:
##
# $1: file name
##
wrapp_with_json() {
  # extract name
  local name=$(cat "$1" | egrep -oe '^[[:space:]]*name[[:space:]]*=.*' | sed 's/[^= ]*= *//')
  if [ "$name" == "" ]; then
    echo "FATAL: I can not extract value of property name from file $1:"
    cat "$1"
    exit 1
  fi
  local value=$(
    echo -n "{ \"name\": \"$name\", \"config\": {"
    cat "$1" | while read line; do
      #trim spaces
      line="${line// /}"
      propname="${line%=*}"
      propvalue="${line#*=}"
      echo " \"$propname\": \"$propvalue\","
    done
    # End json and mark with "d":"d" last prop to remove incongruent ','
    echo "\"d\":\"d\"}}"
  )
  # Remove incongruent "d":"d"
  echo -n $value | sed 's/,"d":"d"\}/}/'
}

edit_file() {
  local file_name="$1"
  local propertiesApplided=0
  shift
  while [[ "$1" =~ ([^= ]+)=.* ]]; do
    # Extract property name
    local property_name=${BASH_REMATCH[1]}

    # Remove exisitng property in file if exists and file is not empty
    if [ $(wc -c $file_name | cut -d ' ' -f1) -gt 0 ]; then
      local tempFile=$(mktemp)
      egrep -ve "^[[:space:]]*${property_name}[[:space:]]*=" $file_name > "$tempFile"
      mv -f "$tempFile" "$file_name"
    fi

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
distributed_mode="no"

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
        echo "ERROR: --server option without argument."
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
    start-distributed-worker)
      distributed_mode="worker"
      shift
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
    --config-props-from-env-var)
      if [ -z "$2" ]; then
        echo "--config-props-from-env-var without environment var name"
        usage
        exit 1
      fi

      env_var_name="$2"
      parameters="$(eval echo -n \$${env_var_name})"
      for f in $WORKINGPATH/*; do
        if [ "$f" != "$server_cfg_file" ]; then
          echo "Editing on-fly configuration file $f"
          edit_file "$f" $parameters > /dev/null
        fi
      done

      # Shift parameters (option and env var name)
      shift 2
      ;;
    --config-props-over-name-from-env-var)
      if [ -z "$2" ]; then
        echo "--config-props-over-name-from-env-var without environment var name"
        usage
        exit 1
      fi
      env_var_name="$2"
      parameters="$(eval echo -n \$${env_var_name})"

      #Extract (and pop) name from parameters
      read -r name parameters <<< "${parameters}"
      if [ -z "$name" ]; then
        echo "--config-props-over-name-from-env-var without connetor name when load data from ${env_var_name} environment variable"
        usage
        exit 1
      fi
      if [ -z "$parameters" ]; then
        echo "--config-props-over-name-from-env-var without any option when load data from ${env_var_name} environment variable"
        usage
        exit 1
      fi
      if [ ! -f $WORKINGPATH/$name.properties ]; then
        echo "--config-props-over-name-from-env-var: $name set does not exist. Ignoring"
      else
        echo "Editing on-fly connector $name file $WORKINGPATH/$name.properties"
        edit_file "$WORKINGPATH/$name.properties" $parameters > /dev/null
      fi

      # Shift parameters (option and env var name)
      shift 2
      ;;
    --config-props-over-file-from-env-var)
      if [ -z "$2" ]; then
        echo "--config-props-over-file-from-env-var without environment var name"
        usage
        exit 1
      fi
      env_var_name="$2"
      parameters="$(eval echo -n \$${env_var_name})"

      #Extract (and pop) fullName from parameters
      read -r fullName parameters <<< "${parameters}"
      name="$(basename $fullName)"

      if [ -z "$fullName" ]; then
        echo "--config-props-over-file-from-env-var: without connetor file name when load data from ${env_var_name} environment variable"
        usage
        exit 1
      fi
      if [ -z "$parameters" ]; then
        echo "--config-props-over-file-from-env-var without any option when load data from ${env_var_name} environment variable"
        usage
        exit 1
      fi
      if [ ! -f $WORKINGPATH/$name ]; then
        echo "--config-props-over-file-from-env-var $fullName (working file $WORKINGPATH/$name) does not exist when load data from ${env_var_name} environment variable. Ignoring"
      else
        echo "Editing on-fly cofiguration file $fullName (working file $WORKINGPATH/$name)"
        edit_file "$WORKINGPATH/$name" $parameters > /dev/null
      fi

      # Shift parameters (option and env var name)
      shift 2
      ;;
    *)
      echo "Unknown option $1"
      usage
      exit 1
      ;;
  esac
done

if [ "$distributed_mode" != "worker" ]; then
  if [ -z ${connectors_cfg} ]; then
    rm_temp_path $WORKINGPATH
    echo "Connectors list empty"
    usage
    exit 1
  fi
fi

case $distributed_mode in
  worker)
    echo "Launching worker"
    start_server_worker "${server_cfg_file}"
    ;;
  *)
    echo "Launhing standalone server, server config: ${server_cfg_file}, connectors config: ${connectors_cfg[@]}"
    start_server_standalone "${server_cfg_file}" ${connectors_cfg[@]}
    ;;
esac
