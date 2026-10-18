#!/usr/bin/env bash
#
# with-sync-lock.sh — run a command that pushes to the Dolt remote while
# holding this clone's push lock, so no two pushes from this machine overlap.
#
#   with-sync-lock.sh <command> [args...]      e.g.  with-sync-lock.sh bd dolt push
#
# Every script in this plugin that pushes goes through here: bd-sync.sh (what
# agents run after `git push`), change-mode.sh, and config-audit.sh's repairs.
# Why it matters: Dolt's git-protocol remotes have no chunk-level upload
# atomicity, so two pushes uploading at once can leave the remote manifest
# pointing at chunks that never arrived — silent corruption, not an error (see
# cmd/bd/dolt_autopush.go upstream). `bd sync` retries a push the remote
# REJECTS; it does nothing about two that land together. That is also why
# `dolt.auto-push` is off on every project, and the dolt sql-server does not
# help: for git-protocol remotes bd pushes via a `dolt push` subprocess, outside
# the server.
#
# The lock is a directory in the git COMMON dir, so every worktree of a clone
# shares it — the parallel sessions this guards against are usually worktrees.
# mkdir is atomic on every filesystem we care about, and needs nothing that
# macOS lacks (no flock(1)). PIDs go inside so a lock left by a killed process
# can be reclaimed rather than wedging every later push. It runs as its own
# process, so its traps never meet a caller's (change-mode has rollback traps).
#
# Only pushes that go through here are serialized. A hand-run `bd sync` or
# `bd dolt push` bypasses it, which is why the guidance forbids those.
#
# Exit status is the command's own, except: 1 if this is not a git repository
# or the lock cannot be created, and 3 if the lock wait timed out — the same
# "transient, nothing pushed, retry later" that `bd sync` uses 3 for.
#
# Environment:
#   BD_SYNC_LOCK_WAIT   seconds to wait for the lock (default 90 — under Claude
#                       Code's 120s Bash timeout, so an agent sees exit 3 rather
#                       than a killed tool call)
#
set -uo pipefail

PROG=with-sync-lock

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }

[ $# -gt 0 ] || { say "usage: with-sync-lock.sh <command> [args...]"; exit 1; }

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { say "not inside a git repository"; exit 1; }
lock="$common/bd-sync.lock"
wait_max=${BD_SYNC_LOCK_WAIT:-90}
case $wait_max in
    ''|*[!0-9]*) say "BD_SYNC_LOCK_WAIT must be a whole number of seconds, not '$wait_max'"; exit 1 ;;
esac

# reclaim_if_stale — remove the lock if its holder is gone. The pid file holds
# the script's PID and the command's, and the lock is live while EITHER is:
# a wrapper killed on its own leaves the command still pushing. All dead is conclusive;
# a missing PID file is the holder's mkdir-to-write window, so it only counts
# as dead once the directory is over a minute old. The rename makes
# the reclaim itself race-free between two waiters: only one mv succeeds. (One
# window remains — a waiter that read the dead PID before another reclaimed and
# re-locked can move the fresh lock aside. It needs a crashed holder AND two
# waiters within microseconds, and costs one overlapping push, so it is accepted
# rather than solved.)
reclaim_if_stale() {
    local pid p aside
    pid=$(cat "$lock/pid" 2>/dev/null) || pid=""
    if [ -n "$pid" ]; then
        for p in $pid; do
            kill -0 "$p" 2>/dev/null && return 0
        done
        pid=$(printf '%s' "$pid" | tr '\n' ' ')
        pid=${pid% }
    else
        [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 0
    fi
    aside="$lock.stale.$$"
    mv "$lock" "$aside" 2>/dev/null || return 0
    rm -rf "$aside"
    say "reclaimed a stale lock${pid:+ left by PID $pid}"
}

waited=0
while :; do
    mkdir "$lock" 2>/dev/null && break
    # mkdir also fails for reasons other than contention (a read-only or
    # sandboxed git dir); waiting out the timeout would misreport those as 3.
    # A lock released between the mkdir and this check gets one more try.
    if [ ! -d "$lock" ]; then
        mkdir "$lock" 2>/dev/null && break
        [ -d "$lock" ] || { say "cannot create $lock; did not run: $*"; exit 1; }
    fi
    reclaim_if_stale
    if [ "$waited" -ge "$wait_max" ]; then
        say "another push still holds $lock after ${wait_max}s; did not run: $*"
        exit 3
    fi
    [ "$waited" -eq 0 ] && say "waiting for another push from this clone to finish"
    sleep 1
    waited=$((waited + 1))
done
trap 'rm -rf "$lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
echo $$ > "$lock/pid"

# Still a foreground child, so the traps above wait for it; the inner shell
# records the command's PID beside ours before exec'ing it (see reclaim_if_stale).
bash -c 'echo $$ >> "$1/pid"; shift; exec "$@"' with-sync-lock "$lock" "$@"
