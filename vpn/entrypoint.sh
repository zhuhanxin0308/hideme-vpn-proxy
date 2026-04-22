#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')]" "$*"
}

require_env() {
  var_name="$1"
  eval "val=\${$var_name:-}"
  if [ -z "$val" ]; then
    echo "Missing required env: $var_name" >&2
    exit 1
  fi
}

require_env HIDEME_USERNAME
require_env HIDEME_PASSWORD

# 统一集中 hide.me 运行时路径，避免状态文件分散。
HIDEME_BIN="/opt/hide.me/hide.me"
CONF_DIR="/run/hide.me"
TOKEN_FILE="$CONF_DIR/accessToken.txt"
READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
NODE="${HIDEME_NODE:-any}"
TOKEN_HOST="${HIDEME_TOKEN_HOST:-free.hideservers.net}"
IFACE="${HIDEME_INTERFACE:-vpn}"
TUNNEL_MODE="${HIDEME_TUNNEL_MODE:-ipv4}"
KILL_SWITCH="${HIDEME_KILL_SWITCH:-true}"
PROXY_PORT="${PROXY_PORT:-3128}"
SPLIT_BYPASS="${SPLIT_TUNNEL_BYPASS:-}"
EXTRA_CONNECT_ARGS="${EXTRA_CONNECT_ARGS:-}"

mkdir -p "$CONF_DIR" "$(dirname "$READY_FILE")"
rm -f "$READY_FILE"

SPLIT_CIDRS="127.0.0.0/8"
if [ -n "$SPLIT_BYPASS" ]; then
  SPLIT_CIDRS="$SPLIT_CIDRS,$SPLIT_BYPASS"
fi

mode_args=""
case "$TUNNEL_MODE" in
  ipv4) mode_args="-4" ;;
  ipv6) mode_args="-6" ;;
  dual) mode_args="" ;;
  *) echo "Unsupported HIDEME_TUNNEL_MODE: $TUNNEL_MODE" >&2; exit 1 ;;
esac

kill_flag=""
case "$KILL_SWITCH" in
  true|1|yes) kill_flag="--kill-switch=true" ;;
  false|0|no) kill_flag="--kill-switch=false" ;;
  *) echo "Unsupported HIDEME_KILL_SWITCH: $KILL_SWITCH" >&2; exit 1 ;;
esac

cleanup() {
  # 容器退出时主动断开 VPN，并清理就绪标记。
  log "disconnecting hide.me"
  "$HIDEME_BIN" -t "$TOKEN_FILE" disconnect >/dev/null 2>&1 || true
  rm -f "$READY_FILE"
}
trap cleanup INT TERM EXIT

log "requesting access token from $TOKEN_HOST"
"$HIDEME_BIN" -u "$HIDEME_USERNAME" -P "$HIDEME_PASSWORD" -t "$TOKEN_FILE" token "$TOKEN_HOST"

log "connecting to node $NODE on interface $IFACE"
# 用参数数组方式拼接命令，避免后续拼接选项时丢失顺序。
set -- "$HIDEME_BIN"
[ -n "$mode_args" ] && set -- "$@" "$mode_args"
set -- "$@" "$kill_flag" -u "$HIDEME_USERNAME" -P "$HIDEME_PASSWORD" -t "$TOKEN_FILE" -i "$IFACE" -s "$SPLIT_CIDRS"
for arg in $EXTRA_CONNECT_ARGS; do
  set -- "$@" "$arg"
done
set -- "$@" connect "$NODE"
"$@" &
VPN_PID=$!

# 在共享命名空间里，只有默认路由切到 VPN 接口后才算真正可用。
attempt=0
max_attempts=120
while [ "$attempt" -lt "$max_attempts" ]; do
  if ! kill -0 "$VPN_PID" 2>/dev/null; then
    echo "hide.me exited before tunnel became ready" >&2
    wait "$VPN_PID"
    exit 1
  fi
  if ip link show "$IFACE" >/dev/null 2>&1; then
    if ip route show default dev "$IFACE" 2>/dev/null | grep -q . || ip -6 route show default dev "$IFACE" 2>/dev/null | grep -q .; then
      break
    fi
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ "$attempt" -ge "$max_attempts" ]; then
  echo "Timed out waiting for VPN interface $IFACE to become ready" >&2
  wait "$VPN_PID"
  exit 1
fi

printf 'ready\n' > "$READY_FILE"
log "vpn ready; proxy port $PROXY_PORT is expected in shared namespace"
wait "$VPN_PID"
