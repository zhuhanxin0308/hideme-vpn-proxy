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
RESOLV_CONF_PATH="${VPN_RESOLV_CONF_PATH:-/etc/resolv.conf}"
FALLBACK_DNS="${VPN_FALLBACK_DNS:-8.8.8.8}"
NODE="${HIDEME_NODE:-any}"
TOKEN_HOST="${HIDEME_TOKEN_HOST:-any}"
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

normalize_hide_me_host() {
  # 兼容旧版本错误使用的 free 主机名，并统一抽取 hide.me/hideservers 的短名称。
  case "$1" in
    ""|free|free.hide.me|free.hideservers.net|any|any.hide.me|any.hideservers.net) printf '%s' "any" ;;
    *.hideservers.net) printf '%s' "${1%.hideservers.net}" ;;
    *.hide.me) printf '%s' "${1%.hide.me}" ;;
    *) printf '%s' "$1" ;;
  esac
}

resolve_token_host() {
  # 与官方 CLI 保持一致：请求 URL 用完整域名，请求体 host 用短名称。
  host_short_name="$(normalize_hide_me_host "$1")"
  case "$host_short_name" in
    *.*) printf '%s' "$host_short_name" ;;
    *) printf '%s.hideservers.net' "$host_short_name" ;;
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

ensure_fallback_dns() {
  # Docker 会在容器启动时生成 resolv.conf，这里在运行时追加公共解析器作为兜底。
  [ -n "$FALLBACK_DNS" ] || return 0

  if [ ! -f "$RESOLV_CONF_PATH" ]; then
    printf 'nameserver %s\n' "$FALLBACK_DNS" > "$RESOLV_CONF_PATH"
    return 0
  fi

  if grep -Eq "^[[:space:]]*nameserver[[:space:]]+${FALLBACK_DNS}([[:space:]]|$)" "$RESOLV_CONF_PATH"; then
    return 0
  fi

  printf 'nameserver %s\n' "$FALLBACK_DNS" >> "$RESOLV_CONF_PATH"
}

request_access_token() {
  # 官方 CLI 的 token 子命令会进入交互式凭据流程，因此容器里改为直接调用 REST 接口取 token。
  token_host_short_name="$(normalize_hide_me_host "$TOKEN_HOST")"
  token_host="$(resolve_token_host "$TOKEN_HOST")"
  response=$(curl --fail --silent --show-error \
    --cacert "$HIDEME_CA_FILE" \
    --header 'Content-Type: application/json' \
    --data-binary "{\"domain\":\"hide.me\",\"host\":$(json_quote "$token_host_short_name"),\"username\":$(json_quote "$HIDEME_USERNAME"),\"password\":$(json_quote "$HIDEME_PASSWORD")}" \
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
ensure_fallback_dns

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

vpn_route_ready() {
  # hide.me 通过 RPDB + table 55555 实现漏网保护，主路由表不会切成 default dev vpn。
  if ! ip rule show 2>/dev/null | grep -Eq '(^|[[:space:]])lookup 55555($|[[:space:]])'; then
    return 1
  fi

  if ip route show table 55555 2>/dev/null | grep -Eq "(^|[[:space:]])dev ${IFACE}($|[[:space:]])"; then
    return 0
  fi

  if ip -6 route show table 55555 2>/dev/null | grep -Eq "(^|[[:space:]])dev ${IFACE}($|[[:space:]])"; then
    return 0
  fi

  return 1
}

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
  if ip link show "$IFACE" >/dev/null 2>&1 && vpn_route_ready; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ "$attempt" -ge "$max_attempts" ]; then
  echo "Timed out waiting for VPN interface $IFACE to become ready" >&2
  wait "$VPN_PID"
  exit 1
fi

ensure_fallback_dns
printf 'ready\n' > "$READY_FILE"
log "vpn ready; proxy port $PROXY_PORT is expected in shared namespace"
wait "$VPN_PID"
