#!/usr/bin/env sh
#
# SessionStart hook: inject the shared beads / PR-workflow guidance, but only in
# projects that actually use beads. Detection = a .beads/ directory found while
# walking up from the session's working directory. This keeps the guidance out
# of non-beads projects without needing a per-project CLAUDE.md import.
#
# Bundled in the beads plugin and auto-registered via hooks/hooks.json,
# so it activates on every machine where the plugin is installed — no per-machine
# settings.json entry required.
#
# Because detection is automatic, this plugin is safe to enable globally: it
# stays silent in projects that don't use beads. Profiles with no detectable
# signal (see personal-project) are opted into per project instead.
#
# SessionStart hooks add their stdout to the session context (same mechanism as
# `bd prime`), so emitting the file contents is nearly all that's needed. The
# one rewrite: @BD_PLUGIN_ROOT@ becomes this plugin's install path, so the
# guidance can name bundled scripts (bd-sync.sh) by an absolute path the agent
# can run. awk with index(), not sed, so no character in the path is special;
# and via ENVIRON, not -v, which would eat the backslashes in a Windows path.

set -eu

# Drain the hook JSON on stdin so the parent never blocks on a full pipe.
cat >/dev/null 2>&1 || true

# The shared doc ships with the plugin; fall back to the legacy ~/.claude copy.
shared="${CLAUDE_PLUGIN_ROOT:-}/shared/beads-pr-workflow.md"
[ -f "$shared" ] || shared="$HOME/.claude/shared/beads-pr-workflow.md"
[ -f "$shared" ] || exit 0

# Walk up from the project dir (falls back to PWD) looking for a .beads/ dir,
# stopping at $HOME. $HOME/.beads is not a workspace but bd's own per-machine
# state (machine-id, registry, eventsData), so matching it would inject the
# guidance into every project under the home directory; and no .beads/ above
# home belongs to a project inside it.
home="${HOME:-}"
home="${home%/}"
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$home" ]; do
    if [ -d "$dir/.beads" ]; then
        BD_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}" awk '{
            root = ENVIRON["BD_PLUGIN_ROOT"]; out = ""
            while ((i = index($0, "@BD_PLUGIN_ROOT@")) > 0) {
                out = out substr($0, 1, i - 1) root
                $0 = substr($0, i + 16)
            }
            print out $0
        }' "$shared"
        exit 0
    fi
    dir=$(dirname "$dir")
done

exit 0
