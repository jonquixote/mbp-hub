#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/41-backup-restic.sh
#
# Installs restic and sets up unattended backups. The human supplies the
# repository and the password file; this kit has NO defaults and never writes
# a secret to disk.
#
# /etc/hub/restic.env (mode 0600, root only) must contain:
#
#     RESTIC_REPOSITORY=s3:s3.example.com/bucket-name
#     RESTIC_PASSWORD_FILE=/etc/hub/restic-password
#
# /etc/hub/restic-password (mode 0600, root only) holds the repository
# password. restic reads it from the file, so the password is never in the
# environment of a process and never in this kit's logs.
#
set -euo pipefail

RESTIC_ENV="/etc/hub/restic.env"
BACKUP_TARGETS=(/etc/hub /etc/jellyfin /var/lib/jellyfin/data /var/lib/vault/vault.img /home)

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

log "installing restic and smartmontools"
apt-get update
apt-get install -y restic smartmontools jq

if [ ! -f "$RESTIC_ENV" ]; then
    die "$RESTIC_ENV is missing. Create it first, as root, with mode 0600:
      sudo install -d -m 0700 /etc/hub
      sudo install -o root -g root -m 0600 /dev/null $RESTIC_ENV
      sudoedit $RESTIC_ENV
It must contain RESTIC_REPOSITORY=... and RESTIC_PASSWORD_FILE=...
This kit will not invent those values."
fi
chmod 0600 "$RESTIC_ENV"
chown root:root "$RESTIC_ENV"

# shellcheck disable=SC1090
set -a
# shellcheck disable=SC1090
. "$RESTIC_ENV"
set +a
[ -n "${RESTIC_REPOSITORY:-}" ] || die "RESTIC_REPOSITORY is not set in $RESTIC_ENV"
[ -n "${RESTIC_PASSWORD_FILE:-}" ] || die "RESTIC_PASSWORD_FILE is not set in $RESTIC_ENV"
[ -r "$RESTIC_PASSWORD_FILE" ] || die "$RESTIC_PASSWORD_FILE is not readable"
log "repository: $RESTIC_REPOSITORY (password read from $RESTIC_PASSWORD_FILE)"

install -d -o root -g root -m 0755 /var/lib/hub

cat >/usr/local/sbin/hub-restic-backup <<EOF
#!/usr/bin/env bash
#
# Weekly restic backup. Writes nothing to the repository except snapshots.
#
set -euo pipefail

RESTIC_ENV="$RESTIC_ENV"
set -a
. "\$RESTIC_ENV"
set +a
: "\${RESTIC_REPOSITORY:?not set}"
: "\${RESTIC_PASSWORD_FILE:?not set}"

install -d -m 0755 /var/lib/hub
dpkg-query -W -f='\${binary:Package}\t\${Version}\n' >/var/lib/hub/packages.txt

targets=()
for t in ${BACKUP_TARGETS[*]}; do
    if [ -e "\$t" ]; then
        targets+=("\$t")
    else
        echo "skipping missing path: \$t"
    fi
done

restic backup \\
    --exclude-caches \\
    --exclude '/home/*/.cache' \\
    --exclude '/home/*/.npm' \\
    --exclude '/home/*/.local/share/Trash' \\
    --exclude '/home/*/.cache/pip' \\
    "\${targets[@]}" \\
    --tag hub --tag automatic --host "\$(hostname)"

restic backup /var/lib/hub/packages.txt --tag hub --tag packages --host "\$(hostname)"

restic forget --keep-weekly 8 --keep-monthly 6 --prune
restic snapshots --latest 3
EOF
chmod 0755 /usr/local/sbin/hub-restic-backup

cat >/usr/local/sbin/hub-restic-check <<EOF
#!/usr/bin/env bash
#
# Monthly integrity check of the restic repository (reads 5% of the data).
#
set -euo pipefail

RESTIC_ENV="$RESTIC_ENV"
set -a
. "\$RESTIC_ENV"
set +a
: "\${RESTIC_REPOSITORY:?not set}"
: "\${RESTIC_PASSWORD_FILE:?not set}"

restic check --read-data-subset=5%
EOF
chmod 0755 /usr/local/sbin/hub-restic-check

cat >/usr/local/sbin/hub-restore-test <<'EOF'
#!/usr/bin/env bash
#
# Restore the newest snapshot into /tmp and compare a sample of the restored
# files with the live ones. It proves the repository is actually usable, not
# just that the backup command exited 0.
#
set -euo pipefail

RESTIC_ENV="/etc/hub/restic.env"
TARGET="${1:-/tmp/hub-restore-test}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1

set -a
# shellcheck disable=SC1091
. "$RESTIC_ENV"
set +a
: "${RESTIC_REPOSITORY:?not set}"
: "${RESTIC_PASSWORD_FILE:?not set}"

rm -rf "$TARGET"
mkdir -p "$TARGET"

latest="$(restic snapshots --json | jq -r 'sort_by(.time) | last | .short_id')"
if [ -z "$latest" ] || [ "$latest" = "null" ]; then
    echo "no snapshots found in $RESTIC_REPOSITORY" >&2
    exit 1
fi
echo "latest snapshot: $latest"
restic restore "$latest" --target "$TARGET"

status=0
checked=0
for f in "$TARGET"/etc/hub/*; do
    [ -f "$f" ] || continue
    live="/etc/hub/$(basename "$f")"
    checked=$((checked + 1))
    if [ -f "$live" ]; then
        if cmp -s "$f" "$live"; then
            echo "OK       /etc/hub/$(basename "$f")"
        else
            echo "MISMATCH /etc/hub/$(basename "$f")"
            status=1
        fi
    else
        echo "MISSING  $live (not present on this machine - not necessarily a problem)"
    fi
done

if [ "$checked" -eq 0 ]; then
    echo "no comparable /etc/hub files in the snapshot"
    status=1
fi

if [ "$KEEP" -eq 0 ]; then
    rm -rf "$TARGET"
else
    echo "restored copy kept at $TARGET"
fi

if [ "$status" -eq 0 ]; then
    echo "restore test OK"
else
    echo "restore test FAILED" >&2
fi
exit "$status"
EOF
chmod 0755 /usr/local/sbin/hub-restore-test

cat >/etc/systemd/system/hub-restic-backup.service <<'EOF'
[Unit]
Description=Weekly restic backup of the hub configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/hub-restic-backup
EOF

cat >/etc/systemd/system/hub-restic-backup.timer <<'EOF'
[Unit]
Description=Weekly restic backup timer

[Timer]
OnCalendar=Sun 03:00:00
Persistent=true
RandomizedDelaySec=1800
Unit=hub-restic-backup.service

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/hub-restic-check.service <<'EOF'
[Unit]
Description=Monthly restic repository integrity check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/hub-restic-check
EOF

cat >/etc/systemd/system/hub-restic-check.timer <<'EOF'
[Unit]
Description=Monthly restic check timer

[Timer]
OnCalendar=*-*-01 05:00:00
Persistent=true
RandomizedDelaySec=3600
Unit=hub-restic-check.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now hub-restic-backup.timer || warn_log "could not enable the backup timer"
systemctl enable --now hub-restic-check.timer || warn_log "could not enable the check timer"
log "restic backup (weekly) and check (monthly) timers installed"

# --------------------------------------------------------------- smartd -----
log "checking whether SMART data is readable on /dev/nvme0"
smart_out="$(smartctl -a /dev/nvme0 2>&1 || true)"
if grep -qiE 'SMART overall-health|SMART/Health Information|Available Spare' <<<"$smart_out"; then
    log "SMART data is readable - enabling smartd"
    cat >/etc/smartd.conf <<'EOF'
# managed by mbp-hub
DEVICESCAN -a -o on -S on -W 4,35,55
EOF
    systemctl enable --now smartd || warn_log "could not start smartd"
    log "smartd enabled with DEVICESCAN"
else
    warn_log "SMART data is NOT readable on /dev/nvme0 - smartd stays disabled"
    printf '%s\n' "$smart_out" | head -10 | sed 's/^/    /'
fi

cat <<'EOF'

USEFUL COMMANDS
  sudo hub-restic-backup      # run a backup now
  sudo hub-restic-check       # run the integrity check now
  sudo hub-restore-test       # restore the latest snapshot to /tmp and compare
  sudo systemctl list-timers 'hub-*'

EOF
log "done"
