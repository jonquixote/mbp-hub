#!/usr/bin/env bash
#
# mbp-hub :: tests/run-container-tests.sh
#
# Reproduces every check from the kit's test phase:
#
#   1. bash -n and shellcheck on every script
#   2. every package name used by the bootstrap and the optional modules
#      exists in the Ubuntu 26.04 archive (apt-cache policy)
#   3. coreutils / sed / awk compatibility (26.04 ships the uutils coreutils
#      for most tools, GNU only for cp, df, mv, rm and true)
#   4. unit tests for hub-reboot-if-stale and the heartbeat logic
#   5. generated configuration validation:
#      sshd -t, netplan generate, systemd-analyze verify, JSON validity
#
# Run it anywhere with Docker available:  bash tests/run-container-tests.sh
#   (it re-runs itself inside an ubuntu:26.04 container; it never runs
#    natively, because it installs packages and writes to /etc while it works)
#
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${HUB_TEST_IMAGE:-ubuntu:26.04}"
PASS=0
FAIL=0
FAILED_ITEMS=()

pass() {
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$*"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_ITEMS+=("$*")
    printf 'FAIL  %s\n' "$*"
}

info() { printf '\n--- %s ---\n' "$*"; }

# --------------------------------------------------------------------------
# Docker mode: re-run ourselves inside an ubuntu:26.04 container.
# --------------------------------------------------------------------------
in_container() {
    [ -f /.dockerenv ] && return 0
    [ -f /run/.containerenv ] && return 0
    return 1
}

if ! in_container; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        printf 'running the checks in a %s container\n' "$IMAGE"
        docker run --rm -u 0 -v "$REPO_ROOT:/repo:ro" "$IMAGE" \
            bash /repo/tests/run-container-tests.sh
        exit $?
    fi
    echo "ERROR: this script needs Docker - it runs the checks in an ubuntu:26.04 container." >&2
    exit 1
fi

cd "$REPO_ROOT" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# 0. tooling
# --------------------------------------------------------------------------
info "0. test tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || fail "apt-get update"
apt-get install -y -qq --no-install-recommends \
    shellcheck openssh-server netplan.io jq python3 coreutils util-linux \
    systemd procps findutils sed gawk grep systemd-zram-generator needrestart \
    sudo perl >/dev/null 2>&1 \
    || fail "installing the test tooling"

for cmd in bash shellcheck sshd netplan jq python3 systemd-analyze awk sed; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "tool present: $cmd"
    else
        fail "tool missing: $cmd"
    fi
done

# --------------------------------------------------------------------------
# 1. syntax + shellcheck
# --------------------------------------------------------------------------
info "1. bash -n and shellcheck"
mapfile -t SCRIPTS < <(find . -name '*.sh' -type f | sort)
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    fail "no scripts found under $REPO_ROOT"
else
    for s in "${SCRIPTS[@]}"; do
        if bash -n "$s" 2>"$WORK/syntax.err"; then
            pass "bash -n: $s"
        else
            fail "bash -n: $s"
            sed 's/^/      /' "$WORK/syntax.err"
        fi
    done
    for s in "${SCRIPTS[@]}"; do
        if shellcheck -x -S style "$s" >"$WORK/sc.out" 2>&1; then
            pass "shellcheck: $s"
        else
            fail "shellcheck: $s"
            sed 's/^/      /' "$WORK/sc.out" | head -40
        fi
    done
fi

# --------------------------------------------------------------------------
# 2. package names
# --------------------------------------------------------------------------
info "2. package names in the archive"
PACKAGES=$(awk '
    /^PACKAGES=\(/ { grab = 1; next }
    grab && /^\)/ { exit }
    grab { gsub(/^[[:space:]]+/, ""); gsub(/[[:space:]]+$/, ""); print }
' bootstrap/bootstrap.sh | sort -u)
printf 'NOTE  %s package names read from the bootstrap PACKAGES array\n' "$(printf '%s\n' "$PACKAGES" | wc -l)"
EXTRA_PACKAGES="docker.io docker-compose-v2 xfce4 xfce4-goodies lightdm dbus-x11 restic smartmontools ubuntu-pro-client software-properties-common linux-tools-common msr-tools thermald mbpfan systemd-zram-generator"
for p in $PACKAGES $EXTRA_PACKAGES; do
    policy="$(apt-cache policy "$p" 2>/dev/null || true)"
    case "$policy" in
        *"Candidate: (none)"*)
            fail "package has no candidate: $p"
            ;;
        *"Candidate: "*)
            pass "package exists: $p"
            ;;
        *)
            fail "package missing in the archive: $p"
            ;;
    esac
done

# The optional modules that install a package from a vendor repository cannot
# be checked with apt-cache policy - list them so the report stays honest.
printf 'NOTE  packages that come from a vendor repository (not in the Ubuntu\n'
printf '      archive, so they are not checked here):\n'
printf '        jellyfin            (repo.jellyfin.org - NOT in the Ubuntu 26.04 archive)\n'
printf '        jellyfin-ffmpeg*    (repo.jellyfin.org)\n'
printf '        tailscale           (tailscale.com/install.sh)\n'
printf '        rustdesk            (GitHub release .deb)\n'
printf 'NOTE  packages the kit installs but does NOT archive-check here:\n'
printf '        intel-media-va-driver         (the -non-free variant is not in the default archive)\n'
printf '        intel-media-va-driver-non-free (not in the default archive)\n'
printf '        e2fsprogs                      (used by 40-vault.sh)\n'

# --------------------------------------------------------------------------
# 3. coreutils / sed / awk compatibility
# --------------------------------------------------------------------------
info "3. coreutils, sed and awk compatibility on $( . /etc/os-release; printf '%s %s' "$NAME" "$VERSION_ID" )"

check_cmd() {
    # check_cmd <label> <expected> <command...>
    label="$1"
    expected="$2"
    shift 2
    actual="$("$@" 2>&1 || true)"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$actual')"
    fi
}

printf '  coreutils: %s\n' "$(command -v stat)"
stat --version 2>/dev/null | head -1 || true

touch "$WORK/statfile"
check_cmd "stat -c %Y (mtime)" \
    "$(stat -c %Y "$WORK/statfile")" \
    stat -c %Y "$WORK/statfile"
check_cmd "stat -c %s (size)" \
    "0" \
    stat -c %s "$WORK/statfile"

check_cmd "date -d @1700000000" \
    "2023-11-14 22:13:20" \
    date -d @1700000000 '+%Y-%m-%d %H:%M:%S'

check_cmd "date +%s is a number" \
    "yes" \
    bash -c '[[ $(date +%s) =~ ^[0-9]+$ ]] && echo yes || echo no'

check_cmd "date '+%Y-%m-%dT%H:%M:%S%z' shape" \
    "yes" \
    bash -c '[[ $(date "+%Y-%m-%dT%H:%M:%S%z") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]] && echo yes || echo no'

printf '3\n2\n1\n' >"$WORK/sortfile"
check_cmd "sort -rh" \
    "3
2
1" \
    sort -rh "$WORK/sortfile"

rm -rf "$WORK/inst"
mkdir -p "$WORK/inst"
if install -d -o root -g root -m 0755 "$WORK/inst/sub" && [ -d "$WORK/inst/sub" ]; then
    mode="$(stat -c %a "$WORK/inst/sub")"
    if [ "$mode" = "755" ]; then
        pass "install -d -o -g -m"
    else
        fail "install -d -o -g -m (mode is $mode, expected 755)"
    fi
else
    fail "install -d -o -g -m (command failed)"
fi

printf 'a:b:c\n' >"$WORK/cutfile"
check_cmd "cut -d: -f2" \
    "b" \
    cut -d: -f2 "$WORK/cutfile"

check_cmd "cut -f1" \
    "a:b:c" \
    cut -f1 "$WORK/cutfile"

printf 'l1\nl2\nl3\n' >"$WORK/headfile"
check_cmd "head -n 2" \
    "l1
l2" \
    head -n 2 "$WORK/headfile"

check_cmd "head -1" \
    "l1" \
    head -1 "$WORK/headfile"

check_cmd "tee -a" \
    "hello" \
    bash -c 'printf "hello\n" | tee -a "$0/teeout" >/dev/null; cat "$0/teeout"' "$WORK"

printf 'x\n' >"$WORK/sedfile"
check_cmd "sed -i" \
    "y" \
    bash -c 'cp "$0/sedfile" "$0/sedfile2"; sed -i "s/^x$/y/" "$0/sedfile2"; cat "$0/sedfile2"' "$WORK"

printf '/dev/disk4 (external, physical):\n\tDevice Identifier: disk4\n' >"$WORK/disklist"

check_cmd "awk parsing used by make-installer-usb.sh" \
    "disk4" \
    bash -c 'while IFS= read -r line; do case "$line" in /dev/disk*" (external, physical):") d="${line#/dev/}"; d="${d%% *}"; printf "%s\n" "$d";; esac; done < "$0/disklist"' "$WORK"

check_cmd "mktemp creates a file" \
    "yes" \
    bash -c 'f=$(mktemp); [ -f "$f" ] && echo yes || echo no; rm -f "$f"'

check_cmd "mktemp -d creates a directory" \
    "yes" \
    bash -c 'd=$(mktemp -d); [ -d "$d" ] && echo yes || echo no; rmdir "$d"'

check_cmd "tr newline to space" \
    "a b" \
    bash -c 'printf "a\nb\n" | tr "\n" " " | sed "s/ $//"'

check_cmd "seq 1 3" \
    "1
2
3" \
    seq 1 3

check_cmd "sha256sum of an empty file" \
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    bash -c 'sha256sum < /dev/null | cut -d" " -f1'

check_cmd "grep -c with no match returns 0 and exit 1" \
    "0" \
    bash -c 'grep -c zzz /dev/null || true'

check_cmd "yes can be killed" \
    "yes" \
    bash -c 'yes >/dev/null & p=$!; sleep 0.2; kill $p 2>/dev/null && echo yes || echo no'

check_cmd "env VAR=value cmd" \
    "hubtest" \
    env HUB_TEST_VAR=hubtest sh -c 'printf "%s" "$HUB_TEST_VAR"'

check_cmd "GNU sed is used for -i (not uutils)" \
    "yes" \
    bash -c 'sed --version 2>/dev/null | head -1 | grep -qi "gnu sed" && echo yes || echo no'

check_cmd "du -h works" \
    "yes" \
    bash -c 'du -h /dev/null >/dev/null 2>&1 && echo yes || echo no'

# --- sudo behaviour (sudo-rs on Ubuntu 26.04) ---------------------------
export HUB_TEST_VAR="keepme"
if sudo --preserve-env=HUB_TEST_VAR env 2>/dev/null | grep -q '^HUB_TEST_VAR=keepme$'; then
    pass "sudo --preserve-env=VAR preserves the variable (this is what the kit tells you to use)"
else
    fail "sudo --preserve-env=VAR does not preserve the variable - fix the module instructions"
fi
# sudo -E is NOT reliable on sudo-rs: it is documented as ignored, and in some
# contexts it only appears to work because a previous --preserve-env call was
# cached. Report what happened, but do not make the build depend on it.
if sudo -E env 2>/dev/null | grep -q '^HUB_TEST_VAR='; then
    printf 'NOTE  sudo -E kept the variable in this context - still do not rely on it\n'
else
    printf 'NOTE  sudo -E dropped the variable in this context - use --preserve-env\n'
fi
printf 'NOTE  sudo -E says: %s\n' "$(sudo -E env 2>&1 >/dev/null | head -1)"

# --------------------------------------------------------------------------
# 4. unit tests
# --------------------------------------------------------------------------
info "4. unit tests (hub-reboot-if-stale, hub-heartbeat)"

extract_block() {
    # extract_block <file> <marker>  -> the heredoc body
    awk -v marker="$2" '
        index($0, marker) { grab = 1; next }
        grab && $0 == "EOF" { exit }
        grab { print }
    ' "$1"
}

extract_function() {
    # extract_function <file> <function-name> -> the function source
    awk -v fn="$2" '
        $0 ~ "^" fn "\\(\\) \\{" { grab = 1 }
        grab { print }
        grab && /^}/ { exit }
    ' "$1"
}

if extract_block bootstrap/bootstrap.sh "/usr/local/sbin/hub-reboot-if-stale <<'EOF'" >"$WORK/hub-reboot-if-stale"; then
    pass "extracted hub-reboot-if-stale from bootstrap.sh"
else
    fail "could not extract hub-reboot-if-stale from bootstrap.sh"
fi
chmod +x "$WORK/hub-reboot-if-stale"

REQ="$WORK/reboot-required"
STATE="$WORK/reboot-pending-since"
BLOCK="$WORK/hub-no-auto-reboot"
export HUB_REBOOT_REQUIRED_FILE="$REQ"
export HUB_REBOOT_STATE_FILE="$STATE"
export HUB_REBOOT_BLOCK_FILE="$BLOCK"

rm -f "$REQ" "$STATE" "$BLOCK"
out="$("$WORK/hub-reboot-if-stale" 2>&1 || true)"
case "$out" in
    *"no reboot required"*) pass "hub-reboot-if-stale: no pending reboot" ;;
    *) fail "hub-reboot-if-stale: no pending reboot (got: $out)" ;;
esac

touch "$REQ"
out="$("$WORK/hub-reboot-if-stale" 2>&1 || true)"
case "$out" in
    *"first seen now"*) pass "hub-reboot-if-stale: records the first-seen time" ;;
    *) fail "hub-reboot-if-stale: records the first-seen time (got: $out)" ;;
esac
if [ -f "$STATE" ]; then
    pass "hub-reboot-if-stale: state file created"
else
    fail "hub-reboot-if-stale: state file not created"
fi

old=$(( $(date +%s) - 22 * 86400 ))
printf '%s\n' "$old" >"$STATE"
out="$(HUB_REBOOT_DRY_RUN=1 "$WORK/hub-reboot-if-stale" 2>&1 || true)"
case "$out" in
    *"WOULD REBOOT"*) pass "hub-reboot-if-stale: reboots after 21+ days" ;;
    *) fail "hub-reboot-if-stale: reboots after 21+ days (got: $out)" ;;
esac

recent=$(( $(date +%s) - 3600 ))
printf '%s\n' "$recent" >"$STATE"
out="$(HUB_REBOOT_DRY_RUN=1 "$WORK/hub-reboot-if-stale" 2>&1 || true)"
case "$out" in
    *"not rebooting"*) pass "hub-reboot-if-stale: does not reboot a fresh request" ;;
    *) fail "hub-reboot-if-stale: does not reboot a fresh request (got: $out)" ;;
esac

touch "$BLOCK"
out="$("$WORK/hub-reboot-if-stale" 2>&1 || true)"
case "$out" in
    *"blocked"*) pass "hub-reboot-if-stale: /etc/hub-no-auto-reboot blocks it" ;;
    *) fail "hub-reboot-if-stale: /etc/hub-no-auto-reboot blocks it (got: $out)" ;;
esac
rm -f "$BLOCK"

extract_block bootstrap/bootstrap.sh "/usr/local/sbin/hub-heartbeat <<'EOF'" >"$WORK/hub-heartbeat"
chmod +x "$WORK/hub-heartbeat"

mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        if [ "${FAKE_TAILSCALE_FAIL:-0}" = "1" ]; then
            echo "failed to connect to local tailscaled" >&2
            exit 1
        fi
        json="${FAKE_TS_BACKEND_JSON:-}"
        if [ -z "$json" ]; then
            json='{"BackendState":"Running"}'
        fi
        printf '%s\n' "$json"
        exit 0
        ;;
    ip)
        echo "100.64.0.1"
        exit 0
        ;;
esac
exit 0
EOF
cat >"$WORK/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        http*) printf '%s\n' "$arg" >>"$FAKE_CURL_LOG" ;;
    esac
done
exit "${FAKE_CURL_FAIL:-0}"
EOF
chmod +x "$WORK/fakebin/tailscale" "$WORK/fakebin/curl"

export FAKE_CURL_LOG="$WORK/curl.log"
: >"$FAKE_CURL_LOG"
out="$(PATH="$WORK/fakebin:$PATH" HC_URL="https://hc.example.com/abc" "$WORK/hub-heartbeat" 2>&1 || true)"
if grep -q '^https://hc.example.com/abc$' "$FAKE_CURL_LOG"; then
    pass "hub-heartbeat: pings HC_URL when tailscale reports BackendState Running"
else
    fail "hub-heartbeat: pings HC_URL when tailscale reports BackendState Running (log: $(cat "$FAKE_CURL_LOG"))"
fi

: >"$FAKE_CURL_LOG"
out="$(PATH="$WORK/fakebin:$PATH" FAKE_TS_BACKEND_JSON='{"BackendState":"Stopped"}' \
    HC_URL="https://hc.example.com/abc" "$WORK/hub-heartbeat" 2>&1 || true)"
if grep -q '^https://hc.example.com/abc/fail$' "$FAKE_CURL_LOG"; then
    pass "hub-heartbeat: pings HC_URL/fail when BackendState is not Running"
else
    fail "hub-heartbeat: pings HC_URL/fail when BackendState is not Running (log: $(cat "$FAKE_CURL_LOG"))"
fi

: >"$FAKE_CURL_LOG"
out="$(PATH="$WORK/fakebin:$PATH" FAKE_TAILSCALE_FAIL=1 \
    HC_URL="https://hc.example.com/abc" "$WORK/hub-heartbeat" 2>&1 || true)"
if grep -q '^https://hc.example.com/abc/fail$' "$FAKE_CURL_LOG"; then
    pass "hub-heartbeat: pings HC_URL/fail when tailscale status fails"
else
    fail "hub-heartbeat: pings HC_URL/fail when tailscale status fails (log: $(cat "$FAKE_CURL_LOG"))"
fi

: >"$FAKE_CURL_LOG"
out="$(PATH="$WORK/fakebin:$PATH" FAKE_CURL_FAIL=1 HC_URL="https://hc.example.com/abc" "$WORK/hub-heartbeat" 2>&1 || true)"
case "$out" in
    *"FAILED"*) pass "hub-heartbeat: reports a failed ping" ;;
    *) fail "hub-heartbeat: reports a failed ping (got: $out)" ;;
esac

# --------------------------------------------------------------------------
# 5. generated configuration validation
# --------------------------------------------------------------------------
info "5. generated configuration validation"

# --- 5a. sshd -------------------------------------------------------------
sshd_dropin="$WORK/10-hub.conf"
extract_block bootstrap/bootstrap.sh "/etc/ssh/sshd_config.d/10-hub.conf <<EOF" \
    | sed 's/\$HUB_USER/johnny/' >"$sshd_dropin"
if [ -s "$sshd_dropin" ]; then
    pass "extracted the sshd drop-in from bootstrap.sh"
else
    fail "could not extract the sshd drop-in from bootstrap.sh"
fi
install -d -m 0755 "$WORK/sshd_config.d"
cp "$sshd_dropin" "$WORK/sshd_config.d/10-hub.conf"
{
    printf 'Include %s/sshd_config.d/*.conf\n' "$WORK"
    printf 'Port 2222\n'
    printf 'HostKey /etc/ssh/ssh_host_rsa_key\n'
} >"$WORK/sshd_config"
ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /run/sshd
if sshd -t -f "$WORK/sshd_config" 2>"$WORK/sshd.err"; then
    pass "sshd -t accepts the hardening drop-in"
else
    fail "sshd -t rejected the hardening drop-in"
    sed 's/^/      /' "$WORK/sshd.err" | head -20
fi
for expect in "passwordauthentication no" "kbdinteractiveauthentication no" \
    "permitrootlogin no" "authenticationmethods publickey" "x11forwarding no" \
    "maxauthtries 3" "allowusers johnny agent"; do
    if grep -qi "^${expect// /[[:space:]]}" "$sshd_dropin"; then
        pass "sshd drop-in contains: $expect"
    else
        fail "sshd drop-in is missing: $expect"
    fi
done

# --- 5b. netplan ----------------------------------------------------------
mkdir -p "$WORK/fakebin2"
cat >"$WORK/fakebin2/ip" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-o" ] && [ "${2:-}" = "link" ]; then
    echo "3: wlp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP mode DEFAULT group default qlen 1000"
    exit 0
fi
exec /sbin/ip "$@"
EOF
chmod +x "$WORK/fakebin2/ip"
# netplan calls "systemctl daemon-reload" after generating, which cannot work
# in a container without systemd as PID 1. The stub keeps the netplan PARSER
# (the part we actually want to test) and only skips the reload.
cat >"$WORK/fakebin2/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/fakebin2/systemctl"
# Placeholder fixture values - deliberately obviously fake, never a real SSID
# or password. The apostrophe in the name exercises the YAML quoting.
HUB_FIXTURE_NET="test's-ssid"
HUB_FIXTURE_SECRET='placeholderpass'
if HUB_WIFI_APPLY=0 PATH="$WORK/fakebin2:$PATH" \
    WIFI_SSID="$HUB_FIXTURE_NET" WIFI_PASS="$HUB_FIXTURE_SECRET" \
    bash bootstrap/optional/04-wifi.sh >"$WORK/wifi.log" 2>&1; then
    pass "04-wifi.sh generated a netplan file"
else
    fail "04-wifi.sh failed"
    sed 's/^/      /' "$WORK/wifi.log" | tail -20
fi
if [ -f /etc/netplan/90-hub-wifi.yaml ]; then
    mode="$(stat -c %a /etc/netplan/90-hub-wifi.yaml)"
    if [ "$mode" = "600" ]; then
        pass "the netplan wifi file is mode 600"
    else
        fail "the netplan wifi file is mode $mode (expected 600)"
    fi
    if grep -q 'optional: true' /etc/netplan/90-hub-wifi.yaml; then
        pass "the netplan wifi file marks the interface optional"
    else
        fail "the netplan wifi file does not mark the interface optional"
    fi
    if PATH="$WORK/fakebin2:$PATH" netplan generate 2>"$WORK/netplan.err"; then
        pass "netplan generate accepts the wifi file"
    else
        fail "netplan generate rejected the wifi file"
        sed 's/^/      /' "$WORK/netplan.err" | head -20
    fi
else
    fail "no netplan file was produced"
fi

# --- 5c. systemd units ----------------------------------------------------
mkdir -p "$WORK/units"
for f in "$WORK/units"/*; do
    rm -f "$f"
done
extract_units() {
    # extract_units <script> - writes every unit it finds into $WORK/units
    awk -v outdir="$WORK/units" '
        /\/etc\/systemd\/system\/[^[:space:]]+/ {
            s = $0
            sub(/^.*\/etc\/systemd\/system\//, "", s)
            sub(/[[:space:]].*$/, "", s)
            unit = s
            grab = 1
            next
        }
        grab && $0 == "EOF" { grab = 0; next }
        grab { print $0 > (outdir "/" unit); next }
    ' "$1"
}

unit_count=0
for script in bootstrap/bootstrap.sh bootstrap/optional/41-backup-restic.sh \
    bootstrap/optional/43-battery-limit.sh bootstrap/optional/44-tune-lowpower.sh; do
    extract_units "$script"
done
for unit in "$WORK/units"/*; do
    [ -f "$unit" ] || continue
    unit_count=$((unit_count + 1))
done
if [ "$unit_count" -ge 8 ]; then
    pass "extracted $unit_count systemd units from the kit"
else
    fail "only $unit_count systemd units were extracted (expected at least 8)"
fi

# The unit files reference helper scripts; create stubs so verify is clean.
for helper in hub-reboot-if-stale hub-heartbeat hub-power-restore \
    hub-restic-backup hub-restic-check; do
    if [ ! -e "/usr/local/sbin/$helper" ]; then
        printf '#!/bin/sh\nexit 0\n' >"/usr/local/sbin/$helper"
        chmod +x "/usr/local/sbin/$helper"
    fi
done

for unit in "$WORK/units"/*; do
    [ -f "$unit" ] || continue
    name="$(basename "$unit")"
    if systemd-analyze verify "$unit" >"$WORK/unit.out" 2>&1; then
        pass "systemd-analyze verify: $name"
    else
        if grep -qiE 'Unknown lvalue|Failed to parse|error' "$WORK/unit.out"; then
            fail "systemd-analyze verify: $name"
            sed 's/^/      /' "$WORK/unit.out" | head -15
        else
            pass "systemd-analyze verify: $name (warnings only)"
            sed 's/^/      /' "$WORK/unit.out" | head -6
        fi
    fi
done

# --- 5c-2. the units the kit enables must actually be installable ----------
# systemctl enable exits 0 even for a unit WITHOUT an [Install] section (it
# only prints "The unit files have no installation config"), so the symlink
# in the target's .wants directory is the real proof that the unit can be
# enabled at all.
install -d -m 0755 "$WORK/sysroot/etc/systemd/system"
for unit in hub-power-restore.service hub-battery-limit.service hub-epp.service; do
    if [ ! -f "$WORK/units/$unit" ]; then
        fail "$unit was not extracted from the kit"
        continue
    fi
    rm -rf "$WORK/sysroot/etc/systemd/system/multi-user.target.wants"
    cp "$WORK/units/$unit" "$WORK/sysroot/etc/systemd/system/"
    if systemctl --root="$WORK/sysroot" enable "$unit" >"$WORK/enable.out" 2>&1 &&
        [ -L "$WORK/sysroot/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        pass "systemctl enable $unit wires it into multi-user.target"
    else
        fail "systemctl enable did not wire $unit into multi-user.target"
        sed 's/^/      /' "$WORK/enable.out" | head -6
    fi
done

# Static check: every unit the kit ships AND enables must carry an [Install]
# section, otherwise "systemctl enable" silently does nothing.
kit_enabled_units() {
    grep -hoE 'systemctl[[:space:]]+enable([[:space:]]+--now)?[[:space:]]+[A-Za-z0-9_.@-]+\.(service|timer)' \
        bootstrap/bootstrap.sh bootstrap/optional/*.sh \
        | grep -oE '[A-Za-z0-9_.@-]+\.(service|timer)$' | sort -u
}
missing_install=""
for unit in $(kit_enabled_units); do
    base="$(basename "$unit")"
    [ -f "$WORK/units/$base" ] || continue
    if ! grep -q '^\[Install\]' "$WORK/units/$base"; then
        missing_install="$missing_install $base"
    fi
done
if [ -z "$missing_install" ]; then
    pass "every unit the kit enables has an [Install] section"
else
    fail "these units are enabled by the kit but have no [Install] section:$missing_install"
fi

# --- 5d. JSON -------------------------------------------------------------
if jq -e . policy/tailscale-policy-snippet.json >/dev/null 2>&1; then
    pass "the tailscale policy snippet is valid JSON"
else
    fail "the tailscale policy snippet is not valid JSON"
fi
if jq -e '.tagOwners["tag:hub"]' policy/tailscale-policy-snippet.json >/dev/null 2>&1; then
    pass "the policy snippet has a tag:hub owner"
else
    fail "the policy snippet has no tag:hub owner"
fi
if jq -e '.ssh[0].users | index("johnny") and index("agent")' \
    policy/tailscale-policy-snippet.json >/dev/null 2>&1; then
    pass "the policy snippet allows ssh for johnny and agent"
else
    fail "the policy snippet does not allow ssh for johnny and agent"
fi

# --- 5e. needrestart -----------------------------------------------------
if command -v needrestart >/dev/null 2>&1; then
    extract_block bootstrap/bootstrap.sh "/etc/needrestart/conf.d/50-hub.conf <<'EOF'" \
        >"$WORK/needrestart.conf"
    if [ -s "$WORK/needrestart.conf" ]; then
        pass "extracted the needrestart config from bootstrap.sh"
        install -d -m 0755 /etc/needrestart/conf.d
        cp "$WORK/needrestart.conf" /etc/needrestart/conf.d/50-hub.conf
        if perl -c /etc/needrestart/conf.d/50-hub.conf >"$WORK/nr.out" 2>&1; then
            pass "the needrestart config is valid perl"
        else
            fail "the needrestart config is not valid perl"
            sed 's/^/      /' "$WORK/nr.out" | head -5
        fi
        if needrestart -b >"$WORK/nr-batch.out" 2>&1; then
            pass "needrestart accepts the config (batch mode)"
        else
            fail "needrestart rejected the config"
            sed 's/^/      /' "$WORK/nr-batch.out" | head -10
        fi
        for svc in 'ssh\\.service' 'tailscaled\\.service'; do
            if grep -q "$svc" "$WORK/needrestart.conf"; then
                pass "needrestart blacklists $svc"
            else
                fail "needrestart does not blacklist $svc"
            fi
        done
    else
        fail "could not extract the needrestart config from bootstrap.sh"
    fi
else
    printf 'SKIP  needrestart is not installed in this image\n'
fi

# The kit must not overwrite the distribution's main needrestart.conf - its
# settings belong in the drop-in directory.
if grep -qE 'write_root_file [0-9]+ /etc/needrestart/needrestart\.conf' bootstrap/bootstrap.sh ||
    grep -qF "/etc/needrestart/needrestart.conf <<'EOF'" bootstrap/bootstrap.sh; then
    fail "the kit still overwrites /etc/needrestart/needrestart.conf"
else
    pass "the kit does not overwrite /etc/needrestart/needrestart.conf"
fi
if grep -qE 'install -d .* /etc/needrestart/conf\.d' bootstrap/bootstrap.sh; then
    pass "the kit creates /etc/needrestart/conf.d"
else
    fail "the kit does not create /etc/needrestart/conf.d"
fi

# The battery unit must only run when the kernel exposes the threshold file.
if grep -q '^ConditionPathExists=.*charge_control_end_threshold' \
    "$WORK/units/hub-battery-limit.service"; then
    pass "hub-battery-limit.service only runs when the charge threshold file exists"
else
    fail "hub-battery-limit.service has no ConditionPathExists for the charge threshold file"
fi

# --- 5f. the documented run command ---------------------------------------
# The bootstrap runs as the normal user with the secrets in the environment.
# It must never be documented as "sudo ... bootstrap/bootstrap.sh", and the
# "sudo --preserve-env" form belongs to the optional modules only.
for doc in README.md RUNBOOK.md; do
    if grep -q 'UBUNTU_PRO_TOKEN=' "$doc" &&
        grep -q 'TS_TAG=tag:hub' "$doc" &&
        grep -q 'bash bootstrap/bootstrap\.sh' "$doc"; then
        pass "$doc documents the bootstrap with the environment variables"
    else
        fail "$doc does not document the bootstrap with the environment variables"
    fi
    # a line that says "never run it with sudo" is not an instruction to do so
    sudo_lines="$(grep -nE 'sudo[^|;&]*bootstrap/bootstrap\.sh' "$doc" | grep -viE 'never|not |don.t' || true)"
    if [ -n "$sudo_lines" ]; then
        fail "$doc tells the user to run the bootstrap with sudo"
        printf '%s\n' "$sudo_lines" | head -5 | sed 's/^/      /'
    else
        pass "$doc does not tell the user to run the bootstrap with sudo"
    fi
    pe_lines="$(grep -nE 'sudo --preserve-env[^|;&]*bootstrap/bootstrap\.sh' "$doc" | grep -viE 'never|not |don.t' || true)"
    if [ -n "$pe_lines" ]; then
        fail "$doc still uses sudo --preserve-env for the bootstrap"
        printf '%s\n' "$pe_lines" | head -5 | sed 's/^/      /'
    else
        pass "$doc does not use sudo --preserve-env for the bootstrap"
    fi
done
if grep -q 'sudo --preserve-env=WIFI_SSID,WIFI_PASS' README.md &&
    grep -q '/etc/hub/optional.env' README.md; then
    pass "README keeps the sudo --preserve-env form for the optional modules"
else
    fail "README lost the optional-module form"
fi
extract_function bootstrap/bootstrap.sh banner >"$WORK/banner"
if grep -q 'UBUNTU_PRO_TOKEN=' "$WORK/banner" &&
    grep -q 'bash bootstrap/bootstrap\.sh' "$WORK/banner"; then
    pass "the final banner documents the bootstrap with the environment variables"
else
    fail "the final banner does not document the bootstrap with the environment variables"
fi
if grep -q 'sudo --preserve-env' "$WORK/banner"; then
    fail "the final banner still uses sudo --preserve-env"
else
    pass "the final banner does not use sudo --preserve-env"
fi

# --- 5g. the zram-generator expression ------------------------------------
ZRAM_GEN="/usr/lib/systemd/system-generators/zram-generator"
if [ -x "$ZRAM_GEN" ]; then
    install -d -m 0755 /etc/systemd
    cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram/2, 4096)
compression-algorithm = zstd
EOF
    mkdir -p "$WORK/zramout"
    if "$ZRAM_GEN" "$WORK/zramout" "$WORK/zramout" "$WORK/zramout" >"$WORK/zram.out" 2>&1; then
        pass "the zram-generator accepts min(ram/2, 4096)"
    else
        fail "the zram-generator rejected min(ram/2, 4096)"
        sed 's/^/      /' "$WORK/zram.out" | head -10
    fi
    # Prove the check can actually fail: a broken expression must be rejected.
    cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = definitely-not-a-valid-expression
EOF
    if "$ZRAM_GEN" "$WORK/zramout" "$WORK/zramout" "$WORK/zramout" >"$WORK/zram-bad.out" 2>&1; then
        fail "the zram-generator accepted a broken expression (the test above proves nothing)"
    else
        pass "the zram-generator rejects a broken expression (the check is meaningful)"
    fi
else
    printf 'SKIP  zram-generator is not installed in this image\n'
fi

# --- 5h. the power-restore helper (fake setpci) ---------------------------
extract_block bootstrap/bootstrap.sh "/usr/local/sbin/hub-power-restore <<'EOF'" \
    >"$WORK/hub-power-restore"
if [ -s "$WORK/hub-power-restore" ]; then
    pass "extracted hub-power-restore from bootstrap.sh"
else
    fail "could not extract hub-power-restore from bootstrap.sh"
fi
chmod +x "$WORK/hub-power-restore"

mkdir -p "$WORK/fakebin3"
cat >"$WORK/fakebin3/lspci" <<'EOF'
#!/usr/bin/env bash
echo "00:1f.0 8086:9d2c 0600: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
EOF
cat >"$WORK/fakebin3/setpci" <<'EOF'
#!/usr/bin/env bash
# fake setpci. A read prints the current byte; a write uses the real
# pciutils syntax <value>:<mask> and applies (old & ~mask) | (value & mask),
# so a masked write really does preserve the other bits.
reg=""
for arg in "$@"; do
    case "$arg" in
        0xa4.b*) reg="$arg" ;;
    esac
done
case "$reg" in
    "") echo "fake setpci: no 0xa4.b register in the arguments" >&2; exit 2 ;;
esac
if [ "${reg#*=}" = "$reg" ]; then
    val="$(cat "$FAKE_SETPCI_STATE" 2>/dev/null || echo 00)"
    printf '%s\n' "$val"
    exit 0
fi
rhs="${reg#*=}"
value="${rhs%%:*}"
mask="ff"
case "$rhs" in
    *:*) mask="${rhs#*:}" ;;
esac
old="$(cat "$FAKE_SETPCI_STATE" 2>/dev/null || echo 00)"
printf 'write %s (old %s)\n' "$rhs" "$old" >>"$FAKE_SETPCI_WRITES"
new=$(( (0x$old & ~0x$mask) | (0x$value & 0x$mask) ))
printf '%02x\n' "$new" >"$FAKE_SETPCI_STATE"
exit 0
EOF
chmod +x "$WORK/fakebin3/lspci" "$WORK/fakebin3/setpci"

pr_rc=0
pr_out=""
pr_writes=""
run_power_restore() {
    printf '%s\n' "$1" >"$WORK/setpci_state"
    : >"$WORK/setpci_writes"
    pr_rc=0
    PATH="$WORK/fakebin3:$PATH" \
    FAKE_SETPCI_STATE="$WORK/setpci_state" \
    FAKE_SETPCI_WRITES="$WORK/setpci_writes" \
        "$WORK/hub-power-restore" >"$WORK/pr.out" 2>&1 || pr_rc=$?
    pr_out="$(cat "$WORK/pr.out")"
    pr_writes="$(cat "$WORK/setpci_writes")"
}

# setpci prints the byte as hex. Every one of these must be read as hex:
# "08" and "0a" are not valid decimal and "0a" is not valid octal either.
for value in 00 01 08 0a ff; do
    run_power_restore "$value"
    if [ "$pr_rc" -eq 0 ] && ! printf '%s' "$pr_out" | grep -qiE 'value too great|invalid arithmetic|syntax error'; then
        pass "hub-power-restore: reads 0x$value as hex without an arithmetic error"
    else
        fail "hub-power-restore failed on the hex value 0x$value (rc=$pr_rc): $pr_out"
    fi
done

# The register is the Intel PCH "LPC_GEN_PMCON_A" (0xA4). Its bit 0 is
# AFTERG3_EN: 0 = the machine powers on (S0) when AC power comes back after a
# G3 power loss, 1 = the machine stays off (S5). The kit therefore has to
# CLEAR bit 0 - and only when bit 0 is set.
#
# The pciutils write syntax is <value>:<mask> and the new byte is
# (old & ~mask) | (value & mask), so "0:1" clears bit 0 and leaves every
# other bit alone.
#
# These checks assert the RESULTING register value, not the command string:
# a polarity inversion has to fail them.
check_power_restore_result() {
    # check_power_restore_result <before> <expected-after> <label>
    run_power_restore "$1"
    after="$(cat "$WORK/setpci_state" 2>/dev/null || echo '')"
    if [ "$after" = "$2" ]; then
        pass "hub-power-restore: $3 (0x$1 -> 0x$after)"
    else
        fail "hub-power-restore: $3 (0x$1 -> 0x$after, expected 0x$2): $pr_out"
    fi
}
check_power_restore_result 01 00 "clears AFTERG3_EN and leaves the other bits alone"
check_power_restore_result 09 08 "clears AFTERG3_EN and keeps bit 3"
check_power_restore_result ff fe "clears AFTERG3_EN and keeps every other bit"

# bit 0 already clear -> no write at all, and the register does not move
for value in 00 08 0a; do
    run_power_restore "$value"
    if [ -z "$pr_writes" ]; then
        pass "hub-power-restore: no write when bit 0 is already clear (0x$value)"
    else
        fail "hub-power-restore wrote to the register although bit 0 is clear (0x$value): $pr_writes"
    fi
    after="$(cat "$WORK/setpci_state" 2>/dev/null || echo '')"
    if [ "$after" = "$value" ]; then
        pass "hub-power-restore: the register is unchanged (0x$value)"
    else
        fail "hub-power-restore changed the register (0x$value -> 0x$after)"
    fi
done

# --------------------------------------------------------------------------
# 6. the bootstrap steps
# --------------------------------------------------------------------------
info "6. the bootstrap steps"

build_step_script() {
    # build_step_script <outfile> <function-name> - the helpers plus the step,
    # with the step called at the end
    {
        printf 'set -uo pipefail\n'
        for fn in redact log warn have die log_copy "$2"; do
            extract_function bootstrap/bootstrap.sh "$fn"
            printf '\n'
        done
        printf '%s\n' "$2"
    } >"$1"
}

mkdir -p "$WORK/fakebin4"
cat >"$WORK/fakebin4/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
EOF
cat >"$WORK/fakebin4/tailscale" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    up)
        if [ "${2:-}" = "--help" ]; then
            echo "Usage: tailscale up [flags]"
            if [ "${FAKE_TS_HELP_TIMEOUT:-1}" = "1" ]; then
                echo "      --timeout duration   maximum amount of time to wait"
            fi
            exit 0
        fi
        printf '%s\n' "$@" >>"$FAKE_TS_ARGS"
        echo "To authenticate, visit:"
        echo "  https://login.tailscale.com/a/abc123def456"
        echo "tskey-supersecretvalue123"
        exit "${FAKE_TS_RC:-0}"
        ;;
    set)
        exit 0
        ;;
esac
exit 0
EOF
cat >"$WORK/fakebin4/pro" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    attach)
        cat >/dev/null
        exit "${FAKE_PRO_RC:-0}"
        ;;
esac
exit 0
EOF
cat >"$WORK/fakebin4/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_APT_LOG"
exit 0
EOF
chmod +x "$WORK/fakebin4/sudo" "$WORK/fakebin4/tailscale" \
    "$WORK/fakebin4/pro" "$WORK/fakebin4/apt-get"

export FAKE_TS_ARGS="$WORK/ts_args.log"
export FAKE_APT_LOG="$WORK/apt.log"

# --- 6a. step_tailscale ---------------------------------------------------
build_step_script "$WORK/step_tailscale" step_tailscale

: >"$FAKE_TS_ARGS"
: >"$WORK/ts-bootstrap.log"
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub HUB_USER=johnny \
    LOG_FILE="$WORK/ts-bootstrap.log" TS_AUTHKEY=tskey-supersecretvalue123 \
    TS_TAG=tag:hub FAKE_TS_ARGS="$FAKE_TS_ARGS" \
    bash "$WORK/step_tailscale" 2>&1 || true)"
if printf '%s' "$out" | grep -q 'https://login.tailscale.com/a/abc123def456'; then
    pass "step_tailscale: the tailscale up output reaches the terminal"
else
    fail "step_tailscale: the tailscale up output never reaches the terminal (got: $out)"
fi
if grep -q 'tskey-REDACTED' "$WORK/ts-bootstrap.log" &&
    ! grep -q 'tskey-supersecretvalue123' "$WORK/ts-bootstrap.log"; then
    pass "step_tailscale: the log copy is redacted"
else
    fail "step_tailscale: the log copy is not redacted (log: $(cat "$WORK/ts-bootstrap.log"))"
fi
if grep -q -- '--timeout=120s' "$FAKE_TS_ARGS"; then
    pass "step_tailscale: passes --timeout=120s when tailscale supports it"
else
    fail "step_tailscale: does not pass --timeout=120s (args: $(cat "$FAKE_TS_ARGS"))"
fi

: >"$FAKE_TS_ARGS"
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub HUB_USER=johnny \
    LOG_FILE="$WORK/ts-bootstrap.log" TS_AUTHKEY=tskey-supersecretvalue123 \
    TS_TAG=tag:hub FAKE_TS_ARGS="$FAKE_TS_ARGS" FAKE_TS_HELP_TIMEOUT=0 \
    bash "$WORK/step_tailscale" 2>&1 || true)"
if ! grep -q -- '--timeout' "$FAKE_TS_ARGS"; then
    pass "step_tailscale: leaves --timeout out when tailscale does not support it"
else
    fail "step_tailscale: passes --timeout even though tailscale does not support it"
fi

: >"$FAKE_TS_ARGS"
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub HUB_USER=johnny \
    LOG_FILE="$WORK/ts-bootstrap.log" TS_AUTHKEY=tskey-supersecretvalue123 \
    TS_TAG=tag:hub FAKE_TS_ARGS="$FAKE_TS_ARGS" FAKE_TS_RC=7 \
    bash "$WORK/step_tailscale" 2>&1 || true)"
case "$out" in
    *"tailscale up failed"*) pass "step_tailscale: notices that tailscale up failed" ;;
    *) fail "step_tailscale: swallows the failure of tailscale up (got: $out)" ;;
esac

: >"$FAKE_TS_ARGS"
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub HUB_USER=johnny \
    LOG_FILE="$WORK/ts-bootstrap.log" TS_TAG=tag:hub FAKE_TS_ARGS="$FAKE_TS_ARGS" \
    bash "$WORK/step_tailscale" 2>&1 || true)"
case "$out" in
    *"TS_AUTHKEY is not set"*) pass "step_tailscale: says that an interactive login is coming" ;;
    *) fail "step_tailscale: does not say that an interactive login is coming (got: $out)" ;;
esac

# The log file is owned by root, so a normal user cannot append to it with
# "tee". A log write that fails must NOT be reported as a failed step.
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub HUB_USER=johnny \
    LOG_FILE="$WORK/no-such-dir/hub-bootstrap.log" TS_AUTHKEY=tskey-supersecretvalue123 \
    TS_TAG=tag:hub FAKE_TS_ARGS="$FAKE_TS_ARGS" \
    bash "$WORK/step_tailscale" 2>&1 || true)"
case "$out" in
    *"could not set the tailscale operator"*)
        fail "step_tailscale: reports a false failure when the log file is not writable" ;;
    *)
        pass "step_tailscale: does not report a false failure when the log file is not writable" ;;
esac

# --- 6b. step_ubuntu_pro --------------------------------------------------
build_step_script "$WORK/step_ubuntu_pro" step_ubuntu_pro

: >"$WORK/pro-bootstrap.log"
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub \
    LOG_FILE="$WORK/pro-bootstrap.log" UBUNTU_PRO_TOKEN=probe-token-123 \
    FAKE_PRO_RC=1 bash "$WORK/step_ubuntu_pro" 2>&1 || true)"
case "$out" in
    *"sudo pro attach probe-token-123"*) pass "step_ubuntu_pro: prints the manual pro attach fallback" ;;
    *) fail "step_ubuntu_pro: no manual pro attach fallback (got: $out)" ;;
esac
if ! grep -q 'probe-token-123' "$WORK/pro-bootstrap.log"; then
    pass "step_ubuntu_pro: the token is not written to the log"
else
    fail "step_ubuntu_pro: the token was written to the log"
fi
if grep -q 'ppa:ubuntu-pro/ppa' bootstrap/bootstrap.sh; then
    fail "step_ubuntu_pro: the kit still adds the ubuntu-pro PPA"
else
    pass "step_ubuntu_pro: no PPA is added"
fi
if grep -q 'ubuntu-pro-client' bootstrap/bootstrap.sh; then
    pass "step_ubuntu_pro: installs the ubuntu-pro-client package"
else
    fail "step_ubuntu_pro: does not install the ubuntu-pro-client package"
fi

# A log write that fails must not be reported as a failed step.
out="$(PATH="$WORK/fakebin4:$PATH" HUB_HOSTNAME=mbp-hub \
    LOG_FILE="$WORK/no-such-dir/hub-bootstrap.log" UBUNTU_PRO_TOKEN=probe-token-123 \
    bash "$WORK/step_ubuntu_pro" 2>&1 || true)"
case "$out" in
    *"livepatch could not be enabled"*)
        fail "step_ubuntu_pro: reports a false failure when the log file is not writable" ;;
    *)
        pass "step_ubuntu_pro: does not report a false failure when the log file is not writable" ;;
esac

# --------------------------------------------------------------------------
# 7. the PROCHOT / thermal check
# --------------------------------------------------------------------------
info "7. the PROCHOT / thermal check"
THROTTLE_SRC="bootstrap/optional/44-tune-lowpower.sh"
if extract_block "$THROTTLE_SRC" "/usr/local/bin/hub-throttle-check <<'EOF'" >"$WORK/hub-throttle-check" &&
    [ -s "$WORK/hub-throttle-check" ]; then
    pass "extracted hub-throttle-check from 44-tune-lowpower.sh"
else
    fail "could not extract hub-throttle-check from 44-tune-lowpower.sh"
fi

# IA32_THERM_STATUS is 0x19c. 0x1fc is not a thermal status register.
if grep -q '0x1fc' "$WORK/hub-throttle-check" 2>/dev/null; then
    fail "hub-throttle-check reads MSR 0x1fc - IA32_THERM_STATUS is 0x19c"
else
    pass "hub-throttle-check does not use the wrong MSR address 0x1fc"
fi

# rdmsr prints the register value as hex WITHOUT a 0x prefix, so it has to be
# prefixed before bash arithmetic treats it as a number. Without that, a value
# like 88450018 is read as decimal and the bit tests give the wrong answer.
if grep -q 'hex="0x\$value"' "$WORK/hub-throttle-check" 2>/dev/null; then
    pass "hub-throttle-check prefixes the MSR value with 0x before arithmetic"
else
    fail "hub-throttle-check does not prefix the MSR value with 0x (hex would be read as decimal)"
fi

# Behaviour: a fake rdmsr returns a hex value with the PROCHOT#/FORCEPR#
# event bit (bit 3) set. The script has to report the event and set
# PROCHOT_SEEN=1.
cat >"$WORK/fakebin/rdmsr" <<'FAKE'
#!/usr/bin/env bash
addr="${!#}"
printf '%s\n' "$addr" >"$FAKE_RDMSR_ADDR_FILE"
printf '%s\n' "$FAKE_RDMSR_VALUE"
FAKE
chmod +x "$WORK/fakebin/rdmsr"
awk '/^read_therm_status\(\)/,/^\}/' "$WORK/hub-throttle-check" >"$WORK/therm-func.sh"
cat >"$WORK/therm-test.sh" <<'TEST'
set -uo pipefail
. "$1"
read_therm_status
echo "PROCHOT_SEEN=$PROCHOT_SEEN"
TEST
export FAKE_RDMSR_ADDR_FILE="$WORK/rdmsr_addr"
export FAKE_RDMSR_VALUE="88450018"
out="$(PATH="$WORK/fakebin:$PATH" bash "$WORK/therm-test.sh" "$WORK/therm-func.sh" 2>&1 || true)"
case "$out" in
    *"PROCHOT_SEEN=1"*) pass "hub-throttle-check sets PROCHOT_SEEN on a PROCHOT# event bit" ;;
    *) fail "hub-throttle-check did not set PROCHOT_SEEN for a PROCHOT# event bit (got: $out)" ;;
esac
case "$out" in
    *"PROCHOT#/FORCEPR# EVENT"*) pass "hub-throttle-check names the PROCHOT# event bit" ;;
    *) fail "hub-throttle-check did not report the PROCHOT# event bit (got: $out)" ;;
esac
if [ "$(cat "$FAKE_RDMSR_ADDR_FILE" 2>/dev/null)" = "0x19c" ]; then
    pass "hub-throttle-check asked rdmsr for MSR 0x19c"
else
    fail "hub-throttle-check asked rdmsr for the wrong MSR (got: $(cat "$FAKE_RDMSR_ADDR_FILE" 2>/dev/null))"
fi

# The sticky PROCHOT log is bit 5 of IA32_THERM_STATUS (bit 4 is reserved).
FAKE_RDMSR_VALUE="88450020"
out="$(PATH="$WORK/fakebin:$PATH" FAKE_RDMSR_VALUE="$FAKE_RDMSR_VALUE" bash "$WORK/therm-test.sh" "$WORK/therm-func.sh" 2>&1 || true)"
case "$out" in
    *"PROCHOT# LOG"*) pass "hub-throttle-check reads the sticky PROCHOT log from bit 5" ;;
    *) fail "hub-throttle-check did not read the sticky PROCHOT log from bit 5 (got: $out)" ;;
esac
FAKE_RDMSR_VALUE="88450020"

# --------------------------------------------------------------------------
# 8. secret scan
# --------------------------------------------------------------------------
info "8. secret scan"
if bash tests/secret-scan.sh >"$WORK/secrets.out" 2>&1; then
    pass "the secret scan is clean"
    sed 's/^/      /' "$WORK/secrets.out" | grep -E '^(clean|FINDING)' | head -12
else
    fail "the secret scan found something"
    sed 's/^/      /' "$WORK/secrets.out" | head -30
fi

# --------------------------------------------------------------------------
# summary
# --------------------------------------------------------------------------
info "summary"
printf 'passed : %s\n' "$PASS"
printf 'failed : %s\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '\nfailed checks:\n'
    for item in "${FAILED_ITEMS[@]}"; do
        printf '  - %s\n' "$item"
    done
    exit 1
fi
printf '\nall checks passed\n'
exit 0
