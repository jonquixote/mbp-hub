#!/usr/bin/env bash
#
# mbp-hub :: bootstrap/optional/10-agents.sh
#
# Installs the Claude Code and opencode CLIs FOR THE 'agent' USER using each
# vendor's own installer. The installers are run as the agent user, never as
# root, and they are the only third-party code this kit executes.
#
# The agent user has no password and no sudo, and its secrets live in the
# encrypted vault - so the agent can only do useful work while a human has
# opened the vault.
#
set -euo pipefail

AGENT_USER="agent"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
warn_log() { log "WARNING: $*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this module as root." >&2
    exit 1
fi

id "$AGENT_USER" >/dev/null 2>&1 || die "user '$AGENT_USER' does not exist - run bootstrap.sh first"

run_as_agent() {
    # $1 = label, rest = shell command
    local label="$1"
    shift
    log "installing $label as $AGENT_USER"
    if sudo -iu "$AGENT_USER" bash -lc "$*"; then
        log "$label installed"
    else
        warn_log "$label installer failed - continuing"
    fi
}

run_as_agent "claude code" 'curl -fsSL https://claude.ai/install.sh | bash'
run_as_agent "opencode" 'curl -fsSL https://opencode.ai/install | bash'

# Make sure the installers' PATH additions survive a new login shell.
agent_profile="/home/$AGENT_USER/.profile"
touch "$agent_profile"
chown "$AGENT_USER:$AGENT_USER" "$agent_profile"
if ! grep -q 'hub-agent-path' "$agent_profile"; then
    {
        # shellcheck disable=SC2016
        printf '\n# hub-agent-path: CLI locations from the vendor installers\n'
        # shellcheck disable=SC2016
        printf 'export PATH="$HOME/.local/bin:$HOME/.claude/local/bin:$PATH"\n'
    } >>"$agent_profile"
    log "updated $agent_profile"
fi

cat >/usr/local/bin/agent-start <<'EOF'
#!/usr/bin/env bash
#
# Start (or attach to) the tmux session the agents work in.
#
# It refuses to run while the vault is closed: the agents' SSH keys, API
# tokens and .env files live in /vault, so there is nothing useful (and
# nothing safe) to run without it.
#
set -euo pipefail

AGENT_USER="agent"
SESSION="agents"

if ! mountpoint -q /vault 2>/dev/null; then
    echo "The vault is closed." >&2
    echo "Open it first:   sudo vault-open" >&2
    echo "Then run:        agent-start" >&2
    exit 1
fi

if ! id "$AGENT_USER" >/dev/null 2>&1; then
    echo "user $AGENT_USER does not exist" >&2
    exit 1
fi

exec sudo -iu "$AGENT_USER" tmux new -As "$SESSION"
EOF
chmod 0755 /usr/local/bin/agent-start
log "installed /usr/local/bin/agent-start"

cat <<'EOF'

The CLIs are installed for the 'agent' user only.
Start a working session with:

    sudo vault-open      # unlock the secrets
    agent-start          # tmux session 'agents' as the agent user

EOF
log "done"
