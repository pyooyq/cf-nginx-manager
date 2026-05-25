# cf-nginx-manager

这是一个给 Alpine VPS 用的 Cloudflare Tunnel + Nginx 反代管理脚本。

它的目的很简单：

- 你的 VPS 没有公网 80/443 端口也没关系。
- 用 Cloudflare Tunnel 把域名流量转进 VPS。
- 可以让 Tunnel 直接连到目标服务。
- 也可以让 Tunnel 先到 VPS 本地 Nginx，再由 Nginx 反代。
- 新增、修改、删除反代可以用菜单完成，也支持常用非交互命令。
- 自动帮你配置 Cloudflare DNS 和 Tunnel ingress，并在执行前显示操作摘要。

访问链路按模式分为三类：

```text
Tunnel 直连模式：
用户访问你的域名
  -> Cloudflare
  -> Cloudflare Tunnel
  -> 目标服务

Tunnel + Nginx 反代模式：
用户访问你的域名
  -> Cloudflare
  -> Cloudflare Tunnel
  -> VPS 本地 Nginx 127.0.0.1:8080
  -> 目标服务

Public 入站模式：
用户访问你的域名和端口
  -> Cloudflare DNS 或 Cloudflare 代理
  -> VPS 公网 HTTPS 端口
  -> VPS 本地 Nginx
  -> 目标服务
```

## 适合什么场景

适合：

- NAT VPS 没有公网 80/443，但想绑定自己的域名。
- 给本地服务、面板、API 加一个 HTTPS 域名入口。
- 简单网站镜像式反代。
- 用菜单或命令行管理多个反代站点。

不保证适合：

- 复杂登录站点。
- 支付、OAuth、第三方登录。
- 有严格 CSP、CORS、Service Worker、HSTS 的网站。
- 需要 100% 完美镜像的大型站点。

## 脚本能做什么

首次运行可以自动：

- 安装 `nginx`、`curl`、`jq`、`cloudflared` 等依赖。
- Alpine 3.21 默认仓库没有 `cloudflared` 时，自动添加带标签的 HTTPS `edge/testing` 仓库，仅用于安装 `cloudflared`。
- 保存 Cloudflare API Token，自动查询 Account ID / Zone ID，并可自动创建 Cloudflare Tunnel。
- 创建 `cloudflared` 的 OpenRC 服务。
- 设置 `nginx` 和 `cloudflared` 开机自启。

日常使用可以：

- 新增反代。
- 修改反代。
- 删除反代。
- 查看反代列表。
- 自动创建 Cloudflare DNS CNAME。
- 自动更新 Cloudflare Tunnel ingress。
- 也可以创建不走 Tunnel 的公网 HTTPS 入站反代。
- 启动、停止、重启 `nginx` 和 `cloudflared`。
- 安装本地 `cfp` 命令并支持自我更新。
- 通过 `cfp help` 查看交互和非交互命令用法。
- 新增、修改站点时输入错误会就地重试，执行前会显示摘要并要求确认。

## 一键运行

### curl 方式

推荐安装为 `cfp`：

```sh
curl -fsSL https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh -o /usr/local/bin/cfp && chmod +x /usr/local/bin/cfp && cfp
```

如果 `/usr/local/bin` 不存在或不想安装到系统路径，可以临时运行：

```sh
curl -fsSL https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh -o cf-nginx-manager.sh && chmod +x cf-nginx-manager.sh && ./cf-nginx-manager.sh
```

### wget 方式

推荐安装为 `cfp`：

```sh
wget -O /usr/local/bin/cfp https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh && chmod +x /usr/local/bin/cfp && cfp
```

临时运行：

```sh
wget -O cf-nginx-manager.sh https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh && chmod +x cf-nginx-manager.sh && ./cf-nginx-manager.sh
```

## 第一次怎么用

运行脚本后，先选：

```text
1) 首次初始化 / 修复环境
```

然后脚本会提示你输入 Cloudflare API Token，并通过 Cloudflare API 自动查询 Account ID 和 Zone ID。正常情况下不需要手动填写 ID；如果 Token 权限太窄或 Cloudflare API 返回中缺少账号信息，脚本会提示原因并让你手动输入 Account ID / Zone ID 兜底。

需要准备：

```text
Cloudflare API Token
```

如果选择配置 Tunnel，脚本会用 API Token 自动创建 Cloudflare Tunnel，并保存 Tunnel ID 和 Tunnel Token。

这些信息准备好后，脚本会保存到：

```text
/etc/cf-nginx-manager/config.env
```

文件权限会设置为 `0600`。

本机 Nginx 服务地址必须填写为 `http://HOST:PORT`，例如 `http://127.0.0.1:8080`，不要使用 `https://`，也不要带路径、查询参数或片段。

初始化 / 修复环境时，脚本会检查本地命令是否已安装。如果还没有安装，会把当前脚本保存到：

```text
/usr/local/bin/cfp
```

之后可以直接运行：

```sh
cfp
```

脚本也会尽量保留 `cf-nginx-manager` 作为兼容入口。

## Cloudflare 需要准备什么

你需要：

1. 一个已经托管到 Cloudflare 的域名。
2. 一个有权限操作 DNS 和 Tunnel 的 API Token。

每台 VPS 建议创建并使用自己的独立 Cloudflare Tunnel。配置时如果已有 Tunnel，脚本会让你选择“创建新的独立 Tunnel”或“沿用当前 Tunnel”。不要在多台 VPS 上共用同一个 Tunnel Token，除非这些机器提供完全相同的服务和 Nginx 配置。

## Account ID 和 Zone ID

脚本会优先通过 `GET /zones` 自动查询 Zone ID，并从返回的 `account.id` 自动取得 Account ID。Cloudflare 官方的 Zone 列表响应包含 zone 所属账号信息，所以大多数情况下只需要 API Token。

如果自动查询失败，或者 Token 没有足够权限读取账号列表，脚本会让你手动输入：

```text
Cloudflare Account ID
Cloudflare Zone ID
```

你可以在 Cloudflare 网站进入对应域名后，从右侧边栏复制这两个 ID。

## 怎么创建 API Token

进入 Cloudflare：

```text
My Profile -> API Tokens -> Create Token
```

可以选择自定义 Token。

推荐给这些权限：

```text
账户 / Cloudflare Tunnel / 编辑
账户 / 账户设置 / 读取
区域 / 区域 / 读取
区域 / DNS / 编辑
```

权限用途：

- `区域 / 区域 / 读取`：脚本调用 `GET /zones` 自动查询 Zone ID，并从 zone 返回里的 `account.id` 获取 Account ID。
- `区域 / DNS / 编辑`：创建、修改、删除 DNS 记录；公网入站反代申请 Let's Encrypt 证书时也需要 DNS 验证。
- `账户 / Cloudflare Tunnel / 编辑`：创建 Cloudflare Tunnel、获取 Tunnel Token、同步 Tunnel ingress。只使用「Nginx 公网入站反代」模式时可以不配置这个权限。
- `账户 / 账户设置 / 读取`：用于脚本在 zone 响应缺少 `account.id` 时调用 `/accounts` 兜底查询账号列表。部分只授予区域权限的 Token 不能列出账号，所以没有这个权限时可能查不到 Account ID；脚本会改为让你手动输入 Account ID / Zone ID。

如果你只用「Nginx 公网入站反代」模式，最小权限是：

```text
区域 / 区域 / 读取
区域 / DNS / 编辑
```

资源范围建议只选你的账号和你的域名，不要给全局权限。

创建完成后复制 API Token。这个 Token 只显示一次，注意保存。

## Cloudflare Tunnel

首次初始化时，如果选择配置 Tunnel，脚本会通过 API 自动创建 Cloudflare Tunnel，并获取本机 `cloudflared` 服务需要的 Tunnel Token。

默认每台 VPS 应该创建并使用自己的独立 Tunnel。Cloudflare 会把同一个 Tunnel Token 下的多台机器当成同一个入口池，如果这些机器的本地服务不同，公网访问可能会随机分配到错误机器并出现 `502 Bad Gateway`。

如果你只使用「Nginx 公网入站反代」模式，可以不配置 Tunnel；仍然需要 Cloudflare API Token 用于 DNS 验证申请证书。

## 新增一个反代

运行脚本：

```sh
cf-nginx-manager
```

选择：

```text
2) 新增反代
```

然后输入：

```text
公网域名：app.example.com
目标地址：https://target.example.com
```

目标地址也可以是：

```text
http://1.2.3.4:8080
127.0.0.1:3000
example.com
```

如果选择 Tunnel 直连模式，脚本会自动：

- 创建或更新 Cloudflare DNS CNAME。
- 如果同名 A/AAAA 等 DNS 记录冲突，会提示先删除或改名。
- 更新 Tunnel ingress，让 Tunnel 直接指向目标地址。
- 不生成 Nginx 配置。

如果选择 Nginx 反代模式，脚本会自动：

- 生成 Nginx 配置。
- 测试 Nginx 配置。
- 重载 Nginx。
- 创建或更新 Cloudflare DNS CNAME。
- 如果同名 A/AAAA 等 DNS 记录冲突，会提示先删除或改名。
- 更新 Tunnel ingress，让 Tunnel 指向你配置的本机 Nginx 服务地址，默认是 `http://127.0.0.1:8080`。

执行前脚本会显示操作摘要，包括域名、模式、访问链路、Nginx 配置路径、Cloudflare 将修改的内容和证书信息。确认后才会写入本地配置、测试 Nginx、更新 DNS 或同步 Tunnel ingress。

然后访问：

```text
https://app.example.com
```

## 非交互命令和 help

查看帮助：

```sh
cfp help
cfp add --help
```

常用命令：

```sh
cfp init
cfp list
cfp sync
cfp config
cfp services
cfp update
cfp uninstall
```

非交互新增 Tunnel 直连反代：

```sh
cfp add --host app.example.com --target 127.0.0.1:3000 --mode direct --yes
```

非交互新增 Tunnel + Nginx 普通反代：

```sh
cfp add --host web.example.com --target https://target.example.com --mode proxy --host-header target.example.com --yes
```

非交互新增 Public 入站反代，不使用 Tunnel：

```sh
cfp add --host pub.example.com --target 127.0.0.1:3000 --mode public --listen-port 52443 --ipv4 1.2.3.4 --dns-only --yes
```

如果要使用 Cloudflare 橙云代理，把 `--dns-only` 改为 `--proxied`，端口必须是 Cloudflare 支持的 HTTPS 端口。

删除指定反代：

```sh
cfp delete --host app.example.com --yes
```

本地测试指定 Host：

```sh
cfp test --host app.example.com
```

非交互命令不会让你输入 Cloudflare API Token，也不会手动兜底输入 Account ID / Zone ID。请先执行 `cfp config` 完成 Cloudflare 配置；正常情况下用户只需要提供 API Token，其他 ID/Token 由脚本自动查询、创建或复用后保存。

## 反代模式怎么选

新增反代时会让你选择模式。

### Tunnel 直连：Cloudflare Tunnel -> 目标服务（默认推荐）

适合：

- 用户自己的后端服务。
- IP + PORT，例如 `1.2.3.4:8080`。
- 本机服务，例如 `127.0.0.1:3000`。
- API。
- 后台面板。
- Docker 服务。

如果你只是想把自己的服务挂到域名下面，选这个。这个模式不经过 Nginx，结构最简单。

### Tunnel + Nginx 普通反代：Cloudflare Tunnel -> 本机 Nginx -> 目标服务

适合：

- 需要 Nginx 改 Host、Cookie 或跳转。
- 需要后续自己加 Nginx rewrite/header 规则。

这个模式不做页面内容替换。

### Tunnel + Nginx 网站镜像反代：Cloudflare Tunnel -> 本机 Nginx -> 简单网页

只适合简单网页镜像。

它会尝试把页面里的目标域名替换成你的域名。

但它不是万能的。尤其是目标网站已经套了 Cloudflare CDN、强校验 Host、CSP、CORS、JS 动态生成链接、第三方登录等情况，通常不要选这个。

### Tunnel + Nginx 代理 CF CDN 目标站：Cloudflare Tunnel -> 本机 Nginx -> 已套 Cloudflare 的目标站

适合目标网站本身已经套了 Cloudflare CDN 的情况。

这个模式会：

- 经过本机 Nginx。
- 保持上游 `Host` 为目标站域名。
- 对 HTTPS 目标启用 SNI。
- 把 `Origin`、`Referer`、`X-Forwarded-Host` 尽量设置成目标站域名。
- 不做页面内容替换。

目标地址建议填写完整 HTTPS 域名，例如：

```text
https://target.example.com
```

如果目标站启用了 Cloudflare 的 Bot Fight Mode、WAF、强风控、Turnstile 或严格登录校验，这个模式也不保证一定能过。

### Nginx 公网入站反代（不使用 Tunnel）

适合你的 VPS 有公网入站端口，想直接用 Nginx 提供 HTTPS 入口的情况。

这个模式会：

- 不使用 Cloudflare Tunnel。
- 让 Nginx 直接监听你输入的公网 HTTPS 端口，例如 `52443`。
- 同一端口收到 HTTP 请求时会自动 301 跳转到 HTTPS。
- 自动检测本机公网 IPv4，并创建或更新 Cloudflare A 记录。
- 如果初始化时启用了 IPv6，可以选择检测并创建 AAAA 记录。
- 可选择 DNS only 灰云或 Cloudflare 代理橙云；橙云只允许 Cloudflare 支持的 HTTPS 端口。
- 如果已有 A/AAAA/CNAME 冲突记录，会提示确认是否覆盖。
- 用 acme.sh 通过 Cloudflare DNS 验证申请 Let's Encrypt 证书，首次安装 acme.sh 前会提示确认远程安装脚本。
- 把证书安装到 `/etc/nginx/certs/<域名>/`。
- 通过 cron 自动续签，续签后自动 reload Nginx。

使用前你需要自己确认：

- VPS 防火墙和服务商安全组已经放行你输入的 TCP 端口。
- Cloudflare API Token 已配置；正常情况下 Account ID / Zone ID 会自动查询，Token 至少有 `Zone / DNS / Edit` 权限。
- 如果选择 Cloudflare 橙云代理，端口必须是 Cloudflare 支持的 HTTPS 端口：`443`、`2053`、`2083`、`2087`、`2096`、`8443`。
- 如果选择灰云 DNS only，端口由你的 VPS 防火墙和服务商安全组决定。

访问地址会带端口，例如：

```text
https://app.example.com:52443
```

## Nginx 上游 DNS 和 IPv6

Nginx 反代模式会使用系统 `/etc/resolv.conf` 里的 DNS 服务器解析上游域名。如果没有读取到可用的 `nameserver`，脚本会回退到 `1.1.1.1 8.8.8.8`。

初始化时可以选择是否启用 Nginx 上游 IPv6 解析，默认关闭。没有 IPv6 出口的 VPS 建议保持关闭，否则 Nginx 可能解析到 IPv6 上游后出现 `Network unreachable` 和 `502 Bad Gateway`。

## 常用菜单

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  cf-nginx-manager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

服务状态
  nginx       : 运行中 / 已停止 / 未安装
  cloudflared : 运行中 / 已停止 / 未安装 / 未配置
  Nginx配置   : 通过 / 失败 / 未安装
  本机Nginx   : http://127.0.0.1:8080
  Tunnel ID   : <已配置的 Tunnel ID> / 未配置
  Tunnel日志  : 无明显错误 / 最近有错误
  反代站点    : N 个（Tunnel X / Public Y）

常用操作
   1) 首次初始化 / 修复环境
   2) 新增反代
   3) 反代管理

系统维护
   4) 服务管理
   5) 配置 Cloudflare 凭据
   6) 查看当前配置
   7) 更新脚本
   8) 卸载本脚本
   0) 退出
```

更新脚本会从 GitHub 下载最新版到临时文件，先执行 `sh -n` 语法检查，通过后备份当前 `/usr/local/bin/cfp`，再替换本地命令。更新成功后当前脚本会自动退出，需要重新运行 `cfp`。也可以直接运行：

```sh
cfp update
```

服务管理里可以：

- 启动 Nginx。
- 停止 Nginx。
- 重启 Nginx。
- 测试 Nginx 配置。
- 启动 cloudflared。
- 停止 cloudflared。
- 重启 cloudflared。
- 查看 cloudflared 日志。

## 常用检查命令

```sh
nginx -t
rc-service nginx status
rc-service cloudflared status
ss -tlnp | grep nginx
tail -n 100 /var/log/cloudflared.log
```

测试本地 Nginx（如果你改过“本机 Nginx 服务地址”，端口也要对应修改）：

```sh
curl -I -H 'Host: app.example.com' http://127.0.0.1:8080/
```

测试公网访问：

```sh
curl -I https://app.example.com/
```

如果是「Nginx 公网入站反代」模式，带上你设置的端口：

```sh
curl -I https://app.example.com:52443/
```

## 安全说明

脚本会保存 Cloudflare API Token 和自动创建的 Tunnel Token，请只在你自己的 VPS 上运行。

脚本只管理这些文件：

```text
/etc/cf-nginx-manager/
/etc/nginx/http.d/cf-nginx-manager-*.conf
/etc/nginx/http.d/00-cf-nginx-manager-map.conf
/etc/init.d/cloudflared
```

修改前会备份到：

```text
/etc/cf-nginx-manager/backups/
```

新增、修改站点前会显示操作摘要并确认；删除反代前会二次确认。输入域名、目标地址、端口、IP 等信息时，如果格式不正确会提示原因并让你重新输入。

## 卸载

推荐从主菜单选择：

```text
7) 卸载本脚本
```

或者直接运行：

```sh
cfp uninstall
```

卸载前会把本脚本管理的配置备份到 `/root/cf-nginx-manager-uninstall-backup-*`。

卸载会删除本脚本管理的本地文件：

```text
/etc/cf-nginx-manager/
/etc/nginx/http.d/cf-nginx-manager-*.conf
/etc/nginx/http.d/00-cf-nginx-manager-map.conf
/etc/init.d/cloudflared
/var/log/cloudflared.log
/usr/local/bin/cfp
/usr/local/bin/cf-nginx-manager
```

卸载不会自动删除：

- `nginx` / `cloudflared` 软件包。
- Cloudflare 后台已经创建的 DNS 记录。
- Cloudflare Tunnel 远端 Public Hostname / ingress。
- `/etc/nginx/certs/` 里的其他证书目录。

Cloudflare 上已经创建的 DNS 和 Tunnel ingress，建议先用脚本删除反代，再卸载。否则需要到 Cloudflare 后台手动删除。
