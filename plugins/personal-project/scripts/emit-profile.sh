#!/usr/bin/env sh
#
# SessionStart hook: emit the personal-project workflow profile.
#
# Unlike the beads-workflow injector, this profile has no detectable signal in
# the tree — "this is a single-maintainer personal project" is a policy fact,
# not something that can be sniffed. Selection is therefore explicit: a project
# opts in by enabling this plugin in its own .claude/settings.json:
#
#   { "enabledPlugins": { "personal-project@samalone-plugins": true } }
#
# That file is tracked in git, so the choice travels with the repository to
# every clone and every machine.
#
# SessionStart hooks add their stdout to the session context (same mechanism as
# `bd prime`), so emitting the file contents is all that's needed.

set -eu

# Drain the hook JSON on stdin so the parent never blocks on a full pipe.
cat >/dev/null 2>&1 || true

profile="${CLAUDE_PLUGIN_ROOT:-}/profile.md"
[ -f "$profile" ] || exit 0

cat "$profile"
