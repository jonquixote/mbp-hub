#!/usr/bin/env bash
#
# mbp-hub :: tests/secret-scan.sh
#
# Scans the repository for anything that must never be committed:
# tokens, private keys, credential literals, real IP addresses and real SSIDs.
#
# It fails (exit 1) when it finds something, so it can be used as a gate.
#
# The scanner skips its own file (it necessarily contains the patterns it
# looks for) and the .git directory.
#
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"
FINDINGS=0

cd "$REPO_ROOT" || exit 1

report() {
    # report <label> <pattern> <extended-regexp>
    label="$1"
    pattern="$2"
    hits="$(grep -rInE --exclude-dir=.git --exclude="$SELF" -- "$pattern" . 2>/dev/null)"
    if [ -n "$hits" ]; then
        FINDINGS=$((FINDINGS + 1))
        printf 'FINDING  %s\n' "$label"
        printf '%s\n' "$hits" | head -10 | sed 's/^/          /'
    else
        printf 'clean    %s\n' "$label"
    fi
}

printf 'scanning %s\n\n' "$REPO_ROOT"

# --- credentials ----------------------------------------------------------
report "tailscale auth key" 'tskey-[A-Za-z0-9_-]{20,}'
report "github token" 'gh[pousr]_[A-Za-z0-9]{20,}'
report "github fine-grained token" 'github_pat_[A-Za-z0-9_]{20,}'
report "openai-style key" 'sk-[A-Za-z0-9]{20,}'
report "aws access key id" 'AKIA[0-9A-Z]{16}'
report "private key block" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
report "literal credential assignment" \
    '(password|passwd|passphrase|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+=_.-]{8,}'

# --- network identifiers --------------------------------------------------
# Public IPv4 literals are findings; private, loopback, link-local and the
# Tailscale CGNAT range (100.64.0.0/10) are expected in documentation.
public_ips="$(grep -rInE --exclude-dir=.git --exclude="$SELF" \
    '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . 2>/dev/null \
    | grep -vE '\b(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
    | grep -vE '0\.0\.0\.0|255\.255\.255\.255' || true)"
if [ -n "$public_ips" ]; then
    FINDINGS=$((FINDINGS + 1))
    printf 'FINDING  public IP address\n'
    printf '%s\n' "$public_ips" | head -10 | sed 's/^/          /'
else
    printf 'clean    public IP address\n'
fi

report "wifi ssid literal" '\b(WIFI_SSID|SSID)="[^"$]{3,}"'
# example.com / example.org / example.net are reserved for documentation
# (RFC 2606), so placeholders using them are not real identifiers.
emails="$(grep -rInE --exclude-dir=.git --exclude="$SELF" \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' . 2>/dev/null \
    | grep -vE '@(example\.(com|org|net)|localhost)\b' || true)"
if [ -n "$emails" ]; then
    FINDINGS=$((FINDINGS + 1))
    printf 'FINDING  email-like identifier\n'
    printf '%s\n' "$emails" | head -10 | sed 's/^/          /'
else
    printf 'clean    email-like identifier (example.com placeholders are allowed)\n'
fi

printf '\n%s\n' "-------------------------------------------"
if [ "$FINDINGS" -eq 0 ]; then
    printf 'SECRET SCAN: CLEAN - no secrets found in the repository\n'
    exit 0
fi
printf 'SECRET SCAN: %s FINDING(S) - fix them before publishing\n' "$FINDINGS"
exit 1
