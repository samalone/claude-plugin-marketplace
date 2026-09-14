#!/usr/bin/env sh
#
# SessionStart hook: emit the xcode-project workflow profile, but only in
# projects that are actually built with Xcode (see lib-xcode-detect.sh).
#
# Because detection is automatic, this plugin is safe to enable globally at the
# user level: it stays silent everywhere else. Profiles with no detectable
# signal (see personal-project) are opted into per project instead.
#
# SessionStart hooks add their stdout to the session context (same mechanism as
# `bd prime`), so emitting the file contents is all that's needed.

set -eu

# Drain the hook JSON on stdin so the parent never blocks on a full pipe.
cat >/dev/null 2>&1 || true

profile="${CLAUDE_PLUGIN_ROOT:-}/profile.md"
[ -f "$profile" ] || exit 0

# shellcheck source-path=SCRIPTDIR source=lib-xcode-detect.sh
. "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib-xcode-detect.sh"
xcode_project_detected || exit 0

cat "$profile"
