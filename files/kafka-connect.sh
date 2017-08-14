#!/bin/bash
set -e

# Common configuration
WAIT_BETWEEN_CHECKS=${WAIT_BETWEEN_CHECKS:-5}
WAIT_FOR_FIRST_CHECK=${WAIT_FOR_FIRST_CHECK:-15}
CHECK_MESSAGES=${CHECK_MESSAGES:-no}
CHECK_EGREP_PATTERN=${CHECK_EGREP_PATTERN:-RUNNING}
CHECK_ONLY_TASK=${CHECK_ONLY_TASK:-yes}
CHECK_LOGSTASH_URI="${CHECK_LOGSTASH_URI}"

# Functions

usage() {
    cat <<EOF
Usage:

  kafka-connect.sh
    [ --servercfg <server.cfg> ]
    [ --distributed-end-point <url> [--health-check-all | --health-check-one] [--force-remove]]
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

  --distributed-end-point <url>: If this opition is present, connectors will be
    launched using REST service behind this <url> end point.
    After response of REST service current process will be end.

  --health-check-one and --health-check-all. When one of this option is present
    and --distributed-end-point is active too, current program does not finish
    just after launchs connector over distributed cluster (default). Instead of
    this current program will remaining checking at least one task per connector
    is running:

    --health-check-all: Current program will finish with exit status 2 if there
    are not any job with at least one task in running mode.

    --health-check-one: Current program will finish with exit status 2 when one
    job connetor will have not any task in running mode.

  --force-remove: If present and connector exists with same name. Existing connector
    will be removed before launch connector over distributed cluster.

  start-distributed-worker: Stars worker node based on configuration of server.cfg
    In this case any connector will be launched, only a worker node.

  name : set that <name_n> is a name that will be used to load
    configuration from /etc/kafka-connect/<name_n>.properties.
    NOTE: In distrbuted mode /etc/kafka-connect/<name_n>.properties will
    be wrapped with a JSON file in order to starts connector over connector class.

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

  ENVIRONMENT CONFIGURATION.
    There are some configuration and behaviours that can be set using next Environment
    Variables:

      WAIT_BETWEEN_CHECKS. Used only with --health-check options. Time in seconds to wait
        between two checks. Default: 5

      WAIT_FOR_FIRST_CHECK. Used only with --health-check options. Time in seconds to wait
        just before to do first check. Default: 15

      CHECK_MESSAGES. Used only with --health-check options. If it is "yes" some
        debug information about health check test is showed for stdout. Default "no"

      CHECK_EGREP_PATTERN. Used only with --health-check options. Pattern to match
        kafka connect status output to consider a Kafa connector as healthy. Default RUNNING

      CHECK_ONLY_TASK. Used only with --health-check options. If it is "yes", task
        status is filtered from kafka connect status output before to evalue pattern.
        This is ussefull when kafka connector is in "RUNNING" mode, but all tasks
        are terminated (with an fatal error for example). Default yes

      CHECK_LOGSTASH_URI. Used only with --health-check options. If it is
        defined, some health-check messages will be sent to logstash server in
        json format through tcp (using nc).
        Expected format is host:port where logstash is listening.

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
#  $1 force_remove: if yes and there are one job with same name, exsisting job will
#     be removed just before launch new connector
#  $2 endpoint (i.e http://localhost:8083) of distributed worker cluster.
#  $3..$@ connectors configurations
launch_over_distributed_worker() {
  local force_remove="$1"
  shift
  local original_endpoint=$1
  local end_point="${1}/connectors"
  shift
  while [ -n "$1" ]; do
    if [ "$force_remove" == "yes" ]; then
      local connector_to_delete_name=$(check_exist_in_distributed "$original_endpoint" "$1")
      delete_by_name_in_distributed "$original_endpoint" "$connector_to_delete_name"
    fi
    echo "Launching job with file $1 to worker cluster ${end_point} with configuration (on-fly)"
    echo "From:"
    cat "$1"
    echo "To:"
    wrap_with_json "$1"
    echo ""
    wrap_with_json "$1" | curl \
      -X POST \
      -H "Content-Type: application/json" \
      --data @- \
      "${end_point}"
    shift
  done
}

##
# Checks if connector loaded from configuratin exists, if exists return connector name.
# Else return empty string
##
# PARAMS
##
#   $1 endpoint (i.e http://localhost:8083) of distributed worker cluster.
#   $2 onnectors configurations
##
check_exist_in_distributed(){
  local end_point="$1/connectors"
  shift
  # extract name
  local name=$(cat "$1" | egrep -oe '^[[:space:]]*name[[:space:]]*=.*' | sed 's/[^= ]*= *//')
  local error_code=$(curl "$end_point/$name/status" | jq '.error_code' 2> /dev/null)

  # With error_code null connector exists
  if [ "$error_code" == "null" ]; then
    echo -n $name
  else
    echo -n ""
  fi
}

##
# Delete existing job by name
##
# PARAMS
##
#   $1 endpoint (i.e http://localhost:8083) of distributed worker cluster.
#   $2 connectors name
##
delete_by_name_in_distributed(){
  if [ -n "$2" ]; then
    local end_point="$1/connectors/$2"
    echo "Deleting job $2 ($end_point)"

    curl -XDELETE "$end_point"
  fi
}

##
# PARAMS
##
#  $1 check mode, allowed values
#     none: no check
#     all: exit with error status when there is not any job which status matchs with
#          CHECK_EGREP_PATTERN
#     one: exit with error status when there is at least one job which status matchs with
#          CHECK_EGREP_PATTERN
#     ANY_OTHER_VALUE: same as none
#  $2 endpoint (i.e http://localhost:8083) of distributed worker cluster.
#  $3..$@ connectors configurations
health_check_over_distributed_mode(){
  echo ""
  echo "Starting health check with config" $@
  local mode="${1}"
  shift
  local end_point="${1}/connectors"
  shift

  #Extract names
  local -a names
  while [ -n "$1" ]; do
    local name=$(cat "$1" | egrep -oe '^[[:space:]]*name[[:space:]]*=.*' | sed 's/[^= ]*= *//')
    if [ "$name" == "" ]; then
      echo "FATAL: I can not extract value of property name from file $1:"
      cat "$1"
      exit 1
    fi
    names+=($name)
    shift
  done

  #Sleep at begin to give time to connectors startup
  sleep $WAIT_FOR_FIRST_CHECK

  while [ "$mode" == "all" -o "$mode" == "one" ]; do
    local failing=0
    for (( i=0 ; i<${#names[@]} ; i++ )); do
      local name="${names[i]}"
      local url="${end_point}/$name/status"
      local extractJsonPath=""
      if [ "${CHECK_ONLY_TASK}" == "yes" ]; then
        extractJsonPath=".tasks"
      fi
      [ "$CHECK_MESSAGES" == "yes" ] && echo -n "checking connector $name..."
      local curlOutput="$(curl -s "$url")"
      local curlFiltered="$(echo "$curlOutput" | jq "$extractJsonPath")"
      if echo "$curlFiltered" | egrep -e "$CHECK_EGREP_PATTERN" 2>&1 > /dev/null; then
        [ "$CHECK_MESSAGES" == "yes" ] && echo "OK"
        [ "$CHECK_MESSAGES" == "yes" ] && logstash "Checking pattern $CHECK_EGREP_PATTERN over $curlOutput filtered by $extractJsonPath => $curlFiltered with result OK" "DEBUG"
      else
        [ "$CHECK_MESSAGES" == "yes" ] && echo "$curlFiltered"
        [ "$CHECK_MESSAGES" == "yes" ] && echo "KO"
        logstash "Checking pattern $CHECK_EGREP_PATTERN over $curlOutput filtered by $extractJsonPath => $curlFiltered with result FAILS" "WARN"
        failing=$((failing + 1))
      fi

      if [ "$mode" == "one" -a $failing -gt 0 ]; then
        echo "Status of job $name returned response that does not match with $CHECK_EGREP_PATTERN patthern and check mode is $mode => ERROR"
        logstash "Status of job $name returned response that does not match with $CHECK_EGREP_PATTERN patthern and check mode is $mode => ERROR" "ERROR"
        exit 2
      fi

      if [ "$mode" == "all" -a $failing -ge ${#names[@]}  ]; then
        echo "Any job of: ${names[@]} returned response that does not match with $CHECK_EGREP_PATTERN patthern and check mode is $mode => ERROR"
        logstash "Any job of: ${names[@]} returned response that does not match with $CHECK_EGREP_PATTERN patthern and check mode is $mode => ERROR" "ERROR"
        exit 2
      fi
    done
    sleep $WAIT_BETWEEN_CHECKS
  done
}

##
# PARAMS
##
#  $1 message will be sent to logstash
#  $2 Optional level message, default INFO
#  $3 Optional host:port where logstash is listening.
#     If it is empty. CHECK_LOGSTASH_URI will be use.
#     If CHECK_LOGSTASH_URI is empty any message will be launched (deactivated)
#
logstash(){
  local message="$(escapeJson "$1")"
  local level="$2"
  [ -z "$level" ] && level="INFO"

  local logstashUri="$3"
  [ -z "$logstashUri" ] && logstashUri="${CHECK_LOGSTASH_URI}"

  if [ -n "$logstashUri" ]
  then
    local logstashHost=${logstashUri%:*}
    local logstashPort=${logstashUri#*:}
    local timestamp="$(date +%s)000"
    local hostname="$(hostname)"
    local jsonMessage="{ \"timestamp\": \"$timestamp\", \"HOSTNAME\": \"$hostname\", \"level\": \"$level\", \"message\": \"$message\"}"
    local verbose=""
    [ "$CHECK_MESSAGES" == "yes" ] && verbose="-vv"
    echo "$jsonMessage" | nc $verbose $logstashHost $logstashPort
  fi
}

##
##
# $1 string with json to escape
#
escapeJson(){
    echo -n "$1" | sed 's/"/\\"/g' | sed -r 's/$/\\n/g'| tr -d "\n"
}

##
# Wrap properties file of connector configuration into a JSON file.
# and push to sdout
##
# PARAMS:
##
# $1: file name
##
wrap_with_json() {
  # extract name
  local name=$(cat "$1" | egrep -oe '^[[:space:]]*name[[:space:]]*=.*' | sed 's/[^= ]*= *//')
  if [ "$name" == "" ]; then
    echo "FATAL: I can not extract value of property name from file $1:"
    cat "$1"
    exit 1
  fi
  local value=$(
    echo -n "{ \"name\": \"$name\", \"config\": {"
    #Properties file without emptylines and comments
    cat "$1" | egrep -ve '^[[:space:]]*$' | egrep -ve '^[[:space:]]*#' | while read line; do
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
  echo -n $value | sed 's/, "d":"d"\}/}/'
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
distributed_url_end_point=""
#Allowed values are none, all, one
healt_check_in_distributed_mode="none"
#Allowed values yes/no
force_remove_in_distributed_mode="no"

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
    --distributed-end-point)
      if [ "$2" == "" ]
      then
        echo "ERROR: --distributed-end-point option without argument."
        usage
        exit 1
      else
        distributed_mode="distributed"
        distributed_url_end_point="$2"
      fi
      shift 2
      ;;
    --health-check-one)
      healt_check_in_distributed_mode="one"
      shift
      ;;
    --health-check-all)
      healt_check_in_distributed_mode="all"
      shift
      ;;
    --force-remove)
      force_remove_in_distributed_mode="yes"
      shift
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
  distributed)
    echo "Launching jobs over distributed cluster workes. End point: $distributed_url_end_point, connectors config: ${connectors_cfg[@]}"
    launch_over_distributed_worker "$force_remove_in_distributed_mode" "$distributed_url_end_point" ${connectors_cfg[@]}
    health_check_over_distributed_mode "$healt_check_in_distributed_mode" "$distributed_url_end_point" ${connectors_cfg[@]}
    ;;
  worker)
    echo "Launching worker"
    start_server_worker "${server_cfg_file}"
    ;;
  *)
    echo "Launhing standalone server, server config: ${server_cfg_file}, connectors config: ${connectors_cfg[@]}"
    start_server_standalone "${server_cfg_file}" ${connectors_cfg[@]}
    ;;
esac
