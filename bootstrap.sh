#!/usr/bin/env bash
# nbot 一键安装引导：拉取仓库并进入安装流程。
#   curl -fsSL https://raw.githubusercontent.com/zcazca1998/nbot/main/bootstrap.sh | sudo bash
# 环境变量：
#   NBOT_REPO_MIRRORS  逗号分隔的 GitHub 加速站，按序尝试（默认内置三个）
#   NBOT_BRANCH        分支，默认 main
#   NBOT_ARGS          传给安装器的参数，默认 install-all；设为 menu 进入菜单
set -Eeuo pipefail

REPO_PATH=zcazca1998/nbot
BRANCH=${NBOT_BRANCH:-main}
TARGET=/usr/local/lib/nbot/installer
MIRRORS=${NBOT_REPO_MIRRORS:-https://ghfast.top,https://gh-proxy.com,https://ghproxy.net}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：curl -fsSL ... | sudo bash"
[[ -d /run/systemd/system ]] || die "当前系统不是 systemd，无法安装服务。"
[[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  info "安装引导依赖：curl tar ca-certificates"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl tar ca-certificates
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="$work/nbot.tar.gz"
direct="https://codeload.github.com/${REPO_PATH}/tar.gz/refs/heads/${BRANCH}"

# 国内直连 GitHub 常年不通，先走加速站，最后直连。
downloaded=0
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
if ((downloaded == 0)); then
  info "尝试直连 GitHub"
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
# 通过 </dev/tty 恢复交互：管道执行时 stdin 是脚本本身。
if [[ -e /dev/tty ]]; then
  exec "$TARGET/install.sh" ${NBOT_ARGS:-install-all} </dev/tty
fi
warn "没有可用终端，改为静默安装全部组件（全部使用默认配置）。"
exec "$TARGET/install.sh" ${NBOT_ARGS:-install-all}
