#!/bin/bash

# Set memlock limit to unlimited (before set -e)
ulimit -l unlimited

set -e

# first arg is `-f` or `--some-option`
if [ "${1:0:1}" = '-' ]; then
	set -- bin/cassandra
fi

# allow the container to be started with `--user`
if [ "$1" = 'bin/cassandra' -a "$(id -u)" = '0' ]; then
	chown -R cassandra /var/lib/cassandra /var/log/cassandra "$CASSANDRA_CONF"
	exec gosu cassandra "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'bin/cassandra' ]; then

  cd $CASSANDRA_HOME
  ARGS="-f -p $CASSANDRA_PIDFILE -e"

  : ${CASSANDRA_DAEMON:'org.apache.cassandra.service.ElassandraDaemon'}
  export CASSANDRA_DAEMON

	: ${CASSANDRA_RPC_ADDRESS='0.0.0.0'}

	: ${CASSANDRA_LISTEN_ADDRESS='auto'}
	if [ "$CASSANDRA_LISTEN_ADDRESS" = 'auto' ]; then
		CASSANDRA_LISTEN_ADDRESS="$(hostname --ip-address)"
	fi

	: ${CASSANDRA_BROADCAST_ADDRESS="$CASSANDRA_LISTEN_ADDRESS"}

	if [ "$CASSANDRA_BROADCAST_ADDRESS" = 'auto' ]; then
		CASSANDRA_BROADCAST_ADDRESS="$(hostname --ip-address)"
	fi
	: ${CASSANDRA_BROADCAST_RPC_ADDRESS:=$CASSANDRA_BROADCAST_ADDRESS}

	if [ -n "${CASSANDRA_NAME:+1}" ]; then
		: ${CASSANDRA_SEEDS:="cassandra"}
	fi
	: ${CASSANDRA_SEEDS:="$CASSANDRA_BROADCAST_ADDRESS"}

	sed -ri 's/(- seeds:).*/\1 "'"$CASSANDRA_SEEDS"'"/' "$CASSANDRA_CONF/cassandra.yaml"

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
			sed -ri 's/^(# )?('"$yaml"':).*/\2 '"$val"'/' "$CASSANDRA_CONF/cassandra.yaml"
		fi
	done

	for rackdc in dc rack; do
		var="CASSANDRA_${rackdc^^}"
		val="${!var}"
		if [ "$val" ]; then
			sed -ri 's/^('"$rackdc"'=).*/\1 '"$val"'/' "$CASSANDRA_CONF/cassandra-rackdc.properties"
		fi
	done
fi

exec $@ $ARGS
