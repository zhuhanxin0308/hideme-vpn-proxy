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
MAX_REQUEST_SIZE="${PROXY_MAX_REQUEST_SIZE:-0}"
ALLOW_LIST="${PROXY_ALLOW:-}"
AUTH_USER="${PROXY_BASIC_AUTH_USER:-}"
AUTH_PASS="${PROXY_BASIC_AUTH_PASSWORD:-}"
REQUIRE_AUTH="${PROXY_REQUIRE_AUTH:-false}"
UPSTREAM_TYPE="${PROXY_UPSTREAM_TYPE:-}"
UPSTREAM_HOST="${PROXY_UPSTREAM_HOST:-}"
UPSTREAM_PORT="${PROXY_UPSTREAM_PORT:-}"
CONF_FILE="/tmp/tinyproxy.conf"

fail() {
  echo "$*" >&2
  exit 1
}

validate_port() {
  value="$1"
  name="$2"

  case "$value" in
    ''|*[!0-9]*)
      fail "Invalid ${name}: ${value}"
      ;;
  esac

  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    fail "Invalid ${name}: ${value}"
  fi
}

validate_positive_integer() {
  value="$1"
  name="$2"

  case "$value" in
    ''|*[!0-9]*)
      fail "Invalid ${name}: ${value}"
      ;;
  esac

  if [ "$value" -lt 1 ]; then
    fail "Invalid ${name}: ${value}"
  fi
}

validate_nonnegative_integer() {
  value="$1"
  name="$2"

  case "$value" in
    ''|*[!0-9]*)
      fail "Invalid ${name}: ${value}"
      ;;
  esac
}

auth_is_required() {
  case "$REQUIRE_AUTH" in
    true|1|yes) return 0 ;;
    false|0|no) return 1 ;;
    *) fail "Unsupported PROXY_REQUIRE_AUTH: $REQUIRE_AUTH" ;;
  esac
}

upstream_is_configured() {
  [ -n "$UPSTREAM_TYPE" ] || [ -n "$UPSTREAM_HOST" ] || [ -n "$UPSTREAM_PORT" ]
}

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

validate_port "$PORT" "PROXY_PORT"
validate_positive_integer "$MAX_CLIENTS" "PROXY_MAX_CLIENTS"
validate_nonnegative_integer "$MAX_REQUEST_SIZE" "PROXY_MAX_REQUEST_SIZE"

if [ -n "$AUTH_USER$AUTH_PASS" ] && { [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; }; then
  fail "Incomplete basic auth configuration: set PROXY_BASIC_AUTH_USER and PROXY_BASIC_AUTH_PASSWORD together"
fi

if auth_is_required && { [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; }; then
  fail "PROXY_REQUIRE_AUTH is true but PROXY_BASIC_AUTH_USER or PROXY_BASIC_AUTH_PASSWORD is empty"
fi

if upstream_is_configured; then
  if [ -z "$UPSTREAM_TYPE" ] || [ -z "$UPSTREAM_HOST" ] || [ -z "$UPSTREAM_PORT" ]; then
    fail "incomplete upstream configuration: set PROXY_UPSTREAM_TYPE, PROXY_UPSTREAM_HOST and PROXY_UPSTREAM_PORT together"
  fi

  case "$UPSTREAM_TYPE" in
    http|socks4|socks5)
      ;;
    *)
      fail "Unsupported PROXY_UPSTREAM_TYPE: $UPSTREAM_TYPE"
      ;;
  esac

  validate_port "$UPSTREAM_PORT" "PROXY_UPSTREAM_PORT"
fi

cat > "$CONF_FILE" <<EOF
Port $PORT
Listen $LISTEN
Timeout $TIMEOUT
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogLevel Info
PidFile "/tmp/tinyproxy.pid"
MaxClients $MAX_CLIENTS
DisableViaHeader Yes
ConnectPort 80
ConnectPort 443
ConnectPort 563
ConnectPort 8443
ConnectPort 9443
EOF

if upstream_is_configured; then
  # 公网入口代理只负责接入，真实外连交给 VPN 命名空间内的出口代理。
  printf 'Upstream %s %s:%s\n' "$UPSTREAM_TYPE" "$UPSTREAM_HOST" "$UPSTREAM_PORT" >> "$CONF_FILE"
fi

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
