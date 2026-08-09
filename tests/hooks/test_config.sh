#!/usr/bin/env bash
#
# test_config.sh — config file, and the precedence the `:=` form buys.
#
# Precedence is asserted twice: once on the loader, and once through a whole
# SessionStart run, because the hook applies its own defaults after loading and
# an order slip there would mask the file just as effectively.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

SANDBOX="$TEST_TMP/bin"
make_sandbox "$SANDBOX"

REPO="$TEST_TMP/repo"
make_repo "$REPO" "https://github.com/acme/widget.git"
PAYLOAD=$(printf '{"session_id":"S1","cwd":"%s","source":"startup"}' "$REPO")

FROM_FILE="http://file.invalid:8786/mcp"
FROM_ENV="http://env.invalid:8786/mcp"

CONFIG="$TEST_TMP/hooks.env"
cat >"$CONFIG" <<EOF
: "\${MEMCP_URL:=$FROM_FILE}"
: "\${MEMCP_SURFACE_LABEL:=fixture-surface}"
EOF

# MEMCP_URL as the loader leaves it, with the environment as given in "$@".
loaded_url() {
    env -u MEMCP_URL "$@" MEMCP_CONFIG="$CONFIG" bash -c \
        '. "$1"/hook_common.sh; memcp_load_config; printf "%s\n" "${MEMCP_URL:-unset}"' \
        _ "$HOOKS_DIR"
}

assert_eq "file only: the file supplies the value" \
    "$FROM_FILE" "$(loaded_url)"

assert_eq "env only: no file, the environment stands" \
    "$FROM_ENV" "$(MEMCP_URL="$FROM_ENV" MEMCP_CONFIG="$TEST_TMP/no-such-file" bash -c \
        '. "$1"/hook_common.sh; memcp_load_config; printf "%s\n" "${MEMCP_URL:-unset}"' \
        _ "$HOOKS_DIR")"

assert_eq "both set: the environment wins" \
    "$FROM_ENV" "$(loaded_url MEMCP_URL="$FROM_ENV")"

assert_eq "an absent config file is not an error" \
    "unset" "$(MEMCP_CONFIG="$TEST_TMP/no-such-file" bash -c \
        '. "$1"/hook_common.sh; memcp_load_config; printf "%s\n" "${MEMCP_URL:-unset}"' \
        _ "$HOOKS_DIR")"

# End to end: the URL the hook actually dials, and the surface it reports.
BODY_LOG="$TEST_TMP/bodies"
ARGV_LOG="$TEST_TMP/argv"

OUT=$(MEMCP_TEST_SCENARIO=healthy MEMCP_TEST_ARGV_LOG="$ARGV_LOG" \
      MEMCP_TEST_BODY_LOG="$BODY_LOG" MEMCP_CONFIG="$CONFIG" PATH="$SANDBOX" \
      bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" 2>/dev/null)
assert_contains "hook run: the file's URL is the one dialled" \
    "$FROM_FILE" "$(cat "$ARGV_LOG")"
assert_contains "hook run: the file's surface label is injected" \
    'surface="fixture-surface"' "$OUT"

: >"$ARGV_LOG"
MEMCP_TEST_SCENARIO=healthy MEMCP_TEST_ARGV_LOG="$ARGV_LOG" \
    MEMCP_TEST_BODY_LOG="$BODY_LOG" MEMCP_CONFIG="$CONFIG" \
    MEMCP_URL="$FROM_ENV" PATH="$SANDBOX" \
    bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" >/dev/null 2>&1
assert_contains "hook run: the environment still overrides the file" \
    "$FROM_ENV" "$(cat "$ARGV_LOG")"
assert_not_contains "hook run: and the file's URL is not dialled at all" \
    "$FROM_FILE" "$(cat "$ARGV_LOG")"

assert_eq "MEMCP_PROJECT overrides derivation" \
    'project="override"' \
    "$(MEMCP_TEST_SCENARIO=healthy MEMCP_CONFIG="$CONFIG" MEMCP_PROJECT=override \
       PATH="$SANDBOX" bash "$HOOKS_DIR/session_start.sh" <<<"$PAYLOAD" 2>/dev/null \
       | sed -n 's/.*\(project="override"\).*/\1/p' | head -n 1)"

finish
