#!/usr/bin/env bash

CADDY_CONF_DIR=${CADDY_CONF_DIR:-/etc/caddy}

caddy_site_file() { printf '%s/conf.d/novnc.caddy\n' "$CADDY_CONF_DIR"; }

install_caddy_binary() {
  local url build
  if command -v caddy >/dev/null 2>&1; then
    info "Caddy 已安装：$(command -v caddy)，跳过下载。"
    return 0
  fi
  url=$(github_asset_url caddyserver/caddy "^caddy_[0-9][0-9.]*_linux_${SYSTEM_ARCH}\\.tar\\.gz$" || true)
  [[ -n "$url" ]] || die "未能定位 ${SYSTEM_ARCH} 架构的 Caddy release。"
  build=$(mktemp -d)
  trap 'rm -rf "${build:-}"' EXIT
  github_download "$url" "$build/caddy.tar.gz"
  tar -xzf "$build/caddy.tar.gz" -C "$build" caddy
  [[ -f "$build/caddy" ]] || die "Caddy 压缩包内没有 caddy 二进制。"
  install -m 0755 "$build/caddy" /usr/local/bin/caddy
  /usr/local/bin/caddy version >/dev/null || die "下载的 Caddy 二进制无法运行。"
  info "Caddy $(/usr/local/bin/caddy version | awk '{print $1}') 已安装到 /usr/local/bin/caddy。"
  rm -rf "$build"
  build=
  trap - EXIT
}

ensure_caddy_user() {
  getent group caddy >/dev/null 2>&1 || groupadd --system caddy
  id caddy >/dev/null 2>&1 || useradd --system --gid caddy \
    --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy
}

install_caddy_units() {
  # Never shadow a distribution-provided unit (apt-installed Caddy).
  if [[ -f /lib/systemd/system/caddy.service || -f /usr/lib/systemd/system/caddy.service ]]; then
    systemctl daemon-reload
    return 0
  fi
  install -m 0644 "$SCRIPT_DIR/assets/systemd/caddy.service" /etc/systemd/system/caddy.service
  systemctl daemon-reload
}

ensure_caddyfile_import() {
  local caddyfile="$CADDY_CONF_DIR/Caddyfile" import="import ${CADDY_CONF_DIR}/conf.d/*.caddy"
  install -d -m 0755 "$CADDY_CONF_DIR" "$CADDY_CONF_DIR/conf.d"
  if [[ ! -f "$caddyfile" ]]; then
    printf '# Managed by bot-stack\n%s\n' "$import" > "$caddyfile"
  elif ! grep -qF "$import" "$caddyfile"; then
    cp -a "$caddyfile" "${caddyfile}.bot-stack.bak"
    printf '\n# Added by bot-stack for noVNC\n%s\n' "$import" >> "$caddyfile"
    warn "已在现有 Caddyfile 末尾追加 conf.d import（备份：${caddyfile}.bot-stack.bak）。"
  fi
}

write_caddy_site() {
  local site=$1 user=$2 hash=$3 tls_line=$4
  install -d -m 0755 "$CADDY_CONF_DIR/conf.d"
  cat > "$(caddy_site_file)" <<EOF
# Managed by bot-stack (install-caddy); rerunning install-caddy rewrites this file.
${site} {
${tls_line}    basic_auth /novnc/* {
        ${user} ${hash}
    }
    handle_path /novnc/* {
        reverse_proxy 127.0.0.1:${NOVNC_PORT}
    }
}
EOF
}

install_caddy() {
  local site tls_line='' pw='' hash='' existing_hash='' site_file code shown_pw=''
  [[ -f /etc/systemd/system/snowluma-novnc.service ]] ||
    die "请先执行 install-novnc，再配置 Caddy 反向代理。"
  install_packages ca-certificates curl jq openssl
  install_caddy_binary
  ensure_caddy_user

  prompt_default CADDY_DOMAIN "用于自动 HTTPS 的公网域名（留空/输入 - 表示无域名，用自签名 + 端口）" "$CADDY_DOMAIN"
  if [[ -n "$CADDY_DOMAIN" ]]; then
    site=$CADDY_DOMAIN
  else
    prompt_port CADDY_HTTPS_PORT "自签名 HTTPS 端口" "$CADDY_HTTPS_PORT"
    site=":${CADDY_HTTPS_PORT}"
    tls_line=$'    tls internal\n'
  fi
  prompt_default CADDY_AUTH_USER "网页登录账号" "$CADDY_AUTH_USER"
  read -r -s -p '网页登录密码（留空 = 沿用旧密码，无旧密码则自动生成）: ' pw; echo

  site_file=$(caddy_site_file)
  if [[ -z "$pw" && -f "$site_file" ]]; then
    existing_hash=$(awk -v u="$CADDY_AUTH_USER" '$1 == u && $2 ~ /^\$2/ { print $2; exit }' "$site_file")
  fi
  if [[ -n "$pw" ]]; then
    hash=$(printf '%s' "$pw" | caddy hash-password)
  elif [[ -n "$existing_hash" ]]; then
    hash=$existing_hash
    info "沿用 ${CADDY_AUTH_USER} 已有的登录密码。"
  else
    pw=$(openssl rand -hex 9)
    shown_pw=$pw
    hash=$(printf '%s' "$pw" | caddy hash-password)
  fi
  [[ -n "$hash" ]] || die "生成登录密码哈希失败。"

  write_config
  ensure_caddyfile_import
  write_caddy_site "$site" "$CADDY_AUTH_USER" "$hash" "$tls_line"
  install_caddy_units
  if ! caddy validate --config "$CADDY_CONF_DIR/Caddyfile" >/dev/null 2>&1; then
    caddy validate --config "$CADDY_CONF_DIR/Caddyfile" || true
    die "Caddyfile 校验失败，未启动 Caddy。"
  fi

  systemctl enable caddy.service >/dev/null
  systemctl restart caddy.service
  sleep 2
  if ! systemctl is-active --quiet caddy.service; then
    journalctl -u caddy.service -n 40 --no-pager
    die "Caddy 启动失败。"
  fi

  if [[ -z "$CADDY_DOMAIN" ]]; then
    code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 8 \
      "https://127.0.0.1:${CADDY_HTTPS_PORT}/novnc/vnc.html" || true)
    if [[ "$code" == 401 ]]; then
      info "反代验证通过：未认证访问返回 401。"
    else
      warn "预期未认证访问返回 401，实际得到 ${code:-无响应}。"
    fi
    if [[ -n "$pw" ]]; then
      code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 8 \
        -u "${CADDY_AUTH_USER}:${pw}" "https://127.0.0.1:${CADDY_HTTPS_PORT}/novnc/vnc.html" || true)
      [[ "$code" == 200 ]] || warn "带凭据访问预期 200，实际得到 ${code:-无响应}。"
    fi
    info "访问：https://服务器IP:${CADDY_HTTPS_PORT}/novnc/vnc.html（自签名证书，浏览器首次需确认例外）"
  else
    info "请确认 ${CADDY_DOMAIN} 已解析到本机，且 80/443 对外可达；证书会自动签发。"
    info "访问：https://${CADDY_DOMAIN}/novnc/vnc.html"
  fi
  [[ -z "$shown_pw" ]] || info "登录账号：${CADDY_AUTH_USER}  密码：${shown_pw}（请立即保存，仅显示这一次）"
  info "如有防火墙或云安全组，请放行 ${CADDY_DOMAIN:+80/443}${CADDY_DOMAIN:-${CADDY_HTTPS_PORT}} 端口。"
}
