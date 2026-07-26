#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE=${BOT_STACK_CONFIG:-/etc/bot-stack.conf}
# 统一工作区：三个组件按名字放在同一目录下；旧安装的自定义路径
# 保存在配置文件里，不受新默认值影响。
BOT_STACK_HOME=${BOT_STACK_HOME:-/bot-stack}
ASTRBOT_ROOT=${ASTRBOT_ROOT:-${BOT_STACK_HOME}/astrbot}
SNOWLUMA_ROOT=${SNOWLUMA_ROOT:-${BOT_STACK_HOME}/snowluma}
ASTRBOT_PORT=${ASTRBOT_PORT:-6185}
ASTRBOT_WS_PORT=${ASTRBOT_WS_PORT:-6199}
SNOWLUMA_WEBUI_PORT=${SNOWLUMA_WEBUI_PORT:-5099}
ONEBOT_HTTP_PORT=${ONEBOT_HTTP_PORT:-3005}
GITHUB_PROXY=${GITHUB_PROXY:-}
GITHUB_ACCESS=${GITHUB_ACCESS:-auto}
SNOWLUMA_IMAGE=${SNOWLUMA_IMAGE:-motricseven7/snowluma:latest}
SNOWLUMA_IMAGE_MIRROR=${SNOWLUMA_IMAGE_MIRROR:-dockerproxy.net}
SNOWLUMA_IMAGE_FALLBACK_MIRROR=${SNOWLUMA_IMAGE_FALLBACK_MIRROR:-docker.1ms.run}
SNOWLUMA_IMAGE_PROXY=${SNOWLUMA_IMAGE_PROXY:-}
SNOWLUMA_PAYLOAD_ROOT=${SNOWLUMA_PAYLOAD_ROOT:-${BOT_STACK_HOME}/payload/snowluma}
NOVNC_PORT=${NOVNC_PORT:-6080}
NOVNC_VNC_PORT=${NOVNC_VNC_PORT:-5901}
CADDY_DOMAIN=${CADDY_DOMAIN:-}
CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT:-8443}
CADDY_AUTH_USER=${CADDY_AUTH_USER:-admin}
QQ_UIN=${QQ_UIN:-}

if [[ -r "$CONFIG_FILE" ]]; then
  # The installer owns this root-only file.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
  [[ -d /run/systemd/system ]] || die "当前系统不是 systemd，无法安装服务。"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) SYSTEM_ARCH=amd64; SNOWLUMA_ARCH=x64 ;;
    aarch64|arm64) SYSTEM_ARCH=arm64; SNOWLUMA_ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)。仅支持 amd64/x86_64 与 arm64/aarch64。" ;;
  esac
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

github_fetch() {
  # Always download into a file: emitting a partial proxy response to stdout
  # and then retrying directly would concatenate two bodies.
  local url=$1 output=${2:-} temp= rc=1
  curl_args
  if [[ -z "$output" ]]; then
    temp=$(mktemp)
    output=$temp
  fi

  if [[ "$GITHUB_ACCESS" != direct && -n "$GITHUB_PROXY" ]]; then
    info "Trying GitHub through proxy: $url" >&2
    if curl "${CURL_ARGS[@]}" --output "$output" --proxy "$GITHUB_PROXY" "$url"; then
      rc=0
    else
      warn "GitHub proxy failed."
    fi
  fi

  if ((rc != 0)) && [[ "$GITHUB_ACCESS" != proxy ]]; then
    info "Trying GitHub directly: $url" >&2
    if curl "${CURL_ARGS[@]}" --output "$output" "$url"; then
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
  local repo=$1 json
  json=$(github_latest_json "$repo")
  jq -er '.tag_name' <<<"$json" || die "无法读取 ${repo} 最新版本。"
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

prompt_default() {
  # Enter keeps the default; a single "-" clears the value entirely.
  local __name=$1 message=$2 default=$3 value
  read -r -p "$message [$default]: " value
  if [[ "$value" == - ]]; then
    printf -v "$__name" ''
    return 0
  fi
  printf -v "$__name" '%s' "${value:-$default}"
}

prompt_port() {
  local __name=$1 message=$2 default=$3 value
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
  [[ "$default" == Y ]] && suffix='[Y/n]'
  read -r -p "$message $suffix " answer
  answer=${answer:-$default}
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

write_config() {
  local tmp
  tmp=$(mktemp)
  {
    printf 'BOT_STACK_HOME=%q\n' "$BOT_STACK_HOME"
    printf 'ASTRBOT_ROOT=%q\n' "$ASTRBOT_ROOT"
    printf 'SNOWLUMA_ROOT=%q\n' "$SNOWLUMA_ROOT"
    printf 'ASTRBOT_PORT=%q\n' "$ASTRBOT_PORT"
    printf 'ASTRBOT_WS_PORT=%q\n' "$ASTRBOT_WS_PORT"
    printf 'SNOWLUMA_WEBUI_PORT=%q\n' "$SNOWLUMA_WEBUI_PORT"
    printf 'ONEBOT_HTTP_PORT=%q\n' "$ONEBOT_HTTP_PORT"
    printf 'GITHUB_PROXY=%q\n' "$GITHUB_PROXY"
    printf 'GITHUB_ACCESS=%q\n' "$GITHUB_ACCESS"
    printf 'SNOWLUMA_IMAGE=%q\n' "$SNOWLUMA_IMAGE"
    printf 'SNOWLUMA_IMAGE_MIRROR=%q\n' "$SNOWLUMA_IMAGE_MIRROR"
    printf 'SNOWLUMA_IMAGE_FALLBACK_MIRROR=%q\n' "$SNOWLUMA_IMAGE_FALLBACK_MIRROR"
    printf 'SNOWLUMA_IMAGE_PROXY=%q\n' "$SNOWLUMA_IMAGE_PROXY"
    printf 'SNOWLUMA_PAYLOAD_ROOT=%q\n' "$SNOWLUMA_PAYLOAD_ROOT"
    printf 'NOVNC_PORT=%q\n' "$NOVNC_PORT"
    printf 'NOVNC_VNC_PORT=%q\n' "$NOVNC_VNC_PORT"
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

wait_http() {
  local url=$1 attempts=${2:-30}
  while ((attempts-- > 0)); do
    curl -fsS --max-time 3 -o /dev/null "$url" && return 0
    sleep 2
  done
  return 1
}
