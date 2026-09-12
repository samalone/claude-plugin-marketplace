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
  them in would mean migrating that infrastructure for no gain. `beads-tools`
  and `claude-1password-plugin` are external for exactly this reason.

Don't migrate an existing external plugin inward without a concrete reason —
`beads-tools` in particular has a Dolt remote pointing at its own repo.

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

`personal-project` and `beads-workflow` are **profiles**: plugins whose only job
is to inject guidance at `SessionStart`. Two selection mechanisms, chosen by
whether the project carries a detectable signal:

- **Explicit opt-in** — for policy facts nothing in the tree reveals ("this is a
  single-maintainer personal project"). The project enables the plugin in its own
  `.claude/settings.json`, which is tracked in git, so the choice travels with the
  repo to every clone and machine:
  ```json
  { "enabledPlugins": { "personal-project@samalone-plugins": true } }
  ```
- **Self-gating** — for projects with a detectable marker. `beads-workflow` walks
  up looking for `.beads/` and emits nothing when it finds none, so it is safe to
  enable globally.

The two compose: a globally-enabled self-gating profile plus per-project explicit
ones. Each profile's emit script drains stdin before writing, so a hook never
blocks the parent on a full pipe.

## Validation

Run `claude plugin validate .` to check the marketplace manifest before committing.

## Plugin Repos

- [claude-1password-plugin](https://github.com/samalone/claude-1password-plugin) — 1Password MCP server
- [beads-tools](https://github.com/samalone/beads-tools) — beads/Dolt workflow toolkit
