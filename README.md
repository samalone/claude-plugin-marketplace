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

### beads-workflow

Workflow profile for beads (`bd`) projects: claiming, closing vs. merging, gates, discovered work, and multi-worktree rules.

- **Category:** Workflow
- **Source:** embedded — [`plugins/beads-workflow`](plugins/beads-workflow)
- **Install:** `/plugin install beads-workflow@samalone-plugins`

Self-gating: it walks up from the session directory looking for `.beads/` and emits nothing when there is none, so it is safe to enable globally.

## License

MIT
