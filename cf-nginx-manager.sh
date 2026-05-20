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
ACME_HOME="/root/.acme.sh"
CERT_HOME="/etc/nginx/certs"
CF_API_BASE="https://api.cloudflare.com/client/v4"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
pause() { printf '\n\033[2m按回车继续...\033[0m ' >/dev/tty; IFS= read -r _ </dev/tty; }
clear_screen() { printf '\033c' >/dev/tty; }

C_RESET='\033[0m'
C_DIM='\033[2m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'
C_BOLD='\033[1m'

ui_line() { printf '%b\n' "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; }
ui_header() {
    clear_screen
    ui_line
    printf '%b\n' "${C_BOLD}${C_CYAN}  $1${C_RESET}"
    ui_line
    printf '\n'
}
ui_section() { printf '%b\n' "${C_BOLD}${C_BLUE}$1${C_RESET}"; }
ui_menu_item() { printf '  %b%2s%b) %s\n' "$C_CYAN" "$1" "$C_RESET" "$2"; }
ui_back_item() { printf '  %b%2s%b) %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }
ui_prompt() { printf '\n%b选择:%b ' "$C_BOLD" "$C_RESET" >/dev/tty; }
ui_ok() { printf '%b%s%b' "$C_GREEN" "$1" "$C_RESET"; }
ui_warn() { printf '%b%s%b' "$C_YELLOW" "$1" "$C_RESET"; }
ui_bad() { printf '%b%s%b' "$C_RED" "$1" "$C_RESET"; }

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
    IFS= read -r value </dev/tty
    if [ -z "$value" ]; then
        value="$default"
    fi
    printf '%s' "$value"
}

read_secret() {
    prompt="$1"
    printf '%s: ' "$prompt" >/dev/tty
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r value </dev/tty
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
    printf '%s' "$value"
}

confirm() {
    prompt="$1"
    printf '%s [y/N]: ' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty
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
    mkdir -p "$CONFIG_DIR" "$SITES_DIR" "$BACKUP_DIR" "$CERT_HOME" /var/log/cf-nginx-manager
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
        printf 'CF_ACCOUNT_ID=%s\n' "$(shell_quote "${CF_ACCOUNT_ID:-}")"
        printf 'CF_ZONE_ID=%s\n' "$(shell_quote "${CF_ZONE_ID:-}")"
        printf 'CF_API_TOKEN=%s\n' "$(shell_quote "${CF_API_TOKEN:-}")"
        printf 'CF_TUNNEL_ID=%s\n' "$(shell_quote "${CF_TUNNEL_ID:-}")"
        printf 'CF_TUNNEL_TOKEN=%s\n' "$(shell_quote "${CF_TUNNEL_TOKEN:-}")"
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

require_cf_api_token() {
    load_config
    if [ -z "${CF_API_TOKEN:-}" ]; then
        say "公网入站反代申请证书需要 Cloudflare API Token（至少 Zone / DNS / Edit 权限）。"
        CF_API_TOKEN=$(read_secret "Cloudflare API Token（输入不会回显）")
        if [ -z "$CF_API_TOKEN" ]; then
            err "Cloudflare API Token 不能为空。"
            return 1
        fi
        save_config
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
    ensure_package dcron crond || return 1
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
    printf '%s' "$1" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|[/?#].*||'
}

target_host_only() {
    authority=$(target_authority "$1")
    case "$authority" in
        \[*\]*) printf '%s' "$authority" | sed 's/^\[//; s/\].*$//' ;;
        *) printf '%s' "$authority" | sed 's/:.*$//' ;;
    esac
}

target_path_prefix() {
    path=$(printf '%s' "$1" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*||; s|[?#].*||')
    [ -n "$path" ] || path="/"
    while [ "$path" != "/" ]; do
        case "$path" in
            */) path=${path%/} ;;
            *) break ;;
        esac
    done
    [ "$path" = "/" ] && path=""
    printf '%s' "$path"
}

ensure_crond() {
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
}

random_acme_email() {
    n=$(date +%s)
    printf '%s@qq.com' "$n"
}

ensure_acme_ready() {
    email="$1"
    [ -n "$email" ] || email=$(random_acme_email)
    if [ ! -x "$ACME_HOME/acme.sh" ]; then
        say "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="$email" || return 1
    fi
    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "$ACME_HOME/acme.sh" --register-account -m "$email" --server letsencrypt >/dev/null 2>&1 || true
    ensure_crond
}

issue_cloudflare_cert() {
    domain="$1"
    email="$2"
    cert_dir="$CERT_HOME/$domain"
    mkdir -p "$cert_dir"
    ensure_acme_ready "$email" || return 1
    export CF_Token="$CF_API_TOKEN"
    say "申请证书：$domain"
    "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$domain" --keylength ec-256 || return 1
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
        --fullchain-file "$cert_dir/fullchain.cer" \
        --key-file "$cert_dir/private.key" \
        --reloadcmd "rc-service nginx reload || rc-service nginx restart || true" || return 1
    chmod 600 "$cert_dir/private.key" 2>/dev/null || true
    chmod 644 "$cert_dir/fullchain.cer" 2>/dev/null || true
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

validate_port() {
    port="$1"
    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_nginx_value() {
    value="$1"
    case "$value" in
        ''|*' '*|*';'*|*'{'*|*'}'*|*'`'*|*'$'*|*'"'*|*'\\'*|*'\n'*|*'\r'*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_proxy_path() {
    value="$1"
    [ -n "$value" ] || return 0
    case "$value" in
        /*) ;;
        *) return 1 ;;
    esac
    validate_nginx_value "$value"
}

validate_host_header() {
    value="$1"
    case "$value" in
        ''|*' '*|*'/'*|*';'*|*'{'*|*'}'*|*'`'*|*'$'*|*'"'*|*'\\'*|*'\n'*|*'\r'*) return 1 ;;
        *) return 0 ;;
    esac
}

save_site_env() {
    hostname="$1"
    target="$2"
    mode="$3"
    upstream_host="$4"
    custom_host="$5"
    service="$6"
    listen_port="${7:-}"
    path=$(site_env_path "$hostname")
    tmp="$path.tmp"
    {
        printf 'HOSTNAME=%s\n' "$(shell_quote "$hostname")"
        printf 'TARGET=%s\n' "$(shell_quote "$target")"
        printf 'MODE=%s\n' "$(shell_quote "$mode")"
        printf 'UPSTREAM_HOST=%s\n' "$(shell_quote "$upstream_host")"
        printf 'CUSTOM_HOST=%s\n' "$(shell_quote "$custom_host")"
        printf 'SERVICE=%s\n' "$(shell_quote "$service")"
        printf 'LISTEN_PORT=%s\n' "$(shell_quote "$listen_port")"
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
    listen_port="${6:-}"
    conf=$(site_conf_path "$hostname")
    scheme=$(target_scheme "$target")
    host_only=$(target_host_only "$target")
    path_prefix=$(target_path_prefix "$target")
    if ! validate_proxy_path "$path_prefix"; then
        err "目标路径包含不安全字符。"
        return 1
    fi
    host_header="$upstream_host"
    cert_dir="$CERT_HOME/$hostname"
    [ -n "$custom_host" ] && host_header="$custom_host"

    tmp="$conf.tmp"
    {
        printf 'server {\n'
        if [ "$mode" = "public" ]; then
            printf '    listen %s ssl;\n' "$listen_port"
            printf '    listen [::]:%s ssl;\n' "$listen_port"
        else
            printf '    listen 127.0.0.1:8080;\n'
        fi
        printf '    server_name %s;\n\n' "$hostname"
        if [ "$mode" = "public" ]; then
            printf '    ssl_certificate     %s/fullchain.cer;\n' "$cert_dir"
            printf '    ssl_certificate_key %s/private.key;\n' "$cert_dir"
            printf '    ssl_session_cache shared:SSL:10m;\n'
            printf '    ssl_session_timeout 10m;\n'
            printf '    ssl_protocols TLSv1.2 TLSv1.3;\n'
            printf '    ssl_prefer_server_ciphers off;\n\n'
        fi
        printf '    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;\n'
        printf '    resolver_timeout 5s;\n\n'
        printf '    client_max_body_size 100m;\n'
        printf '    proxy_buffers 8 16k;\n'
        printf '    proxy_buffer_size 32k;\n'
        printf '    proxy_busy_buffers_size 64k;\n\n'
        printf '    location / {\n'
        if [ -n "$path_prefix" ]; then
            printf '        set $proxy_request_uri "%s$request_uri";\n' "$path_prefix"
        else
            printf '        set $proxy_request_uri "$request_uri";\n'
        fi
        printf '        set $proxy_upstream "%s://%s";\n' "$scheme" "$upstream_host"
        printf '        proxy_pass $proxy_upstream$proxy_request_uri;\n'
        printf '        proxy_http_version 1.1;\n\n'
        if [ "$scheme" = "https" ]; then
            printf '        proxy_ssl_server_name on;\n'
            printf '        proxy_ssl_name %s;\n\n' "$host_only"
        fi
        printf '        proxy_set_header Host %s;\n' "$host_header"
        if [ "$mode" = "cfcdn" ]; then
            printf '        proxy_set_header CF-Connecting-IP $remote_addr;\n'
            printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
            printf '        proxy_set_header X-Forwarded-Proto https;\n'
            printf '        proxy_set_header X-Forwarded-Host %s;\n' "$host_header"
            printf '        proxy_set_header Origin %s://%s;\n' "$scheme" "$host_header"
            printf '        proxy_set_header Referer %s://%s$request_uri;\n' "$scheme" "$host_header"
        else
            printf '        proxy_set_header X-Real-IP $remote_addr;\n'
            printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
            printf '        proxy_set_header X-Forwarded-Host $host;\n'
            printf '        proxy_set_header X-Forwarded-Proto https;\n'
        fi
        printf '        proxy_set_header Accept-Encoding "";\n\n'
        printf '        proxy_set_header Upgrade $http_upgrade;\n'
        printf '        proxy_set_header Connection $connection_upgrade;\n\n'
        if [ "$mode" = "public" ]; then
            redirect_base="https://$hostname:$listen_port"
        else
            redirect_base="https://$hostname"
        fi
        printf '        proxy_redirect %s://%s/ %s/;\n' "$scheme" "$upstream_host" "$redirect_base"
        printf '        proxy_redirect https://%s/ %s/;\n' "$host_only" "$redirect_base"
        printf '        proxy_redirect http://%s/ %s/;\n\n' "$host_only" "$redirect_base"
        printf '        proxy_cookie_domain %s %s;\n' "$host_only" "$hostname"
        printf '        proxy_cookie_domain .%s .%s;\n' "$host_only" "$hostname"
        printf '        proxy_cookie_domain %s %s;\n' "$upstream_host" "$hostname"
        printf '        proxy_cookie_path / /;\n'
        if [ "$mode" = "cfcdn" ] || [ "$mode" = "public" ]; then
            printf '\n'
            if [ "$mode" = "cfcdn" ]; then
                printf '        proxy_ssl_verify off;\n'
            fi
            printf '        proxy_buffering off;\n'
            printf '        proxy_request_buffering off;\n'
        fi
        if [ "$mode" = "mirror" ]; then
            printf '\n'
            printf '        sub_filter_once off;\n'
            printf '        sub_filter_types text/css text/javascript application/javascript application/json application/xml text/xml;\n\n'
            printf "        sub_filter 'https://www.%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'http://www.%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'https://%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter 'http://%s' 'https://%s';\n" "$host_only" "$hostname"
            printf "        sub_filter '//www.%s' '//%s';\n" "$host_only" "$hostname"
            printf "        sub_filter '//%s' '//%s';\n" "$host_only" "$hostname"
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

has_nginx_site() {
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        MODE=
        # shellcheck disable=SC1090
        . "$f"
        case "$MODE" in
            proxy|mirror|cfcdn|public) return 0 ;;
        esac
    done
    return 1
}

reload_nginx_if_needed() {
    if has_nginx_site; then
        nginx_reload_safe
    else
        return 0
    fi
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
        HOSTNAME= MODE= SERVICE=
        # shellcheck disable=SC1090
        . "$f"
        [ -n "$HOSTNAME" ] || continue
        [ "$MODE" != "public" ] || continue
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
        HOSTNAME= MODE= SERVICE=
        # shellcheck disable=SC1090
        . "$f"
        [ -n "$HOSTNAME" ] || continue
        [ "$MODE" != "public" ] || continue
        if [ "$first" = 1 ]; then
            first=0
        else
            printf ',' >> "$tmp"
        fi
        service="${SERVICE:-${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}}"
        jq -cn --arg hostname "$HOSTNAME" --arg service "$service" '{hostname:$hostname,service:$service,originRequest:{}}' >> "$tmp"
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

cf_remove_ingress_hostname() {
    hostname="$1"
    require_config || return 1
    current=$(cf_get_tunnel_config) || return 1
    body=$(printf '%s' "$current" | jq -c \
        --arg hostname "$hostname" \
        '{config:{ingress:((.result.config.ingress // []) | map(select((.hostname // "") != $hostname)) | map(select(.service != "http_status:404")) + [{service:"http_status:404"}])}}') || return 1
    say "移除 Cloudflare Tunnel ingress：$hostname"
    cf_api PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" "$body" | jq -e '.success == true' >/dev/null
}

mode_choice_number() {
    case "$1" in
        proxy) printf '2' ;;
        mirror) printf '3' ;;
        cfcdn) printf '4' ;;
        public) printf '5' ;;
        *) printf '1' ;;
    esac
}

choose_mode() {
    default_mode="${1:-direct}"
    default_choice=$(mode_choice_number "$default_mode")
    printf '%s\n' "请选择反代模式：" >/dev/tty
    printf '%s\n' "1) Cloudflare Tunnel 直连服务（推荐：本机端口、IP:PORT、自建面板、API）" >/dev/tty
    printf '%s\n' "2) Nginx 普通反代（经过 Tunnel，需要 Nginx 处理 Host/Cookie/跳转时用）" >/dev/tty
    printf '%s\n' "3) Nginx 网站镜像反代（经过 Tunnel，仅适合简单网页）" >/dev/tty
    printf '%s\n' "4) Nginx 代理 CF CDN 目标站（经过 Tunnel，目标站本身套了 Cloudflare 时用）" >/dev/tty
    printf '%s\n' "5) Nginx 公网入站反代（不使用 Cloudflare Tunnel，需要开放入站端口）" >/dev/tty
    printf '选择 [%s]: ' "$default_choice" >/dev/tty
    IFS= read -r choice </dev/tty
    [ -n "$choice" ] || choice="$default_choice"
    case "$choice" in
        2) printf 'proxy' ;;
        3) printf 'mirror' ;;
        4) printf 'cfcdn' ;;
        5) printf 'public' ;;
        *) printf 'direct' ;;
    esac
}

choose_host_header() {
    upstream_host="$1"
    printf '%s\n' "Host 头策略：" >/dev/tty
    printf '%s\n' "1) 使用上游 Host：$upstream_host（推荐）" >/dev/tty
    printf '%s\n' "2) 自定义 Host" >/dev/tty
    printf '选择 [1]: ' >/dev/tty
    IFS= read -r choice </dev/tty
    case "$choice" in
        2) read_input "自定义 Host" "$upstream_host" ;;
        *) printf '%s' "$upstream_host" ;;
    esac
}

add_site() {
    load_config
    ensure_dirs
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
    mode=$(choose_mode direct)
    service="${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}"
    custom_host=""
    listen_port=""
    if [ "$mode" = "direct" ]; then
        service="$target"
    elif [ "$mode" = "cfcdn" ]; then
        custom_host="$upstream_host"
    elif [ "$mode" = "public" ]; then
        custom_host="$upstream_host"
    else
        custom_host=$(choose_host_header "$upstream_host")
        if ! validate_host_header "$custom_host"; then
            err "Host 头包含不安全字符。"
            return 1
        fi
    fi
    if [ "$mode" = "public" ]; then
        require_cf_api_token || return 1
        listen_port=$(read_input "公网 HTTPS 入站监听端口，例如 2053 或 52443" "52443")
        if ! validate_port "$listen_port"; then
            err "监听端口不合法。"
            return 1
        fi
        acme_email=$(read_input "ACME 账户邮箱（留空自动生成）" "")
        issue_cloudflare_cert "$hostname" "$acme_email" || return 1
        service=""
    else
        require_config || return 1
    fi

    backup_managed_files
    save_site_env "$hostname" "$target" "$mode" "$upstream_host" "$custom_host" "$service" "$listen_port"
    if [ "$mode" = "direct" ]; then
        rm -f "$(site_conf_path "$hostname")"
    else
        render_site_nginx "$hostname" "$target" "$mode" "$upstream_host" "$custom_host" "$listen_port"
        if ! nginx_reload_safe; then
            err "Nginx 配置测试失败，请检查 $(site_conf_path "$hostname")。"
            return 1
        fi
    fi
    if [ "$mode" = "public" ]; then
        say "新增完成：https://$hostname:$listen_port -> $target [public]"
        say "请确认域名已解析到本机公网 IP，且防火墙/安全组已放行 TCP $listen_port。"
    else
        cf_upsert_dns "$hostname" || return 1
        cf_sync_ingress || return 1
        say "新增完成：https://$hostname -> $target [$mode]"
    fi
}

mode_label() {
    case "$1" in
        direct) printf 'Tunnel直连' ;;
        proxy) printf 'Nginx普通反代' ;;
        mirror) printf 'Nginx镜像反代' ;;
        cfcdn) printf 'Nginx代理CF CDN站' ;;
        public) printf 'Nginx公网入站反代' ;;
        *) printf '%s' "$1" ;;
    esac
}

list_sites() {
    i=1
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        HOSTNAME= TARGET= MODE= LISTEN_PORT=
        # shellcheck disable=SC1090
        . "$f"
        if [ "$MODE" = "public" ] && [ -n "$LISTEN_PORT" ]; then
            printf '%s) %s:%s -> %s [%s]\n' "$i" "$HOSTNAME" "$LISTEN_PORT" "$TARGET" "$(mode_label "$MODE")"
        else
            printf '%s) %s -> %s [%s]\n' "$i" "$HOSTNAME" "$TARGET" "$(mode_label "$MODE")"
        fi
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
            SELECTED_SITE_FILE="$f"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

select_site_file() {
    SELECTED_SITE_FILE=""
    if ! list_sites >/dev/tty; then
        err "当前没有站点。"
        return 1
    fi
    printf '选择站点编号: ' >/dev/tty
    IFS= read -r n </dev/tty
    if ! site_file_by_number "$n"; then
        err "无效的站点编号。"
        return 1
    fi
}

edit_site() {
    load_config
    select_site_file || return 1
    f="$SELECTED_SITE_FILE"
    HOSTNAME= TARGET= MODE= UPSTREAM_HOST= CUSTOM_HOST= LISTEN_PORT=
    # shellcheck disable=SC1090
    . "$f"
    old_hostname="$HOSTNAME"
    old_mode="$MODE"
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
    mode=$(choose_mode "${MODE:-direct}")
    service="${LOCAL_SERVICE:-$LOCAL_SERVICE_DEFAULT}"
    custom_host=""
    listen_port=""
    if [ "$mode" = "direct" ]; then
        service="$target"
    elif [ "$mode" = "cfcdn" ]; then
        custom_host="$upstream_host"
    elif [ "$mode" = "public" ]; then
        custom_host="$upstream_host"
    else
        custom_host=$(choose_host_header "$upstream_host")
        if ! validate_host_header "$custom_host"; then
            err "Host 头包含不安全字符。"
            return 1
        fi
    fi
    if [ "$mode" = "public" ]; then
        require_cf_api_token || return 1
        listen_port=$(read_input "公网 HTTPS 入站监听端口，例如 2053 或 52443" "${LISTEN_PORT:-52443}")
        if ! validate_port "$listen_port"; then
            err "监听端口不合法。"
            return 1
        fi
        if [ "$new_hostname" != "$old_hostname" ] || [ "$old_mode" != "public" ] || [ ! -s "$CERT_HOME/$new_hostname/fullchain.cer" ] || [ ! -s "$CERT_HOME/$new_hostname/private.key" ]; then
            acme_email=$(read_input "ACME 账户邮箱（留空自动生成）" "")
            issue_cloudflare_cert "$new_hostname" "$acme_email" || return 1
        fi
        service=""
    else
        require_config || return 1
    fi

    backup_managed_files
    if [ "$new_hostname" != "$old_hostname" ]; then
        rm -f "$old_conf" "$f"
    fi
    save_site_env "$new_hostname" "$target" "$mode" "$upstream_host" "$custom_host" "$service" "$listen_port"
    if [ "$mode" = "direct" ]; then
        rm -f "$(site_conf_path "$new_hostname")"
        if [ "$old_mode" = "proxy" ] || [ "$old_mode" = "mirror" ] || [ "$old_mode" = "cfcdn" ] || [ "$old_mode" = "public" ]; then
            nginx_reload_safe || warn "旧 Nginx 站点配置已删除，但 Nginx reload 失败，请手动检查。"
        else
            reload_nginx_if_needed || warn "已有 Nginx 站点配置测试失败，请检查 Nginx 配置。"
        fi
    else
        render_site_nginx "$new_hostname" "$target" "$mode" "$upstream_host" "$custom_host" "$listen_port"
        if ! nginx_reload_safe; then
            err "Nginx 配置测试失败。"
            return 1
        fi
    fi
    if [ "$old_mode" != "public" ] && [ "$mode" != "public" ]; then
        if [ "$new_hostname" != "$old_hostname" ]; then
            cf_delete_dns "$old_hostname" || warn "删除旧 DNS 失败：$old_hostname"
            cf_remove_ingress_hostname "$old_hostname" || warn "移除旧 Tunnel ingress 失败：$old_hostname"
        fi
    fi
    if [ "$mode" = "public" ]; then
        if [ "$old_mode" != "public" ]; then
            cf_delete_dns "$old_hostname" || warn "删除旧 DNS 失败：$old_hostname"
            cf_remove_ingress_hostname "$old_hostname" || warn "移除旧 Tunnel ingress 失败：$old_hostname"
        fi
        say "修改完成：https://$new_hostname:$listen_port -> $target [public]"
        say "请确认域名已解析到本机公网 IP，且防火墙/安全组已放行 TCP $listen_port。"
    else
        cf_upsert_dns "$new_hostname" || return 1
        cf_sync_ingress || return 1
        say "修改完成：https://$new_hostname -> $target [$mode]"
    fi
}

delete_site() {
    load_config
    select_site_file || return 1
    f="$SELECTED_SITE_FILE"
    HOSTNAME= TARGET= MODE=
    # shellcheck disable=SC1090
    . "$f"
    old_mode="$MODE"
    say "将删除：$HOSTNAME -> $TARGET"
    if [ "$old_mode" = "public" ]; then
        confirm "确认删除该公网入站反代？证书文件会保留。" || return 0
    else
        require_config || return 1
        confirm "确认删除该反代及 Cloudflare DNS/ingress？" || return 0
    fi
    backup_managed_files
    rm -f "$(site_conf_path "$HOSTNAME")" "$f"
    if [ "$old_mode" = "proxy" ] || [ "$old_mode" = "mirror" ] || [ "$old_mode" = "cfcdn" ] || [ "$old_mode" = "public" ]; then
        if ! nginx_reload_safe; then
            err "删除后 Nginx 配置测试失败。备份位于 $BACKUP_DIR。"
            return 1
        fi
    elif ! reload_nginx_if_needed; then
        err "删除后 Nginx 配置测试失败。备份位于 $BACKUP_DIR。"
        return 1
    fi
    if [ "$old_mode" = "public" ]; then
        say "删除完成：$HOSTNAME"
    else
        cf_delete_dns "$HOSTNAME" || warn "删除 DNS 失败：$HOSTNAME"
        cf_remove_ingress_hostname "$HOSTNAME" || warn "移除 Tunnel ingress 失败：$HOSTNAME"
        say "删除完成：$HOSTNAME"
    fi
}

service_status_label() {
    svc="$1"
    cmd="${2:-$1}"
    if ! has_cmd "$cmd"; then
        ui_bad '未安装'
        return 0
    fi
    if rc-service "$svc" status >/dev/null 2>&1; then
        ui_ok '运行中'
    else
        ui_warn '已停止'
    fi
}

site_count() {
    count=0
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] || continue
        count=$((count + 1))
    done
    printf '%s' "$count"
}

show_status_card() {
    ui_section "服务状态"
    printf '  nginx       : %b\n' "$(service_status_label nginx nginx)"
    printf '  cloudflared : %b\n' "$(service_status_label cloudflared cloudflared)"
    printf '  反代站点    : %s 个\n' "$(site_count)"
    printf '\n'
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

uninstall_manager() {
    ui_header "卸载 $APP_NAME"
    ui_section "将删除"
    printf '  - %s\n' "$CONFIG_DIR"
    printf '  - %s*.conf\n' "$NGINX_PREFIX"
    printf '  - %s\n' "$NGINX_MAP_FILE"
    printf '  - %s\n' "$CLOUDFLARED_INIT"
    printf '  - %s\n' "$CLOUDFLARED_LOG"
    printf '  - /usr/local/bin/cf-nginx-manager\n'
    printf '\n'
    ui_section "不会删除"
    printf '  - nginx / cloudflared 软件包\n'
    printf '  - Cloudflare 后台已经存在的 DNS 记录\n'
    printf '  - Cloudflare Tunnel 远端配置\n'
    printf '  - %s 下的其他证书目录\n' "$CERT_HOME"
    printf '\n'
    confirm "确认卸载本机 $APP_NAME 管理文件？" || return 0
    confirm "再次确认：继续删除这些本地文件？" || return 0

    uninstall_backup="/root/${APP_NAME}-uninstall-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$uninstall_backup/nginx" "$uninstall_backup/sites"
    cp "$NGINX_MAP_FILE" "$uninstall_backup/nginx/" 2>/dev/null || true
    cp "$NGINX_PREFIX"*.conf "$uninstall_backup/nginx/" 2>/dev/null || true
    cp "$SITES_DIR"/*.env "$uninstall_backup/sites/" 2>/dev/null || true
    cp "$CONFIG_ENV" "$uninstall_backup/" 2>/dev/null || true
    rc-service cloudflared stop >/dev/null 2>&1 || true
    rc-update del cloudflared default >/dev/null 2>&1 || true
    rm -f "$NGINX_PREFIX"*.conf 2>/dev/null || true
    rm -f "$NGINX_MAP_FILE" 2>/dev/null || true
    rm -f "$CLOUDFLARED_INIT" 2>/dev/null || true
    rm -f "$CLOUDFLARED_LOG" 2>/dev/null || true
    rm -f /usr/local/bin/cf-nginx-manager 2>/dev/null || true
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    if has_cmd nginx; then
        nginx -t >/dev/null 2>&1 && rc-service nginx reload >/dev/null 2>&1 || true
    fi
    say "卸载完成。"
    say "卸载前备份：$uninstall_backup"
}

local_test_site() {
    hostname=$(read_input "要测试的 Host" "")
    [ -n "$hostname" ] || return 1
    site_file=$(site_env_path "$hostname")
    if [ -f "$site_file" ]; then
        MODE= TARGET= LISTEN_PORT=
        # shellcheck disable=SC1090
        . "$site_file"
        if [ "$MODE" = "direct" ]; then
            curl -I "$TARGET"
            return $?
        fi
        if [ "$MODE" = "public" ]; then
            curl -k -I --resolve "$hostname:$LISTEN_PORT:127.0.0.1" "https://$hostname:$LISTEN_PORT/"
            return $?
        fi
    fi
    curl -I -H "Host: $hostname" http://127.0.0.1:8080/
}

manage_services() {
    while :; do
        ui_header "服务管理"
        show_status_card
        ui_section "Nginx"
        ui_menu_item 1 "启动 nginx"
        ui_menu_item 2 "停止 nginx"
        ui_menu_item 3 "重启 nginx"
        ui_menu_item 4 "重载 nginx"
        ui_menu_item 5 "查看 nginx 状态"
        ui_menu_item 6 "测试 nginx 配置"
        printf '\n'
        ui_section "Cloudflared"
        ui_menu_item 7 "启动 cloudflared"
        ui_menu_item 8 "停止 cloudflared"
        ui_menu_item 9 "重启 cloudflared"
        ui_menu_item 10 "查看 cloudflared 状态"
        ui_menu_item 11 "查看 cloudflared 日志"
        printf '\n'
        ui_section "诊断"
        ui_menu_item 12 "查看 Nginx 监听端口"
        ui_menu_item 13 "本地 Host 测试"
        ui_back_item 0 "返回主菜单"
        ui_prompt
        IFS= read -r c </dev/tty
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
            12) ss -tlnp | grep nginx || true ;;
            13) local_test_site ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
        pause
    done
}

site_menu() {
    while :; do
        ui_header "反代管理"
        show_status_card
        ui_section "站点操作"
        ui_menu_item 1 "修改反代"
        ui_menu_item 2 "删除反代"
        ui_menu_item 3 "查看反代列表"
        printf '\n'
        ui_section "Cloudflare"
        ui_menu_item 4 "同步 Cloudflare Tunnel ingress"
        ui_back_item 0 "返回主菜单"
        ui_prompt
        IFS= read -r c </dev/tty
        case "$c" in
            1) edit_site ;;
            2) delete_site ;;
            3) list_sites || true ;;
            4) cf_sync_ingress ;;
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
        ui_header "$APP_NAME"
        show_status_card
        ui_section "常用操作"
        ui_menu_item 1 "首次初始化 / 修复环境"
        ui_menu_item 2 "新增反代"
        ui_menu_item 3 "反代管理"
        printf '\n'
        ui_section "系统维护"
        ui_menu_item 4 "服务管理"
        ui_menu_item 5 "配置 Cloudflare 凭据"
        ui_menu_item 6 "查看当前配置"
        ui_menu_item 7 "卸载本脚本"
        ui_back_item 0 "退出"
        ui_prompt
        IFS= read -r c </dev/tty
        case "$c" in
            1) init_environment ;;
            2) add_site ;;
            3) site_menu ;;
            4) manage_services ;;
            5) configure_credentials ;;
            6) show_current_config ;;
            7) uninstall_manager ;;
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
    uninstall) uninstall_manager ;;
    *) main_menu ;;
esac
