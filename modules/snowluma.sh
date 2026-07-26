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
  systemctl start nbot-qq.service || start_failed=1
  if ((start_failed == 0)); then
    systemctl start nbot-snowluma.service || start_failed=1
  fi
  if ((start_failed == 0)); then
    systemctl start nbot-snowluma-watchdog.timer || start_failed=1
  fi
  sleep 8

  if ((start_failed != 0)) ||
     ! systemctl is-active --quiet nbot-qq.service ||
     ! systemctl is-active --quiet nbot-snowluma.service; then
    warn "Extracted image failed to start; restoring previous payload links."
    systemctl stop nbot-snowluma.service nbot-qq.service 2>/dev/null || true
    if [[ -n "$old_app" ]]; then atomic_symlink "$old_app" "$SNOWLUMA_ROOT/app"; else rm -f "$SNOWLUMA_ROOT/app"; fi
    if [[ -n "$old_qq" ]]; then atomic_symlink "$old_qq" "$SNOWLUMA_ROOT/qq/current"; else rm -f "$SNOWLUMA_ROOT/qq/current"; fi
    systemctl start nbot-qq.service nbot-snowluma.service 2>/dev/null || true
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

snowluma_webui_token() {
  # SnowLuma 自己生成 WebUI token，安装器不参与。优先读它的配置文件，
  # 读不到再从日志里捞，避免用户自己去爬 journal。
  local file token
  for file in "$SNOWLUMA_ROOT"/data/config/webui.json \
              "$SNOWLUMA_ROOT"/data/config/*webui*.json \
              "$SNOWLUMA_ROOT"/config/webui.json; do
    [[ -r "$file" ]] || continue
    token=$(jq -r '.token // .accessToken // .password // empty' "$file" 2>/dev/null | head -n1)
    [[ -n "$token" ]] && { printf '%s\n' "$token"; return 0; }
  done
  # 日志里通常打印过一次带 token 的访问地址。
  token=$(journalctl -u nbot-snowluma.service --no-pager 2>/dev/null |
            grep -oE 'token=[A-Za-z0-9._~-]+' | tail -n1 | cut -d= -f2)
  [[ -n "$token" ]] && { printf '%s\n' "$token"; return 0; }
  return 1
}

show_snowluma_webui() {
  local ip token
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-服务器IP}
  if token=$(snowluma_webui_token); then
    info "SnowLuma WebUI: http://${ip}:${SNOWLUMA_WEBUI_PORT}/?token=${token}"
    info "  访问令牌：${token}（nbot snowluma webui 可再次查看）"
  else
    info "SnowLuma WebUI: http://${ip}:${SNOWLUMA_WEBUI_PORT}"
    warn "未能自动读取 SnowLuma 访问令牌，可执行：nbot snowluma logs -n 200 | grep -i token"
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
  systemctl restart nbot-snowluma.service
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
