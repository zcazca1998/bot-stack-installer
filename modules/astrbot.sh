#!/usr/bin/env bash

install_managed_python() {
  local triplet json url build archive python_new python_old
  case "$SYSTEM_ARCH" in
    amd64) triplet=x86_64 ;;
    arm64) triplet=aarch64 ;;
    *) die "No managed Python build is available for $SYSTEM_ARCH." ;;
  esac

  info "Python >= 3.12 was not found; installing a managed Python 3.13 runtime."
  mkdir -p "$ASTRBOT_ROOT"
  json=$(github_latest_json astral-sh/python-build-standalone)
  url=$(jq -er --arg triplet "$triplet" '.assets[] | select(.name | test("^cpython-3\\.13\\.[0-9]+\\+.*-" + $triplet + "-unknown-linux-gnu-install_only_stripped\\.tar\\.gz$")) | .browser_download_url' <<<"$json" | head -n1)
  [[ -n "$url" ]] || die "Unable to locate the official Python 3.13 build for $triplet."
  build=$(mktemp -d "${ASTRBOT_ROOT}/.python-build.XXXXXX")
  archive="$build/python.tar.gz"
  trap 'rm -rf "${build:-}"' EXIT
  github_download "$url" "$archive"
  tar -xzf "$archive" -C "$build"
  [[ -x "$build/python/bin/python3" ]] || die "The managed Python archive has an unexpected layout."

  python_new="$ASTRBOT_ROOT/.python.new"
  python_old="$ASTRBOT_ROOT/.python.rollback"
  rm -rf "$python_new" "$python_old"
  mv "$build/python" "$python_new"
  [[ ! -e "$ASTRBOT_ROOT/.python" ]] || mv "$ASTRBOT_ROOT/.python" "$python_old"
  mv "$python_new" "$ASTRBOT_ROOT/.python"
  PYTHON_BIN="$ASTRBOT_ROOT/.python/bin/python3"
  "$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 12)' || {
    rm -rf "$ASTRBOT_ROOT/.python"
    [[ ! -d "$python_old" ]] || mv "$python_old" "$ASTRBOT_ROOT/.python"
    die "Managed Python verification failed."
  }
  rm -rf "$python_old"
  export PYTHON_BIN
  rm -rf "$build"
  build=
  trap - EXIT
}
install_astrbot() {
  local tag archive build app_new venv_new old_app old_venv pip_args
  install_packages ca-certificates curl git jq build-essential
  find_python || install_managed_python
  tag=$(github_latest_tag AstrBotDevs/AstrBot)
  bold "安装 AstrBot ${tag}（Python: $PYTHON_BIN）"

  mkdir -p "$ASTRBOT_ROOT"
  build=$(mktemp -d "${ASTRBOT_ROOT}/.build.XXXXXX")
  archive="$build/astrbot.tar.gz"
  app_new="$build/app"
  venv_new="$build/venv"
  trap 'rm -rf "${build:-}"' EXIT

  github_download "https://github.com/AstrBotDevs/AstrBot/archive/refs/tags/${tag}.tar.gz" "$archive"
  mkdir -p "$app_new"
  tar -xzf "$archive" --strip-components=1 -C "$app_new"
  "$PYTHON_BIN" -m venv "$venv_new"
  # 国内直连 PyPI 基本不可用，默认走镜像；镜像失败再回退官方源。
  pip_args=()
  if [[ -n "$PIP_INDEX_URL" ]]; then
    pip_args=(--index-url "$PIP_INDEX_URL")
    [[ -z "$PIP_TRUSTED_HOST" ]] || pip_args+=(--trusted-host "$PIP_TRUSTED_HOST")
  fi
  "$venv_new/bin/python" -m pip install "${pip_args[@]}" --upgrade pip setuptools wheel ||
    "$venv_new/bin/python" -m pip install --upgrade pip setuptools wheel
  if ! "$venv_new/bin/python" -m pip install "${pip_args[@]}" -r "$app_new/requirements.txt"; then
    warn "镜像源安装依赖失败，回退官方 PyPI。"
    "$venv_new/bin/python" -m pip install -r "$app_new/requirements.txt"
  fi
  printf '%s\n' "$tag" > "$app_new/.nbot-version"

  install_runtime_assets
  install_astrbot_units
  systemctl stop nbot-astrbot.service 2>/dev/null || true
  old_app="${ASTRBOT_ROOT}/.app.rollback"
  old_venv="${ASTRBOT_ROOT}/.venv.rollback"
  rm -rf "$old_app" "$old_venv"
  [[ ! -e "$ASTRBOT_ROOT/app" ]] || mv "$ASTRBOT_ROOT/app" "$old_app"
  [[ ! -e "$ASTRBOT_ROOT/.venv" ]] || mv "$ASTRBOT_ROOT/.venv" "$old_venv"
  mv "$app_new" "$ASTRBOT_ROOT/app"
  mv "$venv_new" "$ASTRBOT_ROOT/.venv"
  chown -R root:root "$ASTRBOT_ROOT/app" "$ASTRBOT_ROOT/.venv"

  systemctl daemon-reload
  systemctl enable nbot-astrbot.service nbot-astrbot-watchdog.timer >/dev/null
  # A start failure must fall through to the rollback below, not kill the
  # script via set -e before it can restore the previous version.
  systemctl start nbot-astrbot.service nbot-astrbot-watchdog.timer || true
  sleep 5
  if ! systemctl is-active --quiet nbot-astrbot.service; then
    warn "新版本未能启动，正在回滚。"
    systemctl stop nbot-astrbot.service 2>/dev/null || true
    rm -rf "$ASTRBOT_ROOT/app" "$ASTRBOT_ROOT/.venv"
    [[ ! -d "$old_app" ]] || mv "$old_app" "$ASTRBOT_ROOT/app"
    [[ ! -d "$old_venv" ]] || mv "$old_venv" "$ASTRBOT_ROOT/.venv"
    systemctl start nbot-astrbot.service 2>/dev/null || true
    journalctl -u nbot-astrbot.service -n 80 --no-pager
    die "AstrBot 更新失败，已尝试恢复旧版本。"
  fi
  rm -rf "$old_app" "$old_venv"
  info "AstrBot ${tag} 已启动。WebUI: http://服务器IP:${ASTRBOT_PORT}"
  rm -rf "$build"
  build=
  trap - EXIT
}

astrbot_config_file() { printf '%s/data/cmd_config.json\n' "$ASTRBOT_ROOT"; }

show_astrbot_webui() {
  # v4.24.4 起首次启动随机生成 24 位密码并打印到日志，不再是 astrbot/astrbot。
  local ip user password
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-服务器IP}
  info "AstrBot WebUI: http://${ip}:${ASTRBOT_PORT}"
  user=$(jq -r '.dashboard.username // "astrbot"' "$(astrbot_config_file)" 2>/dev/null || echo astrbot)
  password=$(journalctl -u nbot-astrbot.service --no-pager 2>/dev/null |
               grep -oP 'Initial password:\s*\K\S+' | tail -n1)
  if [[ -n "$password" ]]; then
    info "  账号 ${user}    初始密码 ${password}"
    info "  （首次登录后请在 WebUI 内修改；忘记密码用 nbot astrbot set-password 重置）"
  else
    info "  账号 ${user}    密码：首次启动时随机生成并打印在日志中"
    info "  查看：nbot astrbot logs | grep -i 'Initial password'"
    info "  忘记了就重置：nbot astrbot set-password"
  fi
}

set_astrbot_password() {
  # 走 AstrBot 官方复位途径，不手改密码哈希：它同时维护 pbkdf2 与 legacy md5
  # 两个字段，自己写格式在版本升级后极易失配，把用户彻底锁在外面。
  local config password
  config=$(astrbot_config_file)
  [[ -f "$config" ]] || die "未找到 ${config}，请先安装并启动 AstrBot。"

  if nbot_interactive; then
    read -r -s -p '新的 AstrBot WebUI 密码（至少 8 位，留空则让 AstrBot 随机生成）: ' password; echo
    if [[ -n "$password" ]]; then
      local confirm_password
      read -r -s -p '再输入一次确认: ' confirm_password; echo
      [[ "$password" == "$confirm_password" ]] || die "两次输入不一致。"
      ((${#password} >= 8)) || die "AstrBot 要求密码至少 8 位。"
    fi
  else
    password=${NBOT_ASTRBOT_PASSWORD:-}
  fi

  systemctl stop nbot-astrbot.service 2>/dev/null || true
  # 官方复位开关：清空两种密码字段并在下次启动时重新生成。
  # ASTRBOT_RESET_DASHBOARD_PASSWORD 自 v4.24.4 起支持，被消费一次即失效。
  install -d -m 0755 /etc/systemd/system/nbot-astrbot.service.d
  {
    printf '[Service]\n'
    printf 'Environment=ASTRBOT_RESET_DASHBOARD_PASSWORD=1\n'
    [[ -z "$password" ]] ||
      printf 'Environment=ASTRBOT_DASHBOARD_INITIAL_PASSWORD=%s\n' "$password"
  } > /etc/systemd/system/nbot-astrbot.service.d/reset-password.conf
  systemctl daemon-reload
  systemctl start nbot-astrbot.service

  # 复位是一次性动作，用完立刻移除 drop-in，避免每次重启都重置密码。
  sleep 8
  rm -f /etc/systemd/system/nbot-astrbot.service.d/reset-password.conf
  rmdir /etc/systemd/system/nbot-astrbot.service.d 2>/dev/null || true
  systemctl daemon-reload

  if ! systemctl is-active --quiet nbot-astrbot.service; then
    journalctl -u nbot-astrbot.service -n 40 --no-pager
    die "AstrBot 重启失败，密码可能未重置。"
  fi
  if [[ -n "$password" ]]; then
    info "AstrBot WebUI 密码已设置为你输入的值。"
  else
    show_astrbot_webui
  fi
}

install_astrbot_units() {
  install -d -m 0755 /usr/local/lib/nbot
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbot-prepare" /usr/local/lib/nbot/astrbot-prepare
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbot-launch" /usr/local/lib/nbot/astrbot-launch
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbot-healthcheck" /usr/local/lib/nbot/astrbot-healthcheck
  install -m 0644 "$SCRIPT_DIR/assets/systemd/nbot-astrbot.service" /etc/systemd/system/nbot-astrbot.service
  install -m 0644 "$SCRIPT_DIR/assets/systemd/nbot-astrbot-watchdog.service" /etc/systemd/system/nbot-astrbot-watchdog.service
  install -m 0644 "$SCRIPT_DIR/assets/systemd/nbot-astrbot-watchdog.timer" /etc/systemd/system/nbot-astrbot-watchdog.timer
  systemctl daemon-reload
}
