#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/modules/astrbot.sh"
source "$SCRIPT_DIR/modules/snowluma.sh"
source "$SCRIPT_DIR/modules/novnc.sh"
source "$SCRIPT_DIR/modules/caddy.sh"

install_self() {
  local target=/usr/local/lib/bot-stack/installer
  # Skip the copy when running from the installed location itself; wipe the
  # target first so files removed upstream do not linger across upgrades.
  if [[ "$SCRIPT_DIR" != "$target" ]]; then
    rm -rf "$target"
    mkdir -p "$target"
    cp -a "$SCRIPT_DIR/." "$target/"
  fi
  cat > /usr/local/sbin/bot-stack <<'EOF'
#!/bin/sh
exec /usr/local/lib/bot-stack/installer/install.sh "$@"
EOF
  chmod 0755 /usr/local/sbin/bot-stack "$target/install.sh"
}

configure_base() {
  bold "基础配置（回车保留默认值，输入 - 可清空该项）"
  prompt_default ASTRBOT_ROOT "AstrBot 数据目录" "$ASTRBOT_ROOT"
  prompt_default SNOWLUMA_ROOT "SnowLuma 数据目录" "$SNOWLUMA_ROOT"
  prompt_default SNOWLUMA_PAYLOAD_ROOT "SnowLuma/QQ 程序载荷目录" "$SNOWLUMA_PAYLOAD_ROOT"
  prompt_port ASTRBOT_PORT "AstrBot WebUI 端口" "$ASTRBOT_PORT"
  prompt_port ASTRBOT_WS_PORT "AstrBot OneBot WS 端口" "$ASTRBOT_WS_PORT"
  prompt_port SNOWLUMA_WEBUI_PORT "SnowLuma WebUI 端口" "$SNOWLUMA_WEBUI_PORT"
  prompt_port ONEBOT_HTTP_PORT "SnowLuma OneBot HTTP 端口" "$ONEBOT_HTTP_PORT"

  while :; do
    prompt_default GITHUB_ACCESS "GitHub 访问方式：auto=代理失败转直连 / proxy=仅代理 / direct=仅直连" "$GITHUB_ACCESS"
    case "$GITHUB_ACCESS" in
      auto|proxy)
        prompt_default GITHUB_PROXY "GitHub 代理地址" \
          "${GITHUB_PROXY:-socks5h://127.0.0.1:20170}"
        if [[ "$GITHUB_ACCESS" == proxy && -z "$GITHUB_PROXY" ]]; then
          warn "proxy 模式必须填写代理地址。"
          continue
        fi
        break
        ;;
      direct) GITHUB_PROXY=; break ;;
      *) warn "只能填 auto、proxy 或 direct。" ;;
    esac
  done

  prompt_default SNOWLUMA_IMAGE "SnowLuma 镜像" "$SNOWLUMA_IMAGE"
  prompt_default SNOWLUMA_IMAGE_MIRROR "容器镜像加速前缀（输入 - 清空表示仅直连）" "$SNOWLUMA_IMAGE_MIRROR"
  prompt_default SNOWLUMA_IMAGE_FALLBACK_MIRROR "备用镜像加速前缀（输入 - 清空）" "$SNOWLUMA_IMAGE_FALLBACK_MIRROR"
  prompt_default SNOWLUMA_IMAGE_PROXY "镜像下载代理（可选，输入 - 清空）" "${SNOWLUMA_IMAGE_PROXY:-$GITHUB_PROXY}"

  write_config
  info "配置已写入 $CONFIG_FILE"
}

status_all() {
  bold "Service status"
  local unit
  for unit in astrbot.service astrbot-watchdog.timer snowluma-qq.service \
    snowluma.service snowluma-watchdog.timer snowluma-vnc.service \
    snowluma-novnc.service caddy.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
      printf '%-28s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
  done
  [[ -x /usr/local/lib/bot-stack/qq-status ]] &&
    /usr/local/lib/bot-stack/qq-status || true
}

doctor() {
  local failed=0 path
  bold "Environment diagnostics"
  printf 'OS:   '; (source /etc/os-release; echo "${PRETTY_NAME:-unknown}")
  printf 'ARCH: '; uname -m
  printf 'ROOT: '; findmnt -no SOURCE,FSTYPE,AVAIL / 2>/dev/null || true
  for path in "$ASTRBOT_ROOT" "$SNOWLUMA_ROOT" "$SNOWLUMA_PAYLOAD_ROOT"; do
    [[ -e "$path" ]] || continue
    printf '%s: ' "$path"
    findmnt -no SOURCE,FSTYPE,AVAIL --target "$path" 2>/dev/null ||
      df -h "$path" | tail -1
  done
  status_all
  if systemctl is-active --quiet astrbot.service &&
     ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${ASTRBOT_PORT}/"; then
    warn "AstrBot is active but WebUI ${ASTRBOT_PORT} is not responding."
    failed=1
  fi
  if systemctl is-active --quiet snowluma.service &&
     ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${SNOWLUMA_WEBUI_PORT}/"; then
    warn "SnowLuma is active but WebUI ${SNOWLUMA_WEBUI_PORT} is not responding."
    failed=1
  fi
  if systemctl is-active --quiet snowluma-novnc.service &&
     ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${NOVNC_PORT}/vnc.html"; then
    warn "noVNC is active but ${NOVNC_PORT} is not responding."
    failed=1
  fi
  return "$failed"
}

show_logs() {
  case "${1:-}" in
    astrbot) journalctl -u astrbot.service --no-pager ;;
    snowluma) journalctl -u snowluma.service -u snowluma-qq.service --no-pager ;;
    watchdog) journalctl -t astrbot-watchdog -t snowluma-watchdog --no-pager ;;
    *) die "Usage: bot-stack logs {astrbot|snowluma|watchdog}" ;;
  esac
}

menu() {
  local choice
  while :; do
    cat <<'EOF'

Bot Stack 安装管理
  1) 基础配置（目录 / 端口 / 下载代理）
  2) 安装/更新 AstrBot
  3) 从官方镜像安装/更新 SnowLuma + QQ
  4) 配置 OneBot 对接 AstrBot
  5) 安装/修复 systemd 服务与看门狗
  6) 显示 QQ 登录二维码（被踢下线也走这里）
  7) 服务状态
  8) 环境诊断
  9) 安装/更新 noVNC 远程画面（供反向代理使用）
 10) 安装/配置 Caddy 反向代理（HTTPS + 登录）
  0) 退出
EOF
    read -r -p '请选择: ' choice
    case "$choice" in
      1) configure_base ;;
      2) install_astrbot ;;
      3) install_snowluma ;;
      4) configure_onebot ;;
      5) install_runtime_assets; install_astrbot_units; install_snowluma_units ;;
      6) /usr/local/bin/qqlogin || true ;;
      7) status_all ;;
      8) doctor || true ;;
      9) install_novnc ;;
      10) install_caddy ;;
      0) return ;;
      *) warn "无效选项，请输入 0-10。" ;;
    esac
  done
}

main() {
  require_root
  detect_os
  detect_arch
  install_self
  case "${1:-menu}" in
    menu) menu ;;
    configure) configure_base ;;
    install-all)
      configure_base
      install_astrbot
      install_snowluma
      install_runtime_assets
      install_astrbot_units
      install_snowluma_units
      ;;
    install-astrbot|update-astrbot) install_astrbot ;;
    install-snowluma|update-snowluma|install-qq|update-qq) install_snowluma ;;
    install-novnc|update-novnc) install_novnc ;;
    install-caddy|configure-caddy|update-caddy) install_caddy ;;
    configure-onebot) configure_onebot ;;
    repair)
      install_runtime_assets
      install_astrbot_units
      install_snowluma_units
      [[ ! -f /etc/systemd/system/snowluma-novnc.service ]] || install_novnc_units
      [[ ! -f /etc/systemd/system/caddy.service ]] || install_caddy_units
      ;;
    status) status_all ;;
    doctor) doctor ;;
    logs) show_logs "${2:-}" ;;
    *) die "未知命令：$1（可用：menu configure install-all install-astrbot install-snowluma install-novnc install-caddy configure-onebot repair status doctor logs）" ;;
  esac
}

main "$@"
