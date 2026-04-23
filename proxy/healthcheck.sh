#!/bin/sh
set -eu

PORT="${PROXY_PORT:-3128}"
AUTH_USER="${PROXY_BASIC_AUTH_USER:-}"
AUTH_PASS="${PROXY_BASIC_AUTH_PASSWORD:-}"

build_request() {
  # 健康检查发送完整 HTTP 请求，避免像裸 TCP 探测那样把 tinyproxy 日志刷成 read_request_line 错误。
  target_url="http://127.0.0.1:${PORT}/"
  if [ -n "$AUTH_USER" ] && [ -n "$AUTH_PASS" ]; then
    auth_token="$(printf '%s' "${AUTH_USER}:${AUTH_PASS}" | base64 | tr -d '\n')"
    printf 'GET %s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nProxy-Authorization: Basic %s\r\nConnection: close\r\n\r\n' "$target_url" "$PORT" "$auth_token"
    return
  fi

  printf 'GET %s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$target_url" "$PORT"
}

response="$(build_request | nc -w 5 127.0.0.1 "$PORT" || true)"
printf '%s' "$response" | grep -Eq '^HTTP/1\.[01] (400|407) '
