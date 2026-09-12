#!/usr/bin/env sh
#
# SessionStart hook: inject the shared beads / PR-workflow guidance, but only in
# projects that actually use beads. Detection = a .beads/ directory found while
# walking up from the session's working directory. This keeps the guidance out
# of non-beads projects without needing a per-project CLAUDE.md import.
#
# Bundled in the beads-workflow plugin and auto-registered via hooks/hooks.json,
# so it activates on every machine where the plugin is installed — no per-machine
# settings.json entry required.
#
# Because detection is automatic, this plugin is safe to enable globally: it
# stays silent in projects that don't use beads. Profiles with no detectable
# signal (see personal-project) are opted into per project instead.
#
# SessionStart hooks add their stdout to the session context (same mechanism as
# `bd prime`), so emitting the file contents is all that's needed.

set -eu

# Drain the hook JSON on stdin so the parent never blocks on a full pipe.
cat >/dev/null 2>&1 || true

# The shared doc ships with the plugin; fall back to the legacy ~/.claude copy.
shared="${CLAUDE_PLUGIN_ROOT:-}/shared/beads-pr-workflow.md"
[ -f "$shared" ] || shared="$HOME/.claude/shared/beads-pr-workflow.md"
[ -f "$shared" ] || exit 0

# Walk up from the project dir (falls back to PWD) looking for a .beads/ dir.
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -d "$dir/.beads" ]; then
        cat "$shared"
        exit 0
    fi
    dir=$(dirname "$dir")
done

exit 0
