#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOT_STACK_CONFIG=/nonexistent
source "$ROOT/lib/common.sh"
source "$ROOT/modules/snowluma.sh"
ref=$(mirrored_image_ref "$SNOWLUMA_IMAGE")
for arch in amd64 arm64; do
  actual=$(skopeo inspect --override-os linux --override-arch "$arch"     "docker://$ref" | jq -r '.Architecture')
  [[ "$actual" == "$arch" ]] || { echo "Missing $arch image in $ref" >&2; exit 1; }
  echo "$arch: $ref"
done
