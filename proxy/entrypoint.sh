#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')]" "$*"
}

READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
PORT="${PROXY_PORT:-3128}"
LISTEN="${PROXY_LISTEN:-0.0.0.0}"
TIMEOUT="${PROXY_TIMEOUT:-600}"
MAX_CLIENTS="${PROXY_MAX_CLIENTS:-200}"
MIN_SPARE="${PROXY_MIN_SPARE_SERVERS:-5}"
MAX_SPARE="${PROXY_MAX_SPARE_SERVERS:-20}"
START_SERVERS="${PROXY_START_SERVERS:-10}"
MAX_REQUEST_SIZE="${PROXY_MAX_REQUEST_SIZE:-0}"
ALLOW_LIST="${PROXY_ALLOW:-}"
AUTH_USER="${PROXY_BASIC_AUTH_USER:-}"
AUTH_PASS="${PROXY_BASIC_AUTH_PASSWORD:-}"
CONF_FILE="/tmp/tinyproxy.conf"

# 代理进程必须等 VPN 可用后再启动，否则第一次请求就会走错出口。
log "waiting for vpn ready flag"
for _ in $(seq 1 180); do
  if [ -f "$READY_FILE" ]; then
    break
  fi
  sleep 1
done

if [ ! -f "$READY_FILE" ]; then
  echo "VPN ready flag not found: $READY_FILE" >&2
  exit 1
fi

cat > "$CONF_FILE" <<EOF
User tinyproxy
Group tinyproxy
Port $PORT
Listen $LISTEN
Timeout $TIMEOUT
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogLevel Info
PidFile "/tmp/tinyproxy.pid"
MaxClients $MAX_CLIENTS
MinSpareServers $MIN_SPARE
MaxSpareServers $MAX_SPARE
StartServers $START_SERVERS
MaxRequestsPerChild 0
DisableViaHeader Yes
ConnectPort 80
ConnectPort 443
ConnectPort 563
ConnectPort 8443
ConnectPort 9443
EOF

if [ "$MAX_REQUEST_SIZE" != "0" ]; then
  printf 'MaxRequestSize %s\n' "$MAX_REQUEST_SIZE" >> "$CONF_FILE"
fi

if [ -n "$AUTH_USER" ] && [ -n "$AUTH_PASS" ]; then
  printf 'BasicAuth %s %s\n' "$AUTH_USER" "$AUTH_PASS" >> "$CONF_FILE"
fi

# 允许列表按逗号拆分，方便在环境变量中声明多个来源网段。
old_ifs="$IFS"
IFS=','
for cidr in $ALLOW_LIST; do
  [ -n "$cidr" ] || continue
  printf 'Allow %s\n' "$cidr" >> "$CONF_FILE"
done
IFS="$old_ifs"

log "starting tinyproxy on $LISTEN:$PORT"
exec tinyproxy -d -c "$CONF_FILE"
