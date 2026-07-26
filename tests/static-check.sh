#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find "$ROOT" -type f \( -name '*.sh' -o -path '*/assets/bin/*' \) ! -name write-onebot-config -print0)

if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/assets/bin/write-onebot-config"
fi

grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/nbot-astrbot.service"
grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/nbot-snowluma.service"
grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/nbot-qq.service"
grep -q '^User=snowluma$' "$ROOT/assets/systemd/nbot-snowluma.service"
grep -q '^User=snowluma$' "$ROOT/assets/systemd/nbot-qq.service"
! grep -R -q '^Restart=always$' "$ROOT/assets/systemd"
! grep -R -q -- '--no-sync' "$ROOT/assets/bin" "$ROOT/lib" "$ROOT/modules" "$ROOT/install.sh" "$ROOT/install-core.sh"
! grep -R -qE '(^|[[:space:]])docker([[:space:]]|$)' "$ROOT/modules" "$ROOT/assets/bin"
grep -q 'skopeo copy' "$ROOT/modules/snowluma.sh"
grep -q 'umoci unpack' "$ROOT/modules/snowluma.sh"
grep -q 'cap_sys_ptrace' "$ROOT/modules/snowluma.sh"
grep -q 'SNOWLUMA_PAYLOAD_ROOT/runtime/node' "$ROOT/assets/bin/snowluma-launch"
grep -q 'cols < 74 || lines < 40' "$ROOT/assets/bin/qqlogin"
! grep -q 'xvfb-run' "$ROOT/assets/bin/qq-launch"
! grep -q '^ExecStartPost=' "$ROOT/assets/systemd/nbot-qq.service"
grep -q 'qq-auto-login &$' "$ROOT/assets/bin/qq-launch"
# Login success must also be detected via the main window (login.enc lags).
grep -q 'main_window_visible' "$ROOT/assets/bin/qqlogin"
grep -q 'main_window_visible' "$ROOT/assets/bin/qq-auto-login"
# Quick-login clicks: visual button detection first, ratio fallback, focus
# and a real press/release so Electron accepts the synthetic event.
[[ -f "$ROOT/assets/bin/qq-find-login-button" ]]
grep -q 'qq-find-login-button' "$ROOT/assets/bin/qq-auto-login"
grep -q 'height \* 71 / 100' "$ROOT/assets/bin/qq-auto-login"
grep -q 'windowactivate' "$ROOT/assets/bin/qq-auto-login"
grep -q 'mousedown 1' "$ROOT/assets/bin/qq-auto-login"
grep -q '+ 90' "$ROOT/assets/bin/qq-auto-login"
! grep -q '160 328' "$ROOT/assets/bin/qq-auto-login"
grep -q 'imagemagick' "$ROOT/modules/snowluma.sh"
grep -q 'exec "$executable"' "$ROOT/assets/bin/qq-launch"
grep -q 'xvfb_ok' "$ROOT/assets/bin/snowluma-healthcheck"

grep -q 'require_commands curl jq skopeo' "$ROOT/modules/snowluma.sh"
grep -q 'verify_dynamic_dependencies' "$ROOT/modules/snowluma.sh"
grep -q 'Prefetching verified large image layer' "$ROOT/modules/snowluma.sh"
grep -q 'cp -aln.*cache/sha256' "$ROOT/modules/snowluma.sh"
grep -q 'prune_image_releases' "$ROOT/modules/snowluma.sh"
grep -q 'astrbot-prepare.*usr/local/lib/nbot/astrbot-prepare' "$ROOT/modules/astrbot.sh"
# astrbot.cli init prompts interactively; systemd has no stdin to answer with.
grep -q "printf 'y" "$ROOT/assets/bin/astrbot-prepare"
# Ubuntu 24.04 / Debian 13 renamed several libs with a t64 suffix.
grep -q 't64' "$ROOT/lib/common-base.sh"
# Unified workspace, one-shot install, and uninstall must exist.
grep -q 'NBOT_HOME' "$ROOT/lib/common-base.sh"
grep -q 'NBOT_HOME=%q' "$ROOT/lib/common-base.sh"
grep -q 'install_all()' "$ROOT/install-core.sh"
grep -q 'uninstall_stack()' "$ROOT/install-core.sh"
# Data deletion must require typing DELETE explicitly.
grep -q 'DELETE' "$ROOT/install-core.sh"

# Log limits: logrotate, daily pruning timer, optional journald cap, help.
grep -q 'logrotate.d/nbot' "$ROOT/lib/common-base.sh"
grep -q 'SystemMaxUse' "$ROOT/lib/common-base.sh"
[[ -f "$ROOT/assets/bin/nbot-logclean" ]]
[[ -f "$ROOT/assets/systemd/nbot-logclean.timer" ]]
grep -q 'nbot-logclean' "$ROOT/modules/snowluma.sh"
grep -q 'show_help()' "$ROOT/install-core.sh"
# Uninstall must remove the logrotate and journald drop-ins.
grep -q 'rm -f /etc/logrotate.d/nbot' "$ROOT/install-core.sh"
grep -q 'journald.conf.d/nbot.conf' "$ROOT/install-core.sh"

# Runtime scripts must survive a partial config file under set -u, and the
# entry point must normalize partial configs into a complete one.
grep -q 'ASTRBOT_PORT:=' "$ROOT/assets/bin/astrbot-prepare"
grep -q 'SNOWLUMA_WEBUI_PORT:=' "$ROOT/assets/bin/snowluma-launch"
grep -q '^write_config$' "$ROOT/install.sh"
# Never copy the git repository into the runtime location.
grep -q 'exclude=./.git' "$ROOT/install.sh"
grep -q 'exclude=./.git' "$ROOT/install-core.sh"

# nbot is the only command name; the legacy bot-stack entry point and runtime
# directory must be removed, and legacy installs must be migrated.
grep -q 'sbin/nbot <<' "$ROOT/install-core.sh"
grep -q 'rm -f /usr/local/sbin/bot-stack' "$ROOT/install-core.sh"
grep -q 'rm -rf /usr/local/lib/bot-stack' "$ROOT/install-core.sh"
grep -q 'migrate_legacy_layout' "$ROOT/install.sh"
grep -q 'migrate_legacy_layout()' "$ROOT/lib/common-base.sh"
grep -q 'NBOT_CONFIG:-/etc/nbot.conf' "$ROOT/lib/common-base.sh"
# No runtime script may still read the old config path or lib directory.
! grep -rq '/etc/bot-stack.conf' "$ROOT/assets" "$ROOT/modules" "$ROOT/lib"
! grep -rq '/usr/local/lib/bot-stack' "$ROOT/assets" "$ROOT/modules"

# install-all must offer QR login; nbot qqlogin must pass through.
grep -q '现在就扫码登录 QQ' "$ROOT/install-core.sh"
grep -q 'exec /usr/local/lib/nbot/qqlogin' "$ROOT/install-core.sh"
# Control commands are nbot subcommands; standalone ctl scripts are gone.
grep -q 'service_command()' "$ROOT/install-core.sh"
[[ ! -e "$ROOT/assets/bin/snowlumactl" ]]
[[ ! -e "$ROOT/assets/bin/astrbotctl" ]]
[[ ! -e "$ROOT/assets/bin/novncctl" ]]
# Every unit ships with the nbot- prefix.
for unit in "$ROOT"/assets/systemd/*.service "$ROOT"/assets/systemd/*.timer; do
  case "$(basename "$unit")" in
    nbot-*|caddy.service) ;;
    *) echo "Unit missing nbot- prefix: $unit" >&2; exit 1 ;;
  esac
done
# China-facing fallbacks: GitHub mirrors and a pip index with PyPI fallback.
grep -q 'GITHUB_MIRRORS' "$ROOT/lib/common-base.sh"
grep -q 'mirrored_github_url' "$ROOT/lib/common-base.sh"
grep -q 'PIP_INDEX_URL' "$ROOT/lib/common-base.sh"
grep -q 'index-url' "$ROOT/modules/astrbot.sh"
grep -q '回退官方 PyPI' "$ROOT/modules/astrbot.sh"
# One-line bootstrap installer, mirror-aware and region-aware.
[[ -f "$ROOT/bootstrap.sh" ]]
grep -q 'NBOT_ARGS:-install-all' "$ROOT/bootstrap.sh"
# /dev/tty may exist yet be unopenable (CI, containers, cron): probe by
# actually opening it, and fall back to a real unattended run.
grep -q 'exec 3</dev/tty' "$ROOT/bootstrap.sh"
grep -q 'NBOT_NONINTERACTIVE=1 "$TARGET/install.sh"' "$ROOT/bootstrap.sh"
! grep -q '\[\[ -e /dev/tty \]\]' "$ROOT/bootstrap.sh"
grep -q 'api.github.com' "$ROOT/bootstrap.sh"
grep -q 'gh-proxy.com' "$ROOT/bootstrap.sh"
grep -q 'NBOT_REPO:-' "$ROOT/bootstrap.sh"
# Preflight checks must happen before downloading anything.
grep -q 'uname -m' "$ROOT/bootstrap.sh"
grep -q 'dpkg --print-architecture' "$ROOT/bootstrap.sh"
grep -q 'command -v apt-get' "$ROOT/bootstrap.sh"
awk '/^case "\$\(uname -m\)"/ {arch=NR} /^downloaded=0/ {dl=NR} END {exit !(arch && dl && arch < dl)}'   "$ROOT/bootstrap.sh" || { echo 'bootstrap 架构检查必须在下载之前' >&2; exit 1; }
# A 64-bit kernel with a 32-bit userland must be rejected, not silently broken.
grep -q 'dpkg --print-architecture' "$ROOT/lib/common-base.sh"
# doctor reports dependencies, package arch and payload free space.
grep -q 'PKGARCH' "$ROOT/install-core.sh"
grep -q '6291456' "$ROOT/install-core.sh"
# The documented one-liner itself must be covered by CI.
grep -q 'bootstrap-e2e:' "$ROOT/.github/workflows/ci.yml"
grep -q 'curl -fsSL' "$ROOT/.github/workflows/ci.yml"
# Region detection plus numbered mirror menus with a custom-entry escape hatch.
grep -q 'detect_network_region()' "$ROOT/lib/common-base.sh"
grep -q 'pick_option()' "$ROOT/lib/common-base.sh"
grep -q 'detect_network_region' "$ROOT/install-core.sh"
grep -q 'PIP_MIRROR_CHOICES' "$ROOT/lib/common-base.sh"
grep -q 'pypi.tuna.tsinghua.edu.cn' "$ROOT/lib/common-base.sh"
grep -q 'mirrors.ustc.edu.cn' "$ROOT/lib/common-base.sh"
grep -q '自定义填写' "$ROOT/lib/common-base.sh"
grep -q 'NETWORK_REGION=%q' "$ROOT/lib/common-base.sh"
# Every prompt must degrade to its default when running unattended, so custom
# mirrors stay fully automatable via env vars or a hand-written config.
grep -q 'nbot_interactive()' "$ROOT/lib/common-base.sh"
for fn in prompt_default prompt_port confirm pick_option detect_network_region; do
  sed -n "/^${fn}() {/,/^}/p" "$ROOT/lib/common-base.sh" | grep -q 'nbot_interactive' ||
    { echo "$fn missing non-interactive guard" >&2; exit 1; }
done
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
grep -q '^User=snowluma$' "$ROOT/assets/systemd/nbot-vnc.service"
grep -q '^User=snowluma$' "$ROOT/assets/systemd/nbot-novnc.service"
grep -q -- '-localhost' "$ROOT/assets/bin/vnc-server-launch"
grep -q '127\.0\.0\.1:\${NOVNC_PORT}' "$ROOT/assets/bin/novnc-web-launch"
grep -q -- '--heartbeat' "$ROOT/assets/bin/novnc-web-launch"
grep -q 'PartOf=nbot-qq.service' "$ROOT/assets/systemd/nbot-vnc.service"
grep -q 'proxy_set_header Upgrade' "$ROOT/modules/novnc.sh"
grep -q 'handle_path /novnc/\*' "$ROOT/modules/novnc.sh"

# Caddy takeover: unprivileged unit, auth in front of noVNC, validated config.
grep -q '^User=caddy$' "$ROOT/assets/systemd/caddy.service"
grep -q 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$ROOT/assets/systemd/caddy.service"
grep -q '^Restart=on-abnormal$' "$ROOT/assets/systemd/caddy.service"
grep -q 'caddy validate' "$ROOT/modules/caddy.sh"
grep -q 'basic_auth /novnc/\*' "$ROOT/modules/caddy.sh"
# Credentials must be changeable after install, not just viewable.
grep -q 'set_vnc_password()' "$ROOT/modules/novnc.sh"
grep -q 'set_caddy_auth()' "$ROOT/modules/caddy.sh"
grep -q 'set-password)' "$ROOT/install-core.sh"
grep -q 'set-auth|set-password)' "$ROOT/install-core.sh"
# Reinstalling must not invalidate an existing VNC password.
grep -q '已有密码保持不变' "$ROOT/modules/novnc.sh"
# Access info must be a ready-to-open URL once Caddy fronts noVNC, and the
# SnowLuma token must be surfaced instead of leaving users to grep the journal.
grep -q 'show_novnc_access()' "$ROOT/modules/novnc.sh"
grep -q 'autoconnect=1' "$ROOT/modules/novnc.sh"
# One credential set only: with Caddy in front, x11vnc runs with -nopw so the
# user never juggles a second password for a loopback-only port.
grep -q 'nopw' "$ROOT/assets/bin/vnc-server-launch"
grep -q 'novnc_fronted_by_caddy()' "$ROOT/modules/novnc.sh"
grep -q 'show_novnc_access' "$ROOT/modules/caddy.sh"
grep -q 'show_snowluma_webui' "$ROOT/install-core.sh"
# Both WebUIs generate a random password on first start; never claim a fixed
# default and always offer an official reset path instead of editing hashes.
! grep -rq 'astrbot/astrbot' "$ROOT/README.md" "$ROOT/install-core.sh" "$ROOT/modules"
grep -q 'set_astrbot_password()' "$ROOT/modules/astrbot.sh"
grep -q 'ASTRBOT_RESET_DASHBOARD_PASSWORD' "$ROOT/modules/astrbot.sh"
grep -q 'set_snowluma_password()' "$ROOT/modules/snowluma.sh"
grep -q 'SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD' "$ROOT/modules/snowluma.sh"
grep -q 'show_astrbot_webui()' "$ROOT/modules/astrbot.sh"
grep -q 'set-password)' "$ROOT/install-core.sh"
grep -q 'reverse_proxy 127.0.0.1' "$ROOT/modules/caddy.sh"
# IP access sends no SNI; an explicit self-signed cert must be used.
grep -q 'novnc-selfsigned' "$ROOT/modules/caddy.sh"
echo 'Static checks passed.'
