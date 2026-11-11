#!/usr/bin/env bash
#
# mbp-hub :: mac-prep/make-installer-usb.sh
#
# Runs on macOS. Downloads the Ubuntu Server 26.04.1 LTS live-server ISO and
# its SHA256SUMS (+ .gpg signature) from releases.ubuntu.com, verifies the
# SHA256 (ABORTS on mismatch), treats the GPG signature as INFORMATIONAL only,
# then writes the ISO to an EXTERNAL physical USB disk after the operator has
# typed the exact confirmation phrase "ERASE diskN".
#
# Safety rules baked in:
#   * only external physical disks are ever offered as targets
#   * the boot disk is refused even if it somehow appears in the list
#   * nothing is written until "ERASE diskN" is typed
#   * the SHA256 must match before any disk is touched
#   * re-running is safe: an already-written disk is detected and skipped
#
# Environment:
#   HUB_USB_WORKDIR   where to keep the ISO (default: ~/hub-kit-usb)
#   HUB_VERIFY_FULL   set to 1 for a full byte-for-byte verification after dd
#
# TODO(verify): the GPG signature check needs the Ubuntu archive keyring
#   (install `ubuntu-keyring` on the Mac). Without it the check reports
#   "no public key" and the script continues - the SHA256 is the hard gate.
#
set -euo pipefail

readonly ISO_NAME="ubuntu-26.04.1-live-server-amd64.iso"
readonly MIRROR="https://releases.ubuntu.com/resolute"
readonly ISO_URL="${MIRROR}/${ISO_NAME}"
readonly SUMS_URL="${MIRROR}/SHA256SUMS"
readonly SUMS_GPG_URL="${MIRROR}/SHA256SUMS.gpg"
readonly WORKDIR="${HUB_USB_WORKDIR:-$HOME/hub-kit-usb}"
readonly VERIFY_FULL="${HUB_VERIFY_FULL:-0}"
readonly CONFIRM_PREFIX="ERASE"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "need shasum or sha256sum"
    fi
}

download() {
    url="$1"
    dest="$2"
    if [ -s "$dest" ]; then
        log "already downloaded: $dest"
        return 0
    fi
    log "downloading $url"
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${dest}.part" "$url"; then
        rm -f "${dest}.part"
        die "download failed: $url"
    fi
    mv "${dest}.part" "$dest"
    log "saved $dest"
}

verify_sha256() {
    iso="$1"
    sums="$2"
    log "verifying SHA256 of $ISO_NAME against SHA256SUMS"
    expected="$(awk -v f="$ISO_NAME" '$2 == f || $2 == "*" f {print $1; exit}' "$sums")"
    [ -n "$expected" ] || die "no SHA256 entry for $ISO_NAME in $sums"
    actual="$(sha256_of "$iso")"
    if [ "$actual" != "$expected" ]; then
        die "SHA256 MISMATCH for $ISO_NAME
  expected: $expected
  actual  : $actual
The download is not trusted. Nothing was written to any disk."
    fi
    log "SHA256 OK: $actual"
}

verify_gpg_informational() {
    sums="$1"
    sig="$2"
    out="$(mktemp)"
    if ! command -v gpg >/dev/null 2>&1; then
        log "gpg not installed - signature check skipped (informational only)"
        rm -f "$out"
        return 0
    fi
    if gpg --verify "$sig" "$sums" >"$out" 2>&1; then
        log "gpg signature VERIFIED (informational)"
    else
        log "gpg signature NOT verified (informational only, SHA256 is the hard gate):"
        sed -n '1,12p' "$out" | sed 's/^/    /'
    fi
    rm -f "$out"
}

list_external_disks() {
    listing="$(mktemp)"
    if ! diskutil list external physical >"$listing" 2>&1; then
        rm -f "$listing"
        return 0
    fi
    disks=""
    while IFS= read -r line; do
        case "$line" in
            /dev/disk*" (external, physical):")
                d="${line#/dev/}"
                d="${d%% *}"
                disks="$disks $d"
                ;;
        esac
    done <"$listing"
    rm -f "$listing"
    for d in $disks; do
        printf '%s\n' "$d"
    done
}

disk_field() {
    # disk_field <diskN> <field name>
    diskutil info "/dev/$1" 2>/dev/null | awk -F': *' -v want="$2" \
        '$1 == want {print $2; exit}'
}

boot_disk() {
    diskutil info / 2>/dev/null | awk -F': *' '$1 == "Device Node" {print $3; exit}' \
        | sed 's#^/dev/##'
}

already_written() {
    # already_written <diskN> <iso>
    d="$1"
    iso="$2"
    isosize="$(stat -f %z "$iso" 2>/dev/null || echo 0)"
    raw="/dev/r$d"
    [ -e "$raw" ] || return 1
    dsize="$(diskutil info "/dev/$d" 2>/dev/null | awk -F': *' '$1 == "Disk Size" {gsub(/[^0-9]/,"",$2); print $2; exit}')"
    [ -n "$dsize" ] || return 1
    [ "$dsize" = "$isosize" ] || return 1
    head_bin="$(mktemp)"
    head_dev="$(mktemp)"
    head -c 1048576 "$iso" >"$head_bin"
    sudo dd if="$raw" bs=1m count=1 of="$head_dev" >/dev/null 2>&1 || true
    if cmp -s "$head_bin" "$head_dev"; then
        rm -f "$head_bin" "$head_dev"
        return 0
    fi
    rm -f "$head_bin" "$head_dev"
    return 1
}

main() {
    require_macos
    need_cmd diskutil
    need_cmd curl
    need_cmd awk
    need_cmd sed
    need_cmd stat
    need_cmd cmp

    mkdir -p "$WORKDIR"
    iso="$WORKDIR/$ISO_NAME"
    sums="$WORKDIR/SHA256SUMS"
    sig="$WORKDIR/SHA256SUMS.gpg"

    log "workdir: $WORKDIR"
    download "$ISO_URL" "$iso"
    download "$SUMS_URL" "$sums"
    download "$SUMS_GPG_URL" "$sig"

    verify_sha256 "$iso" "$sums"
    verify_gpg_informational "$sums" "$sig"

    mapfile_disks="$(list_external_disks)"
    if [ -z "$mapfile_disks" ]; then
        die "no EXTERNAL PHYSICAL disks found - nothing to write to.
Attach the USB stick (and only the USB stick) and run this again."
    fi

    boot="$(boot_disk)"
    log "external physical disks found:"
    for d in $mapfile_disks; do
        size="$(disk_field "$d" "Disk Size")"
        model="$(disk_field "$d" "Device / Media Name")"
        proto="$(disk_field "$d" "Protocol")"
        log "  disk$d  ${size:-unknown}  ${model:-unknown}  proto=${proto:-unknown}"
        if [ "$d" = "$boot" ]; then
            log "    WARNING: disk$d is the current boot disk and must not be used"
        fi
    done

    printf 'Target disk number (from the list above): '
    IFS= read -r target
    [ -n "$target" ] || die "no target selected"

    valid=0
    for d in $mapfile_disks; do
        [ "$d" = "$target" ] && valid=1
    done
    [ "$valid" -eq 1 ] || die "disk$target is not in the list of external physical disks - refusing to write"
    [ "$target" != "$boot" ] || die "disk$target is the boot disk - refusing to write"

    size="$(disk_field "$target" "Disk Size")"
    model="$(disk_field "$target" "Device / Media Name")"
    isosize="$(stat -f %z "$iso")"
    log "target: disk$target  $size  ${model:-unknown}"
    log "image : $ISO_NAME  $isosize bytes"
    log "THIS WILL ERASE disk$target COMPLETELY."

    printf 'Type exactly "%s %s" to confirm: ' "$CONFIRM_PREFIX" "$target"
    IFS= read -r confirm
    if [ "$confirm" != "$CONFIRM_PREFIX $target" ]; then
        die "confirmation phrase did not match - nothing was written"
    fi

    if already_written "$target" "$iso"; then
        log "disk$target already contains this image (size + first MiB match) - skipping the write"
        diskutil eject "/dev/$target" || log "eject failed - unplug the stick manually"
        log "done"
        return 0
    fi

    log "unmounting disk$target"
    diskutil unmountDisk "/dev/$target" || log "unmount reported an error - continuing"

    sudo -v
    log "writing $ISO_NAME to /dev/r$target (bs=4m) - this takes a while"
    sudo dd if="$iso" of="/dev/r$target" bs=4m

    log "verifying written size"
    dsize="$(diskutil info "/dev/$target" 2>/dev/null | awk -F': *' '$1 == "Disk Size" {gsub(/[^0-9]/,"",$2); print $2; exit}')"
    if [ "$dsize" != "$isosize" ]; then
        die "size mismatch after write: disk=$dsize iso=$isosize"
    fi
    log "size OK: $dsize bytes"

    if [ "$VERIFY_FULL" = "1" ]; then
        log "full verification requested - reading the whole stick back"
        if sudo dd if="/dev/r$target" bs=4m | cmp -s - "$iso"; then
            log "full byte-for-byte verification OK"
        else
            die "full verification FAILED - the stick does not match the ISO"
        fi
    else
        log "skipping full verification (set HUB_VERIFY_FULL=1 to force it)"
    fi

    diskutil eject "/dev/$target" || log "eject failed - unplug the stick manually"
    log "done - remove the USB stick now"
}

main "$@"
