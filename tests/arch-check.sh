#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NBOT_CONFIG=/nonexistent
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

# 每个用例都必须同时声明内核架构与包架构：只覆盖 uname 的话，在真装了
# dpkg 的机器上会读到宿主机的真实架构，测试结果随环境漂移。
set_arch() {
  eval "uname() { echo '$1'; }"
  eval "dpkg() { [[ \"\${1:-}\" == --print-architecture ]] && echo '$2'; }"
}

# 一致的 64 位组合正常通过。
set_arch x86_64 amd64
detect_arch
[[ "$SYSTEM_ARCH:$SNOWLUMA_ARCH" == amd64:x64 ]]

set_arch aarch64 arm64
detect_arch
[[ "$SYSTEM_ARCH:$SNOWLUMA_ARCH" == arm64:arm64 ]]

# 32 位用户空间必须被拒绝：uname 报 aarch64 但 apt 只认 armhf 时，
# 拆出来的 64 位载荷根本跑不起来。
set_arch aarch64 armhf
if (detect_arch) 2>/dev/null; then
  echo '32 位用户空间未被拒绝' >&2
  exit 1
fi

set_arch x86_64 i386
if (detect_arch) 2>/dev/null; then
  echo 'i386 用户空间未被拒绝' >&2
  exit 1
fi

# 内核与包架构互相矛盾同样拒绝。
set_arch x86_64 arm64
if (detect_arch) 2>/dev/null; then
  echo '内核与包架构不一致未被拒绝' >&2
  exit 1
fi

set_arch aarch64 amd64
if (detect_arch) 2>/dev/null; then
  echo '内核与包架构不一致未被拒绝（arm 内核 + amd64 包）' >&2
  exit 1
fi

# 不支持的架构在读取包架构之前就被拒绝。
set_arch riscv64 riscv64
if (detect_arch) 2>/dev/null; then
  echo '不支持的架构未被拒绝' >&2
  exit 1
fi

echo 'Architecture mapping checks passed.'
