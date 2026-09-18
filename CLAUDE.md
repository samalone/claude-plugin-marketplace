# Claude Plugin Marketplace

This is a Claude Code plugin marketplace repository for `samalone/claude-plugin-marketplace`.

## Structure

- `.claude-plugin/marketplace.json` — Central registry of all plugins
- `plugins/<name>/` — Embedded plugins that live in this repo
- Plugins may be **embedded** here or **referenced externally** by GitHub repo

## Embedded vs. external

Both work; pick by whether the plugin needs its own infrastructure.

- **Embedded** (`"source": "./plugins/<name>"`) — the default for new work.
  One clone, one history, one CI; marketplace and plugin changes land in the
  same commit. Right for small, self-contained plugins such as the workflow
  profiles.
- **External** (`"source": {"source": "github", "repo": "..."}`) — for plugins
  that already carry their own CI, test suite, or beads database, where folding
  them in would mean migrating that infrastructure for no gain.
  `claude-1password-plugin` is external for exactly this reason.

Don't migrate an existing external plugin inward without a concrete reason. The
reason that justified it for `beads-tools` was that the repo had been hollowed
out: its skill and its hook had already moved here, leaving two shell scripts
whose only consumer was this plugin. A two-repo split costs a real invariant —
its `bd-mode` verified a configuration that the audit skill, by then living here,
no longer installed, and the bats harness went on calling a script that had been
deleted. Weigh that seam, not just the infrastructure.

## Adding a Plugin

1. Add an entry to the `plugins` array in `.claude-plugin/marketplace.json`
2. For an embedded plugin, use a relative `source` and create the directory:
   ```json
   {
     "name": "plugin-name",
     "description": "What it does",
     "source": "./plugins/plugin-name",
     "category": "workflow",
     "tags": ["relevant", "tags"]
   }
   ```
   with `plugins/plugin-name/.claude-plugin/plugin.json` alongside it.
3. For an external plugin, use a GitHub `source` reference instead:
   ```json
   {
     "name": "plugin-name",
     "description": "What it does",
     "version": "1.0.0",
     "source": {
       "source": "github",
       "repo": "samalone/claude-plugin-name"
     },
     "category": "development",
     "tags": ["relevant", "tags"]
   }
   ```
4. Update `README.md` with the new plugin's documentation

## Workflow profiles

`personal-project`, `xcode-project`, and `beads` inject guidance at
`SessionStart`. Two selection mechanisms, chosen by whether the project carries a
detectable signal:

- **Explicit opt-in** — for policy facts nothing in the tree reveals ("this is a
  single-maintainer personal project"). The project enables the plugin in its own
  `.claude/settings.json`, which is tracked in git, so the choice travels with the
  repo to every clone and machine:
  ```json
  { "enabledPlugins": { "personal-project@samalone-plugins": true } }
  ```
- **Self-gating** — for projects with a detectable marker. `beads` walks
  up looking for `.beads/`, and `xcode-project` looks for a `*.xcodeproj` or
  `*.xcworkspace` bundle (down to a bounded depth, then up through the parents);
  each emits nothing when it finds none, so both are safe to enable globally.

The two compose: a globally-enabled self-gating profile plus per-project explicit
ones. Each profile's emit script drains stdin before writing, so a hook never
blocks the parent on a full pipe.

**Only the hook self-gates.** A plugin's `skills/` directory is scanned when the
plugin loads — there is no conditional field in the plugin or marketplace
manifest, and no hook event that registers a skill — so a self-gating plugin's
skill descriptions still enter every session's context. That is why `beads`
bundles its skills with the hook rather than splitting them out: ~300 tokens per
skill description everywhere buys zero per-project setup, and the skill bodies
stay lazy. A skill with `disable-model-invocation: true` is hidden from the model
entirely and costs less still.

## Validation

Run `claude plugin validate .` to check the marketplace manifest before committing.

CI (`.github/workflows/ci.yml`) runs that validator plus `shellcheck` on every
push, and the [bats](https://github.com/bats-core/bats-core) suite in `test/` on
macOS **and** Linux. The suite spins real `bd` + Dolt servers in throwaway
fixtures under `$HOME` (bd refuses `/tmp`-family "unsafe" locations; override the
base with `BD_TESTS_TMPDIR`) and never touches a live repo. Locally:

```bash
brew install bats-core shellcheck jq yq       # bd must already be installed (see gates below)
claude plugin validate .
shellcheck plugins/*/scripts/*.sh && shellcheck -x test/helpers/setup.bash
bats test/                                    # ~9 min (see note below)
```

**The suite is slow, and the cost is per-test by design.** 41 of the 46 tests
call `make_project`, which runs a real `bd init` with a Dolt database, and six
use `--ready`, which also pushes to a bare origin. Measured at ~9 minutes on
2026-09-18 (macOS, with 18 unrelated project Dolt servers running); it was ~3
minutes when the suite was change-mode only. CI's `timeout-minutes: 40` still has
headroom, but less than it used to. If it needs to come down, the lever is
sharing one fixture across the read-only `config-audit` checks rather than
rebuilding per test — bats' per-test `setup()` makes that awkward, which is why
it is not done yet.

Two traps the fixtures hit, worth knowing before editing them:

- **`bd init` writes `.beads/config.yaml` with no trailing newline.** A naive
  `>>` append lands on the end of the `sync.remote` line and silently corrupts
  it. Use the harness's `append_config_line`.
- **The audit's CHECKS are now a script; its repairs are still a skill.**
  `config-audit.sh` is read-only and covered by `test/config-audit.bats`.
  `prepare_for_switch` in the harness still reimplements only the preconditions
  `change-mode.sh` checks, because the repairs a skill performs can't be invoked
  from a test. Keep it in sync with that script's Phase A.
- **Two different bd version gates, deliberately.** `config-audit.sh` declares a
  MINIMUM (`BD_MIN=1.3.0`) and CI asserts it by running the script's own
  `--check-version`, so there is no duplicated constant to drift. `change-mode.sh`
  still declares a verified RANGE (1.1.x-1.3.x) and keeps the paired
  script/workflow gate described above. Don't merge the two schemes without
  deciding which one each script wants.
- **`yq` here means mikefarah/yq v4**, the Go binary. `apt install yq` on Debian
  gives kislyuk/yq, a Python jq wrapper with a different CLI; `config-audit.sh`
  gates on the version banner so the wrong one fails loudly. CI installs it from
  Homebrew on both legs.

## Plugin Repos

- [claude-1password-plugin](https://github.com/samalone/claude-1password-plugin) — 1Password MCP server
