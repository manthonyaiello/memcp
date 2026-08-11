#!/usr/bin/env bash
# memcp hook library: configuration, project derivation, surface identity,
# hook self-digest and staleness.
#
# Sourced by session_start.sh, session_end.sh and install.sh. Defines functions
# and sets MEMCP_HOOK_VERSION; runs nothing else.

# Version of the hook pair, reported to the server in `clientInfo.version`
# alongside the digest. Bumped by hand on any change to this directory: the
# server compares it for equality against the release it shipped with, so a
# surface that is behind by even a comment reports as behind, which is the
# honest answer. Memcp.Hooks.Hook_Version must carry the same string --
# scripts/check-hook-version.sh gates that, and the bump.
MEMCP_HOOK_VERSION="0.3.0"

# --- configuration ----------------------------------------------------------

# Path of the shell-sourceable config file.
memcp_config_file() {
    printf '%s\n' "${MEMCP_CONFIG:-$HOME/.memcp/hooks.env}"
}

# Read the config file. Its assignments are `: "${VAR:=value}"`, so a variable
# already in the environment keeps its value and no precedence logic is needed
# here. Call before applying built-in defaults, or the defaults mask the file.
memcp_load_config() {
    local file
    file=$(memcp_config_file)
    [[ -f "$file" && -r "$file" ]] || return 0
    # shellcheck disable=SC1090
    . "$file"
}

# --- digest -----------------------------------------------------------------

# sha256 of stdin, hex only. Empty when the host has neither tool, which
# disables the digest rather than reporting a wrong one.
memcp_sha256_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        printf ''
    fi
}

# First 8 hex characters of the sha256 over this library and $1, in that order.
# Both are digested because a hook's behaviour is the pair, not the file.
memcp_digest() {
    local hook="$1" sum
    sum=$(cat "${BASH_SOURCE[0]}" "$hook" 2>/dev/null | memcp_sha256_stdin)
    printf '%s\n' "${sum:0:8}"
}

# Config variable recording the digest of hook $1 as installed.
memcp_digest_var() {
    local base
    base=$(basename "$1")
    base="${base%.sh}"
    printf 'MEMCP_HOOK_DIGEST_%s\n' "$(printf '%s' "$base" | tr 'a-z-' 'A-Z_')"
}

# Digest of hook $1 recorded at install; empty when the installer never ran.
memcp_installed_digest() {
    local var
    var=$(memcp_digest_var "$1")
    printf '%s\n' "${!var:-}"
}

# `clientInfo.version` for hook $1: semver, with the digest as build metadata.
memcp_client_version() {
    local digest
    digest=$(memcp_digest "$1")
    if [[ -n "$digest" ]]; then
        printf '%s+%s\n' "$MEMCP_HOOK_VERSION" "$digest"
    else
        printf '%s\n' "$MEMCP_HOOK_VERSION"
    fi
}

# Emit a modification block on stdout when hook $2 no longer digests to what
# install.sh recorded. Silent when either digest is unavailable, and never
# fatal: a modified hook still runs.
memcp_check_digest() {
    local name="$1" hook="$2" installed running
    installed=$(memcp_installed_digest "$hook")
    running=$(memcp_digest "$hook")
    [[ -n "$installed" && -n "$running" && "$installed" != "$running" ]] || return 0
    printf '<memcp-hook-modified hook="%s" installed="%s" running="%s">\n' \
        "$name" "$installed" "$running"
    printf 'This surface is running a locally modified memcp %s hook, so what it does no longer matches what was installed.\n' "$name"
    printf 'Remedy: re-run scripts/hooks/install.sh to adopt the change, or restore the hook from the memcp checkout.\n'
    printf 'Tell the user, then continue.\n'
    printf '</memcp-hook-modified>\n'
}

# --- staleness --------------------------------------------------------------
#
# The digest above answers "is this hook what was installed here"; it cannot
# answer "is what was installed here what the repository ships", because both
# sides of that comparison live on this surface. The server is where the two
# meet: it shipped from the same repository as the hooks and receives the
# version on every `initialize`, so it is the only party that can tell.
#
# The comparison is the server's, not ours. All that arrives here is a verdict.

# The release the server says it shipped with, when it reports this hook as
# stale; empty when it reports nothing. $1 is the file holding the `initialize`
# response. A server too old to carry the note answers without it, so absence is
# silence -- never taken as confirmation that this hook is current.
memcp_stale_expected() {
    jq -r '.result._meta["memcp/hookStatus"]
           | select(.stale == true) | .expected // empty' \
        "$1" 2>/dev/null || printf ''
}

# Emit a staleness block on stdout: $1 hook name, $2 the release the server
# shipped with. Reports and stops there -- stale hooks still work, the surface
# holds no checkout to update itself from, and the party who can act is the user
# reading this.
memcp_stale() {
    local name="$1" expected="$2" label
    label=$(memcp_surface_label)
    printf '<memcp-hook-stale hook="%s" surface="%s" running="%s" expected="%s">\n' \
        "$name" "$label" "$MEMCP_HOOK_VERSION" "$expected"
    printf 'This surface runs memcp hooks at %s, and the memcp server shipped with %s, so the hooks here are behind the repository the corpus is served from.\n' \
        "$MEMCP_HOOK_VERSION" "$expected"
    printf 'Remedy: from a memcp checkout, run `scripts/hooks/deploy.sh %s` -- the argument is an ssh destination, so it may not be the surface name above; use `--local` when the checkout is on this surface.\n' \
        "$label"
    printf 'Tell the user, then continue.\n'
    printf '</memcp-hook-stale>\n'
}

# --- memcp's responses ------------------------------------------------------
#
# Shaped to the server in this repository and to nothing else. It answers every
# request 200 with a plain JSON body, assigns no session id, and returns a
# tool's result as a single text content block. The two are co-designed: a
# change on either side is a change to both, and the hook tests are where that
# is held.

# True when $1 is one of memcp's JSON-RPC responses rather than whatever else
# answered on that port.
memcp_is_rpc() {
    jq -e 'type == "object" and (has("result") or has("error"))' \
        >/dev/null 2>&1 <<<"$1"
}

# The error a call reported. memcp uses both channels and means different
# things by them: a JSON-RPC `error` is a protocol fault caught before the tool
# ran, an `isError` result is the tool itself failing. Empty when it worked.
memcp_tool_error() {
    jq -r '.error.message
           // (select(.result.isError == true) | .result.content[0].text)
           // empty' 2>/dev/null <<<"$1"
}

# The tool's result, decoded from the text block that carries it.
memcp_tool_result() {
    jq -c '.result.content[0].text | try fromjson catch empty' \
        2>/dev/null <<<"$1"
}

# --- project derivation -----------------------------------------------------

# A key fit to be both a project name and an attribute of the injected block:
# not blank, not a path fragment, and free of the characters that would end the
# attribute early or start another element.
memcp_valid_key() {
    local key="${1:-}" forbidden='"<>&'
    [[ -n "${key//[[:space:]]/}" ]] || return 1
    [[ "$key" != "/" && "$key" != "." && "$key" != ".." ]] || return 1
    [[ "$key" != *["$forbidden"]* ]] || return 1
    [[ "$key" != *[[:cntrl:]]* ]] || return 1
    return 0
}

# Repository name from a remote URL: last path segment, `.git` optional, scp
# form (`git@host:repo`) included.
memcp_repo_name_from_url() {
    local url="${1:-}"
    url="${url%/}"
    url="${url%.git}"
    url="${url%/}"
    url="${url##*/}"
    printf '%s\n' "${url##*:}"
}

# Remote of the branch's upstream, else origin, else the first configured one.
memcp_git_remote() {
    local dir="$1" upstream remote=""
    upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
    if [[ -n "$upstream" && "$upstream" == */* ]]; then
        remote="${upstream%%/*}"
    elif git -C "$dir" remote get-url origin >/dev/null 2>&1; then
        remote="origin"
    else
        remote=$(git -C "$dir" remote 2>/dev/null | head -n 1)
    fi
    [[ -n "$remote" ]] || return 1
    printf '%s\n' "$remote"
}

# Directory name of the main worktree. `--git-common-dir` is what collapses a
# named worktree onto its parent; `--show-toplevel` returns the worktree's own
# path and is the bug this replaces.
memcp_main_worktree_name() {
    local dir="$1" common
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [[ -z "$common" ]]; then
        common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
        [[ "$common" == /* ]] || common="$dir/$common"
    fi
    [[ -n "$common" ]] || return 1
    common="${common%/}"
    if [[ "$(basename "$common")" == ".git" ]]; then
        common=$(dirname "$common")
    else
        common="${common%.git}"
    fi
    basename "$common"
}

# The project key for directory $1: upstream repository name, else the main
# worktree's directory name, else the basename of $1. One key per repository,
# whatever subdirectory or worktree the session runs in.
memcp_project_key() {
    local dir="${1:-}" remote url name
    [[ -n "$dir" && -d "$dir" ]] || dir="$PWD"

    if remote=$(memcp_git_remote "$dir"); then
        url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null)
        name=$(memcp_repo_name_from_url "$url")
        if memcp_valid_key "$name"; then printf '%s\n' "$name"; return 0; fi
    fi

    name=$(memcp_main_worktree_name "$dir")
    if memcp_valid_key "$name"; then printf '%s\n' "$name"; return 0; fi

    name=$(basename "$dir")
    if memcp_valid_key "$name"; then printf '%s\n' "$name"; return 0; fi

    return 1
}

# --- surface identity -------------------------------------------------------

# Short host name of the machine running this hook.
memcp_hostname() {
    local name
    name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null)
    printf '%s\n' "${name:-unknown}"
}

# A fresh surface UUID. Minted once by install.sh and never again — the hooks
# read MEMCP_SURFACE_ID from config.
memcp_new_uuid() {
    local hex
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
        return 0
    fi
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    hex=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    printf '%s-%s-%s-%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

# Human-readable name for this surface, defaulting to the current host name.
memcp_surface_label() {
    printf '%s\n' "${MEMCP_SURFACE_LABEL:-$(memcp_hostname)}"
}

# --- emission ---------------------------------------------------------------

# Emit a fault block on stdout: $1 hook name, $2 fault id, $3 what broke,
# $4 what to do about it. The model reads this on turn one; the exit status of
# the hook stays 0 either way.
memcp_fault() {
    printf '<memcp-hook-error hook="%s" fault="%s">\n' "$1" "$2"
    printf '%s\n' "$3"
    printf 'Remedy: %s\n' "$4"
    printf 'Tell the user memcp is not recording this session, then continue.\n'
    printf '</memcp-hook-error>\n'
}
