#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/43-battery-limit.sh
#
# READ-ONLY BY DEFAULT. It prints the battery state and, if the kernel exposes
# the standard charge threshold interface, it can install a small systemd unit
# that keeps the battery between a lower and an upper threshold.
#
#     sudo bash 43-battery-limit.sh              # report only
#     sudo bash 43-battery-limit.sh 80           # install a unit that stops at 80%
#
# This script never downloads and never runs third-party SMC tools.
#
# IMPORTANT FOR THIS MACHINE: the battery in this MacBook reports
# "Service Recommended" (health 43.97 %). Removing the battery makes the
# firmware assert PROCHOT and the CPU throttles hard. So:
#   * keep the battery in the machine, or
#   * accept the throttling, or
#   * replace the battery
# Do not disable PROCHOT to work around it - that is exactly the kind of
# change that turns a slow machine into a broken one.
#
set -euo pipefail

LIMIT="${1:-}"
NOTES_DIR="/usr/share/doc/mbp-hub"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

log "battery state"
found=0
for bat in /sys/class/power_supply/BAT*; do
    [ -d "$bat" ] || continue
    found=1
    printf '  device        : %s\n' "$(basename "$bat")"
    printf '  status        : %s\n' "$(cat "$bat/status" 2>/dev/null || echo unknown)"
    printf '  capacity      : %s%%\n' "$(cat "$bat/capacity" 2>/dev/null || echo unknown)"
    printf '  energy_now    : %s\n' "$(cat "$bat/energy_now" 2>/dev/null || echo unknown)"
    printf '  energy_full   : %s\n' "$(cat "$bat/energy_full" 2>/dev/null || echo unknown)"
    printf '  charge_now    : %s\n' "$(cat "$bat/charge_now" 2>/dev/null || echo unknown)"
    printf '  charge_full   : %s\n' "$(cat "$bat/charge_full" 2>/dev/null || echo unknown)"
    printf '  cycle_count   : %s\n' "$(cat "$bat/cycle_count" 2>/dev/null || echo unknown)"
    printf '  manufacturer  : %s\n' "$(cat "$bat/manufacturer" 2>/dev/null || echo unknown)"
    printf '  model_name    : %s\n' "$(cat "$bat/model_name" 2>/dev/null || echo unknown)"
done
[ "$found" -eq 1 ] || log "no battery device found in /sys/class/power_supply"

threshold_file=""
for bat in /sys/class/power_supply/BAT*; do
    if [ -e "$bat/charge_control_end_threshold" ]; then
        threshold_file="$bat/charge_control_end_threshold"
        break
    fi
done

if [ -z "$threshold_file" ]; then
    log "charge_control_end_threshold is NOT available on this kernel"
    log "the kernel does not expose the standard charge-limit interface for this battery"
    log "nothing was changed - this script stays read-only"
else
    log "charge threshold interface: $threshold_file"
    printf '  current end threshold : %s\n' "$(cat "$threshold_file" 2>/dev/null || echo unknown)"
    if [ -e "${threshold_file%/*}/charge_control_start_threshold" ]; then
        printf '  current start threshold: %s\n' "$(cat "${threshold_file%/*}/charge_control_start_threshold" 2>/dev/null || echo unknown)"
    fi
    if [ -z "$LIMIT" ]; then
        log "no limit given - nothing was changed (pass a percentage, e.g. 80)"
    else
        case "$LIMIT" in
            ''|*[!0-9]*) die "the limit must be a whole percentage" ;;
        esac
        [ "$LIMIT" -ge 20 ] && [ "$LIMIT" -le 100 ] || die "the limit must be between 20 and 100"
        log "installing a unit that stops charging at ${LIMIT}%"
        cat >/etc/systemd/system/hub-battery-limit.service <<EOF
[Unit]
Description=Keep the battery below the charge threshold
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ${LIMIT} > ${threshold_file}'
EOF
        systemctl daemon-reload
        systemctl enable hub-battery-limit.service || warn_log "could not enable the unit"
        systemctl start hub-battery-limit.service || warn_log "could not apply the threshold now"
        log "hub-battery-limit.service installed (applies at every boot)"
    fi
fi

# The notes about the third-party project are shipped with the kit.
install -d -m 0755 "$NOTES_DIR"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
notes_src="$script_dir/../../docs/battery-charge-limit-notes.md"
if [ -f "$notes_src" ]; then
    install -m 0644 "$notes_src" "$NOTES_DIR/battery-charge-limit-notes.md"
    log "notes installed at $NOTES_DIR/battery-charge-limit-notes.md"
else
    cat >"$NOTES_DIR/battery-charge-limit-notes.md" <<'EOF'
# battery charge limit notes

The full notes (including what the third-party project writes and the risks)
ship with the kit as docs/battery-charge-limit-notes.md.
Read them there before you install anything like it.
EOF
    log "short notes installed at $NOTES_DIR/battery-charge-limit-notes.md"
fi

cat <<'EOF'

REMEMBER (this MacBook specifically)
  The battery reports "Service Recommended" and is at 43.97 % health.
  With the battery removed, the firmware asserts PROCHOT and the CPU is
  throttled hard. Keep the battery, replace it, or live with the throttling.
  Never disable PROCHOT.

EOF
log "done"
