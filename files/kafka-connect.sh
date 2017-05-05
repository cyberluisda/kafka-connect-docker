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

expandVarsStrict() {
    # Originally from http://stackoverflow.com/a/40167919/488191
    # Excerpt under CC-By-SA 3.0 by http://stackoverflow.com/users/45375/

    local line lineEscaped
    while IFS= read -r line || [[ -n $line ]]; do # the `||` clause ensures that the last line is read even if it doesn't end with \n
	# Escape ALL chars. that could trigger an expansion
	IFS= read -r -d '' lineEscaped < <(printf %s "$line" | tr '`([$' '\1\2\3\4')
	# ... then selectively reenable ${ references
	lineEscaped=${lineEscaped//$'\4{'/\$'{'}
	# Finally, escape embedded double quotes to preserve them.
	lineEscaped=${lineEscaped//\"/\\\"}
	eval "printf '%s\n' \"$lineEscaped\"" | tr '\1\2\3\4' '`([$'
    done
}

resolve_variables() {
    for VAR in `env`
    do
	if [[ $VAR =~ ^KC_OVERRIDE_ ]]; then
	    kconnect_name=$(echo "$VAR" | sed -r 's/KC_OVERRIDE_(.*)=.*/\1/g' | tr '[:upper:]' '[:lower:]' | tr _ .)
	    env_var=$(echo "$VAR" | sed -r 's/(.*)=.*/\1/g')

	    if egrep -q "(^|^#)$kconnect_name=" "$1"; then
		sed -r -i "s@(^|^#)($kconnect_name)=(.*)@\2=${!env_var}@g" "$1"
	    else
		echo "Preexisting variable $kconnect_name not found at $1" >&2
	    fi
	fi

	expandVarsStrict < "$1" > "$1.exp.properties"

	echo "$1.exp.properties"
    done
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
      connectors_cfg+=($(resolve_variables "/etc/kafka-connect/${2}.properties"))
      shift
      ;;
    file)
      connectors_cfg+=($(resolve_variables "$2"))
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
