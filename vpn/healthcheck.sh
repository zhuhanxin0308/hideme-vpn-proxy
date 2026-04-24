#!/bin/sh
set -eu

GOOGLE_URL="${VPN_HEALTHCHECK_URL:-https://www.google.com/}"
TIMEOUT="${VPN_HEALTHCHECK_TIMEOUT:-5}"

fail() {
  echo "vpn healthcheck failed: $*" >&2
  exit 1
}

# 只检查真实访问 Google 的能力，避免接口、路由或 ready 标记短暂抖动导致 VPN 被反复重启。
curl --fail --silent --show-error --max-time "$TIMEOUT" --output /dev/null "$GOOGLE_URL" \
  || fail "cannot access $GOOGLE_URL"

exit 0
