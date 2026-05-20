# cf-nginx-manager

这是一个给 Alpine VPS 用的 Cloudflare Tunnel + Nginx 反代管理脚本。

它的目的很简单：

- 你的 VPS 没有公网 80/443 端口也没关系。
- 用 Cloudflare Tunnel 把域名流量转进 VPS。
- 可以让 Tunnel 直接连到目标服务。
- 也可以让 Tunnel 先到 VPS 本地 Nginx，再由 Nginx 反代。
- 新增、修改、删除反代都用菜单完成。
- 自动帮你配置 Cloudflare DNS 和 Tunnel 入口。

访问链路有两种：

```text
Tunnel 直连模式：
用户访问你的域名
  -> Cloudflare
  -> Cloudflare Tunnel
  -> 目标服务

Nginx 反代模式：
用户访问你的域名
  -> Cloudflare
  -> Cloudflare Tunnel
  -> VPS 本地 Nginx 127.0.0.1:8080
  -> 目标服务
```

## 适合什么场景

适合：

- NAT VPS 没有公网 80/443，但想绑定自己的域名。
- 给本地服务、面板、API 加一个 HTTPS 域名入口。
- 简单网站镜像式反代。
- 用菜单管理多个反代站点。

不保证适合：

- 复杂登录站点。
- 支付、OAuth、第三方登录。
- 有严格 CSP、CORS、Service Worker、HSTS 的网站。
- 需要 100% 完美镜像的大型站点。

## 脚本能做什么

首次运行可以自动：

- 安装 `nginx`、`curl`、`jq`、`cloudflared` 等依赖。
- Alpine 3.21 默认仓库没有 `cloudflared` 时，自动添加 `edge/testing` 仓库安装。
- 保存 Cloudflare API 信息，并自动创建 Cloudflare Tunnel。
- 创建 `cloudflared` 的 OpenRC 服务。
- 设置 `nginx` 和 `cloudflared` 开机自启。

日常使用可以：

- 新增反代。
- 修改反代。
- 删除反代。
- 查看反代列表。
- 自动创建 Cloudflare DNS CNAME。
- 自动更新 Cloudflare Tunnel Public Hostname。
- 也可以创建不走 Tunnel 的公网 HTTPS 入站反代。
- 启动、停止、重启 `nginx` 和 `cloudflared`。

## 一键运行

### curl 方式

```sh
curl -fsSL https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh -o /usr/local/bin/cf-nginx-manager && chmod +x /usr/local/bin/cf-nginx-manager && cf-nginx-manager
```

如果 `/usr/local/bin` 不存在或不想安装到系统路径，可以临时运行：

```sh
curl -fsSL https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh -o cf-nginx-manager.sh && chmod +x cf-nginx-manager.sh && ./cf-nginx-manager.sh
```

### wget 方式

```sh
wget -O /usr/local/bin/cf-nginx-manager https://raw.githubusercontent.com/pyooyq/cf-nginx-manager/main/cf-nginx-manager.sh && chmod +x /usr/local/bin/cf-nginx-manager && cf-nginx-manager
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

然后脚本会逐项提示你输入 Cloudflare 信息，例如 `Cloudflare Account ID:`、`Cloudflare Zone ID:`。如果看到这些提示，就按提示粘贴对应内容后回车。

需要准备这些东西：

```text
Cloudflare Account ID
Cloudflare Zone ID
Cloudflare API Token
```

脚本会用 API Token 自动创建 Cloudflare Tunnel，并保存 Tunnel ID 和 Tunnel Token。

这些信息准备好后，脚本会保存到：

```text
/etc/cf-nginx-manager/config.env
```

文件权限会设置为 `0600`。

## Cloudflare 需要准备什么

你需要：

1. 一个已经托管到 Cloudflare 的域名。
2. 一个有权限操作 DNS 和 Tunnel 的 API Token。

每台 VPS 初始化时，脚本会自动创建一个独立的 Cloudflare Tunnel。不要在多台 VPS 上共用同一个 Tunnel Token，除非这些机器提供完全相同的服务和 Nginx 配置。

## 怎么获取 Account ID 和 Zone ID

打开 Cloudflare 网站：

1. 进入你的域名。
2. 右侧边栏可以看到：
   - `Account ID`
   - `Zone ID`
3. 复制下来，后面脚本会用到。

## 怎么创建 API Token

进入 Cloudflare：

```text
My Profile -> API Tokens -> Create Token
```

可以选择自定义 Token。

需要给这些权限：

```text
Account / Cloudflare Tunnel / Edit
Zone / DNS / Edit
```

如果你只用「Nginx 公网入站反代」模式，不需要管理 Tunnel，但申请证书仍然需要 `Zone / DNS / Edit`，因为脚本会用 DNS 验证申请 Let's Encrypt 证书。

资源范围建议只选你的账号和你的域名，不要给全局权限。

创建完成后复制 API Token。这个 Token 只显示一次，注意保存。

## Cloudflare Tunnel

首次初始化时，脚本会通过 API 自动创建 Cloudflare Tunnel，并获取本机 `cloudflared` 服务需要的 Tunnel Token。

默认每台 VPS 应该创建并使用自己的独立 Tunnel。Cloudflare 会把同一个 Tunnel Token 下的多台机器当成同一个入口池，如果这些机器的本地服务不同，公网访问可能会随机分配到错误机器并出现 `502 Bad Gateway`。

## 新增一个反代

运行脚本：

```sh
cf-nginx-manager
```

选择：

```text
3) 反代管理
1) 新增反代
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

- 创建 Cloudflare DNS。
- 更新 Tunnel 入口，让 Tunnel 直接指向目标地址。
- 不生成 Nginx 配置。

如果选择 Nginx 反代模式，脚本会自动：

- 生成 Nginx 配置。
- 测试 Nginx 配置。
- 重载 Nginx。
- 创建 Cloudflare DNS。
- 更新 Tunnel 入口，让 Tunnel 指向 `http://127.0.0.1:8080`。

然后访问：

```text
https://app.example.com
```

## 反代模式怎么选

新增反代时会让你选择模式。

### Cloudflare Tunnel 直连服务（默认推荐）

适合：

- 用户自己的后端服务。
- IP + PORT，例如 `1.2.3.4:8080`。
- 本机服务，例如 `127.0.0.1:3000`。
- API。
- 后台面板。
- Docker 服务。

如果你只是想把自己的服务挂到域名下面，选这个。这个模式不经过 Nginx，结构最简单。

### Nginx 普通反代

适合：

- 需要 Nginx 改 Host、Cookie 或跳转。
- 需要后续自己加 Nginx rewrite/header 规则。

这个模式不做页面内容替换。

### Nginx 网站镜像反代

只适合简单网页镜像。

它会尝试把页面里的目标域名替换成你的域名。

但它不是万能的。尤其是目标网站已经套了 Cloudflare CDN、强校验 Host、CSP、CORS、JS 动态生成链接、第三方登录等情况，通常不要选这个。

### Nginx 代理 CF CDN 目标站

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
- 让 Nginx 直接监听你输入的 HTTPS 端口，例如 `52443`。
- 用 acme.sh 通过 Cloudflare DNS 验证申请 Let's Encrypt 证书。
- 把证书安装到 `/etc/nginx/certs/<域名>/`。
- 通过 cron 自动续签，续签后自动 reload Nginx。

使用前你需要自己确认：

- 域名已经解析到这台 VPS 的公网 IP。
- VPS 防火墙和服务商安全组已经放行你输入的 TCP 端口。
- Cloudflare API Token 至少有 `Zone / DNS / Edit` 权限。
- 如果 DNS 开了 Cloudflare 橙云代理，端口要选 Cloudflare 支持的 HTTPS 端口；如果是灰云 DNS only，端口由你的 VPS 防火墙决定。

访问地址会带端口，例如：

```text
https://app.example.com:52443
```

## 常用菜单

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  cf-nginx-manager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

服务状态
  nginx       : 运行中 / 已停止 / 未安装
  cloudflared : 运行中 / 已停止 / 未安装
  反代站点    : N 个

常用操作
   1) 首次初始化 / 修复环境
   2) 新增反代
   3) 反代管理

系统维护
   4) 服务管理
   5) 配置 Cloudflare 凭据
   6) 查看当前配置
   7) 卸载本脚本
   0) 退出
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

测试本地 Nginx：

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

删除反代前会二次确认。

## 卸载

推荐从主菜单选择：

```text
7) 卸载本脚本
```

或者直接运行：

```sh
cf-nginx-manager uninstall
```

卸载前会把本脚本管理的配置备份到 `/root/cf-nginx-manager-uninstall-backup-*`。

卸载会删除本脚本管理的本地文件：

```text
/etc/cf-nginx-manager/
/etc/nginx/http.d/cf-nginx-manager-*.conf
/etc/nginx/http.d/00-cf-nginx-manager-map.conf
/etc/init.d/cloudflared
/var/log/cloudflared.log
/usr/local/bin/cf-nginx-manager
```

卸载不会自动删除：

- `nginx` / `cloudflared` 软件包。
- Cloudflare 后台已经创建的 DNS 记录。
- Cloudflare Tunnel 远端 Public Hostname / ingress。
- `/etc/nginx/certs/` 里的其他证书目录。

Cloudflare 上已经创建的 DNS 和 Tunnel Public Hostname，建议先用脚本删除反代，再卸载。否则需要到 Cloudflare 后台手动删除。
