#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/45-wifi-firmware.sh
#
# Installs Apple's board files for the BCM4350.
#
# The generic brcmfmac firmware is widely reported to be slower than Apple's
# board files, but that was NOT measured on this machine - it is a known
# unknown. The board-file NAME below is derived from the brcmfmac naming
# convention, not read off the hardware.
#
#     sudo bash 45-wifi-firmware.sh <directory>
#
# The directory must contain exactly these three files:
#
#     brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.bin
#     brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.clm_blob
#     brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1.txcap_blob
#
# The PCI ID was measured on this machine: vendor 0x14e4, device 0x43a3
# (BCM4350), IOName pci14e4,43a3, subsystem 0x106b:0x0170. The firmware
# name matches the brcmfmac "brcmfmac4350c2-pcie.<OEM>.<product>" pattern.
#
set -euo pipefail

SRC_DIR="${1:-}"
FIRMWARE_DIR="/lib/firmware/brcm"
BASE="brcmfmac4350c2-pcie.Apple Inc.-MacBookPro14,1"
FILES=("$BASE.bin" "$BASE.clm_blob" "$BASE.txcap_blob")

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

[ -n "$SRC_DIR" ] || die "usage: sudo bash $0 <directory-with-the-firmware-files>"
[ -d "$SRC_DIR" ] || die "no such directory: $SRC_DIR"

missing=0
for f in "${FILES[@]}"; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        warn_log "missing: $SRC_DIR/$f"
        missing=$((missing + 1))
    fi
done
[ "$missing" -eq 0 ] || die "$missing firmware file(s) missing - nothing was copied"

install -d -o root -g root -m 0755 "$FIRMWARE_DIR"
stamp="$(date '+%Y%m%d-%H%M%S')"
for f in "${FILES[@]}"; do
    if [ -f "$FIRMWARE_DIR/$f" ]; then
        cp -a "$FIRMWARE_DIR/$f" "$FIRMWARE_DIR/$f.bak-$stamp"
        log "backed up the existing $f"
    fi
    install -o root -g root -m 0644 "$SRC_DIR/$f" "$FIRMWARE_DIR/$f"
    log "installed $f"
done

log "reloading brcmfmac (the Wi-Fi connection will drop)"
if ! modprobe -r brcmfmac 2>/dev/null; then
    warn_log "could not unload brcmfmac (it may not be loaded right now)"
fi
if ! modprobe brcmfmac 2>/dev/null; then
    warn_log "could not load brcmfmac - check 'dmesg | grep -i brcm'"
fi

sleep 3
log "kernel messages:"
dmesg 2>/dev/null | grep -i 'brcmfmac' | tail -30 | sed 's/^/    /' || true

cat <<'EOF'

CHECK
  iw dev            # the interface should be up
  iw dev wlp2s0 link
  dmesg | grep -i brcmfmac

  If the firmware did not load, the kernel log says which file it wanted.
  To go back to the old files:
      sudo cp -a '/lib/firmware/brcm/<file>.bak-<timestamp>' '/lib/firmware/brcm/<file>'
      sudo modprobe -r brcmfmac && sudo modprobe brcmfmac

EOF
log "done"
