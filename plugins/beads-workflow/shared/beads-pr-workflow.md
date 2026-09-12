# Beads — session guidance

This is injected by a `SessionStart` hook whenever a `.beads/` directory is found
above the project. It describes how I want beads *used* during a session. It does
**not** cover configuration or sync — those are handled by my per-project setup
(see the `beads-config-audit` skill), and are deliberately not your concern here.

**Scope.** This assumes Dolt-era beads (`bd` 1.0+), where issue state lives in a
Dolt database. If a project is on a pre-Dolt version (0.x), none of the model
below applies to it — stop and tell me, don't guess.

## How beads state works here

- Issue state lives in a **shared Dolt database** in a gitignored directory
  under `.beads/` (the exact name varies by bd version — you don't need to know
  or touch it). It is **not** in git commits, and it is **not** partitioned by
  git branch.
- A bead you create, claim, or close is visible **immediately** on every branch
  and every worktree pointing at this database. Checking out a different branch
  does not change which beads you see.
- **Closing a bead is a global, immediate write.** It does not travel with a git
  branch and is not carried to `main` by merging a PR. Closing a bead and merging
  its code are independent events.

## Multiple worktrees / sessions on this machine

My setup is single-user and single-machine, sometimes with several git worktrees
of the same clone open at once. All of them share the one live task graph, so:

- **Claim before working:** `bd update <id> --claim --assignee <name>`. Never
  assume you own the top of `bd ready`. If the claim fails ("already assigned"),
  another session took it — re-query `bd ready` and take the next one.
- Use `--json` on commands you parse. Never use interactive commands like
  `bd edit` (they block waiting for input that won't come).
- Modes differ here: in **embedded** mode the database is single-writer, so if a
  command fails with "database is locked," another session is mid-write — just
  retry; it clears in well under a second. In **server** mode there is no such
  lock (concurrent writers are fine), but the shared Dolt server has to be
  running; if commands fail with a connection error, the server is down — tell me
  rather than trying to start or repair it.

## Closing beads vs. merging code

- Close a bead as soon as the code implementing it is written (and preferably
  tested) — not when you open the PR, and not when the PR merges. Closing is
  independent of the PR lifecycle, so closing early is what lets a blocked
  follow-on bead become ready; do not treat closing a bead as a way to
  coordinate other work.
- A **plain dependency** (`bd dep add B A`) unblocks B as soon as A is *closed*
  (work done), which can be well before A's PR merges. Use it only when B needs
  A's *decision or artifact*, not A's merged code.
- When B genuinely needs A's *code on `main`* (e.g. it builds on the same files),
  **gate** it on the PR, not on closure. The gate blocks B directly, so there's
  no separate `bd dep add`:

      # once A's PR is open as, say, #57:
      bd gate create --type=gh:pr --await-id=57 --blocks <B-id> --reason="needs A's code on main"

  B stays out of `bd ready` until #57 merges; `bd gate check` (run by a hook/CI)
  closes the gate and B becomes claimable, branching from an up-to-date `main`.
  Gates serialize, so use them only for genuine build-on ordering — most beads
  need none. **If that `bd gate create` line errors, don't improvise the syntax:
  its flags can shift between bd versions, so check `bd gate create --help` and
  adapt. This is the one command in this file that pins specific flags — re-verify
  it after a bd upgrade.**

## Discovered work

- When work surfaces that's valid but out of scope, file it as a bead
  (`bd create … --deps discovered-from:<id>`) so it isn't lost. Keep *code*
  changes scoped to their PR.
- Put the bead ID in the branch and PR (e.g. `(bd-a1b2)`) so the issue and its
  code stay traceable to each other.

## Storage and config are managed for me — stay out of them

Durability and remote sync are handled automatically by my setup; they're not
something you need to manage. Keep your focus on the code.

- **Do not** run `bd backup` or migrations, and do not touch the `.beads/` data
  directories, unless I explicitly ask. If something about the database or config
  looks wrong, tell me — don't try to repair it inline. That's what the
  `beads-config-audit` skill is for.
- **Do not** commit `.beads/issues.jsonl` (auto-export is off, so committing a
  stray export just creates noise).