#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/40-vault.sh
#
# Creates an encrypted container file for secrets:
#
#   /var/lib/vault/vault.img   LUKS2 container (sparse file, default 20 GiB)
#   -> ext4 filesystem inside
#   -> mounted at /vault
#
# The passphrase is typed by the human, by cryptsetup, and is NEVER stored by
# this kit in any file. Nothing auto-unlocks: the vault is opened explicitly
# with `sudo vault-open` and closed with `sudo vault-close`.
#
# WHAT LIVES IN THE VAULT
#   SSH private keys, API tokens, .env files - anything you would not paste
#   into a chat window.
# WHAT STAYS ON THE UNENCRYPTED ROOT
#   Tailscale state (/var/lib/tailscale), SSH host keys (/etc/ssh), the
#   agents' accounts. These must be readable while the vault is closed, so
#   they are not inside it.
#
set -euo pipefail

VAULT_IMG="/var/lib/vault/vault.img"
VAULT_NAME="hubvault"
VAULT_MOUNT="/vault"
VAULT_SIZE="${1:-20G}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

apt-get update
apt-get install -y cryptsetup e2fsprogs

install -d -o root -g root -m 0700 /var/lib/vault
install -d -o root -g root -m 0755 "$VAULT_MOUNT"

if [ ! -f "$VAULT_IMG" ]; then
    log "creating a sparse $VAULT_SIZE container at $VAULT_IMG"
    truncate -s "$VAULT_SIZE" "$VAULT_IMG" || die "truncate failed"
    chmod 0600 "$VAULT_IMG"
    log "formatting the container as LUKS2 - type a strong passphrase NOW"
    log "  (there is no recovery: losing the passphrase loses the vault)"
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 "$VAULT_IMG" \
        || die "luksFormat failed"
else
    log "container already exists at $VAULT_IMG"
    cryptsetup isLuks "$VAULT_IMG" || die "$VAULT_IMG exists but is not a LUKS container - move it aside first"
    log "it is already a LUKS container - leaving it untouched"
fi

cat >/usr/local/sbin/vault-open <<EOF
#!/usr/bin/env bash
#
# Open the vault. The passphrase is typed here, by you, and is not stored.
#
set -euo pipefail

IMG="$VAULT_IMG"
NAME="$VAULT_NAME"
MOUNT="$VAULT_MOUNT"

if mountpoint -q "\$MOUNT"; then
    echo "the vault is already open at \$MOUNT"
    exit 0
fi

if [ ! -f "\$IMG" ]; then
    echo "no vault container at \$IMG - run 40-vault.sh first" >&2
    exit 1
fi

cryptsetup open "\$IMG" "\$NAME" || { echo "could not open the vault" >&2; exit 1; }

if ! blkid -p "/dev/mapper/\$NAME" >/dev/null 2>&1; then
    echo "no filesystem inside the vault yet - creating ext4"
    mkfs.ext4 -L "\$NAME" "/dev/mapper/\$NAME"
fi

mount "/dev/mapper/\$NAME" "\$MOUNT"
mkdir -p "\$MOUNT/johnny" "\$MOUNT/agent"
chown johnny:johnny "\$MOUNT/johnny"
chown agent:agent "\$MOUNT/agent"
chmod 0700 "\$MOUNT/johnny" "\$MOUNT/agent"
echo "vault open at \$MOUNT"
df -h "\$MOUNT"
EOF

cat >/usr/local/sbin/vault-close <<EOF
#!/usr/bin/env bash
#
# Close the vault: unmount it and shut the mapper down.
#
set -euo pipefail

MOUNT="$VAULT_MOUNT"
NAME="$VAULT_NAME"

if ! mountpoint -q "\$MOUNT"; then
    echo "the vault is not mounted"
    cryptsetup close "\$NAME" 2>/dev/null || true
    exit 0
fi

umount "\$MOUNT" || { echo "could not unmount \$MOUNT - something is still using it" >&2; exit 1; }
cryptsetup close "\$NAME"
echo "vault closed"
EOF

cat >/usr/local/sbin/vault-status <<EOF
#!/usr/bin/env bash
#
# Show the state of the vault.
#
set -euo pipefail

IMG="$VAULT_IMG"
MOUNT="$VAULT_MOUNT"
NAME="$VAULT_NAME"

if [ -f "\$IMG" ]; then
    printf 'container  : %s (%s bytes on disk, %s bytes apparent)\n' "\$IMG" \\
        "\$(stat -c %s "\$IMG" 2>/dev/null || echo '?')" \\
        "\$(du -h "\$IMG" 2>/dev/null | cut -f1)"
    if cryptsetup isLuks "\$IMG"; then
        echo "format     : LUKS"
        cryptsetup luksDump "\$IMG" 2>/dev/null | grep -E 'Version|cipher|CPU|Keyslot' || true
    else
        echo "format     : not a LUKS container"
    fi
else
    echo "container  : missing"
fi

if mountpoint -q "\$MOUNT"; then
    echo "state      : OPEN"
    df -h "\$MOUNT"
    ls -la "\$MOUNT" || true
else
    echo "state      : closed"
fi
EOF

chmod 0755 /usr/local/sbin/vault-open /usr/local/sbin/vault-close /usr/local/sbin/vault-status
log "installed vault-open, vault-close and vault-status"

cat <<'EOF'

THE VAULT
  /var/lib/vault/vault.img  LUKS2 container (ext4 inside), mounted at /vault
  /vault/johnny             owned by johnny
  /vault/agent              owned by agent

  It holds SSH private keys, API tokens and .env files.
  Tailscale state and SSH host keys deliberately stay on the unencrypted root.

  Nothing auto-unlocks. Open it when you need the secrets:

      sudo vault-open      # you type the passphrase
      ls /vault/johnny
      sudo vault-close     # when you are done

EOF
log "done"
