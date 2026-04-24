# hide.me + HTTP/HTTPS 正向代理（公网入口 + VPN 出口）

这是按你指定的结构做的版本：

- `vpn`：运行 hide.me 开源 Linux CLI，负责登录、取 token、连接指定节点
- `proxy-egress`：运行在 `vpn` 网络命名空间内，负责通过 VPN 出站
- `proxy`：运行在普通 Docker 网络内，发布公网入口端口并转发到 `proxy-egress`
- 宿主机只发布 `proxy` 的入口端口；你的客户端只需要设置代理 IP、端口和认证

## 这套结构的边界

这套结构允许任意公网来源连接入口代理，出站流量仍由 VPN 命名空间里的出口代理完成。

公网入口默认要求 Basic Auth。不要把 `PROXY_REQUIRE_AUTH` 改成 `false` 后直接暴露到公网，否则会变成开放代理。

`proxy-egress` 只允许 Docker 常见内网段访问，默认不发布宿主机端口。

## 目录结构

```text
hideme-vpn-http-proxy/
  docker-compose.yml
  .env.example
  vpn/
    Dockerfile
    entrypoint.sh
    healthcheck.sh
  proxy/
    Dockerfile
    entrypoint.sh
    healthcheck.sh
  tests/
  README.md
```

## 你需要准备什么

1. Linux 宿主机
2. Docker Engine + Docker Compose
3. 宿主机内核支持 WireGuard
4. hide.me 账号和密码

`vpn/Dockerfile` 会在构建时下载 hide.me Linux CLI 预编译发布包。

## 服务行为

### `vpn` 服务

启动时会：

1. 读取环境变量中的账号、密码、节点
2. 申请 Access-Token
3. 连接指定节点
4. 检查 VPN 接口和默认路由是否 ready
5. 在共享卷中写入 `/shared/vpn.ready`

### `proxy` 服务

启动时会：

1. 等待 `/shared/vpn.ready`
2. 生成 tinyproxy 配置
3. 在普通 Docker 网络中监听 `PROXY_PORT`
4. 通过 `Upstream http vpn:PROXY_EGRESS_PORT` 转发到出口代理
5. 支持普通 HTTP 代理和 HTTPS `CONNECT`

### `proxy-egress` 服务

启动时会：

1. 等待 `/shared/vpn.ready`
2. 在与 `vpn` 共享的网络命名空间中监听 `PROXY_EGRESS_PORT`
3. 接收 `proxy` 的上游转发请求
4. 通过 VPN 出站访问目标地址

## 快速开始

### 1. 复制环境变量模板

```bash
cp .env.example .env
```

至少填写：

```env
HIDEME_USERNAME=你的hide.me账号
HIDEME_PASSWORD=你的hide.me密码
HIDEME_NODE=any
```

推荐同时设置：

```env
PROXY_PORT=3128
PROXY_BASIC_AUTH_USER=proxyuser
PROXY_BASIC_AUTH_PASSWORD=change-me
```

公网入口默认绑定所有网卡：

```env
PROXY_BIND_ADDRESS=0.0.0.0
```

如果只想绑定指定宿主机 IP：

```env
PROXY_BIND_ADDRESS=203.0.113.10
```

`SPLIT_TUNNEL_BYPASS` 只用于补充额外直连回程 CIDR，公网入口模式通常不需要设置。

例如需要保留某个固定来源直连回程：

```env
SPLIT_TUNNEL_BYPASS=203.0.113.24/32
```

## 环境变量说明

### hide.me 相关

- `HIDEME_USERNAME`：必填
- `HIDEME_PASSWORD`：必填
- `HIDEME_NODE`：默认 `any`
- `HIDEME_TOKEN_HOST`：默认 `any`
- `HIDEME_INTERFACE`：默认 `vpn`
- `HIDEME_TUNNEL_MODE`：`ipv4`、`ipv6`、`dual`，默认 `ipv4`
- `HIDEME_KILL_SWITCH`：默认 `true`
- `VPN_LOCAL_BYPASS_CIDRS`：默认绕过本地和 Docker 常见内网段
- `SPLIT_TUNNEL_BYPASS`：额外直连 CIDR，多个用逗号分隔
- `EXTRA_CONNECT_ARGS`：额外透传给 `hide.me connect`

### 代理相关

- `PROXY_BIND_ADDRESS`：宿主机发布端口绑定地址，默认 `0.0.0.0`
- `PROXY_PORT`：默认 `3128`
- `PROXY_LISTEN`：默认 `0.0.0.0`
- `PROXY_ALLOW`：允许访问代理的 CIDR 列表，多个用逗号分隔
- `PROXY_REQUIRE_AUTH`：默认 `true`
- `PROXY_BASIC_AUTH_USER` / `PROXY_BASIC_AUTH_PASSWORD`：可选 Basic Auth
- `PROXY_TIMEOUT`：默认 `600`
- `PROXY_MAX_CLIENTS`：默认 `200`
- `PROXY_EGRESS_PORT`：内部出口代理端口，默认 `3129`
- `PROXY_EGRESS_ALLOW`：允许访问内部出口代理的 CIDR 列表

## 启动

```bash
docker compose up -d --build
```

查看日志：

```bash
docker compose logs -f vpn proxy-egress proxy
```

## 使用方法

### curl

不带账号密码：

```bash
curl -x http://你的服务器IP:3128 https://api.openai.com/v1/models \
  -H 'Authorization: Bearer sk-xxxx'
```

带 Basic Auth：

```bash
curl -x http://proxyuser:change-me@你的服务器IP:3128 https://api.openai.com/v1/models \
  -H 'Authorization: Bearer sk-xxxx'
```

### Python requests

```python
import requests

proxies = {
    "http": "http://proxyuser:change-me@your-server:3128",
    "https": "http://proxyuser:change-me@your-server:3128",
}

resp = requests.get(
    "https://api.openai.com/v1/models",
    headers={"Authorization": "Bearer sk-xxxx"},
    proxies=proxies,
    timeout=60,
)
print(resp.status_code)
print(resp.text)
```

这里的 AI 密钥始终由**你的客户端自己携带**；容器只做代理。

## 查看可用节点

```bash
docker compose run --rm --entrypoint /opt/hide.me/hide.me vpn list
```

## 健康检查和排障

### 查看 VPN 是否 ready

```bash
docker compose exec vpn sh -lc 'ls -l /shared && ip link show vpn'
```

### 查看代理是否在监听

```bash
docker compose exec proxy sh -lc '/app/proxy-healthcheck.sh && echo ingress healthy'
docker compose exec proxy-egress sh -lc '/app/proxy-healthcheck.sh && echo egress healthy'
```

### 常见问题

#### 1. `Cannot create a WireGuard interface`

通常说明宿主机内核不支持 WireGuard，或者容器没有 `CAP_NET_ADMIN`。

#### 2. `token` 成功但 `connect` 失败

优先检查：

- 账号密码是否正确
- `HIDEME_NODE` 是否对你的免费账户可用
- 是否能用 `list` 看到可连接节点

#### 3. 外部机器连得上端口，但请求不通

优先检查：

- `PROXY_BASIC_AUTH_USER` 和 `PROXY_BASIC_AUTH_PASSWORD` 是否已经设置
- `proxy-egress` 是否健康
- `VPN_LOCAL_BYPASS_CIDRS` 是否包含当前 Docker 网络网段

#### 4. 为什么没有 SOCKS5

因为你这次明确要的是 HTTP/HTTPS 正向代理，这个项目就用 Tinyproxy 实现。

## 安全建议

至少做一项：

- 设置 `PROXY_BASIC_AUTH_USER` 和 `PROXY_BASIC_AUTH_PASSWORD`
- 设置 `PROXY_ALLOW` 只允许你的办公网 / 家宽出口 IP
- 保持 `PROXY_REQUIRE_AUTH=true`

否则你把端口直接暴露到公网，就会变成开放代理。
