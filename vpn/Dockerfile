FROM alpine:3.21

ARG HIDEME_VERSION=0.9.10

RUN apk add --no-cache \
    ca-certificates \
    curl \
    iproute2 \
    procps-ng \
    tar \
    tini

# Alpine 的架构名与 hide.me 发布产物命名不同，这里显式转换避免跨架构构建失败。
RUN set -eux; \
    arch="$(apk --print-arch)"; \
    case "$arch" in \
      x86_64) asset_arch="amd64" ;; \
      aarch64) asset_arch="arm64" ;; \
      armv7|armhf) asset_arch="arm" ;; \
      x86) asset_arch="386" ;; \
      *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/hide.me.tar.gz "https://github.com/eventure/hide.client.linux/releases/download/${HIDEME_VERSION}/hide.me-linux-${asset_arch}-${HIDEME_VERSION}.tar.gz"; \
    mkdir -p /opt/hide.me; \
    tar -xzf /tmp/hide.me.tar.gz -C /opt/hide.me; \
    rm -f /tmp/hide.me.tar.gz; \
    chmod +x /opt/hide.me/hide.me

WORKDIR /app
COPY entrypoint.sh /app/vpn-entrypoint.sh
COPY healthcheck.sh /app/vpn-healthcheck.sh
RUN chmod +x /app/vpn-entrypoint.sh /app/vpn-healthcheck.sh

ENTRYPOINT ["/sbin/tini", "--", "/app/vpn-entrypoint.sh"]
