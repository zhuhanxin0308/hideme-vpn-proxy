#!/bin/sh
set -eu

READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
PORT="${PROXY_PORT:-3128}"
HOST="${PROXY_HEALTHCHECK_HOST:-127.0.0.1}"

fail() {
  echo "proxy healthcheck failed: $*" >&2
  exit 1
}

[ -f "$READY_FILE" ] || fail "vpn ready file missing: $READY_FILE"
pidof tinyproxy >/dev/null 2>&1 || fail "tinyproxy process not running"
nc -z -w 3 "$HOST" "$PORT" || fail "tinyproxy not listening on ${HOST}:${PORT}"

exit 0
