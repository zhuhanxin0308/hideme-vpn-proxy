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

# 统一集中 hide.me 运行时路径，避免状态文件分散；同时允许测试或特殊部署覆写默认位置。
HIDEME_BIN="${HIDEME_BIN_PATH:-/opt/hide.me/hide.me}"
HIDEME_CA_FILE="${HIDEME_CA_CERT_PATH:-/opt/hide.me/CA.pem}"
CONF_DIR="${HIDEME_CONF_DIR:-/run/hide.me}"
TOKEN_FILE="$CONF_DIR/accessToken.txt"
CONFIG_FILE="$CONF_DIR/hide.me.yml"
READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
NODE="${HIDEME_NODE:-any}"
TOKEN_HOST="${HIDEME_TOKEN_HOST:-free.hideservers.net}"
IFACE="${HIDEME_INTERFACE:-vpn}"
TUNNEL_MODE="${HIDEME_TUNNEL_MODE:-ipv4}"
KILL_SWITCH="${HIDEME_KILL_SWITCH:-true}"
PROXY_PORT="${PROXY_PORT:-3128}"
SPLIT_BYPASS="${SPLIT_TUNNEL_BYPASS:-}"
EXTRA_CONNECT_ARGS="${EXTRA_CONNECT_ARGS:-}"

if [ ! -x "$HIDEME_BIN" ]; then
  echo "hide.me binary is missing or not executable: $HIDEME_BIN" >&2
  exit 1
fi

if [ ! -f "$HIDEME_CA_FILE" ]; then
  echo "hide.me CA bundle is missing: $HIDEME_CA_FILE" >&2
  exit 1
fi

yaml_quote() {
  # YAML 单引号字符串里，单引号自身需要成对转义。
  escaped=$(printf '%s' "$1" | sed "s/'/''/g")
  printf "'%s'" "$escaped"
}

json_quote() {
  # Access-Token REST 请求体是 JSON，因此要转义反斜杠、双引号和常见控制字符。
  escaped=$(printf '%s' "$1" | \
    sed \
      -e 's/\\/\\\\/g' \
      -e 's/"/\\"/g' \
      -e 's/\t/\\t/g' \
      -e 's/\r/\\r/g')
  printf '"%s"' "$escaped"
}

resolve_token_host() {
  # 与 hide.me 自身的主机名规则对齐：短名称补全到 hideservers.net。
  case "$1" in
    *.*) printf '%s' "$1" ;;
    *) printf '%s.hideservers.net' "$1" ;;
  esac
}

write_hide_me_config() {
  # hide.me 在非终端环境下不会交互读取密码，因此必须把敏感凭据落到配置文件里。
  cat > "$CONFIG_FILE" <<EOF
client:
  CA: $(yaml_quote "$HIDEME_CA_FILE")
  accessTokenPath: $(yaml_quote "$TOKEN_FILE")
  username: $(yaml_quote "$HIDEME_USERNAME")
  password: $(yaml_quote "$HIDEME_PASSWORD")
EOF
  chmod 600 "$CONFIG_FILE"
}

request_access_token() {
  # 官方 CLI 的 token 子命令会进入交互式凭据流程，因此容器里改为直接调用 REST 接口取 token。
  token_host="$(resolve_token_host "$TOKEN_HOST")"
  response=$(curl --fail --silent --show-error \
    --cacert "$HIDEME_CA_FILE" \
    --header 'Content-Type: application/json' \
    --data "{\"domain\":\"hide.me\",\"host\":\"\",\"username\":$(json_quote "$HIDEME_USERNAME"),\"password\":$(json_quote "$HIDEME_PASSWORD")}" \
    "https://${token_host}:432/v1.0.0/accessToken")

  case "$response" in
    \"*\") token_value=${response#\"}; token_value=${token_value%\"} ;;
    *) echo "Unexpected access token response" >&2; return 1 ;;
  esac

  printf '%s' "$token_value" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
}

mkdir -p "$CONF_DIR" "$(dirname "$READY_FILE")"
rm -f "$READY_FILE"
write_hide_me_config

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
  true|1|yes) kill_flag="-k=true" ;;
  false|0|no) kill_flag="-k=false" ;;
  *) echo "Unsupported HIDEME_KILL_SWITCH: $KILL_SWITCH" >&2; exit 1 ;;
esac

cleanup() {
  # 容器退出时主动断开 VPN，并清理就绪标记。
  log "disconnecting hide.me"
  "$HIDEME_BIN" -c "$CONFIG_FILE" disconnect >/dev/null 2>&1 || true
  rm -f "$READY_FILE"
}
trap cleanup INT TERM EXIT

log "requesting access token from $TOKEN_HOST"
request_access_token

log "connecting to node $NODE on interface $IFACE"
# 用参数数组方式拼接命令，避免后续拼接选项时丢失顺序。
set -- "$HIDEME_BIN" -c "$CONFIG_FILE"
[ -n "$mode_args" ] && set -- "$@" "$mode_args"
set -- "$@" "$kill_flag" -i "$IFACE" -s "$SPLIT_CIDRS"
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
