---
name: change-mode
description: Switch this project's beads (bd) Dolt database between embedded and project-server mode, transferring the database and verifying the two are equivalent. Invoked by typing `/beads:change-mode [embedded|server]`; with no argument it reports the current mode and changes nothing.
disable-model-invocation: true
argument-hint: "[embedded|server]"
---

# Changing a beads project's Dolt mode

Beads stores its Dolt database in a different directory per mode, so switching
is a physical transfer, not a config flag:

| Mode | Data directory | `dolt.auto-push` |
|------|----------------|------------------|
| `embedded` | `.beads/embeddeddolt/<db>` | `true` |
| `server` | `.beads/dolt/<db>` | `false` |

**This is my deliberate choice, not drift.** The two modes differ in real ways —
server mode is noticeably faster, embedded mode has no server process to manage.
The `/beads:config-audit` skill treats either mode as acceptable *precisely so it
never second-guesses this decision*; that silence is not a statement that the
modes are interchangeable. Never run this skill on your own initiative, and never
suggest a switch because a project "should" be in the other mode.

`auto-push` is the one setting genuinely determined by the mode, and the script
flips it: embedded is single-writer, so background durability is safe; server
mode permits concurrent writers, and concurrent auto-push to a git remote can
corrupt remote history.

## Running it

The work is done by `scripts/change-mode.sh` in this plugin — a sibling of this
skill's directory, at `../../scripts/change-mode.sh` relative to this file (use
`${CLAUDE_PLUGIN_ROOT}/scripts/change-mode.sh` if that variable is set).

Run it from the project root, passing the argument through verbatim:

```bash
"<plugin>/scripts/change-mode.sh"            # report current mode; no changes
"<plugin>/scripts/change-mode.sh" embedded   # switch to embedded
"<plugin>/scripts/change-mode.sh" server     # switch to project-server
```

With no argument, report its output and stop — that path is read-only.

**Run it once and let it finish.** It is not idempotent mid-flight: it stops
servers, moves data directories, and holds rollback state in a trap. If it fails,
read the error and report it; do not re-run it to "try again" until you
understand why it failed, and never run two invocations concurrently.

## What it does, so you can interpret its output

1. **Pre-flight (read-only).** Checks the bd version, `backend: dolt`, a git
   `origin`, `sync.remote` in `config.yaml`, an existing `refs/dolt/data` on
   origin, and a clean `bd migrate --dry-run`. Any failure here aborts before
   anything is touched.
2. **Push.** `bd dolt commit` + `bd dolt push`, so an off-machine copy exists
   before the data moves. A failed push aborts the switch — that is deliberate.
3. **Quiesce and back up.** Stops the server if leaving server mode, then copies
   the Dolt data directory to a temp backup.
4. **Flip.** Rewrites `dolt_mode` in `metadata.json` and `dolt.auto-push` in
   `config.yaml`.
5. **Transfer.** Copies the data directory to the new mode's location, falling
   back to `bd bootstrap` from the remote if the copy doesn't verify.
6. **Verify.** Compares a fingerprint of `{id, status, updated_at}` per issue
   plus the total count against the pre-switch value. A mismatch retries via
   bootstrap, then fails.
7. **Finalize.** Removes the old data directory and prints the backup path.

On any failure after step 4 it rolls back the mode, config, and data, and
restarts the source server if it had stopped one. The message will say
`rolling back to '<mode>' mode`.

## Afterwards

The script deliberately does **not** commit. `.beads/metadata.json` and
`.beads/config.yaml` are left modified and uncommitted; show me the diff and
offer to commit it.

Tell me the backup path it printed. It is a temp directory holding the
pre-switch database — leave it in place, and don't delete it as cleanup.

## Out of scope

- **Git hooks.** `bd init` and `bd hooks install` own the beads git hooks. This
  skill does not install, check, or modify them, and neither does the script.
  If Dolt data isn't syncing on push, that's a question for `bd`, not for this.
- **Fixing configuration.** If pre-flight fails on `sync.remote`, a missing
  `refs/dolt/data`, or a pending migration, that's `/beads:config-audit`'s job.
  Report the error and suggest that skill rather than patching config by hand.
