#!/usr/bin/env bash
#
# bd-sync.sh — run `bd sync` with every other bd-sync.sh on this clone held off.
#
#   bd-sync.sh [bd sync flags...]
#
# The beads guidance has agents run this after every `git push`, so issue data
# leaves the machine as often as code does. It exists because a bare `bd sync`
# is not safe to run from parallel sessions: Dolt's git-protocol remotes have no
# chunk-level upload atomicity, so two pushes uploading at once can leave the
# remote manifest pointing at chunks that never arrived — silent corruption, not
# an error (see cmd/bd/dolt_autopush.go upstream). `bd sync` retries a push the
# remote REJECTS; it does nothing about two that land together. That is also why
# `dolt.auto-push` is off on every project, and the dolt sql-server does not
# help: for git-protocol remotes bd pushes via a `dolt push` subprocess, outside
# the server.
#
# The lock is a directory in the git COMMON dir, so every worktree of a clone
# shares it — the parallel sessions this guards against are usually worktrees.
# mkdir is atomic on every filesystem we care about, and needs nothing that
# macOS lacks (no flock(1)). The holder's PID goes inside so a lock left by a
# killed process can be reclaimed rather than wedging every later sync.
#
# Only pushes that go through this script are serialized. A hand-run `bd sync`
# or `bd dolt push` bypasses it, which is why the guidance forbids those.
#
# Exit status is bd sync's own, so callers can branch on it:
#   0 synced    1 error    2 merge conflict (nothing pushed)
#   3 transient — lost a push race, a writer was busy, or the lock wait timed out
#   4 stuck dirty working set (nothing pushed; an operator must clear it)
#
# Environment:
#   BD_SYNC_LOCK_WAIT   seconds to wait for the lock (default 300)
#
set -uo pipefail

PROG=bd-sync

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { say "not inside a git repository"; exit 1; }
lock="$common/bd-sync.lock"
wait_max=${BD_SYNC_LOCK_WAIT:-300}

# reclaim_if_stale — remove the lock if its holder is gone. A dead PID is
# conclusive; a missing PID file is the holder's mkdir-to-write window, so it
# only counts as dead once the directory is over a minute old. The rename makes
# the reclaim itself race-free between two waiters: only one mv succeeds. (One
# window remains — a waiter that read the dead PID before another reclaimed and
# re-locked can move the fresh lock aside. It needs a crashed holder AND two
# waiters within microseconds, and costs one overlapping sync, so it is accepted
# rather than solved.)
reclaim_if_stale() {
    local pid aside
    pid=$(cat "$lock/pid" 2>/dev/null) || pid=""
    if [ -n "$pid" ]; then
        kill -0 "$pid" 2>/dev/null && return 0
    else
        [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 0
    fi
    aside="$lock.stale.$$"
    mv "$lock" "$aside" 2>/dev/null || return 0
    rm -rf "$aside"
    say "reclaimed a stale lock${pid:+ left by PID $pid}"
}

waited=0
until mkdir "$lock" 2>/dev/null; do
    reclaim_if_stale
    if [ "$waited" -ge "$wait_max" ]; then
        say "another sync still holds $lock after ${wait_max}s; nothing was pushed — the next sync will retry"
        exit 3
    fi
    [ "$waited" -eq 0 ] && say "waiting for another sync on this clone to finish"
    sleep 1
    waited=$((waited + 1))
done
trap 'rm -rf "$lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
echo $$ > "$lock/pid"

bd sync "$@"
rc=$?

case $rc in
    0) ;;
    2) say "merge conflict: the sync halted and nothing was pushed. Tell the user; do not resolve it yourself." ;;
    3) say "transient: lost a push race or a writer was busy, so nothing was pushed. The next sync will retry; don't loop on it." ;;
    4) say "the dirty working set is stuck, so nothing was pushed and retrying won't help. Tell the user." ;;
    *) say "bd sync failed (exit $rc). Tell the user." ;;
esac
exit "$rc"
