#!/usr/bin/env bash
#
# test_digest.sh — surface identity minted once, and hook modification caught.
#
# The hooks run from a copy of scripts/hooks so a case can edit one in place,
# which is the condition a version string alone cannot report.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

SANDBOX="$TEST_TMP/bin"
make_sandbox "$SANDBOX"

REPO="$TEST_TMP/repo"
make_repo "$REPO" "https://github.com/acme/widget.git"
PAYLOAD=$(printf '{"session_id":"S1","cwd":"%s","source":"startup"}' "$REPO")

INSTALLED="$TEST_TMP/installed"
mkdir -p "$INSTALLED"
cp "$HOOKS_DIR"/*.sh "$INSTALLED/"

CONFIG="$TEST_TMP/hooks.env"
export MEMCP_CONFIG="$CONFIG"

install_hooks() {
    env -u MEMCP_SURFACE_ID -u MEMCP_SURFACE_LABEL -u MEMCP_SURFACE_HOST \
        MEMCP_CONFIG="$CONFIG" bash "$INSTALLED/install.sh" >/dev/null
}

run_start() {
    MEMCP_TEST_SCENARIO=healthy MEMCP_TEST_BODY_LOG="${1:-}" \
        MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
        bash "$INSTALLED/session_start.sh" <<<"$PAYLOAD" 2>/dev/null
}

# Value of config variable $1, as the hooks would read it.
config_value() {
    MEMCP_CONFIG="$CONFIG" bash -c \
        '. "$1"/hook_common.sh; memcp_load_config; printf "%s\n" "${!2:-}"' \
        _ "$INSTALLED" "$1"
}

# --- minting ----------------------------------------------------------------

install_hooks
assert_match "install: mints a surface UUID" \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    "$(config_value MEMCP_SURFACE_ID)"
assert_match "install: mints a label"       '.' "$(config_value MEMCP_SURFACE_LABEL)"
assert_match "install: records the install host" '.' "$(config_value MEMCP_SURFACE_HOST)"
assert_match "install: records the SessionStart digest" \
    '^[0-9a-f]{8}$' "$(config_value MEMCP_HOOK_DIGEST_SESSION_START)"
assert_match "install: records the SessionEnd digest" \
    '^[0-9a-f]{8}$' "$(config_value MEMCP_HOOK_DIGEST_SESSION_END)"

MINTED_ID=$(config_value MEMCP_SURFACE_ID)
MINTED_HOST=$(config_value MEMCP_SURFACE_HOST)

install_hooks
assert_eq "re-install: the surface UUID is not re-rolled" \
    "$MINTED_ID" "$(config_value MEMCP_SURFACE_ID)"
assert_eq "re-install: the install host is not refreshed" \
    "$MINTED_HOST" "$(config_value MEMCP_SURFACE_HOST)"

# --- an unmodified hook -----------------------------------------------------

BODY_LOG="$TEST_TMP/bodies"
OUT=$(run_start "$BODY_LOG")
assert_not_contains "unmodified: no modification block" '<memcp-hook-modified' "$OUT"
assert_match "unmodified: reports version and digest" \
    '"version":"0\.2\.0\+[0-9a-f]{8}"' "$(cat "$BODY_LOG")"

# --- a hook edited in place -------------------------------------------------

printf '# edited on this surface\n' >>"$INSTALLED/session_start.sh"
OUT=$(run_start)
STATUS=$?
assert_eq       "edited hook: exit 0"    0 "$STATUS"
assert_contains "edited hook: reports the modification" \
    '<memcp-hook-modified hook="session_start"' "$OUT"
assert_contains "edited hook: names the installed digest" \
    "installed=\"$(config_value MEMCP_HOOK_DIGEST_SESSION_START)\"" "$OUT"
assert_contains "edited hook: still injects the key" \
    '<memcp-session id="S1" project="widget"' "$OUT"

install_hooks
OUT=$(run_start)
assert_not_contains "re-install: adopts the edit and the block clears" \
    '<memcp-hook-modified' "$OUT"

# The library is digested with each hook, so editing it modifies both.
BEFORE_START=$(config_value MEMCP_HOOK_DIGEST_SESSION_START)
BEFORE_END=$(config_value MEMCP_HOOK_DIGEST_SESSION_END)
printf '# edited on this surface\n' >>"$INSTALLED/hook_common.sh"
install_hooks
assert_not_contains "library edit: SessionStart digest changes" \
    "$BEFORE_START" "$(config_value MEMCP_HOOK_DIGEST_SESSION_START)"
assert_not_contains "library edit: SessionEnd digest changes too" \
    "$BEFORE_END" "$(config_value MEMCP_HOOK_DIGEST_SESSION_END)"

# --- no recorded digest -----------------------------------------------------

: >"$CONFIG"
OUT=$(run_start)
assert_not_contains "no recorded digest: nothing to compare, no block" \
    '<memcp-hook-modified' "$OUT"

finish
