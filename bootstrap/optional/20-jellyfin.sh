#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/20-jellyfin.sh
#
# Installs Jellyfin NATIVELY from Jellyfin's own apt repository (no Docker),
# verifies the install script's SHA256 before running it, makes sure the
# hardware encoder tooling is present, and prints the manual steps for
# hardware transcoding.
#
# Jellyfin is NEVER updated automatically by this kit: updates are a manual
# decision so a new Jellyfin cannot break a working library overnight.
#
# CPU/GPU (measured on this machine, see the hardware facts dump):
#   Intel Core i5-7360U, 2 cores / 4 threads
#   Intel Iris Plus Graphics 640 (PCI device ID 0x5926)
# The i5-7360U is a Kaby Lake part - that is inferred from the model number,
# not from a field the machine reports.
# TODO(verify): Intel's specification lists Quick Sync Video for the i5-7360U,
#   but the Linux driver exposing it has not been checked on this machine.
#   Settle it with the vainfo output printed by this module, then transcode
#   one file in the Jellyfin UI.
#
set -euo pipefail

WORKDIR="/tmp/hub-jellyfin"
SCRIPT="install-debuntu.sh"
BASE="https://repo.jellyfin.org"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

install -d -m 0755 "$WORKDIR"
cd "$WORKDIR" || die "cannot enter $WORKDIR"

log "downloading $BASE/$SCRIPT"
curl -fsSL --retry 3 -o "$SCRIPT" "$BASE/$SCRIPT" || die "download failed"
curl -fsSL --retry 3 -o "$SCRIPT.sha256sum" "$BASE/$SCRIPT.sha256sum" || die "checksum download failed"

expected="$(awk '{print $1; exit}' "$SCRIPT.sha256sum")"
actual="$(sha256sum "$SCRIPT" | awk '{print $1}')"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    die "SHA256 MISMATCH for $SCRIPT
  expected: $expected
  actual  : $actual
Refusing to run the installer."
fi
log "SHA256 OK: $actual"

log "running the official Jellyfin install script"
bash "$SCRIPT" || die "the Jellyfin install script failed"

log "making sure a jellyfin-ffmpeg package is installed"
ffmpeg_pkg=""
for candidate in jellyfin-ffmpeg7 jellyfin-ffmpeg6 jellyfin-ffmpeg5 jellyfin-ffmpeg; do
    if apt-cache show "$candidate" >/dev/null 2>&1; then
        ffmpeg_pkg="$candidate"
        break
    fi
done
if [ -n "$ffmpeg_pkg" ]; then
    apt-get install -y "$ffmpeg_pkg" || warn_log "could not install $ffmpeg_pkg"
    log "jellyfin ffmpeg package: $ffmpeg_pkg"
else
    warn_log "no jellyfin-ffmpeg* package found - transcoding may be limited"
fi

if id jellyfin >/dev/null 2>&1; then
    usermod -aG render,video jellyfin
    log "added the jellyfin user to the render and video groups"
else
    warn_log "the jellyfin user does not exist yet"
fi

install -d -m 0755 -o root -g jellyfin /srv/media 2>/dev/null \
    || install -d -m 0755 /srv/media
log "/srv/media is ready (mode 0755)"

log "looking for vainfo"
vainfo_bin=""
for candidate in /usr/lib/jellyfin-ffmpeg/vainfo /usr/lib/jellyfin-ffmpeg-7/vainfo \
    /usr/lib/jellyfin-ffmpeg-6/vainfo /usr/lib/jellyfin-ffmpeg-5/vainfo; do
    if [ -x "$candidate" ]; then
        vainfo_bin="$candidate"
        break
    fi
done
if [ -z "$vainfo_bin" ] && command -v vainfo >/dev/null 2>&1; then
    vainfo_bin="$(command -v vainfo)"
fi
if [ -n "$vainfo_bin" ]; then
    log "vainfo: $vainfo_bin"
    "$vainfo_bin" 2>&1 | head -30 || warn_log "vainfo could not read the driver (it may need the render/video groups)"
else
    warn_log "vainfo not found - install intel-media-va-driver or intel-media-va-driver-non-free for VAAPI"
fi

systemctl enable --now jellyfin || warn_log "could not start the jellyfin service"

cat <<'EOF'

MANUAL HARDWARE TRANSCODING STEPS
  1. Check that /dev/dri/renderD128 exists:
       ls -l /dev/dri/renderD128
     If it is missing, the Intel driver did not bind. Check:
       dmesg | grep -iE 'i915|drm'
  2. Make sure the jellyfin user can use it:
       sudo usermod -aG render,video jellyfin
       sudo systemctl restart jellyfin
   3. In the Jellyfin web UI:
        Dashboard -> Playback -> Transcoding
        - Intel QSV: Intel's specification lists Quick Sync Video for this
          Kaby Lake part, and Jellyfin's QSV support starts at Skylake.
          TODO(verify): whether the QSV engine is exposed by the Linux driver
          on this machine - the vainfo output above answers it. If there is no
          QSV engine, use VAAPI instead.
        - VAAPI -> check "Use VAAPI" and point the device at /dev/dri/renderD128
   4. The VAAPI driver comes from the Ubuntu archive:
        sudo apt install intel-media-va-driver intel-media-va-driver-non-free
      (TODO(verify): which codecs the free driver exposes on this Iris Plus
       640 - the -non-free package adds the codecs that cannot be redistributed
       freely, so install it if a codec you need is missing)

MANUAL UPDATE COMMANDS (never automatic)
       sudo apt update
       sudo apt install --only-upgrade jellyfin jellyfin-web
       sudo systemctl restart jellyfin
  Check the installed version with:
       apt policy jellyfin

PRIVATE HTTPS OVER TAILSCALE
       sudo tailscale serve --bg 8096          # http://<host>.<tailnet>.ts.net
       sudo tailscale serve --bg https://localhost:8096
  `tailscale serve` stays inside your tailnet. NEVER use `tailscale funnel`:
  funnel publishes a service to the public internet.

EOF
log "done"
