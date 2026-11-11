#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/44-tune-lowpower.sh
#
# Three things, all safe:
#
#   1. a oneshot unit that puts the CPUs into "balance_power" (only if the
#      kernel exposes intel_pstate's energy_performance_preference)
#   2. hub-audit          - a report-only overview of the box
#   3. hub-throttle-check - a read-only check for PROCHOT throttling
#
# It never disables a service, never writes an MSR and never suggests
# "powertop --auto-tune" (that can drop the USB Ethernet adapter).
#
set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

# ------------------------------------------------ 1. energy_performance -----
epp_file="/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"
if [ -e "$epp_file" ]; then
    log "installing the balance_power oneshot unit"
    cat >/etc/systemd/system/hub-epp.service <<EOF
[Unit]
Description=Set the CPU energy performance preference to balance_power

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo balance_power > ${epp_file}'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hub-epp.service || warn_log "could not enable hub-epp.service"
    systemctl start hub-epp.service || warn_log "could not apply the preference now"
    log "hub-epp.service installed (applies at every boot)"
    log "current value: $(cat "$epp_file" 2>/dev/null || echo unknown)"
else
    log "$epp_file does not exist - the CPU governor interface is not available"
    log "nothing was installed for the energy performance preference"
fi

# ------------------------------------------------------------ 2. hub-audit --
cat >/usr/local/bin/hub-audit <<'EOF'
#!/usr/bin/env bash
#
# Report-only overview of the box. It changes NOTHING and disables NOTHING.
#
set -uo pipefail

section() { printf '\n== %s ==\n' "$*"; }

section "boot time"
systemd-analyze time 2>/dev/null || true
systemd-analyze blame 2>/dev/null | head -15 || true

section "slowest units"
systemd-analyze critical-chain 2>/dev/null | head -20 || true

section "services that are present (NOT disabled - this script never disables anything)"
for svc in cloud-init cloud-config multipathd ModemManager apport snapd snapd.socket \
    thermald mbpfan ModemManager.timer systemd-resolved NetworkManager \
    networkd docker containerd tailscaled ufw unattended-upgrades; do
    state="$(systemctl is-enabled "$svc" 2>/dev/null || echo not-found)"
    active="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    printf '%-24s enabled=%-12s active=%s\n' "$svc" "$state" "$active"
done

section "memory"
free -h 2>/dev/null || true
if [ -e /sys/block/zram0/disksize ]; then
    printf 'zram0 size : %s\n' "$(cat /sys/block/zram0/disksize)"
else
    echo "zram0      : not present"
fi

section "the biggest memory consumers"
ps -eo pid,comm,rss --sort=-rss 2>/dev/null | head -12 || true

section "disk"
df -h / 2>/dev/null || true

section "timers that will wake the box"
systemctl list-timers --all --no-pager 2>/dev/null | head -20 || true
EOF
chmod 0755 /usr/local/bin/hub-audit
log "installed /usr/local/bin/hub-audit"

# ------------------------------------------------------ 3. hub-throttle -----
cat >/usr/local/bin/hub-throttle-check <<'EOF'
#!/usr/bin/env bash
#
# Read-only check for thermal throttling.
#
# * reads MSR 0x19c (IA32_THERM_STATUS) on every core; bit 0 = Thermal Monitor
#   Status, bit 3 = PROCHOT#/FORCEPR# event, bit 5 = the sticky PROCHOT log
# * runs a 60 second all-core load
# * samples scaling_cur_freq and the CPU temperature while it runs
# * greps the kernel log for throttling messages
#
# It only READS. It never writes an MSR and never changes a governor.
#
set -uo pipefail

DURATION="${HUB_THROTTLE_SECONDS:-60}"

echo "== pre-check =="
echo "cpu count    : $(nproc)"
echo "governor     : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
echo "intel_pstate : $( [ -d /sys/devices/system/cpu/intel_pstate ] && echo present || echo absent )"

if ! modprobe msr 2>/dev/null; then
    echo "could not load the msr module - skipping the MSR read"
    echo "(the msr kernel module ships in linux-modules-extra-$(uname -r);"
    echo " the rdmsr tool comes from msr-tools, which the bootstrap installs)"
fi

read_therm_status() {
    # IA32_THERM_STATUS = 0x19c. Bit layout per the Intel SDM and Linux
    # drivers/thermal/intel/therm_throt.c:
    #   bit 0 = Thermal Monitor Status (the CPU is throttled right now)
    #   bit 1 = Thermal Status Log (sticky: the monitor was engaged since cleared)
    #   bit 2 = FORCEPR# event
    #   bit 3 = PROCHOT# or FORCEPR# event
    #   bit 5 = PROCHOT# log (sticky: a PROCHOT# happened since cleared)
    local cpu count value hex prochot=0 read_any=0
    count="$(nproc)"
    for cpu in $(seq 0 $((count - 1))); do
        value="$(rdmsr -p "$cpu" 0x19c 2>/dev/null || true)"
        if [ -z "$value" ] && [ "$cpu" -eq 0 ]; then
            value="$(rdmsr 0x19c 2>/dev/null || true)"
        fi
        if [ -n "$value" ]; then
            read_any=1
            hex="0x$value"
            printf '  cpu%-3s MSR 0x19c = 0x%s' "$cpu" "$value"
            if (( hex & 8 )); then
                printf '  <- PROCHOT#/FORCEPR# EVENT (bit 3)'
                prochot=1
            elif (( hex & 32 )); then
                printf '  <- PROCHOT# LOG, sticky since boot (bit 5)'
                prochot=1
            elif (( hex & 4 )); then
                printf '  <- FORCEPR# EVENT (bit 2)'
                prochot=1
            elif (( hex & 2 )); then
                printf '  <- THERMAL STATUS LOG, sticky (bit 1)'
                prochot=1
            elif (( hex & 1 )); then
                printf '  <- THERMAL MONITOR STATUS (bit 0: throttling now)'
                prochot=1
            else
                printf '  (no thermal status)'
            fi
            printf '\n'
        fi
    done
    if [ "$read_any" -eq 0 ]; then
        echo "  (the MSR could not be read on any core)"
    fi
    PROCHOT_SEEN="$prochot"
    MSR_READABLE="$read_any"
    return 0
}

PROCHOT_SEEN=0
MSR_READABLE=0

echo
echo "== MSR 0x19c before the load =="
read_therm_status
before="$PROCHOT_SEEN"

echo
echo "== ${DURATION}s all-core load =="
pids=""
for _ in $(seq 1 "$(nproc)"); do
    yes >/dev/null &
    pids="$pids $!"
done

during=0
start="$(date +%s)"
while [ $(( $(date +%s) - start )) -lt "$DURATION" ]; do
    sleep 5
    freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo '?')"
    temp="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo '?')"
    printf '  t=%3ss  scaling_cur_freq=%-8s thermal_zone0=%s\n' \
        "$(( $(date +%s) - start ))" "$freq" "$temp"
    read_therm_status >/dev/null 2>&1
    [ "$PROCHOT_SEEN" -eq 1 ] && during=1
done

for p in $pids; do
    kill "$p" 2>/dev/null || true
done
wait 2>/dev/null || true

echo
echo "== MSR 0x19c after the load =="
read_therm_status
after="$PROCHOT_SEEN"

echo
echo "== kernel log =="
if dmesg 2>/dev/null | grep -iE 'throttl|prochot|thermal' | tail -20; then
    :
else
    echo "  (no throttling messages in dmesg)"
fi

echo
echo "== verdict =="
if [ "$MSR_READABLE" -eq 0 ]; then
    echo "UNKNOWN - the MSR could not be read, so no verdict is possible."
    echo "This usually means the msr module is not loaded or the kernel"
    echo "forbids MSR access. Everything else in this report still holds."
elif [ "$during" -eq 1 ] || [ "$after" -eq 1 ] || [ "$before" -eq 1 ]; then
        echo "PROCHOT WAS ASSERTED during the test."
        echo "A PROCHOT#/FORCEPR# event, a sticky PROCHOT log bit or a live"
        echo "thermal-monitor status was seen in IA32_THERM_STATUS (0x19c)."
        echo "On this MacBook the usual cause is the battery: with a"
        echo "service-required or missing battery the firmware drops the power"
        echo "limit hard. Check the battery first."
else
    echo "No PROCHOT observed during the test."
    echo "If the machine still feels slow, look at the speed governor, the"
    echo "thermals and the disk instead (hub-audit helps)."
fi
echo "Note: this script only reads. It never writes MSRs and never changes a governor."
EOF
chmod 0755 /usr/local/bin/hub-throttle-check
log "installed /usr/local/bin/hub-throttle-check"

cat <<'EOF'

TOOLS
  hub-audit            report-only overview (boot time, services, memory)
  hub-throttle-check   read-only PROCHOT / throttling check (60s load)

  Never use "powertop --auto-tune" on this box: it is known to drop the
  USB Ethernet adapter, and this hub is reached over a network.

EOF
log "done"
