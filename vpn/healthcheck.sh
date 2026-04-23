#!/bin/sh
set -eu

READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
IFACE="${HIDEME_INTERFACE:-vpn}"
ROUTE_TABLE="${VPN_ROUTE_TABLE:-55555}"
DNS_CONNECT_TIMEOUT="${VPN_DNS_CONNECT_TIMEOUT:-3}"

fail() {
  echo "vpn healthcheck failed: $*" >&2
  exit 1
}

has_global_addr() {
  ip -o addr show dev "$IFACE" scope global 2>/dev/null | grep -Eq 'inet6? '
}

has_policy_route() {
  ip rule show 2>/dev/null | grep -Eq "(^|[[:space:]])lookup ${ROUTE_TABLE}($|[[:space:]])" || return 1

  if ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -Eq "(^|[[:space:]])dev ${IFACE}($|[[:space:]])"; then
    return 0
  fi

  if ip -6 route show table "$ROUTE_TABLE" 2>/dev/null | grep -Eq "(^|[[:space:]])dev ${IFACE}($|[[:space:]])"; then
    return 0
  fi

  return 1
}

resolver_route_exists() {
  ns="$1"

  case "$ns" in
    *:*)
      ip -6 route get "$ns" 2>/dev/null | grep -Eq "(^|[[:space:]])dev ${IFACE}([[:space:]]|$)"
      ;;
    *)
      ip route get "$ns" 2>/dev/null | grep -Eq "(^|[[:space:]])dev ${IFACE}([[:space:]]|$)"
      ;;
  esac
}

resolver_reachable() {
  ns="$1"

  case "$ns" in
    *:*) curl_host="[$ns]" ;;
    *)   curl_host="$ns" ;;
  esac

  curl \
    --silent \
    --output /dev/null \
    --connect-timeout "$DNS_CONNECT_TIMEOUT" \
    --max-time "$DNS_CONNECT_TIMEOUT" \
    "telnet://${curl_host}:53"
}

dns_is_healthy() {
  set -- $(awk '/^nameserver[ \t]+/ {print $2}' /etc/resolv.conf)

  [ "$#" -gt 0 ] || return 1

  for ns in "$@"; do
    [ -n "$ns" ] || continue

    if ! resolver_route_exists "$ns"; then
      continue
    fi

    if resolver_reachable "$ns"; then
      return 0
    fi
  done

  return 1
}

[ -f "$READY_FILE" ] || fail "ready file missing: $READY_FILE"
ip link show "$IFACE" >/dev/null 2>&1 || fail "interface missing: $IFACE"
has_global_addr || fail "interface has no global address: $IFACE"
has_policy_route || fail "route table ${ROUTE_TABLE} not bound to ${IFACE}"
dns_is_healthy || fail "no reachable resolver from /etc/resolv.conf"

exit 0
