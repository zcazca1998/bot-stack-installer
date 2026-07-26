#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOT_STACK_CONFIG=/nonexistent
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

uname() { echo x86_64; }
detect_arch
[[ "$SYSTEM_ARCH:$SNOWLUMA_ARCH" == amd64:x64 ]]

uname() { echo aarch64; }
detect_arch
[[ "$SYSTEM_ARCH:$SNOWLUMA_ARCH" == arm64:arm64 ]]

echo 'Architecture mapping checks passed.'
