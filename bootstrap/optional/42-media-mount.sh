#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/42-media-mount.sh
#
# Adds an external media disk to /etc/fstab by UUID.
#
#     sudo bash 42-media-mount.sh <UUID>
#
# The UUID is verified with blkid before anything is written. The fstab entry
# uses "nofail" and a short device timeout, so a disk that is not attached
# NEVER blocks the boot.
#
set -euo pipefail

UUID="${1:-}"
FSTAB="/etc/fstab"
MOUNTPOINT="/srv/media"
FS_TYPE="ext4"
FSTAB_LINE="UUID=${UUID} ${MOUNTPOINT} ${FS_TYPE} defaults,nofail,noatime,x-systemd.device-timeout=5 0 2"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

[ -n "$UUID" ] || die "usage: sudo bash $0 <UUID>   (find it with: blkid)"

log "looking up $UUID"
info="$(blkid -U "$UUID" 2>/dev/null || true)"
if [ -z "$info" ]; then
    die "no device with UUID $UUID found - attach the disk and check 'sudo blkid'"
fi
log "device: $info"

actual_type="$(blkid -o value -s TYPE "$info" 2>/dev/null || true)"
if [ -n "$actual_type" ] && [ "$actual_type" != "$FS_TYPE" ]; then
    warn_log "the filesystem on $info is '$actual_type', not '$FS_TYPE'"
    warn_log "the fstab entry will still say $FS_TYPE - fix it by hand if the mount fails"
fi

install -d -m 0755 "$MOUNTPOINT"

if grep -qE "^UUID=${UUID}[[:space:]]" "$FSTAB"; then
    log "an entry for $UUID already exists - rewriting it"
    sed -i "\|^UUID=${UUID}[[:space:]]|d" "$FSTAB"
fi
printf '%s\n' "$FSTAB_LINE" >>"$FSTAB"
log "added to $FSTAB: $FSTAB_LINE"

log "running mount -a"
if ! mount -a; then
    warn_log "mount -a returned an error - check 'findmnt $MOUNTPOINT'"
fi

if findmnt "$MOUNTPOINT" >/dev/null 2>&1; then
    log "$MOUNTPOINT is mounted:"
    findmnt "$MOUNTPOINT"
    df -h "$MOUNTPOINT"
else
    warn_log "$MOUNTPOINT is not mounted right now (that is fine if the disk is absent)"
    warn_log "the disk will be mounted automatically the next time it is attached and the box boots"
fi

cat <<'EOF'

NOTE
  The fstab entry uses nofail and x-systemd.device-timeout=5, so a missing
  media disk never blocks the boot. If you want the disk mounted as soon as
  it is plugged in, run: sudo systemctl daemon-reload && sudo mount -a

EOF
log "done"
