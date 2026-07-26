#!/usr/bin/env bash
# 证明自定义镜像不妨碍自动化：环境变量与配置文件两条无人值守通道。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 通道一：环境变量覆盖，全程零提问（stdin 关闭也不阻塞）。
out=$(
  NBOT_CONFIG="$tmp/nbot.conf" \
  NBOT_NONINTERACTIVE=1 \
  PIP_INDEX_URL=https://pypi.example.internal/simple \
  GITHUB_MIRRORS=https://mirror.example.internal \
  SNOWLUMA_IMAGE_MIRROR=registry.example.internal \
  bash -c '
    source "'"$ROOT"'/lib/common.sh"
    detect_network_region
    pick_option PIP_INDEX_URL "pip" "$PIP_INDEX_URL" PIP_MIRROR_CHOICES
    prompt_default SNOWLUMA_IMAGE "image" "$SNOWLUMA_IMAGE"
    prompt_port ASTRBOT_PORT "port" "$ASTRBOT_PORT"
    confirm "should be false by default" && echo "CONFIRM_Y" || echo "CONFIRM_N"
    confirm "should be true when default Y" Y && echo "CONFIRM_Y2" || echo "CONFIRM_N2"
    write_config
    printf "%s|%s|%s|%s\n" "$PIP_INDEX_URL" "$GITHUB_MIRRORS" "$SNOWLUMA_IMAGE_MIRROR" "$ASTRBOT_PORT"
  ' < /dev/null
)
grep -q CONFIRM_N <<<"$out"
grep -q CONFIRM_Y2 <<<"$out"
grep -q 'https://pypi.example.internal/simple|https://mirror.example.internal|registry.example.internal|6185' <<<"$out"

# 自定义值必须落盘，后续运行才能沿用。
grep -q "PIP_INDEX_URL=https://pypi.example.internal/simple" "$tmp/nbot.conf"
grep -q "GITHUB_MIRRORS=https://mirror.example.internal" "$tmp/nbot.conf"
grep -q "SNOWLUMA_IMAGE_MIRROR=registry.example.internal" "$tmp/nbot.conf"

# 通道二：直接写配置文件，重新载入后生效（无需环境变量）。
cat > "$tmp/hand.conf" <<'EOF'
PIP_INDEX_URL=https://hand.example.internal/simple
PIP_TRUSTED_HOST=hand.example.internal
GITHUB_MIRRORS=
EOF
result=$(NBOT_CONFIG="$tmp/hand.conf" bash -c '
  source "'"$ROOT"'/lib/common.sh"
  printf "%s|%s|%s\n" "$PIP_INDEX_URL" "$PIP_TRUSTED_HOST" "${GITHUB_MIRRORS:-EMPTY}"
' < /dev/null)
[[ "$result" == 'https://hand.example.internal/simple|hand.example.internal|EMPTY' ]]

# 非交互下不做网络探测（否则 CI 每次白等十几秒）。
region=$(NBOT_CONFIG=/nonexistent NBOT_NONINTERACTIVE=1 bash -c '
  source "'"$ROOT"'/lib/common.sh"
  detect_network_region
  echo "$NETWORK_REGION"
' < /dev/null)
[[ "$region" == cn ]]

echo 'Non-interactive automation checks passed.'
