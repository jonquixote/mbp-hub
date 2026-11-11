#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/05-docker.sh
#
# Installs Docker from the Ubuntu archive (docker.io + docker-compose-v2),
# enables live-restore so containers survive a docker daemon restart, and adds
# the admin users to the docker group.
#
# DOCKER IS OPTIONAL. Jellyfin runs natively from Jellyfin's apt repo and does
# not need Docker at all.
#
set -euo pipefail

HUB_USER="${HUB_USER:-${SUDO_USER:-johnny}}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

log "installing docker.io and docker-compose-v2"
apt-get update
apt-get install -y docker.io docker-compose-v2

install -d -o root -g root -m 0755 /etc/docker
if [ -f /etc/docker/daemon.json ] && ! grep -q 'live-restore' /etc/docker/daemon.json; then
    log "NOTE: /etc/docker/daemon.json already exists and has no live-restore key - leaving it alone"
    log "      add \"live-restore\": true yourself if you want that behaviour"
else
    cat >/etc/docker/daemon.json <<'EOF'
{
  "live-restore": true
}
EOF
    chmod 0644 /etc/docker/daemon.json
    log "wrote /etc/docker/daemon.json with live-restore"
fi

systemctl enable --now docker || die "could not start docker"
log "docker enabled"

for u in "$HUB_USER" agent; do
    if id "$u" >/dev/null 2>&1; then
        usermod -aG docker "$u"
        log "added $u to the docker group (log out and back in for it to take effect)"
    fi
done

cat <<'EOF'

NOTE - firewall and published ports
  Docker publishes ports by writing its own rules into iptables/nftables.
  Those rules BYPASS ufw, so a container with "-p 8096:8096" is reachable
  from the LAN even if ufw would have denied it.

  If you publish a port, either bind it to a specific interface
  ("-p 127.0.0.1:8096:8096") or do not publish it at all and reach the
  container through `tailscale serve` instead.

EOF
log "done"
