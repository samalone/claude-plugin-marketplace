# Claude Plugin Marketplace

This is a Claude Code plugin marketplace repository for `samalone/claude-plugin-marketplace`.

## Structure

- `.claude-plugin/marketplace.json` — Central registry of all plugins
- Plugins are referenced externally via GitHub repos, not stored locally

## Adding a Plugin

1. Add an entry to the `plugins` array in `.claude-plugin/marketplace.json`
2. Use external `source` references pointing to the plugin's GitHub repo:
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
3. Update `README.md` with the new plugin's documentation

## Validation

Run `claude plugin validate .` to check the marketplace manifest before committing.

## Plugin Repos

- [claude-1password-plugin](https://github.com/samalone/claude-1password-plugin) — 1Password MCP server
