#!/bin/bash

# Set memlock limit to unlimited (before set -e)
ulimit -l unlimited 2&>/dev/null

set -e

[ "$DEBUG" ] && set -x

# first arg is `-f` or `--some-option`
# or there are no args
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	set -- cassandra -f "$@"
fi

# allow the container to be started with `--user`
if [ "$1" = 'cassandra' -a "$(id -u)" = '0' ]; then
	find /var/lib/cassandra /var/log/cassandra "$CASSANDRA_CONFIG" \
		\! -user cassandra -exec chown cassandra '{}' +
	exec gosu cassandra "$BASH_SOURCE" "$@"
fi

_ip_address() {
	# scrape the first non-localhost IP address of the container
	# in Swarm Mode, we often get two IPs -- the container IP, and the (shared) VIP, and the container IP should always be first
	ip address | awk '
		$1 == "inet" && $NF != "lo" {
			gsub(/\/.+$/, "", $2)
			print $2
			exit
		}
	'
}

# "sed -i", but without "mv" (which doesn't work on a bind-mounted file, for example)
_sed-in-place() {
	local filename="$1"; shift
	local tempFile
	tempFile="$(mktemp)"
	sed "$@" "$filename" > "$tempFile"
	cat "$tempFile" > "$filename"
	rm "$tempFile"
}

_yq-in-place() {
  local filename="$1"; shift
  local tempFile
  tempFile="$(mktemp)"

  # Jq fails if the yaml file is empty (or containing only blank and comment lines)
  # in this case, we just put '{}' inside the file
  if [[ "$(yq --yaml-output . $filename | wc -l)" == 0 ]]; then
    echo "{}" > $filename
  fi

  yq --yaml-output "$@" "$filename" > "$tempFile"
  cat "$tempFile" > "$filename"
  rm "$tempFile"
}

is_num() {
  re='^-?[0-9]+$'
  [[ $1 =~ $re ]] && true
}

# usage:
#   config_injection CASSANDRA $CASSANDRA_CONFIG/cassandra.yaml
# or:
#   config_injection ELASTICSEARCH $CASSANDRA_CONFIG/elasticsearch.yml
config_injection() {

  local filter=

	for v in $(compgen -v "${1}__"); do
     val="${!v}"
     if [ "$val" ]; then
        var=$(echo ${v#"${1}"}|sed 's/__/\./g')
        if is_num ${val}; then
          filter="${var}=${val}"
        else
          case ${val} in
            true)  filter="${var}=true";;
            false) filter="${var}=false";;
            *)     filter="${var}=\"${val}\"";;
          esac
        fi
        _yq-in-place $2 ${filter}
     fi
	done
}

if [ "$1" = 'cassandra' ]; then

  # btw, it has been already set in Dockerfile
  : ${CASSANDRA_DAEMON:='org.apache.cassandra.service.ElassandraDaemon'}
  export CASSANDRA_DAEMON

	: ${CASSANDRA_RPC_ADDRESS='0.0.0.0'}

	: ${CASSANDRA_LISTEN_ADDRESS='auto'}
	if [ "$CASSANDRA_LISTEN_ADDRESS" = 'auto' ]; then
		CASSANDRA_LISTEN_ADDRESS="$(_ip_address)"
	fi

	: ${CASSANDRA_BROADCAST_ADDRESS="$CASSANDRA_LISTEN_ADDRESS"}

	if [ "$CASSANDRA_BROADCAST_ADDRESS" = 'auto' ]; then
		CASSANDRA_BROADCAST_ADDRESS="$(_ip_address)"
	fi
	: ${CASSANDRA_BROADCAST_RPC_ADDRESS:=$CASSANDRA_BROADCAST_ADDRESS}

	if [ -n "${CASSANDRA_NAME:+1}" ]; then
		: ${CASSANDRA_SEEDS:="cassandra"}
	fi
	: ${CASSANDRA_SEEDS:="$CASSANDRA_BROADCAST_ADDRESS"}

	_sed-in-place "$CASSANDRA_CONFIG/cassandra.yaml" \
		-r 's/(- seeds:).*/\1 "'"$CASSANDRA_SEEDS"'"/'

	for yaml in \
		broadcast_address \
		broadcast_rpc_address \
		cluster_name \
		endpoint_snitch \
		listen_address \
		num_tokens \
		rpc_address \
		start_rpc \
	; do
		var="CASSANDRA_${yaml^^}"
		val="${!var}"
		if [ "$val" ]; then
			_sed-in-place "$CASSANDRA_CONFIG/cassandra.yaml" \
				-r 's/^(# )?('"$yaml"':).*/\2 '"$val"'/'
		fi
	done

	for rackdc in dc rack; do
		var="CASSANDRA_${rackdc^^}"
		val="${!var}"
		if [ "$val" ]; then
			_sed-in-place "$CASSANDRA_CONFIG/cassandra-rackdc.properties" \
				-r 's/^('"$rackdc"'=).*/\1 '"$val"'/'
		fi
	done


  config_injection CASSANDRA $CASSANDRA_CONFIG/cassandra.yaml
  config_injection ELASTICSEARCH $CASSANDRA_CONFIG/elasticsearch.yml

  # init script
  for f in /docker-entrypoint-init.d/*; do
    case "$f" in
        *.sh)     echo "$0: running $f"; . "$f" ;;
        *)        echo "$0: ignoring $f" ;;
    esac
  done
    
fi

exec "$@"
