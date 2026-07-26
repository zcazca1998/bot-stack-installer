#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/payload"
export TEST_STATE="$tmp/state" TEST_LOG="$tmp/log"
cat > "$tmp/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "$*" >> "$TEST_LOG"
[[ ${1:-} != inspect ]] || exit 1
count=0
[[ ! -r "$TEST_STATE" ]] || count=$(<"$TEST_STATE")
count=$((count + 1))
echo "$count" > "$TEST_STATE"
cache=
while (($#)); do
  [[ "$1" != --dest-shared-blob-dir ]] || { cache=$2; break; }
  shift
done
[[ -n "$cache" ]] || exit 20
mkdir -p "$cache"
if ((count == 1)); then
  touch "$cache/completed-blob"
  exit 1
fi
[[ -e "$cache/completed-blob" ]] || exit 21
exit 0
STUB
chmod +x "$tmp/bin/skopeo"
PATH="$tmp/bin:$PATH"
NBOT_CONFIG=/nonexistent
SNOWLUMA_PAYLOAD_ROOT="$tmp/payload"
SNOWLUMA_IMAGE=motricseven7/snowluma:latest
SNOWLUMA_IMAGE_MIRROR=dockerproxy.net
SNOWLUMA_IMAGE_FALLBACK_MIRROR=docker.1ms.run
SYSTEM_ARCH=amd64
source "$ROOT/lib/common.sh"
source "$ROOT/modules/snowluma.sh"
copy_snowluma_image "$tmp/oci"
[[ "$SNOWLUMA_RESOLVED_IMAGE" == docker.1ms.run/motricseven7/snowluma:latest ]]
[[ $(<"$TEST_STATE") == 2 ]]
grep -q 'docker://dockerproxy.net/motricseven7/snowluma:latest' "$TEST_LOG"
grep -q 'docker://docker.1ms.run/motricseven7/snowluma:latest' "$TEST_LOG"
echo 'Image fallback cache checks passed.'
