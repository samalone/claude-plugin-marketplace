#!/usr/bin/env sh
#
# SessionStart hook: make sure this project is configured to use the Xcode MCP
# server, and configure it if not.
#
#   https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode
#
# Apple's documented setup is two halves. This script automates the half that
# lives in configuration:
#
#   claude mcp add --transport stdio xcode -- xcrun mcpbridge
#
# The other half is a GUI toggle — Xcode > Settings > Intelligence > "Allow
# external agents to use Xcode tools" — with the project open in Xcode. That
# cannot be set from a script, and it writes no readable defaults key, so it is
# reported as a prerequisite rather than checked.
#
# Timing, measured: MCP servers are connected before SessionStart hooks run, so
# a server added here is NOT available in the session that adds it. It takes
# effect the next time a session starts in this project. The notice below says
# so explicitly, so the session doesn't assume tools it does not have.
#
# The add is made at local scope — this project only, in ~/.claude.json — which
# is where `claude mcp add` puts it by default. Nothing is written into the
# repository, so no tracked file changes underneath you.
#
# `claude mcp add` keys local scope off its *working directory*, not
# CLAUDE_PROJECT_DIR, so the add below runs in a subshell that cd's to the
# project first. Without that it silently registers the server against whatever
# directory the hook happened to inherit.

set -eu

# Drain the hook JSON on stdin so the parent never blocks on a full pipe.
cat >/dev/null 2>&1 || true

. "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib-xcode-detect.sh"
xcode_project_detected || exit 0

project="${CLAUDE_PROJECT_DIR:-$PWD}"

# Is an "xcode" server already configured for this project, at any scope?
# The fast path reads the config directly; `claude mcp get` is authoritative but
# costs about a second of session-start latency, so it is only the fallback.
if command -v python3 >/dev/null 2>&1; then
    configured=$(python3 - "$project" <<'PY' 2>/dev/null || echo no
import json, os, sys
project = sys.argv[1]

def has_xcode(path, *keys):
    try:
        with open(os.path.expanduser(path)) as fh:
            node = json.load(fh)
    except Exception:
        return False
    for key in keys:
        if not isinstance(node, dict):
            return False
        node = node.get(key)
        if node is None:
            return False
    return isinstance(node, dict) and "xcode" in node

found = (
    has_xcode("~/.claude.json", "projects", project, "mcpServers")  # local scope
    or has_xcode("~/.claude.json", "mcpServers")                    # user scope
    or has_xcode(os.path.join(project, ".mcp.json"), "mcpServers")  # project scope
)
print("yes" if found else "no")
PY
)
elif (cd "$project" && claude mcp get xcode) >/dev/null 2>&1; then
    configured=yes
else
    configured=no
fi

[ "$configured" = "no" ] || exit 0

# Xcode 26.1+ ships the bridge; without it there is nothing to point at.
if ! xcrun -f mcpbridge >/dev/null 2>&1; then
    cat <<'EOT'
## Xcode MCP tools

This project has no `xcode` MCP server configured, and `xcrun mcpbridge` was not
found, so one could not be added — the bridge ships with Xcode 26.1 and later.
Check the selected toolchain with `xcode-select -p` if a recent Xcode is
installed. Until then, build and test through `xcodebuild` rather than assuming
`mcp__xcode__*` tools exist.
EOT
    exit 0
fi

if (cd "$project" && claude mcp add --transport stdio xcode -- xcrun mcpbridge) >/dev/null 2>&1; then
    cat <<'EOT'
## Xcode MCP tools

This project had no `xcode` MCP server configured, so one was just added for it:
`claude mcp add --transport stdio xcode -- xcrun mcpbridge`.

**Its tools are not available in this session.** MCP servers connect before
SessionStart hooks run, so the server takes effect the next time a session
starts in this project. Do not claim to have `mcp__xcode__*` tools, or plan
around them, until then — use `xcodebuild` for anything needed right now, and
tell the user a restart will pick the tools up.

They also need Xcode > Settings > Intelligence > "Allow external agents to use
Xcode tools" turned on, with this project open in Xcode. That is a GUI setting
this hook cannot check or set; if the tools are missing after a restart, that is
the first thing to verify.
EOT
else
    cat <<'EOT'
## Xcode MCP tools

This project has no `xcode` MCP server configured, and adding one automatically
failed. To configure it by hand:

    claude mcp add --transport stdio xcode -- xcrun mcpbridge

Until that succeeds, build and test through `xcodebuild` rather than assuming
`mcp__xcode__*` tools exist.
EOT
fi
