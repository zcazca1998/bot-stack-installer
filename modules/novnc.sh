#!/usr/bin/env bash

install_novnc_units() {
  local unit
  for unit in nbot-vnc.service nbot-novnc.service; do
    install -m 0644 "$SCRIPT_DIR/assets/systemd/$unit" "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload
}

write_novnc_proxy_example() {
  install -d -m 0755 /usr/local/lib/nbot
  cat > /usr/local/lib/nbot/novnc-proxy.example <<EOF
# noVNC listens on 127.0.0.1:${NOVNC_PORT} only; expose it through a reverse
# proxy with WebSocket upgrade enabled. Always add HTTPS and proxy-level
# authentication: the short VNC password alone is weak protection for a live
# QQ session.

## Nginx (inside an existing server block)
location /novnc/ {
    proxy_pass http://127.0.0.1:${NOVNC_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
# Open: https://your.domain/novnc/vnc.html

## Caddy (Caddyfile)
your.domain {
    basic_auth /novnc/* {
        # Generate the hash with: caddy hash-password
        admin REPLACE_WITH_HASH
    }
    handle_path /novnc/* {
        reverse_proxy 127.0.0.1:${NOVNC_PORT}
    }
}
# Open: https://your.domain/novnc/vnc.html
# Caddy handles WebSocket upgrades and HTTPS certificates automatically.
EOF
}

vnc_password_file() { printf '%s/config/vnc-password\n' "$SNOWLUMA_ROOT"; }

novnc_fronted_by_caddy() {
  [[ -f /etc/systemd/system/caddy.service && -f "$CADDY_CONF_DIR/conf.d/novnc.caddy" ]]
}

show_novnc_access() {
  # 鉴权统一由 Caddy 承担：只有一套账号密码，链接点开就能用。
  local ip url
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-服务器IP}

  bold "noVNC 访问地址"
  if novnc_fronted_by_caddy; then
    if [[ -n "$CADDY_DOMAIN" ]]; then
      url="https://${CADDY_DOMAIN}"
    else
      url="https://${ip}:${CADDY_HTTPS_PORT}"
    fi
    info "${url}/novnc/vnc.html?autoconnect=1&resize=scale"
    info "登录账号：${CADDY_AUTH_USER}（密码用 nbot caddy set-auth 更换）"
    [[ -n "$CADDY_DOMAIN" ]] ||
      info "自签名证书，浏览器首次会提示不安全，确认例外即可。"
  else
    info "http://127.0.0.1:${NOVNC_PORT}/vnc.html（仅监听回环，需自行反代或端口转发）"
    info "VNC 密码：$(head -n1 "$(vnc_password_file)" 2>/dev/null || echo 未设置)"
    info "建议执行 nbot install-caddy，由 Caddy 提供 HTTPS 与登录鉴权。"
  fi
}

write_vnc_password() {
  # x11vnc 的 -passwdfile 只读第一行明文，VNC 协议本身没有账号概念；
  # 账号密码那一层由 Caddy 的 basic_auth 承担。
  local password=$1 file
  file=$(vnc_password_file)
  install -d -m 0755 "$SNOWLUMA_ROOT/config"
  (umask 177; printf '%s\n' "$password" > "$file")
  chown snowluma:snowluma "$file" 2>/dev/null || true
  chmod 0600 "$file"
}

set_vnc_password() {
  local password confirm_password file
  file=$(vnc_password_file)
  [[ -f /etc/systemd/system/nbot-vnc.service ]] ||
    die "尚未安装 noVNC，请先执行 nbot install-novnc。"
  if novnc_fronted_by_caddy; then
    warn "已由 Caddy 承担鉴权，VNC 密码层处于关闭状态，改它不影响访问。"
    warn "要更换网页登录凭据请执行：nbot caddy set-auth"
    nbot_interactive && { confirm "仍要设置 VNC 密码（仅在移除 Caddy 后生效）？" N || return 0; }
  fi
  if nbot_interactive; then
    read -r -s -p '新的 VNC 密码（留空自动生成，VNC 协议上限 8 位有效）: ' password; echo
    if [[ -n "$password" ]]; then
      read -r -s -p '再输入一次确认: ' confirm_password; echo
      [[ "$password" == "$confirm_password" ]] || die "两次输入不一致。"
    fi
  else
    password=${NBOT_VNC_PASSWORD:-}
  fi
  if [[ -z "$password" ]]; then
    password=$(openssl rand -hex 4)
    info "已自动生成新密码。"
  fi
  # VNC 协议只取前 8 个字符，超长会让用户以为密码没生效。
  ((${#password} <= 8)) ||
    warn "VNC 协议只使用前 8 位字符，超出部分会被忽略。"
  write_vnc_password "$password"
  if systemctl is-active --quiet nbot-vnc.service; then
    systemctl restart nbot-vnc.service
    info "VNC 桥接已重启，新密码立即生效。"
  else
    info "VNC 桥接当前未运行，新密码将在下次启动时生效。"
  fi
  info "VNC 密码：${password}"
  info "已保存到 ${file}（nbot novnc password 可再次查看）"
}

install_novnc() {
  local passwd_file
  [[ -e "$SNOWLUMA_ROOT/app" ]] || die "请先安装 SnowLuma：noVNC 映射的是 QQ 的 Xvfb 画面。"
  id snowluma >/dev/null 2>&1 || die "缺少 snowluma 用户，请先执行 install-snowluma。"
  install_packages novnc websockify x11vnc openssl
  require_commands websockify x11vnc openssl

  prompt_port NOVNC_PORT "noVNC 网页端口（仅监听 127.0.0.1，由反向代理对外）" "$NOVNC_PORT"
  prompt_port NOVNC_VNC_PORT "内部 VNC 端口（仅监听 127.0.0.1）" "$NOVNC_VNC_PORT"
  write_config

  # 已有密码保持不变，重装不会让用户手上的密码失效。
  passwd_file=$(vnc_password_file)
  if [[ -s "$passwd_file" ]]; then
    chown snowluma:snowluma "$passwd_file" 2>/dev/null || true
    chmod 0600 "$passwd_file"
  else
    write_vnc_password "$(openssl rand -hex 4)"
  fi

  install_runtime_assets
  install_novnc_units
  write_novnc_proxy_example
  systemctl enable nbot-vnc.service nbot-novnc.service >/dev/null
  systemctl restart nbot-novnc.service
  if systemctl is-active --quiet nbot-qq.service; then
    systemctl restart nbot-vnc.service
  else
    info "nbot-qq.service 未运行；VNC 桥接会随 QQ 服务一起启动。"
  fi
  sleep 2
  if ! systemctl is-active --quiet nbot-novnc.service; then
    journalctl -u nbot-novnc.service -n 40 --no-pager
    die "noVNC web 服务启动失败。"
  fi

  info "noVNC 服务已就绪（仅监听 127.0.0.1:${NOVNC_PORT}）。"
  warn "noVNC 可完全操作 QQ 会话，必须由反向代理提供 HTTPS 与登录鉴权后再暴露。"

  if confirm "现在让安装器接管 Caddy（自动配置 HTTPS + 登录，之后直接点链接访问）？" Y; then
    install_caddy
  else
    info "之后可随时执行：nbot install-caddy"
  fi
  # 装完 Caddy 再输出访问信息，这样能直接给出可点击的完整地址。
  show_novnc_access
  if ! novnc_fronted_by_caddy; then
    info "VNC 密码：nbot novnc password 查看，nbot novnc set-password 更换"
  fi
}
