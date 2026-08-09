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
              jq)

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
}

# The stub server: MEMCP_TEST_SCENARIO picks the fault, MEMCP_TEST_BODY_LOG
# collects each request body so a test can assert what was sent.
#
# MEMCP_TEST_FRAMING picks how the answer is shaped, because both are allowed
# and the two servers memcp has had chose differently: `sse` frames the payload
# as a `data:` event and returns the result in `structuredContent`, `json`
# answers in plain JSON with the result encoded as a text content block and
# assigns no session id at all.
make_stub_curl() {
    cat >"$1/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
scenario="${MEMCP_TEST_SCENARIO:-healthy}"
framing="${MEMCP_TEST_FRAMING:-sse}"

if [[ -n "${MEMCP_TEST_ARGV_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$MEMCP_TEST_ARGV_LOG"
fi

ENTRIES='[{"created_at":"2026-08-01T09:00:00Z","kind":"diary","headline":"first headline"},{"created_at":"2026-08-02T09:00:00Z","kind":"autorecap","headline":"second headline"}]'

# One JSON-RPC message, framed as the transport would frame it.
frame() {
    if [[ "$framing" == "json" ]]; then
        printf '%s\n' "$1"
    else
        printf 'data: %s\n' "$1"
    fi
}

# A tool result carrying the JSON in $1, in whichever shape the framing implies.
tool_result() {
    local escaped
    if [[ "$framing" == "json" ]]; then
        escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"content":[{"type":"text","text":"%s"}],"isError":false}' "$escaped"
    else
        printf '{"structuredContent":{"result":%s}}' "$1"
    fi
}

headers=""; output=""; data=""
while (( $# )); do
    case "$1" in
        -D) headers="${2:-}"; shift 2 ;;
        -o) output="${2:-}"; shift 2 ;;
        -d|--data-binary) data="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "$data" == @* ]] && data=$(cat "${data#@}")

if [[ -n "${MEMCP_TEST_BODY_LOG:-}" && -n "$data" ]]; then
    printf '%s\n' "$data" >>"$MEMCP_TEST_BODY_LOG"
fi

# initialize is the only call asking for the response headers.
if [[ -n "$headers" ]]; then
    if [[ "$scenario" == "unreachable" ]]; then
        echo "curl: (7) Failed to connect to 127.0.0.1 port 8786" >&2
        exit 7
    fi
    if [[ "$framing" == "json" ]]; then
        printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' >"$headers"
    else
        printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nmcp-session-id: stub-sid\r\n\r\n' >"$headers"
    fi
    if [[ -n "$output" ]]; then
        if [[ "$scenario" == "initialize-rejected" ]]; then
            printf '<html>not an mcp server</html>\n' >"$output"
        else
            frame '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stub","version":"0.0.0"}}}' >"$output"
        fi
    fi
    exit 0
fi

if [[ "$data" == *notifications/initialized* ]]; then
    [[ "$scenario" == "handshake-failed" ]] && exit 7
    exit 0
fi

case "$scenario" in
    tool-call-failed) exit 7 ;;
    malformed) printf 'this is not an mcp response\n' ;;
    tool-error)
        frame '{"jsonrpc":"2.0","id":2,"error":{"message":"no such tool"}}' ;;
    tool-is-error)
        frame '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"database is locked"}],"isError":true}}' ;;
    no-entries)
        frame "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":$(tool_result '[]')}" ;;
    *)
        frame "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":$(tool_result "$ENTRIES")}" ;;
esac
exit 0
STUB
    chmod +x "$1/curl"
}
