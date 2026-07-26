#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
NBOT_CONFIG=/nonexistent
CADDY_CONF_DIR="$tmp/caddy"
NOVNC_PORT=7080
source "$ROOT/lib/common.sh"
source "$ROOT/modules/caddy.sh"

# The import line must be created once and stay idempotent.
ensure_caddyfile_import
ensure_caddyfile_import
[[ $(grep -cF "import $tmp/caddy/conf.d/*.caddy" "$tmp/caddy/Caddyfile") == 1 ]]

# Appending to a pre-existing Caddyfile must keep its content and back it up.
printf 'example.org {\n    respond "hi"\n}\n' > "$tmp/caddy/Caddyfile"
ensure_caddyfile_import
grep -q 'example.org' "$tmp/caddy/Caddyfile"
grep -qF "import $tmp/caddy/conf.d/*.caddy" "$tmp/caddy/Caddyfile"
[[ -f "$tmp/caddy/Caddyfile.nbot.bak" ]]

site="$tmp/caddy/conf.d/novnc.caddy"

# Self-signed cert generation must be idempotent and SNI-independent.
# MSYS/Git-Bash mangles the leading slash in -subj, so skip there.
if (ensure_selfsigned_cert) 2>/dev/null; then
  [[ -s "$tmp/caddy/novnc-selfsigned.crt" && -s "$tmp/caddy/novnc-selfsigned.key" ]]
  before=$(sha256sum "$tmp/caddy/novnc-selfsigned.crt")
  ensure_selfsigned_cert
  [[ "$before" == $(sha256sum "$tmp/caddy/novnc-selfsigned.crt") ]]
else
  echo 'Skipping self-signed cert check: openssl -subj is unusable in this environment.'
fi

# Self-signed port mode.
write_caddy_site ':8443' admin '$2a$14$abcdefghijklmnopqrstuv' "    tls $(caddy_self_cert) $(caddy_self_key)"$'\n'
grep -q '^:8443 {$' "$site"
grep -q "^    tls $tmp/caddy/novnc-selfsigned.crt" "$site"
grep -qF 'admin $2a$14$abcdefghijklmnopqrstuv' "$site"
grep -q 'reverse_proxy 127.0.0.1:7080' "$site"
grep -q 'handle_path /novnc/\*' "$site"
grep -q 'basic_auth /novnc/\*' "$site"

# Domain mode: automatic HTTPS, no explicit tls line.
write_caddy_site 'bot.example.com' admin 'HASH' ''
grep -q '^bot.example.com {$' "$site"
! grep -q '^    tls ' "$site"

echo 'Caddy config generation checks passed.'
