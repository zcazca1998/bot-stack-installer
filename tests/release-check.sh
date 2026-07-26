#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NBOT_CONFIG=/nonexistent
source "$ROOT/lib/common.sh"
source "$ROOT/modules/snowluma.sh"
detect_arch
direct=$(normalized_image_ref "$SNOWLUMA_IMAGE")
mirror=$(mirrored_image_ref "$SNOWLUMA_IMAGE")
fallback=$(image_ref_for_mirror "$SNOWLUMA_IMAGE" "$SNOWLUMA_IMAGE_FALLBACK_MIRROR")
[[ "$direct" == docker.io/motricseven7/snowluma:latest ]]
[[ "$mirror" == dockerproxy.net/motricseven7/snowluma:latest ]]
[[ "$fallback" == docker.1ms.run/motricseven7/snowluma:latest ]]
astrbot_tag=$(github_latest_tag AstrBotDevs/AstrBot)
[[ -n "$astrbot_tag" ]]
printf 'Architecture: %s\nImage: %s\nMirror: %s\nAstrBot: %s\n'   "$SYSTEM_ARCH" "$direct" "$mirror" "$astrbot_tag"
