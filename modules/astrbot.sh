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
  local tag archive build app_new venv_new old_app old_venv
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
  "$venv_new/bin/python" -m pip install --upgrade pip setuptools wheel
  "$venv_new/bin/python" -m pip install -r "$app_new/requirements.txt"
  printf '%s\n' "$tag" > "$app_new/.bot-stack-version"

  install_runtime_assets
  install_astrbot_units
  systemctl stop astrbot.service 2>/dev/null || true
  old_app="${ASTRBOT_ROOT}/.app.rollback"
  old_venv="${ASTRBOT_ROOT}/.venv.rollback"
  rm -rf "$old_app" "$old_venv"
  [[ ! -e "$ASTRBOT_ROOT/app" ]] || mv "$ASTRBOT_ROOT/app" "$old_app"
  [[ ! -e "$ASTRBOT_ROOT/.venv" ]] || mv "$ASTRBOT_ROOT/.venv" "$old_venv"
  mv "$app_new" "$ASTRBOT_ROOT/app"
  mv "$venv_new" "$ASTRBOT_ROOT/.venv"
  chown -R root:root "$ASTRBOT_ROOT/app" "$ASTRBOT_ROOT/.venv"

  systemctl daemon-reload
  systemctl enable astrbot.service astrbot-watchdog.timer >/dev/null
  systemctl start astrbot.service astrbot-watchdog.timer
  sleep 5
  if ! systemctl is-active --quiet astrbot.service; then
    warn "新版本未能启动，正在回滚。"
    systemctl stop astrbot.service 2>/dev/null || true
    rm -rf "$ASTRBOT_ROOT/app" "$ASTRBOT_ROOT/.venv"
    [[ ! -d "$old_app" ]] || mv "$old_app" "$ASTRBOT_ROOT/app"
    [[ ! -d "$old_venv" ]] || mv "$old_venv" "$ASTRBOT_ROOT/.venv"
    systemctl start astrbot.service 2>/dev/null || true
    journalctl -u astrbot.service -n 80 --no-pager
    die "AstrBot 更新失败，已尝试恢复旧版本。"
  fi
  rm -rf "$old_app" "$old_venv"
  info "AstrBot ${tag} 已启动。WebUI: http://服务器IP:${ASTRBOT_PORT}"
  rm -rf "$build"
  build=
  trap - EXIT
}

install_astrbot_units() {
  install -d -m 0755 /usr/local/lib/bot-stack
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbot-prepare" /usr/local/lib/bot-stack/astrbot-prepare
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbot-launch" /usr/local/lib/bot-stack/astrbot-launch
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbot-healthcheck" /usr/local/lib/bot-stack/astrbot-healthcheck
  install -m 0755 "$SCRIPT_DIR/assets/bin/astrbotctl" /usr/local/bin/astrbotctl
  install -m 0644 "$SCRIPT_DIR/assets/systemd/astrbot.service" /etc/systemd/system/astrbot.service
  install -m 0644 "$SCRIPT_DIR/assets/systemd/astrbot-watchdog.service" /etc/systemd/system/astrbot-watchdog.service
  install -m 0644 "$SCRIPT_DIR/assets/systemd/astrbot-watchdog.timer" /etc/systemd/system/astrbot-watchdog.timer
  systemctl daemon-reload
}
