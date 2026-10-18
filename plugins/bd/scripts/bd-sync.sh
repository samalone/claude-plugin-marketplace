#!/usr/bin/env bash
#
# bd-sync.sh — run `bd sync` under this clone's push lock.
#
#   bd-sync.sh [bd sync flags...]
#
# The beads guidance has agents run this after every `git push`, so issue data
# leaves the machine as often as code does. A bare `bd sync` is not safe from
# parallel sessions; with-sync-lock.sh explains why and holds the lock. This
# wrapper adds only what an agent should DO about each outcome.
#
# Exit status is bd sync's own, so callers can branch on it:
#   0 synced    1 error    2 merge conflict (nothing pushed)
#   3 transient — lost a push race, a writer was busy, or the lock wait timed out
#   4 stuck dirty working set (nothing pushed; an operator must clear it)
#
set -uo pipefail

say() { printf 'bd-sync: %s\n' "$*" >&2; }

"$(dirname "$0")/with-sync-lock.sh" bd sync "$@"
rc=$?

case $rc in
    0) ;;
    2) say "merge conflict: the sync halted and nothing was pushed. Tell the user; do not resolve it yourself." ;;
    3) say "transient: lost a push race, a writer was busy, or another push held the lock, so nothing was pushed. The next sync will retry; don't loop on it." ;;
    4) say "the dirty working set is stuck, so nothing was pushed and retrying won't help. Tell the user." ;;
    *) say "bd sync failed (exit $rc). Tell the user." ;;
esac
exit "$rc"
