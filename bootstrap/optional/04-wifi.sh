#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/04-wifi.sh
#
# Writes a netplan wireless configuration from WIFI_SSID / WIFI_PASS.
#
# The SSID and password are read from the environment, or from
# /etc/hub/optional.env (mode 0600, owned by root) when they are not exported.
# Nothing secret is written to disk by this script beyond the netplan file
# itself, which is created with mode 0600 because netplan refuses to use
# world-readable files that contain credentials.
#
set -euo pipefail

NETPLAN_FILE="/etc/netplan/90-hub-wifi.yaml"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    echo "  sudo bash $0                      # secrets from /etc/hub/optional.env (0600 root)" >&2
    echo "  sudo --preserve-env=WIFI_SSID,WIFI_PASS bash $0   # secrets from the environment" >&2
    echo "  (do NOT use 'sudo -E': on Ubuntu 26.04 it is documented as ignored by sudo-rs)" >&2
    exit 1
fi

if [ -r /etc/hub/optional.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /etc/hub/optional.env
    set +a
fi

[ -n "${WIFI_SSID:-}" ] || die "WIFI_SSID is not set (export it, or put it in /etc/hub/optional.env)"
[ -n "${WIFI_PASS:-}" ] || die "WIFI_PASS is not set (export it, or put it in /etc/hub/optional.env)"

# Collect wireless interfaces (wlp2s0, wlan0, ...).
ifaces="$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wl/ {print $2}' | tr '\n' ' ')"
ifaces="$(printf '%s' "$ifaces" | sed 's/[[:space:]]*$//')"
[ -n "$ifaces" ] || die "no wl* interface found - is the wireless driver loaded? (try: modprobe brcmfmac)"

log "wireless interfaces: $ifaces"

# YAML single-quoted scalars: a literal ' is written as ''.
yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

{
    printf 'network:\n'
    printf '  version: 2\n'
    printf '  wifis:\n'
    for iface in $ifaces; do
        printf '    %s:\n' "$iface"
        printf '      dhcp4: true\n'
        printf '      dhcp6: true\n'
        printf '      optional: true\n'
        printf '      access-points:\n'
        printf '        %s:\n' "$(yaml_quote "$WIFI_SSID")"
        printf '          password: %s\n' "$(yaml_quote "$WIFI_PASS")"
    done
} >/tmp/hub-wifi.yaml

install -o root -g root -m 0600 /tmp/hub-wifi.yaml "$NETPLAN_FILE"
rm -f /tmp/hub-wifi.yaml
log "wrote $NETPLAN_FILE (mode 0600)"

if ! netplan generate; then
    die "netplan generate failed - $NETPLAN_FILE was left in place but is NOT active. Fix it with: sudo netplan generate"
fi
log "netplan generate succeeded"

log "applying (this restarts networking; a remote session over wifi may drop)"
if [ "${HUB_WIFI_APPLY:-1}" = "1" ]; then
    netplan apply
    log "done - check with: ip -brief address"
else
    log "HUB_WIFI_APPLY=0 - the configuration was written and validated but NOT applied"
fi
