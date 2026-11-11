#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/30-gui-rustdesk.sh
#
# HEAVY AND OPTIONAL. Installs a minimal XFCE desktop plus RustDesk so the hub
# can be looked at (and clicked in) from a phone or another computer when
# there is no monitor attached.
#
# The unattended-access password comes from RD_PASS (environment or
# /etc/hub/optional.env). It is not written by this kit - RustDesk stores it
# in its own configuration, which is on the unencrypted root filesystem.
#
set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

if [ -r /etc/hub/optional.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /etc/hub/optional.env
    set +a
fi

log "installing xfce4 and lightdm (this is a big download)"
apt-get update
apt-get install -y xfce4 xfce4-goodies lightdm dbus-x11

log "fetching the latest RustDesk release"
release_json="$(curl -fsSL --retry 3 https://api.github.com/repos/rustdesk/rustdesk/releases/latest)" \
    || die "could not query the RustDesk release API"

deb_url=""
if command -v jq >/dev/null 2>&1; then
    deb_url="$(printf '%s' "$release_json" | jq -r \
        '.assets[] | select(.name | test("\\.deb$")) | .browser_download_url' | head -1)"
else
    deb_url="$(printf '%s' "$release_json" | grep -o '"browser_download_url": *"[^"]*\.deb"' | head -1 | cut -d'"' -f4)"
fi
[ -n "$deb_url" ] && [ "$deb_url" != "null" ] || die "no .deb asset found in the latest release"

deb_file="/tmp/$(basename "$deb_url")"
log "downloading $deb_url"
curl -fL --retry 3 -o "$deb_file" "$deb_url" || die "download failed"
log "installing $deb_file"
apt-get install -y "$deb_file" || die "apt could not install the RustDesk package"
rm -f "$deb_file"

if [ -n "${RD_PASS:-}" ]; then
    log "configuring the RustDesk unattended-access password"
    # Only pass the flags this build actually supports.
    help_out="$(rustdesk --help 2>&1 || true)"
    args="--install"
    grep -q -- '--password' <<<"$help_out" && args="$args --password $RD_PASS"
    grep -q -- '--allow-linux-headless' <<<"$help_out" && args="$args --allow-linux-headless"
    grep -q -- '--service' <<<"$help_out" && args="$args --service"
    # shellcheck disable=SC2086
    rustdesk $args || warn_log "the rustdesk setup command failed - configure it from the GUI instead"
    log "rustdesk configured (password passed on the command line briefly - it is stored by rustdesk in its own config)"
else
    warn_log "RD_PASS not set - RustDesk is installed but unattended access is not configured"
fi

systemctl enable lightdm || warn_log "could not enable lightdm"

cat <<'EOF'

NOTES
  * RustDesk needs a display. Without a monitor it uses its own headless
    X server (x11vnc + virtual display) - that is what --allow-linux-headless
    enables.
  * The unattended-access password is stored by RustDesk itself on the
    unencrypted root filesystem. If that matters to you, use the vault and
    set it from there, or use Tailscale SSH instead of unattended access.
  * This module is heavy: xfce4 pulls in a lot of packages. If you only need
    a remote shell, skip it - SSH + Tailscale + mosh already cover that.

EOF
log "done"
