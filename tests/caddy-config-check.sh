#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BOT_STACK_CONFIG=/nonexistent
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
[[ -f "$tmp/caddy/Caddyfile.bot-stack.bak" ]]

site="$tmp/caddy/conf.d/novnc.caddy"

# Self-signed port mode.
write_caddy_site ':8443' admin '$2a$14$abcdefghijklmnopqrstuv' $'    tls internal\n'
grep -q '^:8443 {$' "$site"
grep -q '^    tls internal$' "$site"
grep -qF 'admin $2a$14$abcdefghijklmnopqrstuv' "$site"
grep -q 'reverse_proxy 127.0.0.1:7080' "$site"
grep -q 'handle_path /novnc/\*' "$site"
grep -q 'basic_auth /novnc/\*' "$site"

# Domain mode: automatic HTTPS, no tls internal.
write_caddy_site 'bot.example.com' admin 'HASH' ''
grep -q '^bot.example.com {$' "$site"
! grep -q 'tls internal' "$site"

echo 'Caddy config generation checks passed.'
