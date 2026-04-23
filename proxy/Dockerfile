FROM alpine:3.21

# Alpine 代理镜像只保留 tinyproxy 运行和健康检查所需的最小依赖。
RUN apk add --no-cache \
    tini \
    tinyproxy

WORKDIR /app
COPY entrypoint.sh /app/proxy-entrypoint.sh
COPY healthcheck.sh /app/proxy-healthcheck.sh
RUN chmod +x /app/proxy-entrypoint.sh /app/proxy-healthcheck.sh

ENTRYPOINT ["/sbin/tini", "--", "/app/proxy-entrypoint.sh"]
