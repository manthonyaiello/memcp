#!/usr/bin/env bash
#
# harness.sh — assertions, fixtures and stubs for the hook tests. Sourced by
# each tests/hooks/test_*.sh; run them through tests/hooks/run_tests.sh.
#
# The server stub is a fake `curl` placed first on PATH, not a listening
# process. What the hooks branch on is curl's exit status and the bytes it
# prints, so producing those directly covers the fault table exactly, needs no
# port and no language the hooks themselves refuse to depend on. One case in
# test_faults.sh still dials a closed port with the real curl, so the
# unreachable path is also exercised end to end.
#
# PATH is replaced outright for each run, from a directory of symlinks, so a
# missing dependency can be staged by leaving one out.

set -uo pipefail

HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HARNESS_DIR/../.." && pwd)"
HOOKS_DIR="$ROOT/scripts/hooks"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# Isolated so a developer's global git config and a real ~/.memcp cannot reach
# the fixtures or the hooks under test.
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

# Rule 3 (basename of cwd) is only observable outside a repository, and a
# temporary directory nested in one would silently test rule 2 instead.
if git -C "$TEST_TMP" rev-parse --git-dir >/dev/null 2>&1; then
    echo "!! $TEST_TMP is inside a git repository; the derivation tests cannot run" >&2
    exit 2
fi

TESTS_RUN=0
TESTS_FAILED=0

# --- assertions -------------------------------------------------------------

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf 'ok   %s\n' "$1"; }

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s\n' "$1"
    shift
    printf '       %s\n' "$@"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected: $expected" "actual:   $actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" text="$3"
    if [[ "$text" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "missing: $needle" "in: ${text:-<empty>}"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" text="$3"
    if [[ "$text" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "unexpected: $needle" "in: $text"
    fi
}

assert_match() {
    local label="$1" regex="$2" text="$3"
    if [[ "$text" =~ $regex ]]; then
        pass "$label"
    else
        fail "$label" "no match for: $regex" "in: ${text:-<empty>}"
    fi
}

# Report the tally and set the exit status. Last line of every test script.
finish() {
    printf '%s: %d run, %d failed\n' \
        "$(basename "$0")" "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}

# --- fixtures ---------------------------------------------------------------

# A repository at $1 with one commit, and remote `origin` at $2 when given.
make_repo() {
    local dir="$1" remote="${2:-}"
    mkdir -p "$dir"
    git -c init.defaultBranch=main init -q "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=t@example.invalid -c user.name=test \
        commit -q --allow-empty -m init
    [[ -z "$remote" ]] || git -C "$dir" remote add origin "$remote"
}

# A linked worktree of repository $1 at $2.
make_worktree() {
    git -C "$1" worktree add -q -b "wt-$(basename "$2")" "$2" >/dev/null 2>&1
}

# Everything the hooks call, symlinked into $1; names passed after $1 are left
# out so their absence can be tested.
SANDBOX_BINS=(bash cat mktemp rm ln grep awk sed tr head basename dirname env
              git shasum sha256sum base64 hostname uname od uuidgen mkdir chmod
              jq tar cp mv)

make_sandbox() {
    local dir="$1"; shift
    local excluded=" $* " bin path
    mkdir -p "$dir"
    for bin in "${SANDBOX_BINS[@]}"; do
        [[ "$excluded" == *" $bin "* ]] && continue
        path=$(command -v "$bin" 2>/dev/null) || continue
        ln -sf "$path" "$dir/$bin"
    done
    make_stub_curl "$dir"
    [[ "$excluded" == *" ssh "* ]] || make_stub_ssh "$dir"
    [[ "$excluded" == *" claude "* ]] || make_stub_claude "$dir"
}

# The stub server: MEMCP_TEST_SCENARIO picks the fault, MEMCP_TEST_BODY_LOG
# collects each request body so a test can assert what was sent.
#
# It answers the way memcp answers and no other way -- 200, plain JSON, no
# session id, one text content block -- so a hook that drifts onto a shape this
# server does not produce fails here rather than in production.
make_stub_curl() {
    cat >"$1/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
scenario="${MEMCP_TEST_SCENARIO:-healthy}"

if [[ -n "${MEMCP_TEST_ARGV_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$MEMCP_TEST_ARGV_LOG"
fi

ENTRIES='[{"created_at":"2026-08-01T09:00:00Z","kind":"diary","headline":"first headline"},{"created_at":"2026-08-02T09:00:00Z","kind":"autorecap","headline":"second headline"}]'

# A tool result carrying the JSON in $1, the way memcp carries one.
tool_result() {
    local escaped
    escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"content":[{"type":"text","text":"%s"}],"isError":false}' "$escaped"
}

output=""; data=""
while (( $# )); do
    case "$1" in
        -o) output="${2:-}"; shift 2 ;;
        -d|--data-binary) data="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "$data" == @* ]] && data=$(cat "${data#@}")

if [[ -n "${MEMCP_TEST_BODY_LOG:-}" && -n "$data" ]]; then
    printf '%s\n' "$data" >>"$MEMCP_TEST_BODY_LOG"
fi

if [[ "$scenario" == "unreachable" ]]; then
    echo "curl: (7) Failed to connect to 127.0.0.1 port 8786" >&2
    exit 7
fi

# initialize is the only call whose body goes to a file.
if [[ -n "$output" ]]; then
    if [[ "$scenario" == "initialize-rejected" ]]; then
        printf '<html>not an mcp server</html>\n' >"$output"
    else
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stub","version":"0.0.0"}}}' >"$output"
    fi
    exit 0
fi

case "$scenario" in
    tool-call-failed) exit 7 ;;
    malformed) printf 'this is not an mcp response\n' ;;
    tool-error)
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"no such tool"}}' ;;
    tool-is-error)
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"database is locked"}],"isError":true}}' ;;
    no-entries)
        printf '{"jsonrpc":"2.0","id":2,"result":%s}\n' "$(tool_result '[]')" ;;
    *)
        printf '{"jsonrpc":"2.0","id":2,"result":%s}\n' "$(tool_result "$ENTRIES")" ;;
esac
exit 0
STUB
    chmod +x "$1/curl"
}

# The ssh stub: joins its command words and runs the result through a shell,
# which is what ssh does. An argument that needed quoting for the far side
# therefore fails here the way it fails against a real host. Set
# MEMCP_TEST_SSH_FAIL to a host name to make that host unreachable.
make_stub_ssh() {
    cat >"$1/ssh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
host="$1"; shift

if [[ -n "${MEMCP_TEST_SSH_LOG:-}" ]]; then
    printf '%s\n' "$host" >>"$MEMCP_TEST_SSH_LOG"
fi

if [[ "${MEMCP_TEST_SSH_FAIL:-}" == "$host" ]]; then
    echo "ssh: connect to host $host port 22: Connection refused" >&2
    exit 255
fi

bash -c "$*"
STUB
    chmod +x "$1/ssh"
}

# The claude stub: `mcp get` and `mcp add` over a registry file, so
# registration is observable without a real CLI and without any risk to a real
# ~/.claude.json. `get` on an unknown name exits 0 and says so in prose, which
# is the CLI behaviour deploy.sh depends on.
make_stub_claude() {
    cat >"$1/claude" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
reg="${MEMCP_TEST_MCP_REGISTRY:-$HOME/.mcp-registry}"

[[ "${1:-}" == mcp ]] || exit 2

case "${2:-}" in
    get)
        name="${3:-}"
        url=""
        [[ ! -f "$reg" ]] || url=$(sed -n "s/^$name //p" "$reg")
        if [[ -n "$url" ]]; then
            printf '%s:\n  Scope: User config\n  Type: http\n  URL: %s\n' \
                "$name" "$url"
        else
            printf 'No MCP server named "%s".\n' "$name"
        fi
        ;;
    add)
        shift 2
        name=""; url=""
        while (( $# )); do
            case "$1" in
                -s|--scope|-t|--transport) shift 2 ;;
                -*) shift ;;
                *) if [[ -z "$name" ]]; then name="$1"; else url="$1"; fi; shift ;;
            esac
        done
        [[ -n "$name" && -n "$url" ]] || exit 2
        [[ "${MEMCP_TEST_MCP_ADD_FAILS:-}" != 1 ]] || exit 1
        #  Replaces rather than appends, so one name holds one URL the way the
        #  real registry does.
        tmp="$reg.tmp"
        : >"$tmp"
        [[ ! -f "$reg" ]] || grep -v "^$name " "$reg" >"$tmp" || :
        printf '%s %s\n' "$name" "$url" >>"$tmp"
        mv "$tmp" "$reg"
        ;;
    *) exit 2 ;;
esac
exit 0
STUB
    chmod +x "$1/claude"
}
