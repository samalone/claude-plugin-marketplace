# Stuart A. Malone's Claude Code Plugin Marketplace

A collection of Claude Code plugins for developer productivity and security.

## Installation

Add this marketplace to Claude Code:

```
/plugin marketplace add samalone/claude-plugin-marketplace
```

Then install any plugin:

```
/plugin install <plugin-name>@samalone-plugins
```

Installing is a per-machine step, and it is separate from enabling. A plugin
that a project opts into via `enabledPlugins` but that has never been installed
on this machine simply does nothing — the entry alone does not fetch the plugin
files into the cache.

From a shell rather than a session, the same two steps are `claude plugin
marketplace add samalone/claude-plugin-marketplace` and `claude plugin install
<plugin-name>@samalone-plugins`; add `--scope project` to install for one
project rather than globally.

## Available Plugins

### 1Password

Securely work with 1Password through the `op` CLI. Manage vaults, items, and secrets without exposing plaintext values to Claude.

- **Category:** Security
- **Repository:** [samalone/claude-1password-plugin](https://github.com/samalone/claude-1password-plugin)
- **Install:** `/plugin install 1password@samalone-plugins`

**Features:**
- List accounts, vaults, and items
- Create, edit, and delete items
- Read secrets via `op://` references
- Inject secrets into template files
- Multi-account support

### beads-tools

Beads (`bd`) Dolt workflow toolkit: the `bd-mode` embedded/server switcher CLI, a deterministic config-audit skill + script, git hooks that sync Dolt data on push/pull, and beads workflow-guidance injection.

- **Category:** Workflow
- **Repository:** [samalone/beads-tools](https://github.com/samalone/beads-tools)
- **Install:** `/plugin install beads-tools@samalone-plugins`

**Features:**
- `bd-mode` CLI for switching a project between embedded and server Dolt modes
- `beads-config-audit` skill + script for deterministic config verification
- Git hooks that sync Dolt data on push and pull
### personal-project

Workflow profile for single-maintainer personal projects: temporary branches instead of PRs, automatic code-review and simplification passes, and merge/cleanup conventions.

- **Category:** Workflow
- **Source:** embedded — [`plugins/personal-project`](plugins/personal-project)
- **Install:** `/plugin install personal-project@samalone-plugins`

Enable it per project, in that project's `.claude/settings.json`:

```json
{ "enabledPlugins": { "personal-project@samalone-plugins": true } }
```

That file is tracked in git, so the choice travels with the repository.

### xcode-project

Workflow profile for Xcode projects: conventions for building, testing, and working with Xcode and Apple platform targets, plus automatic setup of the Xcode MCP server.

- **Category:** Workflow
- **Source:** embedded — [`plugins/xcode-project`](plugins/xcode-project)
- **Install:** `/plugin install xcode-project@samalone-plugins`

Self-gating: it looks for a `*.xcodeproj` or `*.xcworkspace` bundle — scanning down from the project directory to a bounded depth, and up through its parents — and emits nothing when there is none, so it is safe to install once at the user level.

Two things keep that from over-matching:

- **The upward walk stops at the project boundary**, a directory holding `.git` or `.claude` (`.git` may be a file, as it is in a linked worktree). Otherwise it would run to `/`, and one stray workspace in a shared parent such as `~/Projects` would match every project beneath it.
- **Derived bundles are pruned**, `.swiftpm` above all: Xcode writes `.swiftpm/xcode/package.xcworkspace` into any SwiftPM package it has opened, so without that every such package would read as an Xcode project. `DerivedData`, `.build`, `Carthage`, `build`, and `node_modules` are pruned too.

The signal is deliberately narrower than "Swift": a SwiftPM package or a server-side Swift repo has no hand-authored `.xcodeproj` and stays silent.

**Xcode MCP tools.** In an Xcode project with no `xcode` MCP server configured, the plugin runs Apple's documented setup for you:

```
claude mcp add --transport stdio xcode -- xcrun mcpbridge
```

at local scope, so nothing is written into the repository. Two things are worth knowing:

- **The tools are not live in the session that adds them.** MCP servers connect before `SessionStart` hooks run, so they appear on the next session in that project. The hook says so in its output, so the session doesn't plan around tools it doesn't have.
- **The Xcode side is manual.** Xcode > Settings > Intelligence > "Allow external agents to use Xcode tools" must be on, with the project open in Xcode. It is a GUI toggle that writes no readable defaults key, so the plugin reports it as a prerequisite rather than checking it.

See [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode). `xcrun mcpbridge` ships with Xcode 26.1 and later; without it the hook says so instead of adding anything.

### beads

Everything for beads (`bd`) projects in one plugin: workflow guidance injected at session start, plus two skills.

- **Category:** Workflow
- **Source:** embedded — [`plugins/beads`](plugins/beads)
- **Install:** `/plugin install beads@samalone-plugins`

**Workflow guidance (self-gating).** A `SessionStart` hook walks up from the session directory looking for `.beads/` and emits nothing when there is none, so the plugin is safe to install once at the user level. The injected guidance covers claiming, closing vs. merging, gates, discovered work, and multi-worktree rules.

**`/beads:plan <bead-id>`.** Runs a full plan-mode session against one bead and writes the approved plan into that bead's `design` field, for a different session in a different worktree to execute. It never implements. Two frontmatter settings shape how it runs:

- `model: fable` — planning runs on Fable even when the surrounding session is on Opus, with no manual `/model` switch. The override covers the whole skill run, tool-calling turns included. If Fable is not in the account's available models, Claude Code warns and keeps the session model rather than failing.
- `disable-model-invocation: true` — the skill is slash-only. The model cannot pull it in on its own, which matters for a skill that redirects the session into plan mode on another model.

**`/beads:config-audit`.** A deliberate maintenance operation, not a session-time behaviour — invoke it per project, after a `bd` upgrade, or when you suspect config drift. It checks:

- `issues.jsonl` export off, file untracked and gitignored; `interactions.jsonl` kept but untracked
- a Dolt remote on `refs/dolt/data`, with the first push actually done, and its
  URL on HTTPS rather than SSH — SSH keys held by 1Password make background
  auto-push succeed or fail according to whether 1Password is unlocked
- `dolt.auto-push` on for embedded (single-writer) projects, off for server mode
- `backup.git-push` off; `dolt.auto-commit` left at bd's default
- schema matched to the installed `bd`, and mode-appropriate health checks

Skills cannot self-gate the way the hook does: a plugin's `skills/` directory is scanned when the plugin loads, so both skill descriptions enter every session's context, beads project or not. That cost is small — the bodies stay lazy, and `/beads:plan` is hidden from the model entirely — and it buys zero per-project setup.

## License

MIT
