#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/modules/astrbot.sh"
source "$SCRIPT_DIR/modules/snowluma.sh"
source "$SCRIPT_DIR/modules/novnc.sh"
source "$SCRIPT_DIR/modules/caddy.sh"

install_self() {
  local target=/usr/local/lib/nbot/installer
  # Skip the copy when running from the installed location itself; wipe the
  # target first so files removed upstream do not linger across upgrades.
  if [[ "$SCRIPT_DIR" != "$target" ]]; then
    rm -rf "$target"
    mkdir -p "$target"
    # 排除 .git：安装目标只需要运行时文件，仓库历史既占空间，
    # 又会在源目录同时被 git 操作时导致复制报错。
    tar -C "$SCRIPT_DIR" --exclude=./.git -cf - . | tar -C "$target" -xf -
  fi
  cat > /usr/local/sbin/nbot <<'EOF'
#!/bin/sh
exec /usr/local/lib/nbot/installer/install.sh "$@"
EOF
  chmod 0755 /usr/local/sbin/nbot "$target/install.sh"
  # 清理 1.7 之前的 bot-stack 命令与运行时目录。
  rm -f /usr/local/sbin/bot-stack
  [[ ! -d /usr/local/lib/bot-stack ]] || rm -rf /usr/local/lib/bot-stack
}

configure_base() {
  local previous_home=$NBOT_HOME
  detect_network_region
  bold "基础配置（回车保留默认值，输入 - 可清空该项）"
  prompt_default NBOT_HOME "统一工作区目录（各组件按名字放子目录）" "$NBOT_HOME"
  if [[ "$NBOT_HOME" != "$previous_home" ]]; then
    ASTRBOT_ROOT="${NBOT_HOME}/astrbot"
    SNOWLUMA_ROOT="${NBOT_HOME}/snowluma"
    SNOWLUMA_PAYLOAD_ROOT="${NBOT_HOME}/payload/snowluma"
  fi
  prompt_default ASTRBOT_ROOT "AstrBot 数据目录" "$ASTRBOT_ROOT"
  prompt_default SNOWLUMA_ROOT "SnowLuma 数据目录" "$SNOWLUMA_ROOT"
  prompt_default SNOWLUMA_PAYLOAD_ROOT "SnowLuma/QQ 程序载荷目录" "$SNOWLUMA_PAYLOAD_ROOT"
  prompt_port ASTRBOT_PORT "AstrBot WebUI 端口" "$ASTRBOT_PORT"
  prompt_port ASTRBOT_WS_PORT "AstrBot OneBot WS 端口" "$ASTRBOT_WS_PORT"
  prompt_port SNOWLUMA_WEBUI_PORT "SnowLuma WebUI 端口" "$SNOWLUMA_WEBUI_PORT"
  prompt_port ONEBOT_HTTP_PORT "SnowLuma OneBot HTTP 端口" "$ONEBOT_HTTP_PORT"

  bold "网络与加速（国内机器建议保持镜像默认值）"
  while :; do
    prompt_default GITHUB_ACCESS "GitHub 访问方式：auto=代理->加速站->直连 / proxy=仅代理 / direct=不用代理" "$GITHUB_ACCESS"
    case "$GITHUB_ACCESS" in
      auto|proxy)
        prompt_default GITHUB_PROXY "GitHub 代理地址（无代理请输入 - 清空）"           "${GITHUB_PROXY:-socks5h://127.0.0.1:20170}"
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

  pick_option GITHUB_MIRRORS "GitHub 下载加速" "$GITHUB_MIRRORS" GITHUB_MIRROR_CHOICES
  pick_option PIP_INDEX_URL "PyPI 镜像（AstrBot 依赖数百 MB，国内直连基本装不动）"     "$PIP_INDEX_URL" PIP_MIRROR_CHOICES
  if [[ -n "$PIP_INDEX_URL" ]]; then
    PIP_TRUSTED_HOST=$(host_of_url "$PIP_INDEX_URL")
  else
    PIP_TRUSTED_HOST=
  fi
  pick_option SNOWLUMA_IMAGE_MIRROR "容器镜像加速（首选）"     "$SNOWLUMA_IMAGE_MIRROR" IMAGE_MIRROR_CHOICES
  pick_option SNOWLUMA_IMAGE_FALLBACK_MIRROR "容器镜像加速（备用）"     "$SNOWLUMA_IMAGE_FALLBACK_MIRROR" IMAGE_MIRROR_CHOICES
  prompt_default SNOWLUMA_IMAGE "SnowLuma 镜像" "$SNOWLUMA_IMAGE"
  prompt_default SNOWLUMA_IMAGE_PROXY "镜像下载代理（可选，输入 - 清空）" "${SNOWLUMA_IMAGE_PROXY:-$GITHUB_PROXY}"
  prompt_default JOURNALD_MAX_USE "journald 系统日志总量上限（如 500M；输入 - 表示不修改系统默认）" "${JOURNALD_MAX_USE:-500M}"

  write_config
  info "配置已写入 $CONFIG_FILE"
}

status_all() {
  bold "服务状态"
  local unit state failed_units=0
  for unit in nbot-astrbot.service nbot-astrbot-watchdog.timer nbot-qq.service \
    nbot-snowluma.service nbot-snowluma-watchdog.timer nbot-vnc.service \
    nbot-novnc.service caddy.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
      state=$(systemctl is-active "$unit" 2>/dev/null || true)
      if [[ "$state" == failed ]]; then
        printf '%-28s %s（systemd 已停止重试）\n' "$unit" "$state"
        failed_units=1
      else
        printf '%-28s %s\n' "$unit" "$state"
      fi
    fi
  done
  [[ -x /usr/local/lib/nbot/qq-status ]] &&
    /usr/local/lib/nbot/qq-status || true
  ((failed_units == 0)) ||
    warn "有服务处于 failed：短时间内反复启动失败，systemd 已停止重试，看门狗也不会介入。请先查日志排因。"
}

doctor() {
  local failed=0 path free_kb missing=() name
  bold "环境诊断"
  printf 'OS:      '; (source /etc/os-release; echo "${PRETTY_NAME:-unknown}")
  printf 'ARCH:    %s（部署目标 %s，SnowLuma %s）\n' "$(uname -m)" "$SYSTEM_ARCH" "$SNOWLUMA_ARCH"
  printf 'PKGARCH: %s\n' "$(dpkg --print-architecture 2>/dev/null || echo 未知)"
  printf 'SYSTEMD: %s\n' "$(systemctl --version 2>/dev/null | head -1 || echo 不可用)"
  printf 'KERNEL:  %s\n' "$(uname -r)"
  printf 'MEM:     %s\n' "$(free -h 2>/dev/null | awk 'NR==2 {print $2" total, "$7" available"}' || echo 未知)"

  # 关键命令：缺失说明依赖没装全或 PATH 有问题。
  for name in curl jq skopeo umoci setcap Xvfb xauth mcookie dbus-daemon \
              ffmpeg xdotool zbarimg qrencode convert openssl; do
    command -v "$name" >/dev/null 2>&1 || missing+=("$name")
  done
  if ((${#missing[@]})); then
    warn "缺少命令（SnowLuma/QQ 相关功能会受影响）：${missing[*]}"
    warn "执行 nbot install-snowluma 或 nbot repair 可补齐。"
  else
    printf 'DEPS:    全部关键命令就绪\n'
  fi

  printf 'ROOT:    '; findmnt -no SOURCE,FSTYPE,AVAIL / 2>/dev/null || true
  # 载荷目录空间：拆镜像需要 6 GiB，不足会在安装中途失败。
  if [[ -d "$SNOWLUMA_PAYLOAD_ROOT" ]]; then
    free_kb=$(df -Pk "$SNOWLUMA_PAYLOAD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && ((free_kb < 6291456)); then
      warn "载荷目录可用空间不足 6 GiB（当前 $((free_kb / 1024)) MiB），拆镜像会失败。"
      failed=1
    fi
  fi
  for path in "$ASTRBOT_ROOT" "$SNOWLUMA_ROOT" "$SNOWLUMA_PAYLOAD_ROOT"; do
    [[ -e "$path" ]] || continue
    printf '%s: ' "$path"
    findmnt -no SOURCE,FSTYPE,AVAIL --target "$path" 2>/dev/null ||
      df -h "$path" | tail -1
  done
  status_all
  if systemctl is-active --quiet nbot-astrbot.service &&
     ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${ASTRBOT_PORT}/"; then
    warn "AstrBot 在运行但 WebUI ${ASTRBOT_PORT} 无响应。"
    failed=1
  fi
  if systemctl is-active --quiet nbot-snowluma.service &&
     ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${SNOWLUMA_WEBUI_PORT}/"; then
    warn "SnowLuma 在运行但 WebUI ${SNOWLUMA_WEBUI_PORT} 无响应。"
    failed=1
  fi
  if systemctl is-active --quiet nbot-novnc.service &&
     ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${NOVNC_PORT}/vnc.html"; then
    warn "noVNC 在运行但 ${NOVNC_PORT} 无响应。"
    failed=1
  fi

  # 忘记密码是最常见的求助场景，把出路直接写在诊断输出里。
  bold "忘记密码怎么办"
  info "AstrBot WebUI:  nbot astrbot set-password"
  info "SnowLuma WebUI: nbot snowluma set-password"
  [[ ! -f /etc/systemd/system/caddy.service ]] ||
    info "网页登录（Caddy）: nbot caddy set-auth"
  if [[ -f /etc/systemd/system/nbot-vnc.service ]] && ! novnc_fronted_by_caddy; then
    info "VNC 密码:       nbot novnc set-password"
  fi
  info "OneBot token:   nbot configure-onebot（重新生成并显示）"
  return "$failed"
}

print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-服务器IP}
  bold "安装完成"
  show_astrbot_webui
  show_snowluma_webui
  info "下一步："
  info "  1) nbot login                  # 扫码登录 QQ"
  info "  2) nbot configure-onebot       # 生成 OneBot 配置并显示 token"
  info "  3) 在 AstrBot WebUI 添加 OneBot v11 适配器（端口 ${ASTRBOT_WS_PORT} + 上一步的 token）"
  info "常用命令：nbot status / doctor / help；nbot snowluma logs -f；nbot login --fresh"
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
  if [[ -t 1 ]] && confirm "现在就扫码登录 QQ？" Y; then
    /usr/local/lib/nbot/qqlogin || true
    if confirm "继续配置 OneBot 对接 AstrBot？" Y; then
      configure_onebot || true
    fi
  fi
  print_summary
}

uninstall_stack() {
  local unit path answer
  bold "卸载 nbot"
  confirm "停止并移除所有 nbot 服务与程序？（数据目录默认保留）" N || return 0
  for unit in nbot-astrbot-watchdog.timer nbot-snowluma-watchdog.timer nbot-logclean.timer \
    nbot-novnc.service nbot-vnc.service nbot-snowluma.service nbot-qq.service \
    nbot-astrbot.service nbot-astrbot-watchdog.service nbot-snowluma-watchdog.service \
    nbot-logclean.service; do
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
  rm -rf /usr/local/lib/nbot
  rm -f /usr/local/bin/snowlumactl /usr/local/bin/qqlogin /usr/local/bin/qqrefresh \
    /usr/local/bin/astrbotctl /usr/local/bin/novncctl \
    /usr/local/sbin/nbot /usr/local/sbin/bot-stack
  rm -f /etc/logrotate.d/nbot
  if [[ -f /etc/systemd/journald.conf.d/nbot.conf ]]; then
    rm -f /etc/systemd/journald.conf.d/nbot.conf
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

service_command() {
  # 把原来的 astrbotctl / snowlumactl / novncctl 收进 nbot 子命令。
  local group=$1 action=${2:-status} units=() logunits=()
  shift 2 || true
  case "$group" in
    astrbot) units=(nbot-astrbot.service); logunits=(-u nbot-astrbot.service) ;;
    snowluma)
      units=(nbot-snowluma.service)
      logunits=(-u nbot-snowluma.service -u nbot-qq.service) ;;
    qq) units=(nbot-qq.service); logunits=(-u nbot-qq.service) ;;
    novnc)
      units=(nbot-vnc.service nbot-novnc.service)
      logunits=(-u nbot-vnc.service -u nbot-novnc.service) ;;
    *) die "未知组件：$group（可用：astrbot snowluma qq novnc）" ;;
  esac

  # 反复失败触顶 StartLimitBurst 后，systemd 会拒绝一切启动请求（包括手动的），
  # 报 "start request repeated too quickly"。用户不该被这个细节卡住：显式启动
  # 之前先清掉失败状态，让「我知道问题修好了，现在启动」总能生效。
  case "$action" in
    start|restart)
      systemctl reset-failed "${units[@]}" 2>/dev/null || true
      ;;
  esac

  case "$action" in
    start)
      # QQ 必须先起来，SnowLuma 才能进入被动观察。
      if [[ "$group" == snowluma ]]; then
        systemctl start nbot-qq.service
        systemctl --no-block start nbot-snowluma.service
      else
        systemctl start "${units[@]}"
      fi
      ;;
    stop) systemctl stop "${units[@]}" ;;
    restart)
      if [[ "$group" == qq ]]; then
        systemctl stop nbot-snowluma.service
        systemctl restart nbot-qq.service
        systemctl --no-block start nbot-snowluma.service
      else
        systemctl restart "${units[@]}"
      fi
      ;;
    status)
      if [[ "$group" == qq ]]; then
        exec /usr/local/lib/nbot/qq-status "$@"
      fi
      systemctl status "${units[@]}" --no-pager -l
      ;;
    logs)
      case "${1:-all}" in
        all) journalctl "${logunits[@]}" --no-pager ;;
        -f|follow) journalctl "${logunits[@]}" -f ;;
        -n) journalctl "${logunits[@]}" -n "${2:-300}" --no-pager ;;
        *) die "用法: nbot $group logs [all|-f|-n 行数]" ;;
      esac
      ;;
    update)
      case "$group" in
        astrbot) install_astrbot ;;
        snowluma|qq) install_snowluma ;;
        novnc) install_novnc ;;
      esac
      ;;
    password)
      [[ "$group" == novnc ]] || die "仅 novnc 支持 password"
      cat "$(vnc_password_file)" ;;
    set-password)
      case "$group" in
        astrbot) set_astrbot_password ;;
        snowluma) set_snowluma_password ;;
        novnc) set_vnc_password ;;
        *) die "$group 不支持密码重置" ;;
      esac ;;
    rollback)
      case "$group" in
        astrbot) rollback_astrbot ;;
        snowluma|qq) rollback_snowluma ;;
        *) die "$group 不支持回滚" ;;
      esac ;;
    version)
      case "$group" in
        astrbot) show_astrbot_version ;;
        snowluma|qq) show_snowluma_version ;;
        *) die "$group 不支持 version" ;;
      esac ;;
    webui)
      case "$group" in
        snowluma) show_snowluma_webui ;;
        novnc) show_novnc_access ;;
        astrbot) show_astrbot_webui ;;
        *) die "$group 没有 WebUI" ;;
      esac ;;
    url)
      [[ "$group" == novnc ]] || die "仅 novnc 支持 url"
      printf '本机:     http://127.0.0.1:%s/vnc.html\n' "$NOVNC_PORT"
      printf '反向代理: https://你的域名/novnc/vnc.html（nbot novnc proxy-example 查看配置）\n'
      ;;
    proxy-example)
      [[ "$group" == novnc ]] || die "仅 novnc 支持 proxy-example"
      cat /usr/local/lib/nbot/novnc-proxy.example ;;
    *)
      if [[ "$group" == novnc ]]; then
        die "用法: nbot novnc {start|stop|restart|status|logs|update|url|password|set-password|proxy-example}"
      fi
      die "用法: nbot $group {start|stop|restart|status|logs|update|version|rollback}" ;;
  esac
}

show_help() {
  cat <<'EOF'
nbot — AstrBot + SnowLuma + QQ 一键部署器
用法：nbot <命令>        无参数进入交互菜单

安装与配置
  install-all           一键安装全部（推荐）
  install-astrbot       安装 / 更新 AstrBot
  install-snowluma      安装 / 更新 SnowLuma + QQ（拆官方镜像，不装 Docker）
  install-novnc         安装 noVNC 远程画面
  install-caddy         安装 / 配置 Caddy 反向代理（HTTPS + 登录）
  configure             基础配置（目录 / 端口 / 代理 / 镜像 / 日志上限）
  configure-onebot      配置 OneBot 对接 AstrBot，并显示 token
  repair                重装服务、看门狗、控制脚本与日志轮转
  uninstall             卸载（默认保留数据，删数据需输入 DELETE）

QQ 登录
  login                 终端扫码登录
  login --fresh         被踢下线 / 登录过期后强制重新扫码
  refresh               手动点击刷新二维码
  qq status             查询 QQ 在线状态

组件控制    nbot <组件> start|stop|restart|status|logs|update
  组件：astrbot | snowluma | qq | novnc
  例：nbot astrbot restart          重启 AstrBot
      nbot snowluma logs -f         实时跟踪 SnowLuma + QQ 日志
      nbot astrbot logs -n 200      查看最近 200 行
      nbot qq restart               重启 QQ（先停 SnowLuma 避免 Hook 悬空）
      nbot snowluma update          重新拆镜像更新 SnowLuma + QQ
  WebUI 地址：nbot astrbot webui | snowluma webui | novnc url
  重置密码：  nbot astrbot set-password | snowluma set-password | caddy set-auth
  版本回滚：  nbot astrbot version | rollback     nbot snowluma version | rollback
              上游发了坏版本时直接 rollback 退回上一版，不必知道版本号
  noVNC 专属：nbot novnc url | password | set-password | proxy-example
  Caddy：     nbot caddy set-auth | status | restart | logs

状态与诊断
  status                全部服务状态总览
  doctor                环境诊断（挂载、端口、WebUI 探活）
  logs astrbot          AstrBot 完整日志
  logs snowluma         SnowLuma + QQ 完整日志
  logs watchdog         看门狗动作记录（何时重启了什么、为什么）

网络与自动化
  首次配置会实测能否直连 GitHub / PyPI：海外默认直连，国内默认走镜像。
  GitHub：代理 -> 加速站 -> 直连     镜像：首选 -> 备用 -> Docker Hub
  pip：镜像 -> 官方 PyPI（默认清华 TUNA，可选阿里云 / 腾讯云 / USTC / 华为云）
  每项都可在菜单里选或自定义填写；无终端时全部取默认值，可用环境变量或
  直接写 /etc/nbot.conf 实现无人值守安装。

日志占用（自动启用）
  应用日志 logrotate 按 20M / 7 天轮转；QQ 日志与崩溃转储每日清理（留 7 天）；
  journald 总量上限在基础配置中设置。
EOF
}

show_logs() {
  case "${1:-}" in
    astrbot) journalctl -u nbot-astrbot.service --no-pager ;;
    snowluma) journalctl -u nbot-snowluma.service -u nbot-qq.service --no-pager ;;
    watchdog) journalctl -t nbot-astrbot-watchdog -t nbot-snowluma-watchdog --no-pager ;;
    *) die "Usage: nbot logs {astrbot|snowluma|watchdog}" ;;
  esac
}

menu() {
  local choice
  while :; do
    cat <<'EOF'

nbot 安装管理
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
      6) /usr/local/lib/nbot/qqlogin || true ;;
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
    caddy)
      case "${2:-}" in
        set-auth|set-password) set_caddy_auth ;;
        status) systemctl status caddy.service --no-pager -l ;;
        restart) systemctl restart caddy.service ;;
        logs) journalctl -u caddy.service --no-pager ;;
        *) die "用法: nbot caddy {set-auth|status|restart|logs}" ;;
      esac
      ;;
    configure-onebot) configure_onebot ;;
    repair)
      # 修复的目的就是让服务能起来，所以先清掉之前的失败计数。
      systemctl reset-failed nbot-astrbot.service nbot-snowluma.service         nbot-qq.service nbot-vnc.service nbot-novnc.service 2>/dev/null || true
      install_runtime_assets
      install_astrbot_units
      install_snowluma_units
      [[ ! -f /etc/systemd/system/nbot-novnc.service ]] || install_novnc_units
      [[ ! -f /etc/systemd/system/caddy.service ]] || install_caddy_units
      ;;
    status) status_all ;;
    doctor) doctor ;;
    logs) show_logs "${2:-}" ;;
    astrbot) service_command astrbot "${@:2}" ;;
    snowluma) service_command snowluma "${@:2}" ;;
    novnc) service_command novnc "${@:2}" ;;
    qq) service_command qq "${@:2}" ;;
    login|qqlogin) exec /usr/local/lib/nbot/qqlogin "${@:2}" ;;
    refresh) exec /usr/local/lib/nbot/qqrefresh "${@:2}" ;;
    help|-h|--help) show_help ;;
    *) warn "未知命令：$1"; show_help; exit 1 ;;
  esac
}

main "$@"
