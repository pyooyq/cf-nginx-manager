# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`cf-nginx-manager` is a single POSIX shell script for Alpine/OpenRC VPS hosts. It manages Cloudflare Tunnel ingress, Cloudflare DNS CNAME records, local Nginx reverse-proxy configs, and optional public HTTPS Nginx ingress with acme.sh certificates.

The main executable is `cf-nginx-manager.sh`; there is no package manager, build system, or automated test suite in this repository.

## Common commands

Syntax and static checks:

```sh
sh -n cf-nginx-manager.sh
shellcheck cf-nginx-manager.sh
```

Run the script locally:

```sh
chmod +x cf-nginx-manager.sh
./cf-nginx-manager.sh
```

Supported non-interactive entry commands:

```sh
./cf-nginx-manager.sh init
./cf-nginx-manager.sh add
./cf-nginx-manager.sh list
./cf-nginx-manager.sh sync
./cf-nginx-manager.sh services
./cf-nginx-manager.sh config
./cf-nginx-manager.sh update
./cf-nginx-manager.sh install
./cf-nginx-manager.sh uninstall
```

Operational checks from the README, used on target Alpine hosts:

```sh
nginx -t
rc-service nginx status
rc-service cloudflared status
ss -tlnp | grep nginx
tail -n 100 /var/log/cloudflared.log
curl -I -H 'Host: app.example.com' http://127.0.0.1:8080/
curl -I https://app.example.com/
curl -I https://app.example.com:52443/
```

## Runtime environment and managed paths

The script is designed for root execution on Alpine Linux with OpenRC. `init_environment` installs or configures `nginx`, `curl`, `ca-certificates`, `openssl`, `openrc`, `jq`, `dcron`, and `cloudflared` via `apk`.

Managed local state:

- `/etc/cf-nginx-manager/config.env` stores Cloudflare credentials and local service settings with `0600` permissions.
- `/etc/cf-nginx-manager/sites.d/*.env` stores one shell-quoted site record per hostname.
- `/etc/cf-nginx-manager/backups/` receives backups before site/config mutations.
- `/etc/nginx/http.d/00-cf-nginx-manager-map.conf` defines the WebSocket connection upgrade map.
- `/etc/nginx/http.d/cf-nginx-manager-*.conf` contains generated per-site Nginx server blocks.
- `/etc/init.d/cloudflared` is a generated OpenRC service using the saved tunnel token.
- `/var/log/cloudflared.log` is the cloudflared service log.
- `/etc/nginx/certs/<domain>/` stores public-ingress certificates installed by acme.sh.
- `/usr/local/bin/cfp` is the preferred installed command; `/usr/local/bin/cf-nginx-manager` is kept as a compatibility entry when possible.

## High-level architecture

`cf-nginx-manager.sh` is organized around shell functions and a final argument dispatch. With no argument it runs `main_menu`; with an argument it dispatches to `init`, `add`, `list`, `sync`, `services`, `config`, `update`/`self-update`, `install`, or `uninstall`.

Key areas in the script:

- UI and input helpers (`ui_*`, `read_input`, `read_secret`, `confirm`) write prompts to `/dev/tty`, so interactive flows are not simple stdin pipelines.
- Configuration helpers (`load_config`, `save_config`, `save_site_env`) persist shell-quoted `.env` files that are later sourced by the script.
- Target parsing and validation (`normalize_target`, `target_*`, `validate_*`) feed both Cloudflare ingress JSON and generated Nginx config; keep injection-sensitive validation in mind when changing generated directives.
- Nginx rendering (`render_nginx_map`, `render_site_nginx`) writes temp files then moves them into place. `nginx_reload_safe` always runs `nginx -t` before reload/restart.
- Cloudflare integration (`cf_api`, DNS helpers, `cf_sync_ingress`) uses `curl` and `jq` against Cloudflare API v4. Tunnel sync preserves ingress entries not managed by this script, removes managed hostnames from the existing config, appends current managed entries, and ensures a final `http_status:404` rule.
- Site lifecycle (`add_site`, `edit_site`, `delete_site`) backs up managed files before mutation, updates local site state, renders/removes Nginx config as needed, then updates Cloudflare DNS/ingress unless the site is in public mode.
- Service and uninstall flows manage OpenRC services and local files only; uninstall intentionally leaves packages, Cloudflare remote records, and unrelated certificates alone.

## Proxy modes

Site `MODE` values drive both Cloudflare and Nginx behavior:

- `direct`: Cloudflare Tunnel ingress points directly to the target service; no per-site Nginx config is generated.
- `proxy`: Tunnel points to local Nginx at `http://127.0.0.1:8080`; Nginx proxies to the target and can adjust Host/Cookie/redirect behavior.
- `mirror`: Like `proxy`, plus `sub_filter` replacements for simple website mirroring.
- `cfcdn`: Like Nginx proxy mode but keeps upstream Host/SNI oriented toward a target already behind Cloudflare CDN and disables upstream certificate verification.
- `public`: Does not use Cloudflare Tunnel; Nginx listens on a user-selected HTTPS port, creates/updates Cloudflare A and optional AAAA records, obtains a Let's Encrypt certificate through acme.sh Cloudflare DNS validation, and serves directly.

## README-derived user behavior

The README is in Chinese and is user-facing. It positions Tunnel direct mode as the recommended/default mode for self-hosted services, local ports, APIs, panels, and Docker services. It warns that mirror-style reverse proxying is not suitable for complex login flows, payment/OAuth, strict CSP/CORS/Service Worker/HSTS sites, or perfect large-site mirroring.
