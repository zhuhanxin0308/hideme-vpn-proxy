# hide.me + HTTP/HTTPS 正向代理（双服务，共享网络命名空间）

这是按你指定的结构做的版本：

- `vpn`：运行 hide.me 开源 Linux CLI，负责登录、取 token、连接指定节点
- `proxy`：运行 Tinyproxy，提供 HTTP/HTTPS 正向代理
- `proxy` 使用 `network_mode: "service:vpn"`，与 `vpn` 共享同一个网络命名空间
- 宿主机只发布一个代理端口；你的客户端只需要设置代理 IP 和端口

## 这套结构的边界

这套结构的核心优点是：**代理的出站流量天然跟随 VPN**。

但要注意一件很重要的事：hide.me 的 leak protection / kill-switch 是基于**策略路由 + 黑洞路由**。因此，凡是不应该走 VPN 的回程流量，都必须被列进 split-tunnel 绕过范围。

这意味着：

- **同一台宿主机自己使用这个代理**：通常最容易跑通
- **固定来源网段访问这个代理**：可行，把来源 CIDR 写进 `SPLIT_TUNNEL_BYPASS`
- **任意公网客户端都来访问这个代理**：不稳，因为回程流量可能被 VPN 默认路由带走

所以，这个项目最适合：

- 你自己在固定出口 IP 的机器上使用
- 办公网、家宽、跳板机等**已知来源网段**访问

如果你的目标是“完全对公网开放，任何地方都能连”，那你之前那种**分离 ingress 和 VPN egress**的架构仍然更稳。

## 为什么这样设计

Docker Compose 官方文档说明，`network_mode: "service:{name}"` 会让一个服务加入另一个服务的网络命名空间；同时设置了 `network_mode` 后，不能再给这个服务单独配置 `networks`。这正适合“VPN 容器提供网络栈，代理容器共享它”的模式。

hide.me 官方开源仓库 README 说明，这个 Linux CLI 基于 WireGuard；连接流程是先申请 Access-Token，再执行 `connect`；它的 leak protection 不依赖 iptables，而是通过路由策略和黑洞路由实现，并允许显式 split-tunnel 绕过。

Tinyproxy 是一个轻量级 HTTP/HTTPS 正向代理，正好满足“只提供代理，不处理 AI 业务”的需求。

## 目录结构

```text
hideme-vpn-http-proxy/
  docker-compose.yml
  .env.example
  vpn/
    Dockerfile
  proxy/
    Dockerfile
  scripts/
    vpn-entrypoint.sh
    proxy-entrypoint.sh
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
3. 在与 `vpn` 共享的网络命名空间中监听 `PROXY_PORT`
4. 支持普通 HTTP 代理和 HTTPS `CONNECT`

因为 `proxy` 和 `vpn` 共用一个网络命名空间，真正发布端口的是 `vpn` 服务；但监听这个端口的进程是 `proxy` 容器里的 tinyproxy。

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

如果你不是在同一台宿主机上访问，而是从固定外部来源访问，记得加：

```env
SPLIT_TUNNEL_BYPASS=你的客户端出口IP/32
```

例如：

```env
SPLIT_TUNNEL_BYPASS=203.0.113.24/32
```

如果你要允许一整段办公网：

```env
SPLIT_TUNNEL_BYPASS=203.0.113.0/24
```

多个网段用逗号分隔：

```env
SPLIT_TUNNEL_BYPASS=203.0.113.24/32,198.51.100.0/24
```

## 环境变量说明

### hide.me 相关

- `HIDEME_USERNAME`：必填
- `HIDEME_PASSWORD`：必填
- `HIDEME_NODE`：默认 `any`
- `HIDEME_TOKEN_HOST`：默认 `free.hideservers.net`
- `HIDEME_INTERFACE`：默认 `vpn`
- `HIDEME_TUNNEL_MODE`：`ipv4`、`ipv6`、`dual`，默认 `ipv4`
- `HIDEME_KILL_SWITCH`：默认 `true`
- `SPLIT_TUNNEL_BYPASS`：额外直连 CIDR，多个用逗号分隔
- `EXTRA_CONNECT_ARGS`：额外透传给 `hide.me connect`

### 代理相关

- `PROXY_PORT`：默认 `3128`
- `PROXY_LISTEN`：默认 `0.0.0.0`
- `PROXY_ALLOW`：允许访问代理的 CIDR 列表，多个用逗号分隔
- `PROXY_BASIC_AUTH_USER` / `PROXY_BASIC_AUTH_PASSWORD`：可选 Basic Auth
- `PROXY_TIMEOUT`：默认 `600`
- `PROXY_MAX_CLIENTS`：默认 `200`
- `PROXY_MIN_SPARE_SERVERS` / `PROXY_MAX_SPARE_SERVERS` / `PROXY_START_SERVERS`：tinyproxy 进程池参数

## 启动

```bash
docker compose up -d --build
```

查看日志：

```bash
docker compose logs -f vpn proxy
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
docker compose exec proxy sh -lc 'nc -zv 127.0.0.1 3128'
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

大概率是**回程流量没有加入 split-tunnel 绕过**。

先把发起请求的客户端出口 IP / CIDR 加入：

```env
SPLIT_TUNNEL_BYPASS=203.0.113.24/32
```

如果是多个固定来源，就全部列进去。

#### 4. 为什么没有 SOCKS5

因为你这次明确要的是 HTTP/HTTPS 正向代理，这个项目就用 Tinyproxy 实现。

## 安全建议

至少做一项：

- 设置 `PROXY_BASIC_AUTH_USER` 和 `PROXY_BASIC_AUTH_PASSWORD`
- 设置 `PROXY_ALLOW` 只允许你的办公网 / 家宽出口 IP
- 配合 `SPLIT_TUNNEL_BYPASS` 只放已知来源

否则你把端口直接暴露到公网，就会变成开放代理。
