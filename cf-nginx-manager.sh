#!/bin/sh

APP_NAME="cf-nginx-manager"
CONFIG_DIR="/etc/cf-nginx-manager"
SITES_DIR="$CONFIG_DIR/sites.d"
BACKUP_DIR="$CONFIG_DIR/backups"
CONFIG_ENV="$CONFIG_DIR/config.env"
NGINX_MAP_FILE="/etc/nginx/http.d/00-cf-nginx-manager-map.conf"
NGINX_PREFIX="/etc/nginx/http.d/cf-nginx-manager-"
CLOUDFLARED_INIT="/etc/init.d/cloudflared"
CLOUDFLARED_LOG="/var/log/cloudflared.log"
LOCAL_SERVICE_DEFAULT="http://127.0.0.1:8080"
CF_API_BASE="https://api.cloudflare.com/client/v4"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pause() { printf '\n按回车继续... '; read -r _; }

need_root() {
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 运行。"
        exit 1
    fi
}

read_input() {
    prompt="$1"
    default="$2"
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    read -r value
    if [ -z "$value" ]; then
        value="$default"
    fi
    printf '%s' "$value"
}

read_secret() {
    prompt="$1"
    printf '%s: ' "$prompt" >/dev/tty
    stty -echo 2>/dev/null || true
    read -r value
    stty echo 2>/dev/null || true
    printf '\n' >/dev/tty
    printf '%s' "$value"
}

confirm() {
    prompt="$1"
    printf '%s [y/N]: ' "$prompt"
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

json_escape() {
    jq -Rn --arg v "$1" '$v'
}

safe_host() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g; s/[.]/_/g'
}

site_env_path() {
    printf '%s/%s.env' "$SITES_DIR" "$(safe_host "$1")"
}

site_conf_path() {
    printf '%s%s.conf' "$NGINX_PREFIX" "$(safe_host "$1")"
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$SITES_DIR" "$BACKUP_DIR" /var/log/cf-nginx-manager
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    chmod 700 "$SITES_DIR" 2>/dev/null || true
}

load_config() {
    if [ -f "$CONFIG_ENV" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_ENV"
    fi
    LOCAL_SERVICE="${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}"
}

save_config() {
    ensure_dirs
    tmp="$CONFIG_ENV.tmp"
    {
        printf 'CF_ACCOUNT_ID=%s\n' "$(shell_quote "$CF_ACCOUNT_ID")"
        printf 'CF_ZONE_ID=%s\n' "$(shell_quote "$CF_ZONE_ID")"
        printf 'CF_API_TOKEN=%s\n' "$(shell_quote "$CF_API_TOKEN")"
        printf 'CF_TUNNEL_ID=%s\n' "$(shell_quote "$CF_TUNNEL_ID")"
        printf 'CF_TUNNEL_TOKEN=%s\n' "$(shell_quote "$CF_TUNNEL_TOKEN")"
        printf 'LOCAL_SERVICE=%s\n' "$(shell_quote "${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}")"
    } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG_ENV"
}

configure_credentials() {
    load_config
    old_api_token="${CF_API_TOKEN:-}"
    old_tunnel_token="${CF_TUNNEL_TOKEN:-}"
    say "请输入 Cloudflare API 与 Tunnel 信息。"
    CF_ACCOUNT_ID=$(read_input "Cloudflare Account ID" "${CF_ACCOUNT_ID:-}")
    CF_ZONE_ID=$(read_input "Cloudflare Zone ID" "${CF_ZONE_ID:-}")
    CF_API_TOKEN=$(read_secret "Cloudflare API Token（输入不会回显，留空保留旧值）")
    if [ -z "$CF_API_TOKEN" ]; then
        CF_API_TOKEN="$old_api_token"
    fi
    CF_TUNNEL_ID=$(read_input "Cloudflare Tunnel ID" "${CF_TUNNEL_ID:-}")
    CF_TUNNEL_TOKEN=$(read_secret "Cloudflare Tunnel Token（输入不会回显，留空保留旧值）")
    if [ -z "$CF_TUNNEL_TOKEN" ]; then
        CF_TUNNEL_TOKEN="$old_tunnel_token"
    fi
    LOCAL_SERVICE=$(read_input "本机 Nginx 服务地址" "${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}")

    if [ -z "$CF_ACCOUNT_ID" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_API_TOKEN" ] || [ -z "$CF_TUNNEL_ID" ] || [ -z "$CF_TUNNEL_TOKEN" ]; then
        err "Account ID、Zone ID、API Token、Tunnel ID、Tunnel Token 都不能为空。"
        return 1
    fi

    save_config
    render_cloudflared_openrc
    say "配置已保存到 $CONFIG_ENV。"
}

require_config() {
    load_config
    if [ -z "${CF_ACCOUNT_ID:-}" ] || [ -z "${CF_ZONE_ID:-}" ] || [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_TUNNEL_ID:-}" ] || [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
        err "尚未配置 Cloudflare 信息，请先执行初始化或配置 Cloudflare 凭据。"
        return 1
    fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_package() {
    pkg="$1"
    cmd="$2"
    if has_cmd "$cmd"; then
        say "$pkg 已安装，跳过。"
        return 0
    fi
    say "安装 $pkg..."
    apk add --no-cache "$pkg"
}

ensure_cloudflared() {
    if has_cmd cloudflared; then
        say "cloudflared 已安装，跳过。"
        return 0
    fi

    say "尝试从当前 Alpine 仓库安装 cloudflared..."
    if apk add --no-cache cloudflared; then
        return 0
    fi

    if ! grep -q '^http://dl-cdn.alpinelinux.org/alpine/edge/testing' /etc/apk/repositories 2>/dev/null; then
        say "追加 edge/testing 仓库以安装 cloudflared。"
        printf '%s\n' 'http://dl-cdn.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories
    fi

    apk update && apk add --no-cache cloudflared
}

install_dependencies() {
    if [ -f /etc/alpine-release ]; then
        say "检测到 Alpine $(cat /etc/alpine-release)。"
    else
        warn "未检测到 /etc/alpine-release，本脚本主要面向 Alpine/OpenRC。"
    fi

    apk update
    ensure_package nginx nginx || return 1
    ensure_package curl curl || return 1
    ensure_package ca-certificates update-ca-certificates || return 1
    ensure_package openssl openssl || return 1
    ensure_package openrc rc-service || return 1
    ensure_package jq jq || return 1
    ensure_cloudflared || return 1
}

render_cloudflared_openrc() {
    cat > "$CLOUDFLARED_INIT" <<'EOF'
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"
command="/usr/bin/cloudflared"
command_background=true
pidfile="/run/cloudflared.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.log"

start_pre() {
    if [ -f /etc/cf-nginx-manager/config.env ]; then
        . /etc/cf-nginx-manager/config.env
    fi
    checkpath -f -m 0600 -o root:root /var/log/cloudflared.log
    if [ -z "${CF_TUNNEL_TOKEN}" ]; then
        eerror "CF_TUNNEL_TOKEN is empty. Configure /etc/cf-nginx-manager/config.env first."
        return 1
    fi
    command_args="tunnel run --token ${CF_TUNNEL_TOKEN}"
}

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$CLOUDFLARED_INIT"
}

render_nginx_map() {
    cat > "$NGINX_MAP_FILE" <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
EOF
}

service_add_default() {
    svc="$1"
    rc-update add "$svc" default >/dev/null 2>&1 || true
}

init_environment() {
    need_root
    ensure_dirs
    install_dependencies || return 1
    render_nginx_map
    render_cloudflared_openrc
    service_add_default nginx
    service_add_default cloudflared
    if [ ! -f "$CONFIG_ENV" ]; then
        configure_credentials || return 1
    fi
    nginx -t && rc-service nginx restart
    rc-service cloudflared restart || warn "cloudflared 启动失败，请检查 token 或日志：$CLOUDFLARED_LOG"
    say "初始化完成。"
}

normalize_target() {
    raw="$1"
    case "$raw" in
        http://*|https://*) target="$raw" ;;
        *:*) target="http://$raw" ;;
        *) target="https://$raw" ;;
    esac
    printf '%s' "$target"
}

target_scheme() {
    printf '%s' "$1" | sed 's#://.*##'
}

target_authority() {
    printf '%s' "$1" | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##'
}

target_host_only() {
    authority=$(target_authority "$1")
    case "$authority" in
        \[*\]*) printf '%s' "$authority" | sed 's/^\[//; s/\].*$//' ;;
        *) printf '%s' "$authority" | sed 's/:.*$//' ;;
    esac
}

validate_hostname() {
    host="$1"
    case "$host" in
        ''|*' '*|*/*|*:*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_nginx_value() {
    value="$1"
    case "$value" in
        ''|*' '*|*';'*|*'{'*|*'}'*|*'`'*|*'$('*|*'\n'*|*'\r'*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_host_header() {
    value="$1"
    case "$value" in
        ''|*' '*|*'/'*|*';'*|*'{'*|*'}'*|*'`'*|*'$('*|*'\n'*|*'\r'*) return 1 ;;
        *) return 0 ;;
    esac
}

save_site_env() {
    hostname="$1"
    target="$2"
    mode="$3"
    upstream_host="$4"
    custom_host="$5"
    path=$(site_env_path "$hostname")
    tmp="$path.tmp"
    {
        printf 'HOSTNAME=%s\n' "$(shell_quote "$hostname")"
        printf 'TARGET=%s\n' "$(shell_quote "$target")"
        printf 'MODE=%s\n' "$(shell_quote "$mode")"
        printf 'UPSTREAM_HOST=%s\n' "$(shell_quote "$upstream_host")"
        printf 'CUSTOM_HOST=%s\n' "$(shell_quote "$custom_host")"
        printf 'NGINX_CONF=%s\n' "$(shell_quote "$(site_conf_path "$hostname")")"
    } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$path"
}

render_site_nginx() {
    hostname="$1"
    target="$2"
    mode="$3"
    upstream_host="$4"
    custom_host="$5"
    conf=$(site_conf_path "$hostname")
    scheme=$(target_scheme "$target")
    host_only=$(target_host_only "$target")
    host_header="$upstream_host"
    [ -n "$custom_host" ] && host_header="$custom_host"

    tmp="$conf.tmp"
    {
        printf 'server {\n'
        printf '    listen 127.0.0.1:8080;\n'
        printf '    server_name %s;\n\n' "$hostname"
        printf '    client_max_body_size 100m;\n'
        printf '    proxy_buffers 8 16k;\n'
        printf '    proxy_buffer_size 32k;\n'
        printf '    proxy_busy_buffers_size 64k;\n\n'
        printf '    location / {\n'
        printf '        proxy_pass %s;\n' "$target"
        printf '        proxy_http_version 1.1;\n\n'
        if [ "$scheme" = "https" ]; then
            printf '        proxy_ssl_server_name on;\n'
            printf '        proxy_ssl_name %s;\n\n' "$host_only"
        fi
        printf '        proxy_set_header Host %s;\n' "$host_header"
        printf '        proxy_set_header X-Real-IP $remote_addr;\n'
        printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        proxy_set_header X-Forwarded-Host $host;\n'
        printf '        proxy_set_header X-Forwarded-Proto https;\n'
        printf '        proxy_set_header Accept-Encoding "";\n\n'
        printf '        proxy_set_header Upgrade $http_upgrade;\n'
        printf '        proxy_set_header Connection $connection_upgrade;\n\n'
        printf '        proxy_redirect %s://%s/ https://%s/;\n' "$scheme" "$upstream_host" "$hostname"
        printf '        proxy_redirect https://%s/ https://%s/;\n' "$host_only" "$hostname"
        printf '        proxy_redirect http://%s/ https://%s/;\n\n' "$host_only" "$hostname"
        printf '        proxy_cookie_domain %s %s;\n' "$host_only" "$hostname"
        printf '        proxy_cookie_domain .%s .%s;\n' "$host_only" "$hostname"
        printf '        proxy_cookie_domain %s %s;\n' "$upstream_host" "$hostname"
        printf '        proxy_cookie_path / /;\n'
        if [ "$mode" = "mirror" ]; then
            printf '\n'
            printf '        sub_filter_once off;\n'
            printf '        sub_filter_types text/html text/css text/javascript application/javascript application/json application/xml text/xml;\n\n'
            printf "        sub_filter 'https://www.%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'http://www.%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'https://%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'http://%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter '//www.%s' '//%s';\n" "$host_only" "$hostname"
            printf "        sub_filter '//%s' '//%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'www.%s' '%s';\n" "$host_only" "$hostname"
            printf "        sub_filter '%s' '%s';\n" "$host_only" "$hostname"
        fi
        printf '    }\n'
        printf '}\n'
    } > "$tmp"
    mv "$tmp" "$conf"
}

backup_managed_files() {
    ts=$(date +%Y%m%d-%H%M%S)
    dst="$BACKUP_DIR/$ts"
    mkdir -p "$dst/nginx" "$dst/sites"
    cp "$NGINX_MAP_FILE" "$dst/nginx/" 2>/dev/null || true
    cp "$NGINX_PREFIX"*.conf "$dst/nginx/" 2>/dev/null || true
    cp "$SITES_DIR"/*.env "$dst/sites/" 2>/dev/null || true
}

nginx_reload_safe() {
    if nginx -t; then
        rc-service nginx reload >/dev/null 2>&1 || rc-service nginx restart
        return 0
    fi
    return 1
}

cf_api() {
    method="$1"
    path="$2"
    body="${3:-}"
    require_config || return 1
    if [ -n "$body" ]; then
        curl -fsS -X "$method" "$CF_API_BASE$path" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H 'Content-Type: application/json' \
            --data "$body"
    else
        curl -fsS -X "$method" "$CF_API_BASE$path" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H 'Content-Type: application/json'
    fi
}

cf_dns_record_id() {
    hostname="$1"
    cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$hostname" | jq -r '.result[0].id // empty'
}

cf_upsert_dns() {
    hostname="$1"
    content="$CF_TUNNEL_ID.cfargotunnel.com"
    body=$(jq -cn --arg type CNAME --arg name "$hostname" --arg content "$content" '{type:$type,name:$name,content:$content,proxied:true}')
    id=$(cf_dns_record_id "$hostname")
    if [ -n "$id" ]; then
        say "更新 Cloudflare DNS：$hostname -> $content"
        cf_api PUT "/zones/$CF_ZONE_ID/dns_records/$id" "$body" | jq -e '.success == true' >/dev/null
    else
        say "创建 Cloudflare DNS：$hostname -> $content"
        cf_api POST "/zones/$CF_ZONE_ID/dns_records" "$body" | jq -e '.success == true' >/dev/null
    fi
}

cf_delete_dns() {
    hostname="$1"
    id=$(cf_dns_record_id "$hostname")
    if [ -n "$id" ]; then
        say "删除 Cloudflare DNS：$hostname"
        cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$id" | jq -e '.success == true' >/dev/null
    else
        say "Cloudflare DNS 不存在，跳过：$hostname"
    fi
}

managed_hostnames_json() {
    tmp=$(mktemp)
    printf '[' > "$tmp"
    first=1
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        HOSTNAME=
        # shellcheck disable=SC1090
        . "$f"
        [ -n "$HOSTNAME" ] || continue
        if [ "$first" = 1 ]; then
            first=0
        else
            printf ',' >> "$tmp"
        fi
        json_escape "$HOSTNAME" >> "$tmp"
    done
    printf ']' >> "$tmp"
    cat "$tmp"
    rm -f "$tmp"
}

managed_ingress_json() {
    tmp=$(mktemp)
    printf '[' > "$tmp"
    first=1
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        HOSTNAME=
        # shellcheck disable=SC1090
        . "$f"
        [ -n "$HOSTNAME" ] || continue
        if [ "$first" = 1 ]; then
            first=0
        else
            printf ',' >> "$tmp"
        fi
        jq -cn --arg hostname "$HOSTNAME" --arg service "${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}" '{hostname:$hostname,service:$service,originRequest:{}}' >> "$tmp"
    done
    printf ']' >> "$tmp"
    cat "$tmp"
    rm -f "$tmp"
}

cf_get_tunnel_config() {
    cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations"
}

cf_sync_ingress() {
    require_config || return 1
    current=$(cf_get_tunnel_config) || return 1
    managed_hosts=$(managed_hostnames_json)
    managed_ingress=$(managed_ingress_json)
    body=$(printf '%s' "$current" | jq -c \
        --argjson managedHosts "$managed_hosts" \
        --argjson managedIngress "$managed_ingress" \
        '{config:{ingress:((.result.config.ingress // []) | map(select((.hostname // "") as $h | ($managedHosts | index($h) | not))) | map(select(.service != "http_status:404")) + $managedIngress + [{service:"http_status:404"}])}}') || return 1
    say "同步 Cloudflare Tunnel ingress。"
    cf_api PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" "$body" | jq -e '.success == true' >/dev/null
}

choose_mode() {
    printf '%s\n' "请选择反代模式：" >/dev/tty
    printf '%s\n' "1) 普通反代（跳转/Cookie 改写）" >/dev/tty
    printf '%s\n' "2) 镜像反代（额外替换响应体域名）" >/dev/tty
    printf '选择 [2]: ' >/dev/tty
    read -r choice
    case "$choice" in
        1) printf 'proxy' ;;
        *) printf 'mirror' ;;
    esac
}

choose_host_header() {
    upstream_host="$1"
    printf '%s\n' "Host 头策略：" >/dev/tty
    printf '%s\n' "1) 使用上游 Host：$upstream_host（推荐）" >/dev/tty
    printf '%s\n' "2) 自定义 Host" >/dev/tty
    printf '选择 [1]: ' >/dev/tty
    read -r choice
    case "$choice" in
        2) read_input "自定义 Host" "$upstream_host" ;;
        *) printf '%s' "$upstream_host" ;;
    esac
}

add_site() {
    require_config || return 1
    ensure_dirs
    render_nginx_map
    hostname=$(read_input "公网域名，例如 app.example.com" "")
    if ! validate_hostname "$hostname"; then
        err "域名格式不正确。"
        return 1
    fi
    raw_target=$(read_input "目标地址，例如 https://target.com 或 127.0.0.1:3000" "")
    [ -n "$raw_target" ] || { err "目标地址不能为空。"; return 1; }
    target=$(normalize_target "$raw_target")
    if ! validate_nginx_value "$target"; then
        err "目标地址包含不安全字符。"
        return 1
    fi
    upstream_host=$(target_authority "$target")
    if ! validate_host_header "$upstream_host"; then
        err "无法从目标地址解析出安全的上游 Host。"
        return 1
    fi
    mode=$(choose_mode)
    custom_host=$(choose_host_header "$upstream_host")
    if ! validate_host_header "$custom_host"; then
        err "Host 头包含不安全字符。"
        return 1
    fi

    backup_managed_files
    save_site_env "$hostname" "$target" "$mode" "$upstream_host" "$custom_host"
    render_site_nginx "$hostname" "$target" "$mode" "$upstream_host" "$custom_host"
    if ! nginx_reload_safe; then
        err "Nginx 配置测试失败，请检查 $(site_conf_path "$hostname")。"
        return 1
    fi
    cf_upsert_dns "$hostname" || return 1
    cf_sync_ingress || return 1
    say "新增完成：https://$hostname -> $target"
}

list_sites() {
    i=1
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        HOSTNAME= TARGET= MODE=
        # shellcheck disable=SC1090
        . "$f"
        printf '%s) %s -> %s [%s]\n' "$i" "$HOSTNAME" "$TARGET" "$MODE"
        i=$((i + 1))
    done
    [ "$i" -gt 1 ]
}

site_file_by_number() {
    wanted="$1"
    i=1
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        if [ "$i" = "$wanted" ]; then
            printf '%s' "$f"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

select_site_file() {
    if ! list_sites; then
        err "当前没有站点。"
        return 1
    fi
    printf '选择站点编号: '
    read -r n
    site_file_by_number "$n"
}

edit_site() {
    require_config || return 1
    f=$(select_site_file) || return 1
    HOSTNAME= TARGET= MODE= UPSTREAM_HOST= CUSTOM_HOST=
    # shellcheck disable=SC1090
    . "$f"
    old_hostname="$HOSTNAME"
    old_conf=$(site_conf_path "$old_hostname")

    new_hostname=$(read_input "公网域名" "$HOSTNAME")
    if ! validate_hostname "$new_hostname"; then
        err "域名格式不正确。"
        return 1
    fi
    raw_target=$(read_input "目标地址" "$TARGET")
    target=$(normalize_target "$raw_target")
    if ! validate_nginx_value "$target"; then
        err "目标地址包含不安全字符。"
        return 1
    fi
    upstream_host=$(target_authority "$target")
    if ! validate_host_header "$upstream_host"; then
        err "无法从目标地址解析出安全的上游 Host。"
        return 1
    fi
    mode=$(choose_mode)
    custom_host=$(choose_host_header "$upstream_host")
    if ! validate_host_header "$custom_host"; then
        err "Host 头包含不安全字符。"
        return 1
    fi

    backup_managed_files
    if [ "$new_hostname" != "$old_hostname" ]; then
        rm -f "$old_conf" "$f"
    fi
    save_site_env "$new_hostname" "$target" "$mode" "$upstream_host" "$custom_host"
    render_site_nginx "$new_hostname" "$target" "$mode" "$upstream_host" "$custom_host"
    if ! nginx_reload_safe; then
        err "Nginx 配置测试失败。"
        return 1
    fi
    if [ "$new_hostname" != "$old_hostname" ]; then
        cf_delete_dns "$old_hostname" || warn "删除旧 DNS 失败：$old_hostname"
    fi
    cf_upsert_dns "$new_hostname" || return 1
    cf_sync_ingress || return 1
    say "修改完成：https://$new_hostname -> $target"
}

delete_site() {
    require_config || return 1
    f=$(select_site_file) || return 1
    HOSTNAME= TARGET=
    # shellcheck disable=SC1090
    . "$f"
    say "将删除：$HOSTNAME -> $TARGET"
    confirm "确认删除该反代及 Cloudflare DNS/ingress？" || return 0
    backup_managed_files
    rm -f "$(site_conf_path "$HOSTNAME")" "$f"
    if ! nginx_reload_safe; then
        err "删除后 Nginx 配置测试失败。备份位于 $BACKUP_DIR。"
        return 1
    fi
    cf_delete_dns "$HOSTNAME" || warn "删除 DNS 失败：$HOSTNAME"
    cf_sync_ingress || warn "同步 Tunnel ingress 失败。"
    say "删除完成：$HOSTNAME"
}

service_action() {
    svc="$1"
    action="$2"
    case "$action" in
        start|stop|restart|reload|status) rc-service "$svc" "$action" ;;
        *) err "未知服务动作：$action"; return 1 ;;
    esac
}

show_logs() {
    log="$1"
    if [ -f "$log" ]; then
        tail -n 80 "$log"
    else
        warn "日志不存在：$log"
    fi
}

local_test_site() {
    hostname=$(read_input "要测试的 Host" "")
    [ -n "$hostname" ] || return 1
    curl -I -H "Host: $hostname" http://127.0.0.1:8080/
}

manage_services() {
    while :; do
        say ""
        say "服务管理"
        say "1) nginx start"
        say "2) nginx stop"
        say "3) nginx restart"
        say "4) nginx reload"
        say "5) nginx status"
        say "6) nginx -t"
        say "7) cloudflared start"
        say "8) cloudflared stop"
        say "9) cloudflared restart"
        say "10) cloudflared status"
        say "11) 查看 cloudflared 日志"
        say "12) 查看 127.0.0.1:8080 监听"
        say "13) 本地 Host 测试"
        say "0) 返回"
        printf '选择: '
        read -r c
        case "$c" in
            1) service_action nginx start ;;
            2) service_action nginx stop ;;
            3) service_action nginx restart ;;
            4) service_action nginx reload ;;
            5) service_action nginx status ;;
            6) nginx -t ;;
            7) service_action cloudflared start ;;
            8) service_action cloudflared stop ;;
            9) service_action cloudflared restart ;;
            10) service_action cloudflared status ;;
            11) show_logs "$CLOUDFLARED_LOG" ;;
            12) ss -tlnp | grep ':8080' || true ;;
            13) local_test_site ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
        pause
    done
}

site_menu() {
    while :; do
        say ""
        say "反代管理"
        say "1) 新增反代"
        say "2) 修改反代"
        say "3) 删除反代"
        say "4) 查看反代列表"
        say "5) 同步 Cloudflare Tunnel ingress"
        say "0) 返回"
        printf '选择: '
        read -r c
        case "$c" in
            1) add_site ;;
            2) edit_site ;;
            3) delete_site ;;
            4) list_sites || true ;;
            5) cf_sync_ingress ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
        pause
    done
}

main_menu() {
    need_root
    ensure_dirs
    load_config
    while :; do
        say ""
        say "$APP_NAME"
        say "1) 首次初始化 / 修复环境"
        say "2) 配置 Cloudflare 凭据"
        say "3) 反代管理"
        say "4) 服务管理"
        say "5) 查看当前配置"
        say "0) 退出"
        printf '选择: '
        read -r c
        case "$c" in
            1) init_environment ;;
            2) configure_credentials ;;
            3) site_menu ;;
            4) manage_services ;;
            5) show_current_config ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
        pause
    done
}

show_current_config() {
    load_config
    say "配置目录：$CONFIG_DIR"
    say "本地服务：${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}"
    say "Account ID：${CF_ACCOUNT_ID:-未配置}"
    say "Zone ID：${CF_ZONE_ID:-未配置}"
    say "Tunnel ID：${CF_TUNNEL_ID:-未配置}"
    if [ -n "${CF_API_TOKEN:-}" ]; then say "API Token：已保存"; else say "API Token：未配置"; fi
    if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then say "Tunnel Token：已保存"; else say "Tunnel Token：未配置"; fi
    say ""
    list_sites || say "暂无站点。"
}

case "${1:-}" in
    init) init_environment ;;
    add) add_site ;;
    list) list_sites ;;
    sync) cf_sync_ingress ;;
    services) manage_services ;;
    config) configure_credentials ;;
    *) main_menu ;;
esac
