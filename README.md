# Alpine 3.21 + Cloudflare Tunnel + Nginx 反代一键管理脚本

版本：v4.0（一键脚本 + 手工部署备用）

> 适用前提：只反代或镜像你拥有、控制或已获得授权的网站。复杂站点可能受 CSP、CORS、Cookie、OAuth、Service Worker、SRI、JS 动态拼接等机制影响，无法保证 100% 透明镜像。

## 1. 实现目标

在 Alpine NAT VPS 上用 `cloudflared` + Nginx 实现公网反代入口：

```text
用户浏览器
  -> Cloudflare HTTPS / CDN / WAF
  -> Cloudflare Tunnel
  -> NAT VPS: 127.0.0.1:8080
  -> Nginx
  -> 目标域名 / IP:PORT
```

脚本能力：

- 首次运行自动初始化环境。
- 自动安装 `nginx`、`curl`、`jq`、`cloudflared` 等依赖。
- Alpine 3.21 默认仓库没有 `cloudflared` 时，自动追加 `edge/testing` 后安装。
- 保存 Cloudflare Account ID、Zone ID、API Token、Tunnel ID、Tunnel Token。
- 新增反代：输入公网域名和目标地址，自动生成 Nginx 配置。
- 自动创建/更新 Cloudflare DNS CNAME。
- 自动同步 Cloudflare Tunnel Public Hostname / ingress。
- 修改、删除已有反代。
- 管理 `nginx`、`cloudflared` 启动、停止、重启、状态和日志。

## 2. 文件说明

```text
cf-nginx-manager.sh   # 一键管理脚本
README.md             # 使用文档
```

脚本在 VPS 上会管理这些路径：

```text
/etc/cf-nginx-manager/config.env              # Cloudflare 凭据，权限 0600
/etc/cf-nginx-manager/sites.d/*.env           # 站点元数据
/etc/cf-nginx-manager/backups/                # 配置备份
/etc/nginx/http.d/00-cf-nginx-manager-map.conf
/etc/nginx/http.d/cf-nginx-manager-*.conf
/etc/init.d/cloudflared
/var/log/cloudflared.log
```

脚本只管理 `cf-nginx-manager-*` 相关 Nginx 配置，不会主动覆盖其他站点配置。

## 3. Cloudflare 准备工作

你需要先在 Cloudflare 准备：

1. 一个已经添加到 Cloudflare 的域名，例如 `example.com`。
2. 一个 Cloudflare Tunnel。
3. Tunnel ID。
4. Tunnel Token。
5. Account ID。
6. Zone ID。
7. Cloudflare API Token。

API Token 推荐权限：

```text
Account / Cloudflare Tunnel / Edit
Zone / DNS / Edit
```

资源范围建议限制到对应 Account 和 Zone。

脚本使用 Cloudflare API 自动执行两件事：

- 创建或更新 DNS：

```text
app.example.com CNAME <TUNNEL_ID>.cfargotunnel.com proxied=true
```

- 更新 Tunnel ingress：

```json
{
  "hostname": "app.example.com",
  "service": "http://127.0.0.1:8080",
  "originRequest": {}
}
```

## 4. 快速开始

把脚本上传到 Alpine VPS 后执行：

```sh
chmod +x cf-nginx-manager.sh
./cf-nginx-manager.sh
```

首次菜单选择：

```text
1) 首次初始化 / 修复环境
```

脚本会：

- 安装依赖。
- 检测并安装 `cloudflared`。
- 创建 `/etc/cf-nginx-manager`。
- 创建 `/etc/init.d/cloudflared`。
- 写入 Nginx 全局 WebSocket map。
- 设置 `nginx` 和 `cloudflared` 开机自启。
- 让你输入 Cloudflare API / Tunnel 信息。
- 重启 `nginx` 和 `cloudflared`。

如果 Alpine 3.21 提示默认仓库没有 `cloudflared`，脚本会自动执行等价逻辑：

```sh
printf '%s\n' 'http://dl-cdn.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories
apk update
apk add --no-cache cloudflared
```

## 5. 菜单功能

主菜单：

```text
1) 首次初始化 / 修复环境
2) 配置 Cloudflare 凭据
3) 反代管理
4) 服务管理
5) 查看当前配置
0) 退出
```

反代管理：

```text
1) 新增反代
2) 修改反代
3) 删除反代
4) 查看反代列表
5) 同步 Cloudflare Tunnel ingress
0) 返回
```

服务管理：

```text
1) nginx start
2) nginx stop
3) nginx restart
4) nginx reload
5) nginx status
6) nginx -t
7) cloudflared start
8) cloudflared stop
9) cloudflared restart
10) cloudflared status
11) 查看 cloudflared 日志
12) 查看 127.0.0.1:8080 监听
13) 本地 Host 测试
0) 返回
```

## 6. 新增反代示例

运行：

```sh
./cf-nginx-manager.sh
```

选择：

```text
3) 反代管理
1) 新增反代
```

输入示例：

```text
公网域名：app.example.com
目标地址：https://target.example.org
反代模式：镜像反代
Host 头策略：使用上游 Host
```

脚本会自动：

1. 写入 Nginx 配置：

```text
/etc/nginx/http.d/cf-nginx-manager-app_example_com.conf
```

2. 执行：

```sh
nginx -t
rc-service nginx reload
```

3. 创建或更新 Cloudflare DNS：

```text
app.example.com -> <TUNNEL_ID>.cfargotunnel.com
```

4. 同步 Tunnel ingress。

5. 访问：

```text
https://app.example.com
```

## 7. 支持的目标地址格式

支持：

```text
example.com
https://example.com
http://example.com
1.2.3.4:8080
http://1.2.3.4:8080
127.0.0.1:3000
```

自动推导规则：

- `example.com` 默认变成 `https://example.com`。
- `1.2.3.4:8080` 默认变成 `http://1.2.3.4:8080`。
- `https://...` 自动启用 SNI：

```nginx
proxy_ssl_server_name on;
proxy_ssl_name <上游host>;
```

## 8. 普通反代 vs 镜像反代

### 普通反代

适合 API、面板、简单后端服务。

主要处理：

- `proxy_pass`
- `proxy_redirect`
- `proxy_cookie_domain`
- WebSocket

### 镜像反代

适合简单网站镜像。

在普通反代基础上增加：

```nginx
proxy_set_header Accept-Encoding "";
sub_filter_once off;
sub_filter_types text/html text/css text/javascript application/javascript application/json application/xml text/xml;
sub_filter 'https://目标域名' 'https://你的域名';
sub_filter 'http://目标域名' 'https://你的域名';
sub_filter '//目标域名' '//你的域名';
sub_filter '目标域名' '你的域名';
```

注意：Nginx `sub_filter` 语法没有尾部 `g`，全局替换依靠：

```nginx
sub_filter_once off;
```

## 9. 脚本命令参数

除了菜单，也可以直接运行部分命令：

```sh
./cf-nginx-manager.sh init      # 初始化环境
./cf-nginx-manager.sh config    # 配置 Cloudflare 凭据
./cf-nginx-manager.sh add       # 新增反代
./cf-nginx-manager.sh list      # 查看反代列表
./cf-nginx-manager.sh sync      # 同步 Tunnel ingress
./cf-nginx-manager.sh services  # 服务管理菜单
```

## 10. 验证部署

基础检查：

```sh
cloudflared --version
nginx -v
nginx -t
rc-service nginx status
rc-service cloudflared status
rc-update show | grep -E 'nginx|cloudflared'
```

确认 Nginx 只监听本地：

```sh
ss -tlnp | grep ':8080'
```

预期类似：

```text
LISTEN 0 511 127.0.0.1:8080 0.0.0.0:* users:(("nginx",pid=...,fd=...))
```

本机 Host 测试：

```sh
curl -I -H 'Host: app.example.com' http://127.0.0.1:8080/
```

公网测试：

```sh
curl -I https://app.example.com/
```

浏览器检查：

- 页面是否能打开。
- 地址栏是否保持你的域名。
- 图片、CSS、JS 是否正常加载。
- 登录态 Cookie 是否写入你的域名。
- Network 面板是否仍大量请求目标域名。

## 11. 常见问题

### 11.1 `apk add cloudflared` 提示 no such package

Alpine 3.21 默认仓库可能没有 `cloudflared`。脚本会自动追加：

```sh
http://dl-cdn.alpinelinux.org/alpine/edge/testing
```

然后重新：

```sh
apk update
apk add --no-cache cloudflared
```

你已经手动这样安装成功，脚本后续检测到 `cloudflared` 已存在会跳过安装。

### 11.2 Cloudflare API 同步失败

检查：

- Account ID 是否正确。
- Zone ID 是否正确。
- Tunnel ID 是否正确。
- API Token 是否有：
  - Account / Cloudflare Tunnel / Edit
  - Zone / DNS / Edit
- 域名是否属于该 Zone。

### 11.3 Cloudflare 显示 502 / 1033 / Tunnel disconnected

检查：

```sh
rc-service cloudflared status
tail -n 100 /var/log/cloudflared.log
curl -I -H 'Host: app.example.com' http://127.0.0.1:8080/
```

常见原因：

- Tunnel Token 错误。
- `cloudflared` 未启动。
- Nginx 未启动。
- Tunnel ingress 没同步成功。

### 11.4 `nginx -t` 报 `invalid number of arguments in "sub_filter" directive`

错误写法：

```nginx
sub_filter 'https://b.com' 'https://a.com' g;
```

正确写法：

```nginx
sub_filter 'https://b.com' 'https://a.com';
```

### 11.5 页面能打开，但源码仍有目标域名

常见原因：

- JS 运行时拼接域名。
- Base64、protobuf、wasm、加密配置里包含域名。
- 还有 `api.example.com`、`static.example.com`、`cdn.example.com` 等子域名没配置。
- 目标站 CSP/CORS/SRI/HSTS 限制。

Nginx `sub_filter` 只能替换明文响应体，不是万能全站重写引擎。

## 12. 安全和回滚

脚本安全策略：

- 敏感配置保存为 `0600`。
- 只管理 `/etc/nginx/http.d/cf-nginx-manager-*.conf`。
- 修改前备份到 `/etc/cf-nginx-manager/backups/<时间>/`。
- `nginx -t` 失败不会 reload。
- 删除站点前需要二次确认。
- 不执行 `apk upgrade -a`，避免升级整个系统。
- 同步 Tunnel ingress 时会保留非本脚本管理的 hostname。

如果需要手动回滚，可以从备份目录恢复对应文件后执行：

```sh
nginx -t
rc-service nginx reload
./cf-nginx-manager.sh sync
```

## 13. 手工部署备用方案

如果不想使用脚本，可以手工部署。

### 13.1 安装软件

```sh
apk update
apk add --no-cache nginx curl ca-certificates openssl openrc jq
```

安装 `cloudflared`：

```sh
apk add --no-cache cloudflared || {
  printf '%s\n' 'http://dl-cdn.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories
  apk update
  apk add --no-cache cloudflared
}
```

### 13.2 Nginx 示例配置

创建 `/etc/nginx/http.d/mirror.conf`：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 127.0.0.1:8080;
    server_name a.com www.a.com;

    client_max_body_size 100m;

    location / {
        proxy_pass https://b.com;
        proxy_http_version 1.1;

        proxy_ssl_server_name on;
        proxy_ssl_name b.com;

        proxy_set_header Host b.com;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Accept-Encoding "";

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_redirect https://b.com/ https://a.com/;
        proxy_redirect http://b.com/ https://a.com/;

        proxy_cookie_domain b.com a.com;
        proxy_cookie_domain .b.com .a.com;
        proxy_cookie_path / /;

        sub_filter_once off;
        sub_filter_types text/html text/css text/javascript application/javascript application/json application/xml text/xml;
        sub_filter 'https://b.com' 'https://a.com';
        sub_filter 'http://b.com' 'https://a.com';
        sub_filter '//b.com' '//a.com';
        sub_filter 'b.com' 'a.com';
    }
}
```

启动：

```sh
nginx -t
rc-service nginx restart
rc-update add nginx default
```

### 13.3 cloudflared OpenRC 示例

```sh
cat > /etc/init.d/cloudflared <<'EOF'
#!/sbin/openrc-run
name="cloudflared"
command="/usr/bin/cloudflared"
command_args="tunnel run --token 你的完整TunnelToken"
pidfile="/run/cloudflared.pid"
command_background=true
depend() { need net; }
EOF
chmod +x /etc/init.d/cloudflared
rc-update add cloudflared default
rc-service cloudflared restart
```

手工方案下，Cloudflare DNS 和 Public Hostname 需要你在后台或 API 里自行配置。
