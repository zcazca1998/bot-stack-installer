#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE=${NBOT_CONFIG:-/etc/nbot.conf}
# 统一工作区：三个组件按名字放在同一目录下；旧安装的自定义路径
# 保存在配置文件里，不受新默认值影响。
NBOT_HOME=${NBOT_HOME:-/nbot}
ASTRBOT_ROOT=${ASTRBOT_ROOT:-${NBOT_HOME}/astrbot}
SNOWLUMA_ROOT=${SNOWLUMA_ROOT:-${NBOT_HOME}/snowluma}
ASTRBOT_PORT=${ASTRBOT_PORT:-6185}
ASTRBOT_WS_PORT=${ASTRBOT_WS_PORT:-6199}
SNOWLUMA_WEBUI_PORT=${SNOWLUMA_WEBUI_PORT:-5099}
ONEBOT_HTTP_PORT=${ONEBOT_HTTP_PORT:-3005}
GITHUB_PROXY=${GITHUB_PROXY:-}
GITHUB_ACCESS=${GITHUB_ACCESS:-auto}
# GitHub 下载加速前缀（国内直连常年不通）。按顺序尝试，全部失败后直连。
# 留空表示不使用加速镜像。
GITHUB_MIRRORS=${GITHUB_MIRRORS:-https://gh-proxy.com,https://ghfast.top,https://ghproxy.net}
# pip 索引（AstrBot 依赖数百 MB，国内直连 PyPI 基本不可用）。
PIP_INDEX_URL=${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}
PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST:-pypi.tuna.tsinghua.edu.cn}
# 网络地区：auto 首次运行时探测，cn=国内（默认用镜像），global=海外（默认直连）。
NETWORK_REGION=${NETWORK_REGION:-auto}

# 候选镜像：编号 | 显示名 | 值（第二字段用于 trusted-host 推导）
PIP_MIRROR_CHOICES=(
  "清华 TUNA|https://pypi.tuna.tsinghua.edu.cn/simple"
  "阿里云|https://mirrors.aliyun.com/pypi/simple/"
  "腾讯云|https://mirrors.cloud.tencent.com/pypi/simple"
  "中科大 USTC|https://mirrors.ustc.edu.cn/pypi/simple"
  "华为云|https://repo.huaweicloud.com/repository/pypi/simple"
  "官方 pypi.org|https://pypi.org/simple"
)
GITHUB_MIRROR_CHOICES=(
  "gh-proxy.com|https://gh-proxy.com"
  "ghfast.top|https://ghfast.top"
  "ghproxy.net|https://ghproxy.net"
  "全部依次尝试|https://gh-proxy.com,https://ghfast.top,https://ghproxy.net"
  "不使用加速（直连）|"
)
IMAGE_MIRROR_CHOICES=(
  "dockerproxy.net|dockerproxy.net"
  "docker.1ms.run|docker.1ms.run"
  "m.daocloud.io/docker.io|m.daocloud.io/docker.io"
  "docker.xuanyuan.me|docker.xuanyuan.me"
  "不使用加速（直连 Docker Hub）|"
)
SNOWLUMA_IMAGE=${SNOWLUMA_IMAGE:-motricseven7/snowluma:latest}
SNOWLUMA_IMAGE_MIRROR=${SNOWLUMA_IMAGE_MIRROR:-dockerproxy.net}
SNOWLUMA_IMAGE_FALLBACK_MIRROR=${SNOWLUMA_IMAGE_FALLBACK_MIRROR:-docker.1ms.run}
SNOWLUMA_IMAGE_PROXY=${SNOWLUMA_IMAGE_PROXY:-}
SNOWLUMA_PAYLOAD_ROOT=${SNOWLUMA_PAYLOAD_ROOT:-${NBOT_HOME}/payload/snowluma}
NOVNC_PORT=${NOVNC_PORT:-6080}
NOVNC_VNC_PORT=${NOVNC_VNC_PORT:-5901}
# journald 总量上限；留空表示不修改系统默认。
JOURNALD_MAX_USE=${JOURNALD_MAX_USE:-}
CADDY_DOMAIN=${CADDY_DOMAIN:-}
CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT:-8443}
CADDY_AUTH_USER=${CADDY_AUTH_USER:-admin}
QQ_UIN=${QQ_UIN:-}

# 从旧的 bot-stack 命名迁移：只读取旧配置，实际搬迁在 migrate_legacy_layout
# 里进行（需要 root 且要先停服务）。
LEGACY_CONFIG=/etc/bot-stack.conf
if [[ ! -r "$CONFIG_FILE" && -r "$LEGACY_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$LEGACY_CONFIG"
  NBOT_LEGACY_FOUND=1
elif [[ -r "$CONFIG_FILE" ]]; then
  # The installer owns this root-only file.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
# 旧配置里没有 NBOT_HOME，且路径仍指向旧默认值时保持原样，避免误搬用户数据。
BOT_STACK_HOME=${BOT_STACK_HOME:-}
[[ -z "$BOT_STACK_HOME" ]] || NBOT_HOME=$BOT_STACK_HOME

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
  [[ -d /run/systemd/system ]] || die "当前系统不是 systemd，无法安装服务。"
}

detect_arch() {
  local dpkg_arch
  case "$(uname -m)" in
    x86_64|amd64) SYSTEM_ARCH=amd64; SNOWLUMA_ARCH=x64 ;;
    aarch64|arm64) SYSTEM_ARCH=arm64; SNOWLUMA_ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)。仅支持 amd64/x86_64 与 arm64/aarch64。" ;;
  esac
  # 64 位内核可能跑 32 位用户空间（部分旧 Armbian）：此时 uname 报 aarch64，
  # 但 apt 只认 armhf，装出来的 64 位载荷跑不起来。以包架构为准。
  if command -v dpkg >/dev/null 2>&1; then
    dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)
    case "$dpkg_arch" in
      amd64|arm64)
        [[ "$dpkg_arch" == "$SYSTEM_ARCH" ]] ||
          die "内核架构 $(uname -m) 与系统包架构 ${dpkg_arch} 不一致，无法安装。"
        ;;
      '') ;;
      *) die "系统包架构为 ${dpkg_arch}（32 位用户空间），不支持；需要 amd64 或 arm64。" ;;
    esac
  fi
  export SYSTEM_ARCH SNOWLUMA_ARCH
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|armbian:*|*:debian*|*:ubuntu*) ;;
    *) die "当前安装器仅支持 Debian、Ubuntu、Armbian 及其 systemd 衍生版。" ;;
  esac
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_installable() {
  apt-get install -s -y --no-install-recommends "$1" >/dev/null 2>&1
}

install_packages() {
  local missing=() resolved=() package
  for package in "$@"; do
    # Debian 13 / Ubuntu 24.04 renamed several libraries with a t64 suffix;
    # treat either name as satisfying the dependency.
    package_installed "$package" || package_installed "${package}t64" || missing+=("$package")
  done
  ((${#missing[@]} == 0)) && return 0
  info "安装系统依赖：${missing[*]}"
  apt-get update
  for package in "${missing[@]}"; do
    if apt_installable "$package"; then
      resolved+=("$package")
    elif apt_installable "${package}t64"; then
      info "使用 ${package}t64 替代 ${package}（time_t 过渡包名）"
      resolved+=("${package}t64")
    else
      # Keep the original name so apt reports the real error.
      resolved+=("$package")
    fi
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${resolved[@]}"
}

require_commands() {
  local missing=() name
  for name in "$@"; do
    command -v "$name" >/dev/null 2>&1 || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "Installed dependencies are missing commands: ${missing[*]}"
}
curl_args() {
  CURL_ARGS=(--fail --location --retry 3 --retry-delay 2 --connect-timeout 20)
}

download() {
  local url=$1 output=$2
  curl_args
  info "下载：$url"
  curl "${CURL_ARGS[@]}" --output "$output" "$url"
}

mirrored_github_url() {
  # 加速站只代理下载类地址（release 资产、archive、raw），API 不适用。
  local prefix=${1%/} url=$2
  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*|https://codeload.github.com/*)
      printf '%s/%s\n' "$prefix" "$url" ;;
    *) return 1 ;;
  esac
}

github_fetch() {
  # Always download into a file: emitting a partial proxy response to stdout
  # and then retrying directly would concatenate two bodies.
  local url=$1 output=${2:-} temp= rc=1 mirror mirror_url auth=()
  curl_args
  if [[ -z "$output" ]]; then
    temp=$(mktemp)
    output=$temp
  fi
  # 有令牌就带上：匿名 API 每小时每 IP 仅 60 次，认证后是 5000 次。
  # 只对 api.github.com 使用，避免把令牌发给第三方加速站。
  if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
    auth=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  if [[ "$GITHUB_ACCESS" != direct && -n "$GITHUB_PROXY" ]]; then
    info "Trying GitHub through proxy: $url" >&2
    if curl "${CURL_ARGS[@]}" "${auth[@]}" --output "$output" --proxy "$GITHUB_PROXY" "$url"; then
      rc=0
    else
      warn "GitHub proxy failed."
    fi
  fi

  # 代理不可用时先走国内加速站，再直连。
  if ((rc != 0)) && [[ "$GITHUB_ACCESS" != proxy && -n "$GITHUB_MIRRORS" ]]; then
    local IFS=,
    for mirror in $GITHUB_MIRRORS; do
      [[ -n "$mirror" ]] || continue
      mirror_url=$(mirrored_github_url "$mirror" "$url") || continue
      info "Trying GitHub mirror: $mirror_url" >&2
      if curl "${CURL_ARGS[@]}" --output "$output" "$mirror_url"; then
        rc=0
        break
      fi
    done
    unset IFS
  fi

  if ((rc != 0)) && [[ "$GITHUB_ACCESS" != proxy ]]; then
    info "Trying GitHub directly: $url" >&2
    if curl "${CURL_ARGS[@]}" "${auth[@]}" --output "$output" "$url"; then
      rc=0
    fi
  fi

  if [[ -n "$temp" ]]; then
    ((rc != 0)) || cat "$temp"
    rm -f "$temp"
  fi
  return "$rc"
}

github_download() {
  github_fetch "$1" "$2"
}

github_latest_json() {
  local repo=$1
  github_fetch "https://api.github.com/repos/${repo}/releases/latest"
}

github_latest_tag() {
  local repo=$1 json tag
  json=$(github_latest_json "$repo") || json=
  tag=$(jq -er '.tag_name' <<<"$json" 2>/dev/null) && { printf '%s\n' "$tag"; return 0; }
  # 匿名调用 GitHub API 每小时每 IP 只有 60 次，共用出口 IP 或频繁重装很容易
  # 触顶，返回 403 且响应体是 rate limit 提示。直接报「读不到版本」会让用户
  # 以为是自己网络坏了。
  # curl --fail 会在 403 时丢弃响应体，所以单独取一次错误内容来判别原因。
  if [[ -z "$json" ]] && [[ "$GITHUB_ACCESS" != proxy ]]; then
    json=$(curl -sS --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)
  fi
  if grep -qi 'rate limit\|API rate' <<<"$json" 2>/dev/null; then
    warn "GitHub API 触发限流（匿名每小时 60 次）。"
    warn "可等一小时后重试，或设置 GITHUB_TOKEN 环境变量提高配额："
    warn "  sudo GITHUB_TOKEN=你的令牌 nbot install-astrbot"
  fi
  die "无法读取 ${repo} 最新版本。"
}

github_asset_url() {
  local repo=$1 pattern=$2 json
  json=$(github_latest_json "$repo")
  jq -er --arg pattern "$pattern" '.assets[] | select(.name | test($pattern)) | .browser_download_url' <<<"$json" | head -n1
}

git_args() {
  GIT_ARGS=()
  [[ "$GITHUB_ACCESS" != direct && -n "$GITHUB_PROXY" ]] && GIT_ARGS=(-c "http.proxy=$GITHUB_PROXY" -c "https.proxy=$GITHUB_PROXY")
}

nbot_interactive() {
  # NBOT_FORCE_PROMPT=1 供测试用管道喂输入；NBOT_NONINTERACTIVE=1 强制静默。
  [[ "${NBOT_NONINTERACTIVE:-0}" != 1 ]] || return 1
  [[ "${NBOT_FORCE_PROMPT:-0}" != 1 ]] || return 0
  [[ -t 0 ]]
}

detect_network_region() {
  # 用实测连通性判断，而不是猜时区：能快速直连 GitHub 就按海外处理。
  # 结果写回配置，后续运行不再重复探测。
  [[ "$NETWORK_REGION" == auto ]] || return 0
  # 非交互运行（CI、cloud-init、管道）不探测也不提问：保留镜像默认值，
  # 需要覆盖的用环境变量或直接写 /etc/nbot.conf。
  if ! nbot_interactive; then
    NETWORK_REGION=cn
    export NETWORK_REGION
    return 0
  fi
  info "正在探测网络环境（约需 10 秒）..."
  if curl -fsS --max-time 6 -o /dev/null https://api.github.com/ 2>/dev/null &&
     curl -fsS --max-time 6 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then
    NETWORK_REGION=global
    info "检测到可直连 GitHub 与 PyPI，按海外网络配置（默认直连，不用镜像）。"
    GITHUB_MIRRORS=
    PIP_INDEX_URL=
    PIP_TRUSTED_HOST=
    SNOWLUMA_IMAGE_MIRROR=
    SNOWLUMA_IMAGE_FALLBACK_MIRROR=
  else
    NETWORK_REGION=cn
    info "直连 GitHub/PyPI 不通，按国内网络配置（默认启用镜像加速）。"
  fi
  export NETWORK_REGION
}

pick_option() {
  # 编号选择：pick_option 变量名 "提示" 当前值 候选数组名
  # 候选格式 "显示名|值"，另外总是提供「自定义填写」与「保持当前」。
  local __name=$1 message=$2 current=$3 arr_name=$4
  local -n choices=$arr_name
  local i label value custom_index keep_index answer
  # 非交互运行保持当前值，不提问。
  if ! nbot_interactive; then
    printf -v "$__name" '%s' "$current"
    return 0
  fi
  bold "$message"
  for i in "${!choices[@]}"; do
    label=${choices[$i]%%|*}
    value=${choices[$i]#*|}
    if [[ "$value" == "$current" ]]; then
      printf '  %d) %s  <- 当前\n' "$((i + 1))" "$label"
    else
      printf '  %d) %s\n' "$((i + 1))" "$label"
    fi
  done
  custom_index=$(( ${#choices[@]} + 1 ))
  keep_index=$(( ${#choices[@]} + 2 ))
  printf '  %d) 自定义填写\n' "$custom_index"
  printf '  %d) 保持当前值（%s）\n' "$keep_index" "${current:-空}"
  while :; do
    read -r -p "请选择 [${keep_index}]: " answer
    answer=${answer:-$keep_index}
    if [[ "$answer" == "$keep_index" ]]; then
      return 0
    elif [[ "$answer" == "$custom_index" ]]; then
      read -r -p '请输入自定义值（留空表示不使用）: ' value
      printf -v "$__name" '%s' "$value"
      return 0
    elif [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#choices[@]})); then
      value=${choices[$((answer - 1))]#*|}
      printf -v "$__name" '%s' "$value"
      return 0
    fi
    warn "请输入 1-${keep_index} 之间的编号。"
  done
}

host_of_url() {
  local url=${1#*://}
  printf '%s\n' "${url%%/*}"
}

prompt_default() {
  # Enter keeps the default; a single "-" clears the value entirely.
  local __name=$1 message=$2 default=$3 value
  if ! nbot_interactive; then
    printf -v "$__name" '%s' "$default"
    return 0
  fi
  read -r -p "$message [$default]: " value
  if [[ "$value" == - ]]; then
    printf -v "$__name" ''
    return 0
  fi
  printf -v "$__name" '%s' "${value:-$default}"
}

prompt_port() {
  local __name=$1 message=$2 default=$3 value
  if ! nbot_interactive; then
    printf -v "$__name" '%s' "$default"
    return 0
  fi
  while :; do
    read -r -p "$message [$default]: " value
    value=${value:-$default}
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 65535)); then
      break
    fi
    warn "端口需为 1-65535 之间的数字。"
  done
  printf -v "$__name" '%s' "$value"
}

confirm() {
  local message=$1 default=${2:-N} answer suffix='[y/N]'
  if ! nbot_interactive; then
    [[ "$default" == Y ]]
    return
  fi
  [[ "$default" == Y ]] && suffix='[Y/n]'
  read -r -p "$message $suffix " answer
  answer=${answer:-$default}
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

write_config() {
  local tmp
  tmp=$(mktemp)
  {
    printf 'NBOT_HOME=%q\n' "$NBOT_HOME"
    printf 'ASTRBOT_ROOT=%q\n' "$ASTRBOT_ROOT"
    printf 'SNOWLUMA_ROOT=%q\n' "$SNOWLUMA_ROOT"
    printf 'ASTRBOT_PORT=%q\n' "$ASTRBOT_PORT"
    printf 'ASTRBOT_WS_PORT=%q\n' "$ASTRBOT_WS_PORT"
    printf 'SNOWLUMA_WEBUI_PORT=%q\n' "$SNOWLUMA_WEBUI_PORT"
    printf 'ONEBOT_HTTP_PORT=%q\n' "$ONEBOT_HTTP_PORT"
    printf 'GITHUB_PROXY=%q\n' "$GITHUB_PROXY"
    printf 'GITHUB_ACCESS=%q\n' "$GITHUB_ACCESS"
    printf 'NETWORK_REGION=%q\n' "$NETWORK_REGION"
    printf 'GITHUB_MIRRORS=%q\n' "$GITHUB_MIRRORS"
    printf 'PIP_INDEX_URL=%q\n' "$PIP_INDEX_URL"
    printf 'PIP_TRUSTED_HOST=%q\n' "$PIP_TRUSTED_HOST"
    printf 'SNOWLUMA_IMAGE=%q\n' "$SNOWLUMA_IMAGE"
    printf 'SNOWLUMA_IMAGE_MIRROR=%q\n' "$SNOWLUMA_IMAGE_MIRROR"
    printf 'SNOWLUMA_IMAGE_FALLBACK_MIRROR=%q\n' "$SNOWLUMA_IMAGE_FALLBACK_MIRROR"
    printf 'SNOWLUMA_IMAGE_PROXY=%q\n' "$SNOWLUMA_IMAGE_PROXY"
    printf 'SNOWLUMA_PAYLOAD_ROOT=%q\n' "$SNOWLUMA_PAYLOAD_ROOT"
    printf 'NOVNC_PORT=%q\n' "$NOVNC_PORT"
    printf 'NOVNC_VNC_PORT=%q\n' "$NOVNC_VNC_PORT"
    printf 'JOURNALD_MAX_USE=%q\n' "$JOURNALD_MAX_USE"
    printf 'CADDY_DOMAIN=%q\n' "$CADDY_DOMAIN"
    printf 'CADDY_HTTPS_PORT=%q\n' "$CADDY_HTTPS_PORT"
    printf 'CADDY_AUTH_USER=%q\n' "$CADDY_AUTH_USER"
    printf 'QQ_UIN=%q\n' "$QQ_UIN"
  } > "$tmp"
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    # Unprivileged runs (tests) cannot chown; keep the file private.
    install -m 0600 "$tmp" "$CONFIG_FILE"
  elif getent group snowluma >/dev/null 2>&1; then
    install -o root -g snowluma -m 0640 "$tmp" "$CONFIG_FILE"
  else
    install -o root -g root -m 0600 "$tmp" "$CONFIG_FILE"
  fi
  rm -f "$tmp"
}

find_python() {
  local candidate version
  for candidate in "${PYTHON_BIN:-}" "$ASTRBOT_ROOT/.python/bin/python3" python3.14 python3.13 python3.12 python3; do
    [[ -n "$candidate" ]] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    version=$($candidate -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if awk -v v="$version" 'BEGIN { split(v,a,"."); exit !((a[1] > 3) || (a[1] == 3 && a[2] >= 12)) }'; then
      PYTHON_BIN=$(command -v "$candidate")
      export PYTHON_BIN
      return 0
    fi
  done
  return 1
}

migrate_legacy_layout() {
  # 1.7 之前叫 bot-stack：配置在 /etc/bot-stack.conf，运行时脚本在
  # /usr/local/lib/bot-stack，单元名前缀 bot-stack-。数据目录保持原样
  # （配置里已记录绝对路径），只搬迁安装器自身的文件与命名。
  [[ ${NBOT_LEGACY_FOUND:-0} == 1 ]] || return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
  info "检测到旧版 bot-stack 安装，正在迁移到 nbot 命名。"
  systemctl stop bot-stack-logclean.timer 2>/dev/null || true
  systemctl disable bot-stack-logclean.timer 2>/dev/null || true
  rm -f /etc/systemd/system/bot-stack-logclean.timer \
        /etc/systemd/system/bot-stack-logclean.service \
        /etc/logrotate.d/bot-stack
  if [[ -f /etc/systemd/journald.conf.d/bot-stack.conf ]]; then
    mv -f /etc/systemd/journald.conf.d/bot-stack.conf \
          /etc/systemd/journald.conf.d/nbot.conf
  fi
  write_config
  rm -f "$LEGACY_CONFIG"
  info "迁移完成：配置现在位于 $CONFIG_FILE，数据目录未改动。"
  info "旧的 systemd 单元会在本次安装/修复中以 nbot 命名重新写入。"
  NBOT_LEGACY_FOUND=0
}

write_logrotate_config() {
  # 按大小 + 天数轮转应用自有日志文件；journald 部分由 SystemMaxUse 兜底。
  # snowluma 用户还不存在时（仅装 AstrBot）跳过对应段，避免 logrotate 报错。
  {
    if id snowluma >/dev/null 2>&1; then
      cat <<EOF
${SNOWLUMA_ROOT}/logs/*.log {
    su snowluma snowluma
    daily
    rotate 7
    maxsize 20M
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    fi
    cat <<EOF
${ASTRBOT_ROOT}/data/logs/*.log {
    daily
    rotate 7
    maxsize 20M
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  } > /etc/logrotate.d/nbot
  chmod 0644 /etc/logrotate.d/nbot
}

write_journald_limit() {
  local dropin=/etc/systemd/journald.conf.d/nbot.conf content
  [[ -n "$JOURNALD_MAX_USE" ]] || return 0
  content="[Journal]
SystemMaxUse=${JOURNALD_MAX_USE}"
  if [[ ! -f "$dropin" ]] || [[ $(<"$dropin") != "$content" ]]; then
    mkdir -p /etc/systemd/journald.conf.d
    printf '%s\n' "$content" > "$dropin"
    systemctl restart systemd-journald 2>/dev/null || true
    info "journald 总量上限已设置为 ${JOURNALD_MAX_USE}。"
  fi
}

wait_http() {
  local url=$1 attempts=${2:-30}
  while ((attempts-- > 0)); do
    curl -fsS --max-time 3 -o /dev/null "$url" && return 0
    sleep 2
  done
  return 1
}
