#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
node=${NODE_BIN:-node}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data/config"
SNOWLUMA_ROOT=$tmp QQ_UIN=123456 ONEBOT_TOKEN=test-secret ONEBOT_HTTP_PORT=3005 ASTRBOT_WS_PORT=6199   "$node" "$ROOT/assets/bin/write-onebot-config"
"$node" "$ROOT/tests/assert-onebot-config.js" "$tmp/data/config/onebot_123456.json"
