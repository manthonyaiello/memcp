#!/usr/bin/env bash
#
# test_derivation.sh — the project key, over fixture repositories.
#
# One key per repository is the whole point: a subdirectory, a linked worktree
# and a detached HEAD must all answer with the same name the top of the main
# worktree does.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"

# The key the hooks would derive for directory $1.
key_for() {
    bash -c '. "$1"/hook_common.sh; memcp_project_key "$2"' _ "$HOOKS_DIR" "$1"
}

FIX="$TEST_TMP/fixtures"
mkdir -p "$FIX"

make_repo "$FIX/checkout"  "https://github.com/acme/widget.git"
make_repo "$FIX/plain"     "https://github.com/acme/gadget"
make_repo "$FIX/scp"       "git@github.com:acme/sprocket.git"
make_repo "$FIX/solo"
mkdir -p "$FIX/checkout/src/deep" "$FIX/solo/src/deep" "$FIX/bare-dir"

make_worktree "$FIX/checkout" "$FIX/wt-checkout"
make_worktree "$FIX/solo"     "$FIX/wt-solo"

assert_eq "remote URL ending .git loses the suffix" \
    "widget" "$(key_for "$FIX/checkout")"

assert_eq "remote URL without .git is unchanged" \
    "gadget" "$(key_for "$FIX/plain")"

assert_eq "scp-form remote resolves to the repository name" \
    "sprocket" "$(key_for "$FIX/scp")"

assert_eq "subdirectory of a repository keeps the repository key" \
    "widget" "$(key_for "$FIX/checkout/src/deep")"

assert_eq "named worktree keeps the parent repository key" \
    "widget" "$(key_for "$FIX/wt-checkout")"

assert_eq "repository with no remote uses the main worktree name" \
    "solo" "$(key_for "$FIX/solo")"

assert_eq "subdirectory of a remoteless repository uses the main worktree" \
    "solo" "$(key_for "$FIX/solo/src/deep")"

assert_eq "worktree of a remoteless repository uses the main worktree" \
    "solo" "$(key_for "$FIX/wt-solo")"

git -C "$FIX/checkout" checkout -q --detach HEAD
assert_eq "detached HEAD still resolves through the remote" \
    "widget" "$(key_for "$FIX/checkout")"

assert_eq "no repository at all falls back to basename(cwd)" \
    "bare-dir" "$(key_for "$FIX/bare-dir")"

# A cwd that no longer exists must not produce a path fragment as a key.
assert_eq "vanished directory falls back to the caller's own cwd" \
    "bare-dir" "$(cd "$FIX/bare-dir" && key_for "$FIX/does-not-exist")"

finish
