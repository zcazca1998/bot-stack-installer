#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find "$ROOT" -type f \( -name '*.sh' -o -path '*/assets/bin/*' \) ! -name write-onebot-config -print0)

if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/assets/bin/write-onebot-config"
fi

grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/astrbot.service"
grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/snowluma.service"
grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/snowluma-qq.service"
grep -q '^User=snowluma$' "$ROOT/assets/systemd/snowluma.service"
grep -q '^User=snowluma$' "$ROOT/assets/systemd/snowluma-qq.service"
! grep -R -q '^Restart=always$' "$ROOT/assets/systemd"
! grep -R -q -- '--no-sync' "$ROOT/assets/bin" "$ROOT/lib" "$ROOT/modules" "$ROOT/install.sh" "$ROOT/install-core.sh"
! grep -R -qE '(^|[[:space:]])docker([[:space:]]|$)' "$ROOT/modules" "$ROOT/assets/bin"
grep -q 'skopeo copy' "$ROOT/modules/snowluma.sh"
grep -q 'umoci unpack' "$ROOT/modules/snowluma.sh"
grep -q 'cap_sys_ptrace' "$ROOT/modules/snowluma.sh"
grep -q 'SNOWLUMA_PAYLOAD_ROOT/runtime/node' "$ROOT/assets/bin/snowluma-launch"
grep -q 'cols < 74 || lines < 40' "$ROOT/assets/bin/qqlogin"
! grep -q 'xvfb-run' "$ROOT/assets/bin/qq-launch"
! grep -q '^ExecStartPost=' "$ROOT/assets/systemd/snowluma-qq.service"
grep -q 'qq-auto-login &$' "$ROOT/assets/bin/qq-launch"
# Login success must also be detected via the main window (login.enc lags).
grep -q 'main_window_visible' "$ROOT/assets/bin/qqlogin"
grep -q 'main_window_visible' "$ROOT/assets/bin/qq-auto-login"
# Quick-login clicks must be proportional with a generous startup budget.
grep -q 'height \* 71 / 100' "$ROOT/assets/bin/qq-auto-login"
grep -q '+ 90' "$ROOT/assets/bin/qq-auto-login"
! grep -q '160 328' "$ROOT/assets/bin/qq-auto-login"
grep -q 'exec "$executable"' "$ROOT/assets/bin/qq-launch"
grep -q 'xvfb_ok' "$ROOT/assets/bin/snowluma-healthcheck"

grep -q 'require_commands curl jq skopeo' "$ROOT/modules/snowluma.sh"
grep -q 'verify_dynamic_dependencies' "$ROOT/modules/snowluma.sh"
grep -q 'Prefetching verified large image layer' "$ROOT/modules/snowluma.sh"
grep -q 'cp -aln.*cache/sha256' "$ROOT/modules/snowluma.sh"
grep -q 'prune_image_releases' "$ROOT/modules/snowluma.sh"
grep -q 'astrbot-prepare.*usr/local/lib/bot-stack/astrbot-prepare' "$ROOT/modules/astrbot.sh"
# astrbot.cli init prompts interactively; systemd has no stdin to answer with.
grep -q "printf 'y" "$ROOT/assets/bin/astrbot-prepare"
# Ubuntu 24.04 / Debian 13 renamed several libs with a t64 suffix.
grep -q 't64' "$ROOT/lib/common-base.sh"
# Unified workspace, one-shot install, and uninstall must exist.
grep -q 'BOT_STACK_HOME' "$ROOT/lib/common-base.sh"
grep -q 'BOT_STACK_HOME=%q' "$ROOT/lib/common-base.sh"
grep -q 'install_all()' "$ROOT/install-core.sh"
grep -q 'uninstall_stack()' "$ROOT/install-core.sh"
# Data deletion must require typing DELETE explicitly.
grep -q 'DELETE' "$ROOT/install-core.sh"

# Log limits: logrotate, daily pruning timer, optional journald cap, help.
grep -q 'logrotate.d/bot-stack' "$ROOT/lib/common-base.sh"
grep -q 'SystemMaxUse' "$ROOT/lib/common-base.sh"
[[ -f "$ROOT/assets/bin/bot-stack-logclean" ]]
[[ -f "$ROOT/assets/systemd/bot-stack-logclean.timer" ]]
grep -q 'bot-stack-logclean' "$ROOT/modules/snowluma.sh"
grep -q 'show_help()' "$ROOT/install-core.sh"
# Uninstall must remove the logrotate and journald drop-ins.
grep -q 'rm -f /etc/logrotate.d/bot-stack' "$ROOT/install-core.sh"
grep -q 'journald.conf.d/bot-stack.conf' "$ROOT/install-core.sh"

# Runtime scripts must survive a partial config file under set -u, and the
# entry point must normalize partial configs into a complete one.
grep -q 'ASTRBOT_PORT:=' "$ROOT/assets/bin/astrbot-prepare"
grep -q 'SNOWLUMA_WEBUI_PORT:=' "$ROOT/assets/bin/snowluma-launch"
grep -q '^write_config$' "$ROOT/install.sh"

# install-all must offer QR login; bot-stack qqlogin must pass through.
grep -q '现在就扫码登录 QQ' "$ROOT/install-core.sh"
grep -q 'qqlogin) exec /usr/local/bin/qqlogin' "$ROOT/install-core.sh"
# Every helper script must carry the executable bit in git (JS files are
# invoked via node and are exempt).
if [[ "$(uname -s)" == Linux ]]; then
  unexec=$( { find "$ROOT/assets/bin" -type f ! -name '*.js' ! -name 'write-onebot-config' ! -perm -u+x; find "$ROOT/tests" -name '*.sh' -type f ! -perm -u+x; } || true)
  [[ -z "$unexec" ]] || { echo "Missing exec bit: $unexec" >&2; exit 1; }
fi
grep -q 'python-build-standalone' "$ROOT/modules/astrbot.sh"
grep -q 'release_id=.*RANDOM' "$ROOT/modules/snowluma.sh"

# Signal traps must terminate qqlogin; a bare cleanup trap would let the
# refresh loop continue after Ctrl+C.
grep -q "trap 'exit 130' HUP INT TERM" "$ROOT/assets/bin/qqlogin"
# SnowLuma must tolerate slow QQ startup on low-end boards.
grep -q '{1\.\.600}' "$ROOT/assets/bin/snowluma-launch"
# SnowLuma starts in passive observation; it must never wait for QQ login.
[[ ! -e "$ROOT/assets/bin/wait-for-qq-login" ]]

# Kicked-account recovery: trust OneBot over login.enc, escalate to a
# state-clearing restart, and never cache Xvfb credentials across restarts.
grep -q -- '--fresh' "$ROOT/assets/bin/qqlogin"
grep -q 'qq-status --machine' "$ROOT/assets/bin/qqlogin"
grep -q 'expired.bak' "$ROOT/assets/bin/qqlogin"
grep -q 'resolve_display' "$ROOT/assets/bin/qqlogin"
# QQ runtime protection must not be gated behind SnowLuma being active.
grep -q 'does not depend on SnowLuma' "$ROOT/assets/bin/snowluma-healthcheck"
grep -q 'grace_time" =~ \^\[0-9\]' "$ROOT/assets/bin/snowluma-healthcheck"
grep -q 'grace_time" =~ \^\[0-9\]' "$ROOT/assets/bin/astrbot-healthcheck"

# noVNC stack: unprivileged, loopback-only, reverse-proxy friendly.
grep -q '^User=snowluma$' "$ROOT/assets/systemd/snowluma-vnc.service"
grep -q '^User=snowluma$' "$ROOT/assets/systemd/snowluma-novnc.service"
grep -q -- '-localhost' "$ROOT/assets/bin/vnc-server-launch"
grep -q '127\.0\.0\.1:\${NOVNC_PORT}' "$ROOT/assets/bin/novnc-web-launch"
grep -q -- '--heartbeat' "$ROOT/assets/bin/novnc-web-launch"
grep -q 'PartOf=snowluma-qq.service' "$ROOT/assets/systemd/snowluma-vnc.service"
grep -q 'proxy_set_header Upgrade' "$ROOT/modules/novnc.sh"
grep -q 'handle_path /novnc/\*' "$ROOT/modules/novnc.sh"

# Caddy takeover: unprivileged unit, auth in front of noVNC, validated config.
grep -q '^User=caddy$' "$ROOT/assets/systemd/caddy.service"
grep -q 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$ROOT/assets/systemd/caddy.service"
grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/caddy.service"
grep -q 'caddy validate' "$ROOT/modules/caddy.sh"
grep -q 'basic_auth /novnc/\*' "$ROOT/modules/caddy.sh"
grep -q 'reverse_proxy 127.0.0.1' "$ROOT/modules/caddy.sh"
# IP access sends no SNI; an explicit self-signed cert must be used.
grep -q 'novnc-selfsigned' "$ROOT/modules/caddy.sh"
echo 'Static checks passed.'
