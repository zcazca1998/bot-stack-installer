#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BOT_STACK_CONFIG="$tmp/bot-stack.conf"
source "$ROOT/lib/common.sh"

ASTRBOT_ROOT="$tmp/Astr Bot"
SNOWLUMA_ROOT="$tmp/Snow Luma"
SNOWLUMA_PAYLOAD_ROOT="$tmp/Payload Root"
GITHUB_ACCESS=auto
GITHUB_PROXY='socks5h://127.0.0.1:20170'
SNOWLUMA_IMAGE='motricseven7/snowluma:v1.12.9'
SNOWLUMA_IMAGE_MIRROR='dockerproxy.net'
SNOWLUMA_IMAGE_FALLBACK_MIRROR='docker.1ms.run'
SNOWLUMA_IMAGE_PROXY='socks5h://127.0.0.1:20170'
write_config
unset ASTRBOT_ROOT SNOWLUMA_ROOT SNOWLUMA_PAYLOAD_ROOT GITHUB_ACCESS GITHUB_PROXY
unset SNOWLUMA_IMAGE SNOWLUMA_IMAGE_MIRROR SNOWLUMA_IMAGE_FALLBACK_MIRROR SNOWLUMA_IMAGE_PROXY
source "$BOT_STACK_CONFIG"
[[ "$ASTRBOT_ROOT" == "$tmp/Astr Bot" ]]
[[ "$SNOWLUMA_ROOT" == "$tmp/Snow Luma" ]]
[[ "$SNOWLUMA_PAYLOAD_ROOT" == "$tmp/Payload Root" ]]
[[ "$GITHUB_ACCESS" == auto ]]
[[ "$GITHUB_PROXY" == 'socks5h://127.0.0.1:20170' ]]
[[ "$SNOWLUMA_IMAGE" == 'motricseven7/snowluma:v1.12.9' ]]
[[ "$SNOWLUMA_IMAGE_MIRROR" == 'dockerproxy.net' ]]
[[ "$SNOWLUMA_IMAGE_FALLBACK_MIRROR" == 'docker.1ms.run' ]]
[[ "$SNOWLUMA_IMAGE_PROXY" == 'socks5h://127.0.0.1:20170' ]]

mkdir "$tmp/release"
ln -sfn "$tmp/release" "$tmp/symlink-probe" 2>/dev/null || true
if [[ -L "$tmp/symlink-probe" ]]; then
  atomic_symlink "$tmp/release" "$tmp/current"
  [[ $(readlink -f "$tmp/current") == "$tmp/release" ]]
else
  echo 'Skipping atomic_symlink check: filesystem does not support symlinks.'
fi
echo 'Common helper checks passed.'
