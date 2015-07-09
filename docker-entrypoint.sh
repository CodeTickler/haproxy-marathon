#!/bin/bash

set -e

REFRESH_TIMEOUT=${REFRESH_TIMEOUT:-60}
LISTEN=${LISTEN:-0.0.0.0}

HAPROXY_PID=/var/run/haproxy.pid
HAPROXY_CFG=/etc/haproxy/haproxy.cfg
HAPROXY_CFG_TMP=/tmp/haproxy.cfg

function haproxy_start {
  haproxy -f "$HAPROXY_CFG" -D -p "$HAPROXY_PID"
}

function haproxy_reload {
  haproxy -f "$HAPROXY_CFG" -D -p "$HAPROXY_PID" -sf $(cat "$HAPROXY_PID")
}

function haproxy_soft_reload {
  # Soft-reload haproxy, avoiding any broken connection attempts
  # (see http://marc.info/?l=haproxy&m=133262017329084&w=2)
  # (see also http://engineeringblog.yelp.com/2015/04/true-zero-downtime-haproxy-reloads.html)

  PORTS=$(cat "$HAPROXY_CFG" | grep '^ *\<bind\>.*:' | sed -E 's/.*:(.+)/\1/')
  for PORT in $PORTS; do
      iptables -I INPUT -p tcp --dport $PORT --syn -j DROP
  done

  sleep 0.5
  haproxy_reload

  for PORT in $PORTS; do
      iptables -D INPUT -p tcp --dport $PORT --syn -j DROP
  done
}

function config {
  header
  apps "$@"
}

function header {
cat <<EOF
global
  log /dev/log local0 notice
  maxconn 4096
defaults
  log            global
  retries             3
  maxconn          2000
  timeout connect  ${CONNECT_TIMEOUT:-11s}
  timeout client   ${CLIENT_TIMEOUT:-11m}
  timeout server   ${SERVER_TIMEOUT:-11m}
EOF

if [ ! -z "$ENABLE_STATS" ]
then
  echo "listen stats"

  if [ ! -z "$STATS_LISTEN_PORT" ]
  then
    echo "  bind ${STATS_LISTEN_HOST:-127.0.0.1}:${STATS_LISTEN_PORT:-9090}"
  fi

  if [ ! -z "$STATS_LISTEN_PORT_INDEX" ]
  then
    echo "  bind ${STATS_LISTEN_HOST:-127.0.0.1}:$(eval echo \${PORT$STATS_LISTEN_PORT_INDEX})"
  fi

  cat <<EOF
  balance
  mode http
  stats enable
  stats uri /
EOF

  if [ ! -z "$STATS_USER" ] || [ ! -z "$STATS_PASSWORD" ]
  then
    echo "  stats auth ${STATS_USER:-admin}:${STATS_PASSWORD:-admin}"
  fi
fi
}

function apps {
  (until curl -sSfLk -m 10 -H 'Accept: text/plain' "${1%/}"/v2/tasks; do [ $# -lt 2 ] && return 1 || shift; done) | while read -r txt
  do
    set -- $txt
    if [ $# -lt 2 ]; then
      shift $#
      continue
    fi

    local app_name="$1"
    local app_port="$2"
    shift 2

    for ignored_app in ${IGNORED_APPS}
    do
      if [ "${app_name}" = "${ignored_app}" ]; then
        shift $#
        continue 2
      fi
    done

    if [ ! -z "${app_port##*[!0-9]*}" ]
    then
      cat <<EOF
listen ${app_name}-${app_port}
  bind ${LISTEN}:${app_port}
  mode tcp
  option tcplog
  balance leastconn
EOF
      while [[ $# -ne 0 ]]
      do
        out "  server ${app_name}-$# $1 check"
        shift
      done
    fi
  done
}

function msg { out "$*" >&2 ;}
function err { local x=$? ; msg "$*" ; return $(( $x == 0 ? 1 : $x )) ;}
function out { printf '%s\n' "$*" ;}

if [ "$#" -lt 1 ]; then
  echo "USAGE: $0 <marathon_masters>"
  exit 1
fi

mkdir -p $(dirname "$HAPROXY_CFG")
config "$@" > "$HAPROXY_CFG"
haproxy_start

while true
do
  sleep "$REFRESH_TIMEOUT"
  config "$@" > "$HAPROXY_CFG_TMP"
  if ! diff -q "$HAPROXY_CFG_TMP" "$HAPROXY_CFG" >&2
  then
    cp "$HAPROXY_CFG_TMP" "$HAPROXY_CFG"
    if [ ! -z "$HAPROXY_SOFT_RELOAD" ]; then
        haproxy_soft_reload
    else
        haproxy_reload
    fi
  fi
done
