#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NBOT_CONFIG=/nonexistent
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

uname() { echo x86_64; }
detect_arch
[[ "$SYSTEM_ARCH:$SNOWLUMA_ARCH" == amd64:x64 ]]

uname() { echo aarch64; }
detect_arch
[[ "$SYSTEM_ARCH:$SNOWLUMA_ARCH" == arm64:arm64 ]]

# 32 位用户空间必须被拒绝：uname 报 aarch64 但 apt 只认 armhf 时，
# 装出来的 64 位载荷根本跑不起来。
uname() { echo aarch64; }
dpkg() { [[ "${1:-}" == --print-architecture ]] && echo armhf; }
export -f dpkg 2>/dev/null || true
if (detect_arch) 2>/dev/null; then
  echo '32 位用户空间未被拒绝' >&2
  exit 1
fi

# 内核与包架构不一致同样拒绝。
uname() { echo x86_64; }
dpkg() { [[ "${1:-}" == --print-architecture ]] && echo arm64; }
if (detect_arch) 2>/dev/null; then
  echo '内核与包架构不一致未被拒绝' >&2
  exit 1
fi

# 一致时正常通过。
uname() { echo x86_64; }
dpkg() { [[ "${1:-}" == --print-architecture ]] && echo amd64; }
detect_arch
[[ "$SYSTEM_ARCH" == amd64 ]]

echo 'Architecture mapping checks passed.'
