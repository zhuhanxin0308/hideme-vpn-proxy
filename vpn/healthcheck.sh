#!/bin/sh
set -eu

READY_FILE="${VPN_READY_FILE:-/shared/vpn.ready}"
IFACE="${HIDEME_INTERFACE:-vpn}"
ROUTE_TABLE="${VPN_ROUTE_TABLE:-55555}"
RESOLV_CONF_PATH="${VPN_RESOLV_CONF_PATH:-/etc/resolv.conf}"
DNS_TEST_HOST="${VPN_DNS_TEST_HOST:-www.google.com}"
DNS_LOOKUP_TIMEOUT="${VPN_DNS_LOOKUP_TIMEOUT:-5}"
FALLBACK_DNS="${VPN_FALLBACK_DNS:-8.8.8.8}"

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

has_configured_nameserver() {
  grep -Eq '^[[:space:]]*nameserver[[:space:]]+' "$RESOLV_CONF_PATH"
}

has_fallback_dns() {
  [ -z "$FALLBACK_DNS" ] && return 0
  grep -Eq "^[[:space:]]*nameserver[[:space:]]+${FALLBACK_DNS}([[:space:]]|$)" "$RESOLV_CONF_PATH"
}

dns_is_healthy() {
  timeout "$DNS_LOOKUP_TIMEOUT" getent hosts "$DNS_TEST_HOST" 2>/dev/null | grep -Eq '^[0-9A-Fa-f:.]+[[:space:]]+'
}

[ -f "$READY_FILE" ] || fail "ready file missing: $READY_FILE"
ip link show "$IFACE" >/dev/null 2>&1 || fail "interface missing: $IFACE"
has_global_addr || fail "interface has no global address: $IFACE"
has_policy_route || fail "route table ${ROUTE_TABLE} not bound to ${IFACE}"
[ -f "$RESOLV_CONF_PATH" ] || fail "resolv.conf missing: $RESOLV_CONF_PATH"
has_configured_nameserver || fail "no nameserver configured in ${RESOLV_CONF_PATH}"
has_fallback_dns || fail "fallback dns missing from ${RESOLV_CONF_PATH}: ${FALLBACK_DNS}"
dns_is_healthy || fail "dns lookup failed for ${DNS_TEST_HOST}"

exit 0
