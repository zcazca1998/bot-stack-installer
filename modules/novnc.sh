#!/usr/bin/env bash

install_novnc_units() {
  local unit
  for unit in snowluma-vnc.service snowluma-novnc.service; do
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

install_novnc() {
  local passwd_file
  [[ -e "$SNOWLUMA_ROOT/app" ]] || die "请先安装 SnowLuma：noVNC 映射的是 QQ 的 Xvfb 画面。"
  id snowluma >/dev/null 2>&1 || die "缺少 snowluma 用户，请先执行 install-snowluma。"
  install_packages novnc websockify x11vnc openssl
  require_commands websockify x11vnc openssl

  prompt_port NOVNC_PORT "noVNC 网页端口（仅监听 127.0.0.1，由反向代理对外）" "$NOVNC_PORT"
  prompt_port NOVNC_VNC_PORT "内部 VNC 端口（仅监听 127.0.0.1）" "$NOVNC_VNC_PORT"
  write_config

  passwd_file="$SNOWLUMA_ROOT/config/vnc-password"
  mkdir -p "$SNOWLUMA_ROOT/config"
  if [[ ! -s "$passwd_file" ]]; then
    (umask 177; openssl rand -hex 4 > "$passwd_file")
  fi
  chown snowluma:snowluma "$passwd_file"
  chmod 0600 "$passwd_file"

  install_runtime_assets
  install_novnc_units
  write_novnc_proxy_example
  systemctl enable snowluma-vnc.service snowluma-novnc.service >/dev/null
  systemctl restart snowluma-novnc.service
  if systemctl is-active --quiet snowluma-qq.service; then
    systemctl restart snowluma-vnc.service
  else
    info "snowluma-qq.service 未运行；VNC 桥接会随 QQ 服务一起启动。"
  fi
  sleep 2
  if ! systemctl is-active --quiet snowluma-novnc.service; then
    journalctl -u snowluma-novnc.service -n 40 --no-pager
    die "noVNC web 服务启动失败。"
  fi

  info "noVNC 已就绪：http://127.0.0.1:${NOVNC_PORT}/vnc.html（仅监听本机）"
  info "VNC 密码：$(<"$passwd_file")（novncctl password 可再次查看）"
  info "反向代理示例：/usr/local/lib/nbot/novnc-proxy.example（novncctl proxy-example 查看）"
  warn "noVNC 可完全操作 QQ 会话，务必在反向代理上叠加 HTTPS 与鉴权后再暴露。"

  if confirm "现在让安装器接管 Caddy（自动安装并生成 HTTPS + 登录配置）吗？" Y; then
    install_caddy
  else
    info "之后可随时执行：nbot install-caddy"
  fi
}
