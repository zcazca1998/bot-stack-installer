#!/usr/bin/env bash
# nbot 一键安装引导：拉取仓库并进入安装流程。
#
# 国内（脚本本身也走加速站，推荐）：
#   curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zcazca1998/nbot-linux/main/bootstrap.sh | sudo bash
# 海外：
#   curl -fsSL https://raw.githubusercontent.com/zcazca1998/nbot-linux/main/bootstrap.sh | sudo bash
#
# 环境变量：
#   NBOT_REPO          仓库 owner/name，默认 zcazca1998/nbot-linux（fork 可覆盖）
#   NBOT_REPO_MIRRORS  逗号分隔的 GitHub 加速站，按序尝试（默认内置三个）
#   NBOT_REF           分支或 tag，默认 main。填 tag（如 v1.0.0）可装到确定的
#                      快照，便于复现安装或退回上个稳定版。
#   NBOT_BRANCH        NBOT_REF 的旧名，仍然支持
#   NBOT_ARGS          传给安装器的参数，默认 install-all；设为 menu 进入菜单
set -Eeuo pipefail

REPO_PATH=${NBOT_REPO:-zcazca1998/nbot-linux}
REF=${NBOT_REF:-${NBOT_BRANCH:-main}}
TARGET=/usr/local/lib/nbot/installer
MIRRORS=${NBOT_REPO_MIRRORS:-https://gh-proxy.com,https://ghfast.top,https://ghproxy.net}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# 前置检查放在下载之前：不合要求的机器不该先装依赖、拉完源码才报错。
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：curl -fsSL ... | sudo bash"
[[ -d /run/systemd/system ]] || die "当前系统不是 systemd，无法安装服务。"
[[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) die "不支持的架构：$(uname -m)。仅支持 amd64/x86_64 与 arm64/aarch64。" ;;
esac

# 64 位内核 + 32 位用户空间（部分旧 Armbian）装不了 arm64 包。
if command -v dpkg >/dev/null 2>&1; then
  case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64|arm64) ;;
    '') ;;
    *) die "系统包架构为 $(dpkg --print-architecture)，与 64 位运行时不兼容。" ;;
  esac
fi

# shellcheck disable=SC1091
if ! (source /etc/os-release; case "${ID:-}:${ID_LIKE:-}" in
        debian:*|ubuntu:*|armbian:*|*:debian*|*:ubuntu*) exit 0 ;;
        *) exit 1 ;;
      esac); then
  die "仅支持 Debian、Ubuntu、Armbian 及其衍生版（需要 apt）。"
fi
command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，当前发行版不受支持。"

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  info "安装引导依赖：curl tar ca-certificates"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl tar ca-certificates
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="$work/nbot.tar.gz"
# tag 在 refs/tags 下，分支在 refs/heads 下；用不带前缀的形式让 GitHub
# 自己解析，这样 NBOT_REF 既能填分支也能填 tag 或提交号。
direct="https://codeload.github.com/${REPO_PATH}/tar.gz/${REF}"

downloaded=0
# 先探测能否快速直连 GitHub：海外机器直接下载，不必绕加速站。
if curl -fsS --max-time 6 -o /dev/null https://api.github.com/ 2>/dev/null; then
  info "可直连 GitHub，直接下载源码。"
  if curl -fsSL --connect-timeout 15 --retry 2 -o "$archive" "$direct"; then
    downloaded=1
  fi
fi

# 国内直连常年不通：逐个加速站尝试，最后再赌一次直连。
if ((downloaded == 0)); then
  IFS=,
  for mirror in $MIRRORS; do
    [[ -n "$mirror" ]] || continue
    unset IFS
    info "尝试加速站：${mirror%/}"
    if curl -fsSL --connect-timeout 15 --retry 2 -o "$archive" "${mirror%/}/$direct"; then
      downloaded=1
      break
    fi
    warn "加速站不可用：${mirror%/}"
    IFS=,
  done
  unset IFS
fi
if ((downloaded == 0)); then
  info "最后尝试直连 GitHub"
  curl -fsSL --connect-timeout 20 --retry 2 -o "$archive" "$direct" ||
    die "无法下载 nbot 源码。请检查网络，或手动 git clone 后执行 sudo ./install.sh"
fi

mkdir -p "$work/src"
tar -xzf "$archive" --strip-components=1 -C "$work/src"
[[ -x "$work/src/install.sh" || -f "$work/src/install.sh" ]] ||
  die "下载的压缩包缺少 install.sh。"

rm -rf "$TARGET"
mkdir -p "$TARGET"
tar -C "$work/src" -cf - . | tar -C "$TARGET" -xf -
chmod 0755 "$TARGET/install.sh"

info "源码已就绪：$TARGET"
# 管道执行时 stdin 是脚本本身，需要 </dev/tty 才能提问。/dev/tty 在
# CI、容器和 cron 里可能存在却打不开，所以必须实际尝试打开而不是判断节点。
if [[ "${NBOT_NONINTERACTIVE:-0}" != 1 ]] && (exec 3</dev/tty) 2>/dev/null; then
  exec "$TARGET/install.sh" ${NBOT_ARGS:-install-all} </dev/tty
fi
info "没有可用终端，改为无人值守安装（全部使用默认值或已有配置）。"
exec env NBOT_NONINTERACTIVE=1 "$TARGET/install.sh" ${NBOT_ARGS:-install-all} </dev/null
