#!/bin/sh
set -eu

READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
PORT="${PROXY_PORT:-3128}"

fail() {
  echo "proxy healthcheck failed: $*" >&2
  exit 1
}

validate_port() {
  case "$PORT" in
    ''|*[!0-9]*)
      fail "invalid proxy port: $PORT"
      ;;
  esac

  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    fail "invalid proxy port: $PORT"
  fi
}

port_hex() {
  # /proc/net/tcp* 用十六进制端口表示监听套接字，这里统一转成大写方便比对。
  printf '%04X' "$1"
}

port_is_listening_in_file() {
  proc_file="$1"
  expected_port_hex="$2"

  [ -r "$proc_file" ] || return 1

  awk -v expected_port_hex="$expected_port_hex" '
    NR > 1 {
      split($2, local_address, ":")
      if (toupper(local_address[2]) == expected_port_hex && $4 == "0A") {
        found = 1
        exit 0
      }
    }

    END {
      exit found ? 0 : 1
    }
  ' "$proc_file"
}

port_is_listening() {
  expected_port_hex="$(port_hex "$PORT")"

  # 同时检查 IPv4 和 IPv6 监听表，避免用户切到 IPv6 监听地址后被误判。
  port_is_listening_in_file /proc/net/tcp "$expected_port_hex" && return 0
  port_is_listening_in_file /proc/net/tcp6 "$expected_port_hex" && return 0
  return 1
}

[ -f "$READY_FILE" ] || fail "vpn ready file missing: $READY_FILE"
validate_port
port_is_listening || fail "proxy port is not listening: $PORT"

exit 0
