#!/usr/bin/env bash
#
# run_tests.sh — run every tests/hooks/test_*.sh and set the exit status.
#
# The hooks are bash + curl + jq and are tested with the same, so this needs no
# toolchain and runs before anything is built.
#
# Usage:
#   tests/hooks/run_tests.sh            # all of them
#   tests/hooks/run_tests.sh derivation # just tests/hooks/test_derivation.sh

set -uo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for bin in curl jq git; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "!! the hook tests need $bin on PATH" >&2
        exit 2
    fi
done

if [[ $# -gt 0 ]]; then
    scripts=()
    for name in "$@"; do scripts+=("$DIR/test_$name.sh"); done
else
    scripts=("$DIR"/test_*.sh)
fi

failed=0
for script in "${scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
        echo "!! no such test: $script" >&2
        exit 2
    fi
    echo "== $(basename "$script")"
    bash "$script" || failed=$((failed + 1))
    echo
done

if [[ "$failed" -ne 0 ]]; then
    echo "!! $failed hook test script(s) failed" >&2
    exit 1
fi

echo "hook tests: all green"
