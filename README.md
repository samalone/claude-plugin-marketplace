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

### bd

Additions to the **public** beads plugin (`beads@beads-marketplace`), not a replacement for it: PR-workflow guidance injected at session start, plus three skills the public plugin does not provide. Install both — the public plugin supplies `bd prime` at SessionStart and PreCompact plus an MCP server; this one adds personal policy and tooling on top.

- **Category:** Workflow
- **Source:** embedded — [`plugins/bd`](plugins/bd)
- **Install:** `/plugin install bd@samalone-plugins` (alongside `/plugin install beads@beads-marketplace`)

**Workflow guidance (self-gating).** A `SessionStart` hook walks up from the session directory looking for `.beads/` and emits nothing when there is none, so the plugin is safe to install once at the user level. The injected guidance covers claiming, closing vs. merging, gates, discovered work, and multi-worktree rules.

**`/bd:plan <bead-id>`.** Runs a full plan-mode session against one bead and writes the approved plan into that bead's `design` field, for a different session in a different worktree to execute. It never implements. Two frontmatter settings shape how it runs:

- `model: fable` — planning runs on Fable even when the surrounding session is on Opus, with no manual `/model` switch. The override covers the whole skill run, tool-calling turns included. If Fable is not in the account's available models, Claude Code warns and keeps the session model rather than failing.
- `disable-model-invocation: true` — the skill is slash-only. The model cannot pull it in on its own, which matters for a skill that redirects the session into plan mode on another model.

**`/bd:config-audit`.** A deliberate maintenance operation, not a session-time behaviour — invoke it per project, after a `bd` upgrade, or when you suspect config drift. It checks:

- `issues.jsonl` export off, file untracked and gitignored; `interactions.jsonl` kept but untracked
- a Dolt remote on `refs/dolt/data`, with the first push actually done, and its
  URL on HTTPS rather than SSH — SSH keys held by 1Password make background
  auto-push succeed or fail according to whether 1Password is unlocked
- `dolt.auto-push` off on **every** project, set explicitly rather than left to
  the default — git-protocol Dolt remotes have no chunk-level upload atomicity,
  and the debounce is an unlocked read-modify-write, so even one machine running
  parallel agent sessions is a multi-writer setup. Off-machine sync is a
  deliberate `bd sync`.
- `backup.git-push` off; `dolt.auto-commit` left at bd's default
- schema matched to the installed `bd`, and mode-appropriate health checks

The checks are performed by `scripts/config-audit.sh`. Without `--apply` it is
**strictly read-only** — it never runs `bd config set`, touches `.beads/`,
stages, commits, or starts a server — so it is safe to sweep across every project
before deciding anything. `--json` emits the findings machine-readably and
`--no-network` skips the `ls-remote` probe. Exit codes: 0 clean, 1 drift, 2 a
condition needing your decision (a pre-Dolt layout, a real pending migration),
3 script error.

`--apply` prints a repair plan and changes nothing; `--apply --yes` performs the
repairs and re-audits. It acts only on `FAIL` findings, only when no `STOP` is
present, and never on a `WARN` — those are the judgement calls. The order is a
safety property rather than a convenience: the remote must exist, be on HTTPS,
and have taken a real push before anything deletes `issues.jsonl`, and that step
re-runs its own `ls-remote` instead of trusting an earlier repair in the same run,
because it is the one step that destroys data. It makes no git commit — the
working tree is left for review — but it does push `refs/dolt/data`, since that
is what establishes the durability the ordering depends on.

It needs **mikefarah/yq v4** alongside `bd`, `git` and `jq`, and refuses to run
against kislyuk/yq — the unrelated Python tool of the same name that `apt install
yq` provides. yq is there because grep cannot do this job: on bd's stock
`config.yaml`, which is ~95% commented-out documentation, a leaf-name grep for
`git-push:` matches bd's own commented example and *misses* the live
`backup.git-push:` whose leaf is preceded by a dot. To YAML the flat dotted key
and the nested child are genuinely different keys, so `has()` on each answers
exactly. A round-trip yq edit of a real config produces a one-line diff with
every comment byte-identical.

**`/bd:change-mode [embedded|server]`.** Switches the project's Dolt database between embedded mode (`.beads/embeddeddolt/`) and project-server mode (`.beads/dolt/`). The modes are not interchangeable — server mode is noticeably faster, embedded mode has no server process to manage — so this is a deliberate choice, and `disable-model-invocation: true` keeps the skill slash-only so the model can never switch modes on its own initiative. `/bd:config-audit` treats either mode as acceptable precisely so it never second-guesses that choice.

Because the two modes keep their database in different directories, a switch is a physical transfer rather than a config flag. `scripts/change-mode.sh` pushes `refs/dolt/data` first so an off-machine copy exists, backs the database up to a temp directory, copies it across (falling back to `bd bootstrap` from the remote), flips `dolt.auto-push` to match the mode — on for single-writer embedded, off for server, where concurrent auto-push can corrupt remote history — and verifies a per-issue `{id, status, updated_at}` fingerprint against the pre-switch value. Any failure rolls back the mode, config, and data, and restarts a server it had stopped. It never commits: `metadata.json` and `config.yaml` are left modified for you to review.

Git hooks are out of scope by design. `bd init` and `bd hooks install` own the beads git hooks, and the plugin defers to them rather than writing sync sections of its own.

With no argument the skill reports the current mode and changes nothing.

Skills cannot self-gate the way the hook does: a plugin's `skills/` directory is scanned when the plugin loads, so the skill descriptions enter every session's context, beads project or not. That cost is small — the bodies stay lazy, and `/bd:plan` and `/bd:change-mode` are hidden from the model entirely — and it buys zero per-project setup.

## License

MIT
