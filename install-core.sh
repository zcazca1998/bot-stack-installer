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
  local previous_home=$BOT_STACK_HOME
  bold "基础配置（回车保留默认值，输入 - 可清空该项）"
  prompt_default BOT_STACK_HOME "统一工作区目录（各组件按名字放子目录）" "$BOT_STACK_HOME"
  if [[ "$BOT_STACK_HOME" != "$previous_home" ]]; then
    ASTRBOT_ROOT="${BOT_STACK_HOME}/astrbot"
    SNOWLUMA_ROOT="${BOT_STACK_HOME}/snowluma"
    SNOWLUMA_PAYLOAD_ROOT="${BOT_STACK_HOME}/payload/snowluma"
  fi
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
  prompt_default JOURNALD_MAX_USE "journald 系统日志总量上限（如 500M；输入 - 表示不修改系统默认）" "${JOURNALD_MAX_USE:-500M}"

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

print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-服务器IP}
  bold "安装完成"
  info "AstrBot WebUI:  http://${ip}:${ASTRBOT_PORT}（默认账号/密码 astrbot/astrbot，请尽快修改）"
  info "SnowLuma WebUI: http://${ip}:${SNOWLUMA_WEBUI_PORT}"
  info "下一步："
  info "  1) qqlogin                     # 扫码登录 QQ"
  info "  2) bot-stack configure-onebot  # 生成 OneBot 配置并显示 token"
  info "  3) 在 AstrBot WebUI 添加 OneBot v11 适配器（端口 ${ASTRBOT_WS_PORT} + 上一步的 token）"
  info "常用命令：bot-stack status / doctor / logs；snowlumactl；astrbotctl；qqlogin --fresh"
}

install_all() {
  configure_base
  install_astrbot
  install_snowluma
  install_runtime_assets
  install_astrbot_units
  install_snowluma_units
  if confirm "同时安装 noVNC 远程画面（浏览器查看 QQ 画面，可接 Caddy 反代）？" N; then
    install_novnc
  fi
  print_summary
}

uninstall_stack() {
  local unit path answer
  bold "卸载 Bot Stack"
  confirm "停止并移除所有 bot-stack 服务与程序？（数据目录默认保留）" N || return 0
  for unit in astrbot-watchdog.timer snowluma-watchdog.timer bot-stack-logclean.timer \
    snowluma-novnc.service snowluma-vnc.service snowluma.service snowluma-qq.service \
    astrbot.service astrbot-watchdog.service snowluma-watchdog.service \
    bot-stack-logclean.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    rm -f "/etc/systemd/system/$unit"
  done
  if [[ -f /etc/systemd/system/caddy.service ]] &&
     confirm "同时移除由安装器安装的 Caddy？" N; then
    systemctl stop caddy.service 2>/dev/null || true
    systemctl disable caddy.service 2>/dev/null || true
    rm -f /etc/systemd/system/caddy.service /usr/local/bin/caddy
    rm -f "$CADDY_CONF_DIR/conf.d/novnc.caddy"
  fi
  systemctl daemon-reload
  rm -rf /usr/local/lib/bot-stack
  rm -f /usr/local/bin/snowlumactl /usr/local/bin/qqlogin /usr/local/bin/qqrefresh \
    /usr/local/bin/astrbotctl /usr/local/bin/novncctl /usr/local/sbin/bot-stack
  rm -f /etc/logrotate.d/bot-stack
  if [[ -f /etc/systemd/journald.conf.d/bot-stack.conf ]]; then
    rm -f /etc/systemd/journald.conf.d/bot-stack.conf
    systemctl restart systemd-journald 2>/dev/null || true
  fi
  info "服务与程序已移除。数据仍保留在："
  info "  ${ASTRBOT_ROOT} / ${SNOWLUMA_ROOT} / ${SNOWLUMA_PAYLOAD_ROOT}"
  if confirm "危险：连同数据一起删除（QQ 登录态、配置、聊天数据，不可恢复）？" N; then
    read -r -p '确认删除请输入 DELETE： ' answer
    if [[ "$answer" == DELETE ]]; then
      for path in "$SNOWLUMA_PAYLOAD_ROOT" "$SNOWLUMA_ROOT" "$ASTRBOT_ROOT"; do
        [[ -n "$path" && "$path" != / ]] && rm -rf "$path"
      done
      rm -f "$CONFIG_FILE"
      id snowluma >/dev/null 2>&1 && userdel snowluma 2>/dev/null || true
      info "数据已删除。"
    else
      warn "未输入 DELETE，数据保留。"
    fi
  fi
  info "卸载完成。"
}

show_help() {
  cat <<'EOF'
Bot Stack 安装管理器
用法：bot-stack <命令>        （无参数进入交互菜单）

安装与配置
  install-all        一键安装全部（推荐：配置 -> AstrBot -> SnowLuma+QQ -> 可选 noVNC/Caddy）
  install-astrbot    安装/更新 AstrBot
  install-snowluma   安装/更新 SnowLuma + QQ（拆官方镜像，不装 Docker）
  install-novnc      安装 noVNC 远程画面（浏览器看 QQ 桌面）
  install-caddy      安装/配置 Caddy 反向代理（HTTPS + 登录）
  configure          基础配置（工作区/端口/代理/日志上限）
  configure-onebot   配置 OneBot 对接 AstrBot（会显示 token）
  repair             重装服务、看门狗、控制脚本与日志轮转
  uninstall          卸载（默认保留数据；删数据需输入 DELETE）

状态与日志
  status             全部服务状态总览
  doctor             环境诊断（挂载、端口、WebUI 探活）
  logs astrbot       AstrBot 完整日志
  logs snowluma      SnowLuma + QQ 日志
  logs watchdog      看门狗动作记录
  跟踪模式：astrbotctl logs -f / snowlumactl logs -f / novncctl logs -f
  最近 N 行：astrbotctl logs -n 200（snowlumactl/novncctl 同理）

QQ 登录
  qqlogin            终端扫码登录
  qqlogin --fresh    被踢下线/登录过期后强制重新扫码
  qqrefresh          手动点击刷新二维码
  snowlumactl qq-status   查询 QQ 在线状态

日志占用限制（自动启用）
  应用日志由 logrotate 按 20M/7 天轮转；QQ 日志与崩溃转储每日清理（保留 7 天）；
  journald 总量上限在基础配置中设置（默认建议 500M）。
EOF
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
  0) 一键安装全部（AstrBot + SnowLuma + QQ，可选 noVNC/Caddy）
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
 11) 卸载
  q) 退出
EOF
    read -r -p '请选择: ' choice
    case "$choice" in
      0) install_all ;;
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
      11) uninstall_stack ;;
      q|Q|exit|quit) return ;;
      *) warn "无效选项，请输入 0-11 或 q 退出。" ;;
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
    install-all) install_all ;;
    uninstall) uninstall_stack ;;
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
    help|-h|--help) show_help ;;
    *) warn "未知命令：$1"; show_help; exit 1 ;;
  esac
}

main "$@"
