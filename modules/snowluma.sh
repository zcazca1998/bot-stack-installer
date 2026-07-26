#!/usr/bin/env bash
set -Eeuo pipefail

install_runtime_assets() {
  local file
  install -d -m 0755 /usr/local/lib/nbot
  for file in "$SCRIPT_DIR"/assets/bin/*; do
    install -m 0755 "$file" "/usr/local/lib/nbot/$(basename "$file")"
  done
  # 控制命令统一为 nbot 子命令；清理旧的独立入口。
  rm -f /usr/local/bin/snowlumactl /usr/local/bin/astrbotctl         /usr/local/bin/novncctl /usr/local/bin/qqlogin /usr/local/bin/qqrefresh
  # 日志限制：logrotate 轮转 + 每日清理定时器 + 可选 journald 总量上限。
  install -m 0644 "$SCRIPT_DIR/assets/systemd/nbot-logclean.service" /etc/systemd/system/nbot-logclean.service
  install -m 0644 "$SCRIPT_DIR/assets/systemd/nbot-logclean.timer" /etc/systemd/system/nbot-logclean.timer
  write_logrotate_config
  write_journald_limit
  systemctl daemon-reload
  systemctl enable --now nbot-logclean.timer >/dev/null 2>&1 || true
}

normalized_image_ref() {
  local image=$1
  [[ "$image" == */* ]] || image="library/$image"
  [[ "$image" == *.*/* || "$image" == localhost/* ]] || image="docker.io/$image"
  printf '%s\n' "$image"
}

image_ref_for_mirror() {
  local image prefix=$2
  image=$(normalized_image_ref "$1")
  [[ -n "$prefix" ]] || return 1
  printf '%s/%s\n' "${prefix%/}" "${image#docker.io/}"
}

mirrored_image_ref() {
  image_ref_for_mirror "$1" "$SNOWLUMA_IMAGE_MIRROR"
}

download_large_blob() {
  local url=$1 output=$2 proxy=${SNOWLUMA_IMAGE_PROXY:-${GITHUB_PROXY:-}}
  curl_args
  if [[ -n "$proxy" ]]; then
    info "Trying large image layer through the configured proxy."
    if curl "${CURL_ARGS[@]}" --connect-timeout 5 --retry-all-errors --max-time 1800 --proxy "$proxy" --output "$output" "$url"; then
      return 0
    fi
    warn "Image proxy failed; retrying the layer directly."
  fi
  curl "${CURL_ARGS[@]}" --retry-all-errors --max-time 1800 --output "$output" "$url"
}
prefetch_dockerproxy_layers() {
  local ref=$1 cache=$2 repo temp raw manifest manifest_digest digest size target actual
  [[ "$ref" == dockerproxy.net/* ]] || return 0
  repo=${ref#dockerproxy.net/}
  repo=${repo%:*}
  mkdir -p "$cache/sha256"
  temp=$(mktemp -d "${cache}/.manifest.XXXXXX")
  raw="$temp/index.json"
  manifest="$temp/manifest.json"
  if ! skopeo inspect --raw "docker://$ref" > "$raw"; then rm -rf "$temp"; return 0; fi
  if jq -e '.manifests' "$raw" >/dev/null 2>&1; then
    manifest_digest=$(jq -er --arg arch "$SYSTEM_ARCH" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' "$raw" | head -n1) || { rm -rf "$temp"; return 0; }
    skopeo inspect --raw "docker://dockerproxy.net/${repo}@${manifest_digest}" > "$manifest" || { rm -rf "$temp"; return 0; }
  else
    cp "$raw" "$manifest"
  fi
  while IFS=$'\t' read -r digest size; do
    target="$cache/sha256/${digest#sha256:}"
    if [[ -f "$target" && $(stat -c %s "$target") == "$size" ]]; then
      actual=$(sha256sum "$target" | awk '{print $1}')
      [[ "$actual" == "${digest#sha256:}" ]] && continue
    fi
    rm -f "${target}.part"
    info "Prefetching verified large image layer: $digest ($size bytes)"
    if download_large_blob "https://dockerproxy.net/v2/${repo}/blobs/${digest}" "${target}.part" &&
       [[ $(stat -c %s "${target}.part") == "$size" ]] &&
       [[ $(sha256sum "${target}.part" | awk '{print $1}') == "${digest#sha256:}" ]]; then
      mv "${target}.part" "$target"
    else
      warn "Large-layer prefetch failed; skopeo will continue with normal mirror fallback."
      rm -f "${target}.part"
    fi
  done < <(jq -r '.layers[] | select(.size >= 67108864) | [.digest, (.size | tostring)] | @tsv' "$manifest")
  rm -rf "$temp"
}
copy_snowluma_image() {
  local oci=$1 direct mirror fallback ref cache
  direct=$(normalized_image_ref "$SNOWLUMA_IMAGE")
  mirror=$(image_ref_for_mirror "$SNOWLUMA_IMAGE" "$SNOWLUMA_IMAGE_MIRROR" || true)
  fallback=$(image_ref_for_mirror "$SNOWLUMA_IMAGE" "$SNOWLUMA_IMAGE_FALLBACK_MIRROR" || true)
  rm -rf "$oci"
  cache="$SNOWLUMA_PAYLOAD_ROOT/.image-blob-cache"
  mkdir -p "$cache"
  SNOWLUMA_BLOB_CACHE=$cache
  export SNOWLUMA_BLOB_CACHE
  prefetch_dockerproxy_layers "$mirror" "$cache"
  for ref in "$mirror" "$fallback" "$direct"; do
    [[ -n "$ref" ]] || continue
    info "Trying SnowLuma image: $ref"
    if skopeo copy --override-os linux --override-arch "$SYSTEM_ARCH" --retry-times 5 --dest-shared-blob-dir "$cache" "docker://$ref" "oci:$oci:release"; then
      mkdir -p "$oci/blobs/sha256"
      cp -aln "$cache/sha256/." "$oci/blobs/sha256/"
      SNOWLUMA_RESOLVED_IMAGE=$ref
      export SNOWLUMA_RESOLVED_IMAGE
      return 0
    fi
    warn "Image source failed: $ref; completed blobs are retained for the next source."
  done
  return 1
}

safe_version() {
  tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//'
}

verify_dynamic_dependencies() {
  local target output failed=0
  for target in "$@"; do
    output=$(ldd "$target" 2>&1 || true)
    if grep -q 'not found' <<<"$output"; then
      warn "Missing shared libraries for $target:"
      grep 'not found' <<<"$output" >&2
      failed=1
    fi
  done
  ((failed == 0)) || die "The host is missing runtime libraries required by the extracted image."
}
prune_image_releases() {
  local parent=$1 current=$2 previous=${3:-} release resolved
  [[ -d "$parent" ]] || return 0
  # Canonicalize before comparing so a symlinked payload path never causes an
  # in-use release to be deleted.
  current=$(readlink -f -- "$current" 2>/dev/null || printf '%s' "$current")
  [[ -z "$previous" ]] || previous=$(readlink -f -- "$previous" 2>/dev/null || printf '%s' "$previous")
  while IFS= read -r -d '' release; do
    resolved=$(readlink -f -- "$release" 2>/dev/null || printf '%s' "$release")
    [[ "$resolved" == "$current" || "$resolved" == "$previous" ]] || rm -rf "$release"
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -name 'image-*' -print0)
}
install_snowluma() {
  local build oci bundle rootfs snow_version qq_version release_id snow_release qq_release
  local old_app old_qq free_kb start_failed=0 required_kb=6291456

  install_packages ca-certificates curl jq openssl skopeo umoci libcap2-bin xvfb dbus-user-session ffmpeg xdotool zbar-tools qrencode imagemagick fonts-wqy-zenhei libasound2 libatspi2.0-0 libgbm1 libgtk-3-0 libnotify4 libnss3 libsecret-1-0 procps util-linux xauth xdg-utils
  require_commands curl jq skopeo umoci setcap Xvfb xauth mcookie dbus-daemon ffmpeg xdotool zbarimg qrencode
  mkdir -p "$SNOWLUMA_ROOT" "$SNOWLUMA_PAYLOAD_ROOT"
  free_kb=$(df -Pk "$SNOWLUMA_PAYLOAD_ROOT" | awk 'NR==2 {print $4}')
  ((free_kb >= required_kb)) ||
    die "At least 6 GiB free is required in $SNOWLUMA_PAYLOAD_ROOT to unpack the image."

  build=$(mktemp -d "${SNOWLUMA_PAYLOAD_ROOT}/.image-build.XXXXXX")
  oci="$build/oci"
  bundle="$build/bundle"
  trap 'rm -rf "${build:-}"' EXIT

  copy_snowluma_image "$oci" ||
    die "Unable to download the SnowLuma image from the mirror or Docker Hub."
  info "Unpacking the OCI image without installing Docker."
  umoci unpack --image "$oci:release" "$bundle"
  rm -rf "$SNOWLUMA_BLOB_CACHE"
  rootfs="$bundle/rootfs"

  [[ -f "$rootfs/app/snowluma/index.mjs" ]] ||
    die "The image does not contain /app/snowluma/index.mjs."
  [[ -x "$rootfs/opt/QQ/qq" ]] ||
    die "The image does not contain /opt/QQ/qq."
  [[ -x "$rootfs/usr/local/bin/node" ]] ||
    die "The image does not contain /usr/local/bin/node."

  verify_dynamic_dependencies "$rootfs/usr/local/bin/node" "$rootfs/opt/QQ/qq" "$rootfs/app/snowluma/native/snowluma-linux-${SNOWLUMA_ARCH}.node" "$rootfs/app/snowluma/native/snowluma-linux-${SNOWLUMA_ARCH}.so" "$rootfs/app/snowluma/native/websocket-linux-${SNOWLUMA_ARCH}.node"

  snow_version=$(jq -r '.version // "unknown"' "$rootfs/app/snowluma/package.json" 2>/dev/null | safe_version)
  qq_version=$(jq -r '.version // "unknown"' "$rootfs/opt/QQ/resources/app/package.json" 2>/dev/null | safe_version)
  [[ -n "$snow_version" ]] || snow_version=unknown
  [[ -n "$qq_version" ]] || qq_version=unknown
  release_id=$(date +%Y%m%d%H%M%S)-${RANDOM}
  snow_release="$SNOWLUMA_PAYLOAD_ROOT/releases/image-$snow_version-$release_id"
  qq_release="$SNOWLUMA_PAYLOAD_ROOT/qq/releases/image-$qq_version-$release_id"

  rm -rf "${snow_release}.new" "${qq_release}.new"
  mkdir -p "${snow_release}.new" "${qq_release}.new/opt" "$SNOWLUMA_PAYLOAD_ROOT/runtime"
  cp -a "$rootfs/app/snowluma/." "${snow_release}.new/"
  cp -a "$rootfs/opt/QQ" "${qq_release}.new/opt/QQ"
  install -m 0755 "$rootfs/usr/local/bin/node" "$SNOWLUMA_PAYLOAD_ROOT/runtime/node"
  printf '%s\n' 'opt/QQ/qq' > "${qq_release}.new/.qq-executable"
  printf '%s\n' "$SNOWLUMA_RESOLVED_IMAGE" > "${snow_release}.new/.image-source"

  rm -rf "$snow_release" "$qq_release"
  mv "${snow_release}.new" "$snow_release"
  mv "${qq_release}.new" "$qq_release"

  getent group snowluma >/dev/null || groupadd --system snowluma
  id snowluma >/dev/null 2>&1 || useradd --system --gid snowluma \
    --home-dir "$SNOWLUMA_ROOT/home" --shell /usr/sbin/nologin snowluma
  chown root:snowluma "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
  mkdir -p "$SNOWLUMA_ROOT"/{home,config,cache,data,tmp,logs,run/hook,run/session}
  chown -R snowluma:snowluma "$SNOWLUMA_ROOT" "$snow_release" "$qq_release" "$SNOWLUMA_PAYLOAD_ROOT/runtime"
  chmod 0700 "$SNOWLUMA_ROOT/run/session"
  setcap cap_sys_ptrace=ep "$SNOWLUMA_PAYLOAD_ROOT/runtime/node"
  getcap "$SNOWLUMA_PAYLOAD_ROOT/runtime/node" | grep -q cap_sys_ptrace ||
    die "Unable to set cap_sys_ptrace on the extracted Node runtime."

  old_app=$(readlink -f "$SNOWLUMA_ROOT/app" 2>/dev/null || true)
  old_qq=$(readlink -f "$SNOWLUMA_ROOT/qq/current" 2>/dev/null || true)
  mkdir -p "$SNOWLUMA_ROOT/qq"
  atomic_symlink "$snow_release" "$SNOWLUMA_ROOT/app"
  atomic_symlink "$qq_release" "$SNOWLUMA_ROOT/qq/current"

  install_runtime_assets
  install_snowluma_units
  systemctl stop nbot-snowluma.service nbot-qq.service 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable nbot-qq.service nbot-snowluma.service nbot-snowluma-watchdog.timer >/dev/null
  start_service nbot-qq.service || start_failed=1
  if ((start_failed == 0)); then
    start_service nbot-snowluma.service || start_failed=1
  fi
  if ((start_failed == 0)); then
    start_service nbot-snowluma-watchdog.timer || start_failed=1
  fi
  sleep 8

  if ((start_failed != 0)) ||
     ! systemctl is-active --quiet nbot-qq.service ||
     ! systemctl is-active --quiet nbot-snowluma.service; then
    warn "Extracted image failed to start; restoring previous payload links."
    systemctl stop nbot-snowluma.service nbot-qq.service 2>/dev/null || true
    if [[ -n "$old_app" ]]; then atomic_symlink "$old_app" "$SNOWLUMA_ROOT/app"; else rm -f "$SNOWLUMA_ROOT/app"; fi
    if [[ -n "$old_qq" ]]; then atomic_symlink "$old_qq" "$SNOWLUMA_ROOT/qq/current"; else rm -f "$SNOWLUMA_ROOT/qq/current"; fi
    start_service nbot-qq.service nbot-snowluma.service 2>/dev/null || true
    journalctl -u nbot-qq.service -u nbot-snowluma.service -n 120 --no-pager
    die "SnowLuma image extraction installed but runtime verification failed."
  fi

  prune_image_releases "$SNOWLUMA_PAYLOAD_ROOT/releases" "$snow_release" "$old_app"
  prune_image_releases "$SNOWLUMA_PAYLOAD_ROOT/qq/releases" "$qq_release" "$old_qq"

  info "SnowLuma $snow_version and QQ $qq_version were extracted from $SNOWLUMA_RESOLVED_IMAGE."
  info "WebUI: http://SERVER_IP:${SNOWLUMA_WEBUI_PORT}"
  rm -rf "$build"
  build=
  trap - EXIT
}

install_qq_interactive() {
  info "QQ is bundled in the SnowLuma image; refreshing the image payload."
  install_snowluma
}

install_qq() {
  [[ -z "${1:-}" ]] ||
    warn "A separate QQ package is ignored because the SnowLuma image bundles a pinned QQ build."
  install_snowluma
}

snowluma_other_release() {
  # 载荷目录只保留当前和上一个 image-* release，所以「另一个」就是回滚目标。
  local parent=$1 current release
  current=$(readlink -f "$2" 2>/dev/null || true)
  while IFS= read -r release; do
    [[ "$(readlink -f "$release")" != "$current" ]] && { printf '%s
' "$release"; return 0; }
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -name 'image-*' 2>/dev/null | sort -r)
  return 1
}

show_snowluma_version() {
  local current other
  current=$(readlink -f "$SNOWLUMA_ROOT/app" 2>/dev/null || true)
  if [[ -z "$current" ]]; then
    info "SnowLuma 尚未安装。"
    return 0
  fi
  info "当前版本：$(basename "$current")"
  [[ ! -r "$current/.image-source" ]] ||
    info "  镜像来源：$(<"$current/.image-source")"
  if other=$(snowluma_other_release "$SNOWLUMA_PAYLOAD_ROOT/releases" "$SNOWLUMA_ROOT/app"); then
    info "可回滚到：$(basename "$other")"
    info "  执行 nbot snowluma rollback 即可退回，无需知道版本号。"
  else
    info "可回滚到：无（尚未经历过一次更新）"
  fi
}

rollback_snowluma() {
  # 程序载荷是软链接切换，回滚只需把链接指回另一个 release；配置、缓存和
  # QQ 登录态不在版本目录里，所以回滚不会丢数据。
  local snow_target qq_target old_app old_qq
  snow_target=$(snowluma_other_release "$SNOWLUMA_PAYLOAD_ROOT/releases" "$SNOWLUMA_ROOT/app") ||
    die "没有可回滚的 SnowLuma 版本（需要先经历一次 nbot snowluma update）。"
  qq_target=$(snowluma_other_release "$SNOWLUMA_PAYLOAD_ROOT/qq/releases" "$SNOWLUMA_ROOT/qq/current") || qq_target=

  old_app=$(readlink -f "$SNOWLUMA_ROOT/app")
  old_qq=$(readlink -f "$SNOWLUMA_ROOT/qq/current" 2>/dev/null || true)
  info "准备回滚：$(basename "$old_app") -> $(basename "$snow_target")"
  [[ -z "$qq_target" ]] || info "  QQ：$(basename "${old_qq:-无}") -> $(basename "$qq_target")"
  nbot_interactive && { confirm "确认回滚 SnowLuma 与 QQ？" Y || return 0; }

  systemctl stop nbot-snowluma.service nbot-qq.service 2>/dev/null || true
  atomic_symlink "$snow_target" "$SNOWLUMA_ROOT/app"
  [[ -z "$qq_target" ]] || atomic_symlink "$qq_target" "$SNOWLUMA_ROOT/qq/current"
  start_service nbot-qq.service || true
  systemctl reset-failed nbot-snowluma.service 2>/dev/null || true; systemctl --no-block start nbot-snowluma.service 2>/dev/null || true
  sleep 8
  if ! systemctl is-active --quiet nbot-qq.service; then
    warn "回滚后的版本未能启动，正在切回原版本。"
    systemctl stop nbot-snowluma.service nbot-qq.service 2>/dev/null || true
    atomic_symlink "$old_app" "$SNOWLUMA_ROOT/app"
    [[ -z "$old_qq" ]] || atomic_symlink "$old_qq" "$SNOWLUMA_ROOT/qq/current"
    start_service nbot-qq.service 2>/dev/null || true
    systemctl reset-failed nbot-snowluma.service 2>/dev/null || true; systemctl --no-block start nbot-snowluma.service 2>/dev/null || true
    die "回滚失败，已恢复到 $(basename "$old_app")。"
  fi
  info "已回滚到 $(basename "$snow_target")。再次执行 nbot snowluma rollback 可切回。"
}


snowluma_webui_auth_file() { printf '%s/data/config/webui.json
' "$SNOWLUMA_ROOT"; }

show_snowluma_webui() {
  # SnowLuma 用密码登录（scrypt 哈希存 webui.json），没有 token；初始密码
  # 只在首次启动时打印一次，日志里那行格式被第三方启动器解析，稳定可 grep。
  local ip password
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-服务器IP}
  info "SnowLuma WebUI: http://${ip}:${SNOWLUMA_WEBUI_PORT}"
  password=$(journalctl -u nbot-snowluma.service --no-pager 2>/dev/null |
               grep -oP 'initial credentials: user=admin password=\K\S+' | tail -n1)
  if [[ -n "$password" ]]; then
    info "  账号 admin    初始密码 ${password}"
    info "  （首次登录后必须改密；忘记密码用 nbot snowluma set-password 重置）"
  else
    info "  账号 admin    密码：首次启动时随机生成并打印在日志中"
    info "  查看：nbot snowluma logs | grep -i 'initial credentials'"
    info "  忘记了就重置：nbot snowluma set-password"
  fi
}

set_snowluma_password() {
  # SnowLuma 的密码是 scrypt 哈希（N=16384,r=8,p=1,keylen=64），无法手工构造，
  # 官方复位途径是删除 webui.json 让它重新生成；能指定密码的
  # SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD 也只在该文件不存在时生效。
  local auth_file password backup
  auth_file=$(snowluma_webui_auth_file)
  [[ -f /etc/systemd/system/nbot-snowluma.service ]] ||
    die "尚未安装 SnowLuma，请先执行 nbot install-snowluma。"

  if nbot_interactive; then
    info "SnowLuma 密码要求：至少 10 位，含大小写字母与特殊字符，不能有空格。"
    read -r -s -p '新的 SnowLuma WebUI 密码（留空则由 SnowLuma 随机生成）: ' password; echo
    if [[ -n "$password" ]]; then
      local confirm_password
      read -r -s -p '再输入一次确认: ' confirm_password; echo
      [[ "$password" == "$confirm_password" ]] || die "两次输入不一致。"
      ((${#password} >= 10)) || die "SnowLuma 要求密码至少 10 位。"
      [[ "$password" =~ [a-z] && "$password" =~ [A-Z] && "$password" =~ [^A-Za-z0-9] ]] ||
        die "密码需同时包含小写、大写字母与特殊字符。"
      [[ ! "$password" =~ [[:space:]] ]] || die "密码不能包含空格。"
    fi
  else
    password=${NBOT_SNOWLUMA_PASSWORD:-}
  fi

  systemctl stop nbot-snowluma.service 2>/dev/null || true
  if [[ -f "$auth_file" ]]; then
    backup="${auth_file}.bak.$(date +%s)"
    mv -f "$auth_file" "$backup"
    info "原凭据已备份：${backup}"
  fi

  if [[ -n "$password" ]]; then
    # 该环境变量自 v1.8.2 起支持；旧版本会忽略并退回随机生成。
    install -d -m 0755 /etc/systemd/system/nbot-snowluma.service.d
    printf '[Service]
Environment=SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD=%s
' "$password"       > /etc/systemd/system/nbot-snowluma.service.d/bootstrap-password.conf
    chmod 0600 /etc/systemd/system/nbot-snowluma.service.d/bootstrap-password.conf
    systemctl daemon-reload
  fi

  start_service nbot-snowluma.service
  sleep 8
  # 指定密码只在首次生成时被读取，用完即清，避免长期把明文留在 unit 里。
  if [[ -n "$password" ]]; then
    rm -f /etc/systemd/system/nbot-snowluma.service.d/bootstrap-password.conf
    rmdir /etc/systemd/system/nbot-snowluma.service.d 2>/dev/null || true
    systemctl daemon-reload
  fi

  if ! systemctl is-active --quiet nbot-snowluma.service; then
    journalctl -u nbot-snowluma.service -n 40 --no-pager
    die "SnowLuma 重启失败，密码可能未重置。"
  fi
  if [[ -n "$password" ]]; then
    if [[ -s "$auth_file" ]]; then
      info "SnowLuma WebUI 密码已设置为你输入的值（账号 admin）。"
    else
      warn "未生成凭据文件，当前 SnowLuma 版本可能不支持指定初始密码。"
      show_snowluma_webui
    fi
  else
    show_snowluma_webui
  fi
}

configure_onebot() {
  local uin token
  [[ -f "$SNOWLUMA_ROOT/app/index.mjs" ]] || die "Install SnowLuma first."
  uin=$(/usr/local/lib/nbot/qq-login-state --uin 2>/dev/null || true)
  [[ -n "$uin" ]] || prompt_default uin "QQ 号 (UIN)" "$QQ_UIN"
  [[ -n "$uin" ]] || die "未检测到已登录的 QQ 账号，也未提供 QQ 号。"
  read -r -s -p 'OneBot token（留空自动生成）: ' token; echo
  [[ -n "$token" ]] || token=$(openssl rand -hex 24)
  QQ_UIN=$uin
  write_config
  ONEBOT_TOKEN=$token QQ_UIN=$uin SNOWLUMA_ROOT=$SNOWLUMA_ROOT \
    ONEBOT_HTTP_PORT=$ONEBOT_HTTP_PORT ASTRBOT_WS_PORT=$ASTRBOT_WS_PORT \
    "$SNOWLUMA_PAYLOAD_ROOT/runtime/node" \
    /usr/local/lib/nbot/write-onebot-config
  restart_service nbot-snowluma.service
  info "OneBot configured: HTTP 127.0.0.1:${ONEBOT_HTTP_PORT}; WS -> 127.0.0.1:${ASTRBOT_WS_PORT}/ws"
  info "OneBot token：${token}"
  info "在 AstrBot WebUI 添加 OneBot v11 适配器时填写：端口 ${ASTRBOT_WS_PORT}，token 如上。"
}

install_snowluma_units() {
  local unit
  install_runtime_assets
  for unit in nbot-snowluma.service nbot-qq.service nbot-snowluma-watchdog.service nbot-snowluma-watchdog.timer; do
    install -m 0644 "$SCRIPT_DIR/assets/systemd/$unit" "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload
}
