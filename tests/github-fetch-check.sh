#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The proxy attempt writes a partial body and fails; the direct attempt
# succeeds. The caller must only ever observe the complete direct body.
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
out= proxy=0
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [[ ${args[$i]} == --output ]] && out=${args[$((i+1))]:-}
  [[ ${args[$i]} == --proxy ]] && proxy=1
done
[[ -n "$out" ]] || exit 20
if ((proxy)); then
  printf 'PARTIAL-GARBAGE' > "$out"
  exit 7
fi
printf '{"tag_name":"v9.9.9"}' > "$out"
STUB
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"

NBOT_CONFIG=/nonexistent
source "$ROOT/lib/common.sh"
GITHUB_ACCESS=auto
GITHUB_PROXY='socks5h://127.0.0.1:1'

json=$(github_fetch https://api.github.invalid/test)
[[ "$json" == '{"tag_name":"v9.9.9"}' ]]

github_fetch https://api.github.invalid/test "$tmp/asset.bin"
[[ $(<"$tmp/asset.bin") == '{"tag_name":"v9.9.9"}' ]]

# Proxy-only mode must fail instead of silently falling back to direct.
GITHUB_ACCESS=proxy
if github_fetch https://api.github.invalid/test >/dev/null; then
  echo 'proxy-only mode unexpectedly succeeded' >&2
  exit 1
fi

echo 'GitHub fetch fallback checks passed.'
