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

function config {
  header
  apps "$@"
}

function header {
cat <<EOF
global
  log 127.0.0.1 local0
  log 127.0.0.1 local1 notice
  maxconn 4096
defaults
  log            global
  retries             3
  maxconn          2000
  timeout connect  5000
  timeout client  50000
  timeout server  50000
listen stats
  bind 127.0.0.1:9090
  balance
  mode http
  stats enable
  stats auth admin:admin
EOF
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

config "$@" > "$HAPROXY_CFG"
haproxy_start

while true
do
  sleep "$REFRESH_TIMEOUT"
  config "$@" > "$HAPROXY_CFG_TMP"
  if ! diff -q "$HAPROXY_CFG_TMP" "$HAPROXY_CFG" >&2
  then
    cp "$HAPROXY_CFG_TMP" "$HAPROXY_CFG"
    haproxy_reload
  fi
done