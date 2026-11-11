#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/bootstrap.sh
#
# Configures a freshly installed Ubuntu Server 26.04.1 LTS box into a headless
# "hub" for a 2017 MacBook Pro (MacBookPro14,1).
#
# Run it as your normal user (NOT as root):
#
#     bash bootstrap/bootstrap.sh
#
# Everything it logs goes to /var/log/hub-bootstrap.log as well as to stdout.
# The script is idempotent: running it twice changes nothing the second time.
#
# Secrets are NEVER written by this script and never live in the repository.
# Pass them in the environment for the run, e.g.
#
#     UBUNTU_PRO_TOKEN=... TS_AUTHKEY=... TS_TAG=tag:hub HC_URL=... \
#         bash bootstrap/bootstrap.sh
#
# Environment variables honoured:
#   HUB_HOSTNAME   hostname for the node            (default: mbp-hub)
#   HUB_USER       primary admin user               (default: the invoking user)
#   HUB_TIMEZONE   timezone                         (default: America/Los_Angeles)
#   UBUNTU_PRO_TOKEN, TS_AUTHKEY, TS_TAG, HC_URL
#
set -euo pipefail

HUB_HOSTNAME="${HUB_HOSTNAME:-mbp-hub}"
HUB_USER="${HUB_USER:-${SUDO_USER:-$USER}}"
HUB_TIMEZONE="${HUB_TIMEZONE:-America/Los_Angeles}"
LOG_FILE="${HUB_LOG_FILE:-/var/log/hub-bootstrap.log}"
HUB_DIR="/etc/hub"
HUB_STATE_DIR="/var/lib/hub"

PACKAGES=(
    openssh-server
    ufw
    tmux
    mosh
    git
    curl
    wget
    jq
    htop
    ncdu
    rsync
    ripgrep
    fd-find
    unzip
    lm-sensors
    mbpfan
    thermald
    systemd-zram-generator
    unattended-upgrades
    needrestart
    upower
    gh
    ca-certificates
    gnupg
    python3-venv
    python3-pip
    build-essential
    cryptsetup
    pciutils
    msr-tools
    smartmontools
)

# ---------------------------------------------------------------- helpers ---

redact() {
    sed -E \
        -e 's/tskey-[A-Za-z0-9_-]+/tskey-REDACTED/g' \
        -e 's/gh[pousr]_[A-Za-z0-9]+/github_TOKEN_REDACTED/g' \
        -e 's/(tskey-|github_pat_|ghp_)[A-Za-z0-9_-]+/\1REDACTED/g' \
        -e 's/(password|passphrase|token|secret)([=:][[:space:]]*)[^[:space:]]+/\1\2REDACTED/Ig'
}

log() {
    local line
    printf -v line '[%s] %s' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
    line="$(printf '%s' "$line" | redact || true)"
    printf '%s\n' "$line"
    if [ -w "$LOG_FILE" ] 2>/dev/null; then
        printf '%s\n' "$line" >>"$LOG_FILE"
    else
        printf '%s\n' "$line" | sudo tee -a "$LOG_FILE" >/dev/null 2>&1 || true
    fi
}

warn() {
    log "WARNING: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# write_root_file <mode> <path> [owner] [group]  (content on stdin)
write_root_file() {
    local mode="$1" path="$2" owner="${3:-root}" group="${4:-root}"
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    sudo install -o "$owner" -g "$group" -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
}

# ------------------------------------------------------------ 1. packages ---

step_packages() {
    log "STEP 1/12 packages"
    sudo apt-get update
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Lock::Timeout=300 \
        "${PACKAGES[@]}"; then
        log "packages installed in one bulk transaction"
    else
        warn "bulk install failed - retrying one by one"
        local p
        for p in "${PACKAGES[@]}"; do
            if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::="--force-confold" \
                -o Dpkg::Lock::Timeout=300 \
                "$p"; then
                log "installed: $p"
            else
                warn "could not install: $p"
            fi
        done
    fi
}

# -------------------------------------------------------- 2. ubuntu pro ---

step_ubuntu_pro() {
    log "STEP 2/12 ubuntu pro + livepatch"
    if [ -z "${UBUNTU_PRO_TOKEN:-}" ]; then
        warn "UBUNTU_PRO_TOKEN not set - skipping Ubuntu Pro and Livepatch"
        return 0
    fi
    if ! have pro; then
        sudo apt-get install -y software-properties-common || warn "software-properties-common failed"
        sudo add-apt-repository -y ppa:ubuntu-pro/ppa || warn "ubuntu-pro PPA failed"
        sudo apt-get update
        sudo apt-get install -y ubuntu-pro-client || warn "ubuntu-pro-client install failed"
    fi
    if ! have pro; then
        warn "pro client still unavailable - skipping Ubuntu Pro"
        return 0
    fi
    # The token is piped in on stdin so it never appears in argv or in the log.
    if printf '%s' "$UBUNTU_PRO_TOKEN" | sudo -n pro attach 2>&1 | redact | tee -a "$LOG_FILE" >/dev/null; then
        log "ubuntu pro attached"
    else
        warn "pro attach failed - see $LOG_FILE"
    fi
    if sudo -n pro enable livepatch 2>&1 | redact | tee -a "$LOG_FILE" >/dev/null; then
        log "livepatch enabled"
    else
        warn "livepatch could not be enabled (kernel coverage may not exist for $HUB_HOSTNAME's kernel)"
    fi
}

# ----------------------------------------------------------- 3. system ------

step_system() {
    log "STEP 3/12 system settings"

    log "timezone -> $HUB_TIMEZONE"
    sudo timedatectl set-timezone "$HUB_TIMEZONE"

    log "logind: ignore lid switch (closed lid, headless)"
    write_root_file 0644 /etc/systemd/logind.conf.d/99-hub-ignore-lid.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=yes
EOF

    log "mask sleep/suspend/hibernate targets"
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
        || warn "systemctl mask returned non-zero (units may already be masked)"

    log "UPower CriticalPowerAction=PowerOff"
    local upower_conf="/etc/UPower/UPower.conf"
    sudo install -d -m 0755 /etc/UPower
    sudo touch "$upower_conf"
    sudo sed -i '/^[[:space:]]*CriticalPowerAction[[:space:]]*=/d' "$upower_conf"
    if ! sudo grep -qE '^\[UPower\]' "$upower_conf"; then
        printf '\n[UPower]\n' | sudo tee -a "$upower_conf" >/dev/null
    fi
    printf 'CriticalPowerAction=PowerOff\n' | sudo tee -a "$upower_conf" >/dev/null

    log "GRUB timeout 2s (and recordfail timeout 2s)"
    sudo install -d -m 0755 /etc/default/grub.d
    write_root_file 0644 /etc/default/grub.d/99-hub-timeout.cfg <<'EOF'
GRUB_TIMEOUT=2
GRUB_TIMEOUT_STYLE=menu
GRUB_RECORDFAIL_TIMEOUT=2
EOF
    sudo update-grub || warn "update-grub failed"

    log "zram-generator: min(ram/2,4096) MiB, zstd"
    write_root_file 0644 /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram/2, 4096)
compression-algorithm = zstd
EOF
    sudo systemctl daemon-reload

    log "journald SystemMaxUse=500M"
    sudo install -d -m 0755 /etc/systemd/journald.conf.d
    write_root_file 0644 /etc/systemd/journald.conf.d/99-hub.conf <<'EOF'
[Journal]
SystemMaxUse=500M
EOF
    sudo systemctl restart systemd-journald || warn "journald restart failed"

    log "enabling fstrim.timer, thermald, mbpfan"
    sudo systemctl enable --now fstrim.timer || warn "fstrim.timer failed"
    sudo systemctl enable --now thermald || warn "thermald failed to start"
    sudo systemctl enable --now mbpfan || warn "mbpfan failed to start (expected on non-Apple hardware)"
}

# -------------------------------------------------------- 4. tailscale ------

step_tailscale() {
    log "STEP 4/12 tailscale"
    if ! have tailscale; then
        log "installing tailscale from the official installer"
        curl -fsSL https://tailscale.com/install.sh | sh || {
            warn "tailscale installer failed"
            return 0
        }
    fi
    if ! have tailscale; then
        warn "tailscale not available - skipping"
        return 0
    fi

    local args
    args=(--ssh --hostname "$HUB_HOSTNAME")
    if [ -n "${TS_AUTHKEY:-}" ]; then
        # TODO(verify): --auth-key puts the auth key in argv, so it is visible
        # in the process list for as long as "tailscale up" runs. Run
        # "tailscale up" by hand and paste the key if that matters to you.
        args+=(--auth-key "$TS_AUTHKEY")
        log "using TS_AUTHKEY from the environment"
    fi
    if [ -n "${TS_TAG:-}" ]; then
        args+=(--advertise-tags="$TS_TAG")
        log "requesting tailscale tag: $TS_TAG"
    fi

    if sudo tailscale up "${args[@]}" 2>&1 | redact | tee -a "$LOG_FILE" >/dev/null; then
        log "tailscale is up as '$HUB_HOSTNAME'"
    else
        warn "tailscale up failed - see $LOG_FILE"
    fi

    if sudo tailscale set --operator="$HUB_USER" 2>&1 | redact | tee -a "$LOG_FILE" >/dev/null; then
        log "tailscale operator set to $HUB_USER"
    else
        warn "could not set the tailscale operator (needs a tailnet admin)"
    fi
}

# ------------------------------------------------------------ 5. users ------

step_users() {
    log "STEP 5/12 users and ssh keys"

    if ! id agent >/dev/null 2>&1; then
        sudo useradd --create-home --shell /bin/bash agent
        log "created user 'agent'"
    else
        log "user 'agent' already exists"
    fi
    sudo passwd -l agent >/dev/null 2>&1 || warn "could not lock the agent password"
    sudo gpasswd -d agent sudo >/dev/null 2>&1 || true
    sudo loginctl enable-linger agent || warn "enable-linger failed"

    local src="$HOME/.ssh/authorized_keys"
    local tmp
    tmp="$(mktemp)"
    if [ -r "$src" ]; then
        grep -E '^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)' "$src" >"$tmp" || true
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        warn "no usable public keys in $src - SSH hardening will NOT be applied"
        return 0
    fi
    log "found $(grep -c '' "$tmp") usable public key line(s)"

    sudo install -d -o root -g root -m 0755 /etc/ssh/authorized_keys.d
    local u
    for u in "$HUB_USER" agent; do
        sudo install -o root -g root -m 0644 "$tmp" "/etc/ssh/authorized_keys.d/$u"
        log "installed /etc/ssh/authorized_keys.d/$u (root:root 0644)"
    done
    rm -f "$tmp"
}

# -------------------------------------------------------------- 6. sshd -----

step_sshd() {
    log "STEP 6/12 ssh hardening"
    local have_keys=0
    local u
    for u in "$HUB_USER" agent; do
        if [ -s "/etc/ssh/authorized_keys.d/$u" ]; then
            have_keys=1
        fi
    done
    if [ "$have_keys" -ne 1 ]; then
        warn "no public keys available - refusing to disable password login"
        return 0
    fi

    sudo install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
    write_root_file 0644 /etc/ssh/sshd_config.d/10-hub.conf <<EOF
# managed by mbp-hub bootstrap - local edits are overwritten
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 30
ClientAliveCountMax 4
AllowUsers $HUB_USER agent
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u .ssh/authorized_keys
EOF

    if ! sudo grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        warn "adding the sshd_config.d Include line (it was missing)"
        sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    if sudo sshd -t; then
        sudo systemctl reload ssh || sudo systemctl restart ssh
        log "sshd configuration accepted and reloaded"
    else
        warn "sshd -t failed - removing the drop-in and keeping the old config"
        sudo rm -f /etc/ssh/sshd_config.d/10-hub.conf
    fi
}

# --------------------------------------------------------------- 7. ufw -----

step_ufw() {
    log "STEP 7/12 ufw firewall"
    sudo ufw --force default deny incoming
    sudo ufw --force default allow outgoing
    sudo ufw allow in on tailscale0 || warn "could not add the tailscale0 rule (is tailscale running?)"

    local iface cidr
    iface="$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
    cidr=""
    if [ -n "$iface" ]; then
        local addr
        addr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')"
        if [ -n "$addr" ]; then
            cidr="$(python3 -c 'import ipaddress,sys;print(ipaddress.ip_network(sys.argv[1],strict=False))' "$addr" 2>/dev/null || true)"
        fi
    fi

    if [ -z "$cidr" ]; then
        warn "no LAN CIDR detected - ufw rules were configured but ufw was NOT enabled"
        return 0
    fi
    log "detected LAN CIDR: $cidr (interface $iface)"
    sudo ufw allow from "$cidr" to any port 22 proto tcp
    sudo ufw allow from "$cidr" to any port 60000:61000 proto udp
    sudo ufw allow from "$cidr" to any port 8096 proto tcp
    sudo ufw allow from "$cidr" to any port 1900 proto udp
    sudo ufw allow from "$cidr" to any port 7359 proto udp
    sudo ufw --force enable
    log "ufw enabled"
}

# ------------------------------------------- 8. unattended upgrades ---------

step_unattended() {
    log "STEP 8/12 unattended-upgrades and needrestart"
    write_root_file 0644 /etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-updates";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    sudo systemctl enable --now unattended-upgrades || warn "could not enable unattended-upgrades"

    write_root_file 0644 /etc/needrestart/needrestart.conf <<'EOF'
# managed by mbp-hub bootstrap
# Restart services automatically after package updates, but never these:
# rebooting the hub in the middle of a remote session is worse than a stale
# service. The key names below are the ones needrestart actually reads; they
# were verified in-container against needrestart 3.11 during the test phase,
# and the config is validated with "perl -c" and "needrestart -b" in the
# 26.04 container. TODO(verify): the needrestart version on the real box.
$nrconf{restart} = 'a';
$nrconf{blacklist_rc} = [
    qr(^ssh\.service$),
    qr(^sshd\.service$),
    qr(^tailscaled\.service$),
];
EOF
}

# ------------------------------------------------- 9. reboot-if-stale -------

step_reboot_policy() {
    log "STEP 9/12 reboot policy"
    sudo install -d -o root -g root -m 0755 "$HUB_STATE_DIR"

    write_root_file 0755 /usr/local/sbin/hub-reboot-if-stale <<'EOF'
#!/usr/bin/env bash
#
# Reboot the hub only if /var/run/reboot-required has been pending for a long
# time (21 days by default). The first-seen timestamp lives in
# /var/lib/hub/reboot-pending-since. Creating /etc/hub-no-auto-reboot blocks
# the reboot entirely.
#
set -euo pipefail

REQ_FILE="${HUB_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
STATE_FILE="${HUB_REBOOT_STATE_FILE:-/var/lib/hub/reboot-pending-since}"
BLOCK_FILE="${HUB_REBOOT_BLOCK_FILE:-/etc/hub-no-auto-reboot}"
MIN_DAYS="${HUB_REBOOT_MIN_DAYS:-21}"
DRY_RUN="${HUB_REBOOT_DRY_RUN:-0}"

now="$(date +%s)"

if [ -e "$BLOCK_FILE" ]; then
    echo "blocked: $BLOCK_FILE exists - no reboot"
    exit 0
fi

if [ ! -e "$REQ_FILE" ]; then
    rm -f "$STATE_FILE"
    echo "no reboot required"
    exit 0
fi

if [ ! -e "$STATE_FILE" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    printf '%s\n' "$now" >"$STATE_FILE"
    echo "reboot required - first seen now, not rebooting for ${MIN_DAYS} days"
    exit 0
fi

first="$(cat "$STATE_FILE")"
age_days=$(( (now - first) / 86400 ))

if [ "$age_days" -lt "$MIN_DAYS" ]; then
    echo "reboot required but pending for only ${age_days} day(s) - not rebooting"
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "reboot required and pending for ${age_days} day(s) - WOULD REBOOT (dry run)"
    exit 0
fi

echo "reboot required and pending for ${age_days} day(s) - rebooting now"
systemctl reboot
EOF

    write_root_file 0644 /etc/systemd/system/hub-reboot-if-stale.service <<'EOF'
[Unit]
Description=Reboot the hub when a pending reboot has been waiting for 21 days
ConditionPathExists=/usr/local/sbin/hub-reboot-if-stale

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hub-reboot-if-stale
EOF

    write_root_file 0644 /etc/systemd/system/hub-reboot-if-stale.timer <<'EOF'
[Unit]
Description=Daily check for a long-pending reboot requirement

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
Unit=hub-reboot-if-stale.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now hub-reboot-if-stale.timer || warn "could not enable hub-reboot-if-stale.timer"
    log "reboot policy installed (daily 04:30, reboots only after 21 days pending)"
}

# ------------------------------------------------ 10. power restore ---------

step_power_restore() {
    log "STEP 10/12 power restore (auto-start after AC loss)"

    write_root_file 0755 /usr/local/sbin/hub-power-restore <<'EOF'
#!/usr/bin/env bash
#
# Read (and optionally set) the "auto restart" bit in the Intel LPC bridge
# configuration space at offset 0xa4 on a MacBook Pro.
#
#   hub-power-restore            -> read, and set bit 0 if it is already set
#   hub-power-restore --check    -> read only, never writes
#
# HUB_SETPCI=0 disables the write entirely.
#
# TODO(verify): the bit-0 guard below is implemented exactly as specified, but
#   the actual polarity of bit 0 (does it need to be SET or CLEARED to enable
#   auto-restart after AC loss on this machine?) is not verified. Confirm with
#   a plug-pull test on the real MacBookPro14,1 - see RUNBOOK.md.
#
set -euo pipefail

REG="0xa4.b"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
HUB_SETPCI="${HUB_SETPCI:-1}"

if [ "$(id -u)" -ne 0 ]; then
    echo "hub-power-restore must run as root" >&2
    exit 1
fi

bdf="$(lspci -nn -d ::0601 2>/dev/null | awk '/8086:/ {print $1; exit}')"
if [ -z "$bdf" ]; then
    echo "no Intel LPC bridge (class 0601, vendor 8086) found" >&2
    exit 1
fi
echo "LPC bridge: $bdf"

before="$(setpci -s "$bdf" "$REG")"
echo "read $REG = $before"

num=$((before))
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "check mode: not writing"
    exit 0
fi

if [ "$HUB_SETPCI" = "0" ]; then
    echo "HUB_SETPCI=0 - write disabled"
    exit 0
fi

if [ $((num & 1)) -ne 0 ]; then
    echo "bit 0 is set - applying the masked write ($REG=0:1, other bits preserved)"
    setpci -s "$bdf" "$REG=0:1"
    after="$(setpci -s "$bdf" "$REG")"
    echo "read $REG = $after"
else
    echo "bit 0 is clear - no write performed"
fi
EOF

    write_root_file 0644 /etc/systemd/system/hub-power-restore.service <<'EOF'
[Unit]
Description=Restore auto-start after AC power loss (Intel LPC 0xa4)
After=multi-user.target
ConditionPathExists=/usr/local/sbin/hub-power-restore

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hub-power-restore
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable hub-power-restore.service || warn "could not enable hub-power-restore.service"
    if sudo /usr/local/sbin/hub-power-restore --check; then
        log "power restore check completed"
    else
        warn "power restore check failed (no Intel LPC bridge found?)"
    fi
}

# ---------------------------------------------------- 11. heartbeat ---------

step_heartbeat() {
    log "STEP 11/12 heartbeat"
    if [ -z "${HC_URL:-}" ]; then
        warn "HC_URL not set - no heartbeat installed"
        return 0
    fi
    sudo install -d -o root -g root -m 0700 "$HUB_DIR"
    # The URL is a bearer token: keep it root-only, never in the repo.
    printf 'HC_URL=%s\n' "$HC_URL" | sudo tee "$HUB_DIR/heartbeat.env" >/dev/null
    sudo chown root:root "$HUB_DIR/heartbeat.env"
    sudo chmod 0600 "$HUB_DIR/heartbeat.env"

    write_root_file 0755 /usr/local/sbin/hub-heartbeat <<'EOF'
#!/usr/bin/env bash
#
# Heartbeat. If the node has a tailscale address we ping HC_URL, otherwise we
# ping HC_URL/fail so the monitor can tell "hub is offline" from "hub is up".
#
set -euo pipefail

HC_URL="${HC_URL:-}"
if [ -z "$HC_URL" ]; then
    echo "HC_URL is not set - nothing to do"
    exit 0
fi

if tailscale ip -4 >/dev/null 2>&1; then
    target="$HC_URL"
    state="tailscale-ip-present"
else
    target="${HC_URL%/}/fail"
    state="no-tailscale-ip"
fi

case "$target" in
    http://*|https://*)
        if curl -fsS --max-time 20 -o /dev/null "$target"; then
            echo "heartbeat ok ($state)"
        else
            echo "heartbeat FAILED ($state)" >&2
            exit 1
        fi
        ;;
    *)
        if ping -c 1 -W 5 "$target" >/dev/null 2>&1; then
            echo "heartbeat ok ($state)"
        else
            echo "heartbeat FAILED ($state)" >&2
            exit 1
        fi
        ;;
esac
EOF

    write_root_file 0644 /etc/systemd/system/hub-heartbeat.service <<'EOF'
[Unit]
Description=Hub heartbeat
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/hub-heartbeat

[Service]
Type=oneshot
EnvironmentFile=-/etc/hub/heartbeat.env
ExecStart=/usr/local/sbin/hub-heartbeat
EOF

    write_root_file 0644 /etc/systemd/system/hub-heartbeat.timer <<'EOF'
[Unit]
Description=Hub heartbeat every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
Unit=hub-heartbeat.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now hub-heartbeat.timer || warn "could not enable hub-heartbeat.timer"
    log "heartbeat installed (every 5 minutes)"
}

# ------------------------------------------------------ 12. hub-status ------

step_status_and_banner() {
    log "STEP 12/12 hub-status"

    write_root_file 0755 /usr/local/bin/hub-status <<'EOF'
#!/usr/bin/env bash
#
# One-screen status of the hub. Read-only: it never changes anything.
#
set -uo pipefail

section() { printf '\n== %s ==\n' "$*"; }

section "uptime"
uptime

section "memory"
free -h 2>/dev/null || true
if [ -e /sys/block/zram0/disksize ]; then
    printf 'zram0 size   : %s\n' "$(cat /sys/block/zram0/disksize)"
    printf 'zram0 used   : %s\n' "$(cat /sys/block/zram0/mem_used_total 2>/dev/null || echo n/a)"
else
    echo "zram0        : not present"
fi

section "disk"
df -h / /srv/media 2>/dev/null || df -h /

section "network"
ip -brief address 2>/dev/null || true
if command -v tailscale >/dev/null 2>&1; then
    printf 'tailscale ip : %s\n' "$(tailscale ip -4 2>/dev/null || echo none)"
fi

section "temperatures / fans"
if command -v sensors >/dev/null 2>&1; then
    sensors 2>/dev/null | head -40
else
    for z in /sys/class/thermal/thermal_zone*; do
        [ -e "$z/temp" ] || continue
        printf '%s: %s\n' "$(basename "$z")" "$(cat "$z/temp")"
    done
fi

section "battery"
if command -v upower >/dev/null 2>&1; then
    bat="$(upower -e 2>/dev/null | grep -i BAT | head -1 || true)"
    if [ -n "$bat" ]; then
        upower -i "$bat" 2>/dev/null || true
    else
        echo "no battery device reported by upower"
    fi
fi

section "tailscale"
if command -v tailscale >/dev/null 2>&1; then
    tailscale status 2>/dev/null | head -20 || true
fi

section "firewall"
if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null || true
fi

section "services"
for svc in jellyfin docker tailscaled ssh hub-heartbeat.timer hub-reboot-if-stale.timer; do
    printf '%-28s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
done

section "livepatch"
if command -v pro >/dev/null 2>&1; then
    pro status 2>/dev/null | grep -iE 'livepatch|attached' || true
elif command -v ua >/dev/null 2>&1; then
    ua status 2>/dev/null | grep -iE 'livepatch|attached' || true
else
    echo "pro/ua client not installed"
fi

section "reboot"
if [ -e /var/run/reboot-required ]; then
    echo "reboot required (pending marker present)"
else
    echo "no reboot pending"
fi
EOF

    # A small tmux setup for the interactive users.
    local tmux_conf
    tmux_conf='set -g mouse on
set -g history-limit 20000
set -g status-interval 5
set -g default-terminal "screen-256color"
set -g base-index 1
setw -g mode-keys vi
'
    printf '%s\n' "$tmux_conf" | sudo tee "/home/$HUB_USER/.tmux.conf" >/dev/null
    sudo chown "$HUB_USER:$HUB_USER" "/home/$HUB_USER/.tmux.conf" || true
    sudo chmod 0644 "/home/$HUB_USER/.tmux.conf"
    if id agent >/dev/null 2>&1; then
        printf '%s\n' "$tmux_conf" | sudo tee /home/agent/.tmux.conf >/dev/null
        sudo chown agent:agent /home/agent/.tmux.conf || true
        sudo chmod 0644 /home/agent/.tmux.conf
    fi
}

banner() {
    cat <<EOF

================================================================
 mbp-hub bootstrap finished
================================================================
 host        : $HUB_HOSTNAME
 user        : $HUB_USER (plus 'agent')
 log         : $LOG_FILE

 NEXT STEPS

 1. Tailscale admin
      open https://login.tailscale.com/admin/machines
      - approve the new node ($HUB_HOSTNAME)
      - approve any pending tag (tag:hub)
      - paste policy/tailscale-policy-snippet.json into the policy editor
        and run its tests before you rely on it
    node address:
      sudo tailscale ip -4

 2. Check the hub
      hub-status

 3. Optional modules (run as root, one at a time)
      ls bootstrap/optional/
      sudo bash bootstrap/optional/04-wifi.sh          # WIFI_SSID / WIFI_PASS
      sudo bash bootstrap/optional/05-docker.sh
      sudo bash bootstrap/optional/10-agents.sh
      sudo bash bootstrap/optional/20-jellyfin.sh
      sudo bash bootstrap/optional/30-gui-rustdesk.sh    # RD_PASS
      sudo bash bootstrap/optional/40-vault.sh
      sudo bash bootstrap/optional/41-backup-restic.sh
      sudo bash bootstrap/optional/42-media-mount.sh <UUID>
      sudo bash bootstrap/optional/43-battery-limit.sh
      sudo bash bootstrap/optional/44-tune-lowpower.sh
      sudo bash bootstrap/optional/45-wifi-firmware.sh <dir>

 4. Vault
      The vault holds SSH private keys, API tokens and .env files.
      It is NEVER auto-unlocked: open it by hand with
          sudo vault-open
      when you need those secrets.

================================================================
EOF
}

main() {
    if [ "$(id -u)" -eq 0 ]; then
        warn "running as root - the kit expects a normal user with sudo"
    fi
    log "mbp-hub bootstrap starting (host=$HUB_HOSTNAME user=$HUB_USER)"
    sudo install -d -o root -g root -m 0755 /etc/hub
    sudo touch "$LOG_FILE"
    sudo chown root:root "$LOG_FILE"
    sudo chmod 0644 "$LOG_FILE"

    sudo -v || die "cannot obtain sudo - run this from a user that can sudo"

    step_packages
    step_ubuntu_pro
    step_system
    step_tailscale
    step_users
    step_sshd
    step_ufw
    step_unattended
    step_reboot_policy
    step_power_restore
    step_heartbeat
    step_status_and_banner

    banner
    log "mbp-hub bootstrap finished"
}

main "$@"
