#!/usr/bin/env bash
#
# install.sh — mint this surface's identity and record what is installed.
#
# Writes the shell-sourceable config the hooks read. Surface identity is minted
# on the first run and carried across later ones: the UUID names the machine
# for the lifetime of the corpus, and MEMCP_SURFACE_HOST holds the host name as
# of that first run, so a config that turns up on a differently named host was
# inherited (clone, restore, fork) rather than created there.
#
# Hook digests are re-recorded every run: they are the claim "this is what I
# installed", which each hook checks against itself at runtime.
#
# Idempotent. Run it again after every pull.
#
# Usage:
#   scripts/hooks/install.sh          # write $HOME/.memcp/hooks.env
#   MEMCP_CONFIG=... scripts/hooks/install.sh

set -euo pipefail

HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hook_common.sh"

# Existing values win, so identity survives a re-run.
memcp_load_config

CONFIG=$(memcp_config_file)
HOOKS=(session_start session_end)

surface_id="${MEMCP_SURFACE_ID:-$(memcp_new_uuid)}"
surface_label="${MEMCP_SURFACE_LABEL:-$(memcp_hostname)}"
surface_host="${MEMCP_SURFACE_HOST:-$(memcp_hostname)}"
url="${MEMCP_URL:-http://127.0.0.1:8786/mcp}"

for hook in "${HOOKS[@]}"; do
    if [[ ! -f "$HOOK_DIR/$hook.sh" ]]; then
        echo "!! missing $HOOK_DIR/$hook.sh" >&2
        exit 1
    fi
done

mkdir -p "$(dirname "$CONFIG")"

{
    echo "# memcp hook configuration. Sourced by scripts/hooks/*.sh."
    echo "#"
    echo "# Every assignment is \`:=\`, so an environment variable of the same name"
    echo "# wins. Rewritten by scripts/hooks/install.sh; the surface identity below"
    echo "# is preserved across runs, the digests are not."
    echo
    echo ": \"\${MEMCP_URL:=$url}\""
    echo
    echo "# This surface, for the lifetime of the corpus."
    echo ": \"\${MEMCP_SURFACE_ID:=$surface_id}\""
    echo ": \"\${MEMCP_SURFACE_LABEL:=$surface_label}\""
    echo
    echo "# Host name when the identity above was minted. A mismatch with the"
    echo "# current host means this config was inherited, not created here."
    echo ": \"\${MEMCP_SURFACE_HOST:=$surface_host}\""
    echo
    echo "# What install.sh put in place, digested with hook_common.sh."
    echo "# A hook that digests differently at runtime has been modified locally."
    for hook in "${HOOKS[@]}"; do
        echo ": \"\${$(memcp_digest_var "$hook.sh"):=$(memcp_digest "$HOOK_DIR/$hook.sh")}\""
    done
} >"$CONFIG"

echo "memcp: wrote $CONFIG"
echo "memcp: surface $surface_label ($surface_id), hooks $MEMCP_HOOK_VERSION"
echo
echo "Wire the hooks into ~/.claude/settings.json:"
cat <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": "$HOOK_DIR/session_start.sh" } ] } ],
    "SessionEnd": [
      { "hooks": [
        { "type": "command", "command": "$HOOK_DIR/session_end.sh" } ] } ]
  }
}
EOF
