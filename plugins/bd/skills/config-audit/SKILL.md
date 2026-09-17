---
name: config-audit
description: >-
    Audit and repair a project's Beads (bd) configuration to my preferred
    single-user Dolt workflow. Use this whenever I ask to check, fix, update,
    verify, or migrate a project's Beads setup — for example after I upgrade the
    bd binary, when I first set up beads in a project, when bd commands behave
    oddly or the database seems corrupted or out of date, or when I say my
    config preferences have changed. It verifies the bd version and schema, runs
    the right health checks for the storage mode, turns off issues.jsonl
    auto-export, ensures a refs/dolt/data remote over HTTPS rather than SSH,
    turns dolt.auto-push off on every project, fixes the gitignores including
    the dolt-server-config.yaml pattern bd omits, disables the branch-polluting
    backup git-push, suppresses the bd 1.3.0 doctor warnings that describe my
    deliberate choices rather than drift, and confirms everything works. Don't wait for me to spell
    out each step — invoke this whenever the task is "get this project's Beads
    config into my preferred state."
---

# Beads config audit

Bring the current project's Beads configuration into my preferred state and
confirm the database is healthy. This is a maintenance operation I run
deliberately — per project, after a `bd` upgrade, or when I suspect drift or
corruption. It is separate from normal session use.

## My preferred state (the target)

For a single-user, single-machine project:

- **Either storage mode is fine.** Embedded and server mode are equally
  acceptable — in my experience server mode is much faster and just as
  reliable, so never treat server mode on a solo project as drift to fix or a
  decision I need to make. Mode no longer changes any config value — it affects
  only which health checks are available (`bd sql` and `bd doctor` are
  server-mode-only). `dolt.auto-push` used to branch on mode; it does not any
  more, see below.
- `issues.jsonl` auto-export **OFF**, and the file untracked, deleted, and
  gitignored — I don't read it and it only creates surprise edits and junk
  commits.
- `interactions.jsonl` (the audit log) kept locally but untracked and gitignored
  — **not** deleted; it's a recovery trail, not a redundant snapshot.
- A **Dolt remote** on `refs/dolt/data` (normally the same git `origin`), with
  the first push done so the ref actually exists — and its URL over **HTTPS,
  never SSH**. My SSH keys are held by 1Password's agent, so they exist only
  while 1Password is unlocked and I'm at the machine; a background auto-push
  over SSH fails unpredictably depending on the lock state and whether I'm AFK.
- `dolt.auto-push` **OFF on every project, unconditionally** — set explicitly
  to `false`, never left to the default. Off-machine sync is a deliberate
  `bd sync` (or `bd dolt push`) that I run. See the auto-push note below for
  why this is not mode-dependent and why "I am a single writer" is not a safe
  enough premise to build on.
- The backup system's git-push (`backup.git-push`) **OFF** — it force-commits
  and pushes on the working branch, which is exactly the friction I'm avoiding.
- `dolt.auto-commit` left at bd's default (**on** in 1.1.0, regardless of mode)
  so writes land in Dolt history rather than piling up uncommitted in the
  working set. Do **not** force it off in either mode — an uncommitted working
  set is the state that can block migrations and brick `bd`.
- Schema migrated to match the installed `bd`, and health checks clean —
  with `doctor.suppress.dolt-remote-vs-git-origin` and
  `doctor.suppress.cursor-integration` set, since both of those warnings
  describe a deliberate choice rather than drift (step 4).
- The project's `CLAUDE.md` carries my **memory division-of-labor note**, placed
  *outside* bd's managed block, correcting `bd prime`'s blanket "do NOT use
  MEMORY.md files" rule (step 4).

## Before you touch anything

- **This is a fast-moving tool.** Command names, flags, and config defaults
  change between versions. Before relying on any command below, confirm it with
  `bd <command> --help` and adapt. If a command errors or isn't recognized, stop
  and tell me rather than forcing it.
- **Verify every config change with `bd config get <key>`**, not just the exit
  code of `bd config set` — config routing for some keys has been buggy, and a
  `set` that reports success may not have taken.
- **Duplicate/ambiguous config lines (confirmed in 1.1.0) — `bd config get`
  alone can't detect them; inspect the file.** `bd config set` writes a setting
  inconsistently: sometimes as a flat dotted key (`dolt.auto-push: true`) and
  sometimes as a child of a nested block (`dolt:` → `    auto-push: true`),
  depending on what's already in `.beads/config.yaml`. The same setting can end
  up present in **both** forms at once, with **conflicting values**. When that
  happens:
    - `bd config get <key>` silently returns only the **flat** dotted line and
      ignores the nested one — so it reports a single value and looks fine even
      though the file is ambiguous. Verifying with `get` is necessary but **not
      sufficient**.
    - `bd config unset <key>` removes only **one layer**. Unsetting a duplicated
      key can *uncover a stale shadow value* underneath instead of clearing the
      setting — e.g. an `unset` flipped the effective value from `true` to
      `false` rather than returning it to the default. Re-`set` has the same
      one-layer blind spot.
  - **Workaround.** After changing any config key, don't trust `get` by itself —
    grep the raw file and confirm the key appears **exactly once**:

        grep -nE '(^|[[:space:]])<key-leaf>:' .beads/config.yaml   # e.g. auto-push:

    (Check both the flat form `namespace.key:` at column 0 and the nested child
    `key:` indented under a `namespace:` line.) If it appears more than once,
    the file is ambiguous: hand-edit (or `sed`) it down to a **single**
    representation — either one flat dotted line or one nested-block child, your
    choice — delete the stale duplicate, then re-run `bd config get <key>` to
    confirm the intended value survived. Do not rely on repeated
    `bd config set`/`unset` to clean this up; they operate one representation at
    a time and can leave or reveal the other. A direct file edit is the reliable
    fix here.
- **Known 1.1.0 display quirks — don't be fooled into "fixing" a non-problem.**
  `bd dolt show` can print `Remotes: (none)` even when a remote exists, and the
  remote key is `sync.remote` (so `bd config get sync.git-remote` reports "not
  set" — that's the wrong key, not a missing remote). Treat
  `bd dolt remote list` plus a successful `bd dolt push` (and the
  `refs/dolt/data` ref actually existing) as the source of truth for whether a
  working remote is in place. Never re-add a remote based on `bd dolt show` or a
  `sync.git-remote` lookup — you'd just be duplicating one that's already there.
- **Known 1.1.0 command quirks around history — use `bd vc status`, not
  `bd history`.** `bd vc log` does **not** exist in 1.1.0 (it's in older docs);
  don't call it. But the `bd vc` group _does_ exist, and **`bd vc status`
  works** — it reports the current branch, the HEAD commit, and whether the
  working set is clean, which is the health/state signal you actually want (a
  clean working set also confirms auto-commit is keeping up and nothing is
  accumulating toward a migration brick). **A clean working set prints
  nothing.** In 1.2.2 the command outputs only `Branch:` and `Commit:` when
  there is nothing uncommitted — `bd vc status --help` confirms it shows "any
  uncommitted changes", i.e. the changes line appears *only* when the set is
  dirty. Absent output is therefore the pass, not a broken or truncated
  command; don't go hunting for a cleanliness line that was never going to
  print, and don't conclude the signal was dropped from the command.
  **But do not treat it as the authority on cleanliness.** Measured on 1.3.0:
  right after a `bd config set`, `bd vc status` printed branch and commit with
  no changes line — reading as clean — while `bd doctor` in the same instant
  reported `config: modified`, and `bd vc commit` went on to create a real
  commit. So `bd vc status` under-reports at least table-level config changes.
  When cleanliness actually matters (before a migration, or at final
  verification), trust `bd doctor`'s `Dolt Status` / `Dolt Locks` checks and
  treat `bd vc status` as the branch/commit readout only.
  `bd history` does exist but is
  currently broken on migrated databases (known bug, fix unmerged): it fails on
  historical rows whose `description` was NULL, with
  `Scan error on column index 2, name "description": converting NULL to string is unsupported`.
  That's a read-path bug, **not** corruption — the tell is that it fails
  _uniformly_ on every issue rather than on a few. Since migrated DBs are
  exactly what this skill audits, treat a `bd history` failure as noise, don't
  repair anything over it, and verify state with `bd vc status` plus `bd list`
  and `bd dolt status`.
- **Back up before migrating — but `bd backup` alone is no longer that
  command.** As of 1.2.2 `bd backup` is a subcommand group
  (`init`/`sync`/`restore`/`remove`/`status`): bare `bd backup` just prints help
  and backs nothing up, so a run that believes it "did the backup step" may have
  done nothing at all. Don't paper over that with `bd backup sync` either — it
  errors with *"no backup destination configured"* unless a destination was
  explicitly `bd backup init`-ed, and it says that even on a project where
  `bd backup status` reports a healthy recent archive (bd's automatic backup and
  the `sync` subcommand disagree about what counts as "configured"). What to
  actually do: run `bd backup status` and confirm it reports an archive at the
  **current** Dolt commit (compare it against `bd vc status`), then treat
  **`bd dolt push` as the real pre-migration durability step** — by the time you
  migrate, this skill has already guaranteed a remote, and the push is the one
  path that reliably works. Only run `bd backup init <path>` if I ask for a
  second, independent backup destination.
- **Don't destroy data.** If anything is ambiguous — a possible pre-Dolt layout,
  a remote-backed database, a pending migration you're unsure about — stop and
  report rather than acting.

## Procedure

### 1. Identify the project

- `bd version` — the installed binary version.
- `bd dolt show` and `bd dolt status` — storage mode (embedded vs server) and
  data directory.
- `bd dolt remote list` — remotes ("No remotes configured" is a durability gap
  to fix in step 4).
- Inspect `.beads/`: `embeddeddolt/` = embedded, `dolt/` = server. If there is
  **no** Dolt data directory and the project looks JSONL-centric, it is likely a
  **pre-Dolt (0.x) project** — do not treat this as a normal audit. Stop and
  tell me; that needs a dedicated pre-Dolt → Dolt migration, not this skill.

### 2. Check schema / version state

- Determine whether the database schema matches the installed binary. Try
  `bd info` (it reports schema versioning) and `bd migrate --dry-run` (or
  `--inspect`) to preview any pending migrations. **Never run bare `bd migrate`
  to inspect** — it can apply migrations. Use the dry-run form to look first.
- **A version mismatch is not automatically a schema migration — read
  `Registered Migrations` before deciding how careful to be.**
  `bd migrate --inspect` reports both the version skew *and* a
  `Registered Migrations:` count, and the two mean very different things:
    - **`Registered Migrations: 0`**, with a warning like *"schema version
      mismatch (current: 1.1.0, expected: 1.2.2)"*, is a **metadata version
      stamp only** — no DDL, no data rewrite. `bd migrate --dry-run` confirms it
      by reporting nothing but `Would update Dolt version: X → Y`. That is safe
      to apply in place even on a remote-backed database: apply it, then push.
      Do **not** escalate it into the single-designated-migrator ceremony below
      — that is a lot of caution spent on a one-line stamp, and it's the common
      case right after I upgrade the `bd` binary.
    - A **non-zero** count means real schema work, and the remote rules below
      apply in full.
    - Note that `bd migrate schema` (the DDL subcommand) takes **no**
      `--dry-run` flag; `bd migrate --inspect` is the inspection path.
- If a *real* (non-zero-count) migration is pending:
    - If the database has **no remote** (single local copy, my common case):
      it's safe to migrate here. Take the durability step above (`bd backup
      status` check plus `bd dolt push`), then run `bd migrate`.
    - If the database **has a remote**: beads may refuse to auto-apply (a
      remote-migrate safety gate). Migrate deliberately as the single designated
      migrator — `bd migrate` here, then `bd dolt push` — and remember any
      _other_ clone must adopt the migrated DB with `bd bootstrap`, not migrate
      on its own. If you can't tell whether other clones exist, stop and ask me.

### 3. Run health checks (mode-aware)

- **Server mode:** first confirm the Dolt server is actually running and
  reachable — `bd dolt status`, and `bd dolt start` if it's a per-project server
  that isn't up (a connection-refused error means it's down). Then run
  `bd doctor` and `bd doctor --server` for reachability, version compatibility,
  and pool health, with `bd doctor --fix` for repairable issues. Also note
  whether this is a **per-project** server or an **external/shared** one (an
  explicit host/port in config, or shared-server mode): a shared server must
  give this project a unique prefix/database name, and its lifecycle is not this
  project's to start or stop.
- **What `--fix` can actually touch — and why `--dry-run` overstates it.**
  `bd doctor --fix --dry-run` echoes the `Fix:` advice string of *every*
  warning and closes with "Would attempt to fix N issue(s)", which reads as a
  plan. It is not one. `DoctorCheck` (`cmd/bd/doctor/types.go`) has **no
  `Fixable` field**; `applyFixList` (`cmd/bd/doctor_fix.go`) dispatches on the
  check **name**, and a name with no `case` falls to a default that prints
  "No automatic fix available for X" and continues. Verified on 1.3.0 — these
  four are *not* cases, so `--fix --yes` cannot act on them:
  `Dolt Remote vs Git Origin`, `Cursor Integration`, `Agent Doc Divergence`,
  `Git Working Tree`. That matters because the first one's advice is *"remove
  the conflicting remote(s)"*, which would sever the project's only off-machine
  copy of the beads data. It is safe to run `--fix --yes`; it is not safe to
  read the dry-run as a list of intended changes. If a future version adds a
  `case` for one of these, re-check before trusting this note.
- **Hook updates produce no commit.** `bd hooks install` writes to
  `.git/hooks/`, which is outside the work tree, so refreshing outdated hooks
  (a near-universal warning after a `bd` upgrade) changes nothing git tracks —
  don't budget a diff for it. Two details: `--force` is now a documented no-op
  ("kept for compatibility (section markers always preserve non-bd content)"),
  so plain `bd hooks install` suffices; and the install leaves
  `pre-commit.backup` / `post-merge.backup` behind in `.git/hooks/`, which are
  harmless and unversioned.
- **Embedded mode:** `bd doctor` may report that it isn't supported in embedded
  mode. If so, verify health directly instead. First get the actual data
  directory from `bd dolt show` / `bd dolt status` (the reported `Data:` path) —
  **do not assume the directory name.** It has been `.beads/embeddeddolt/` on
  databases created by older `bd` and `.beads/proxieddb/` on ones created by
  newer `bd`, and the published docs don't always match a given install. Then
  confirm that directory exists, `bd version` is current, `bd list` returns
  issues, and `bd vc status` reports the expected branch with a clean working
  set (use this, not `bd vc log` or `bd history` — see the command-quirks note
  above). Reconcile stale server marker files only if present and clearly
  orphaned.

### 4. Apply my preferred config

**Order matters — establish durability before removing anything.** Ensure the
remote is configured and a first `bd dolt push` has actually _succeeded_ (the
remote bullet below), or a `bd backup init` destination is set up, **before** you
delete `issues.jsonl`. That file is not a backup, but on a project that has no
remote yet it may be the only off-machine copy that exists — so never remove it
until a real durability path is in place. If the remote can't be established
(e.g. no git origin), stop and tell me; leave the export alone.

Set each, then confirm with `bd config get`:

- **Turn off auto-export and clean up the JSONL files.** First
  `bd config set export.auto false` (a past release flipped this on by default,
  so on an upgraded project it's an active change, not a no-op). Then handle the
  two `.beads/*.jsonl` files — which are _not_ the same kind of thing:
    - **`issues.jsonl` — remove it entirely.** It's a regenerable snapshot of
      the issues table and I don't use it. Stopping the export is not enough on
      its own: if the file was already committed, that just freezes a stale,
      misleading copy in the repo. Check whether git tracks it
      (`git ls-files --error-unmatch .beads/issues.jsonl`). If tracked,
      `git rm .beads/issues.jsonl` (drops it from the index _and_ the working
      tree); if it's present but untracked, just delete it. Either way, add
      `.beads/issues.jsonl` to `.gitignore` so it can't be re-added, and commit
      the removal plus the gitignore change as a small cleanup commit. Deletion
      is safe — it's redundant with the Dolt database and regenerable via
      `bd export` if a JSONL-reading viewer ever needs one.

    - **`interactions.jsonl` — keep it, but keep it out of git.** This is _not_
      a redundant snapshot: it's an append-only audit log of
      status/assignee/priority changes and close reasons that deliberately
      survives Dolt GC/flatten, so it's a genuine recovery trail after
      aggressive cleanup (`bd prune`/`bd flatten`). Do **not** delete it, and do
      **not** disable the logging. Just take it out of git so it stops causing
      surprise-modification commits: if tracked,
      `git rm --cached .beads/interactions.jsonl` (untrack but **keep** the
      working file) and gitignore it; if already untracked, just gitignore it.
      This is correct for my single-machine setup, where a local-only log still
      covers recovery. If I ever go multi-machine and want the audit trail to
      travel, that would be a deliberate choice to commit it and accept the
      churn — flag that to me, don't decide it here.

- **Ensure a remote:** check with `bd dolt remote list` (the authoritative
  source — see the display-quirk note above; do not judge this from
  `bd dolt show`). If it _truly_ shows none, add one with
  `bd dolt remote add origin https://<host>/<owner>/<repo>.git` — that command
  registers the remote and writes the correct `sync.remote` key into
  `.beads/config.yaml` itself, so don't hand-edit the config or guess the key
  name. Build that URL from the repo path rather than copying git `origin`
  verbatim: if `origin` is itself SSH, copying it walks straight into the
  problem the next bullet exists to prevent. Then run the first `bd dolt push`
  to create `refs/dolt/data`, and commit the config change bd wrote so a fresh
  clone can `bd bootstrap`.
- **Force the remote onto HTTPS if it's on SSH.** Read the URL in
  `bd dolt remote list`. Anything of the form `git+ssh://git@host/owner/repo.git`,
  `ssh://…`, or scp-style `git@host:owner/repo.git` must be replaced; the
  equivalent is `https://host/owner/repo.git`.

  This is the one remote property worth changing on an otherwise-working
  project. `dolt.auto-push` fires in the background after `bd` writes, with no
  one watching — over SSH it depends on 1Password holding my keys, so it
  succeeds or fails according to whether 1Password happens to be unlocked, and
  the failures are silent background noise rather than something I'd notice.
  HTTPS goes through the `osxkeychain` credential helper and the `gh` token
  instead, which need no unlock.

  There is **no `set-url`** — `bd dolt remote` offers only `add`, `list`, and
  `remove` (1.2.2) — so the change is remove-then-add:

      bd dolt remote remove origin
      bd dolt remote add origin https://<host>/<owner>/<repo>.git
      bd dolt push

  Removing the remote drops only the local registration; it does not touch
  `refs/dolt/data` on the server or anything in the local database. Then commit
  the `.beads/config.yaml` change bd wrote.

  Two things **not** to do here:

    - **Don't touch git `origin`.** Git pushes are interactive, so an unlock
      prompt there is fine — this is only about unattended auto-push. Changing
      `origin` is a separate decision, and mine to make.
    - **Don't normalize `https://` to `git+https://` or back.** Both spellings
      are in use across my projects and both work; `bd dolt remote add` writes
      the `git+` prefix itself on current versions. Only the *transport*
      matters — a bare `https://` is not drift.

  Afterwards, apply the duplicate-key check from the top of this skill: the
  remote lives as either a flat `sync.remote:` or a nested `remote:` under
  `sync:`, and a remove/add cycle is exactly the sort of thing that can leave
  both. Grep for `remote:` in `.beads/config.yaml` and confirm exactly one
  uncommented line.
- **Auto-push: turn it OFF, on every project.**
    - `bd config set dolt.auto-push false`, then **verify with
      `bd config get dolt.auto-push`** and check the file for a duplicate key.
      Set it explicitly even when `bd config get` already reports `false`:
      the default has changed before — bd's own source records that it once
      "auto-enable[d] when an 'origin' remote exists" — so an unset key is an
      inherited answer, not a stated one.
    - **Why not mode-dependent, and why my own single-writer habits are not
      enough.** The hazard is concurrent *push sources*, and the damage is to
      the remote: per `cmd/bd/dolt_autopush.go`, git-protocol Dolt remotes have
      no chunk-level upload atomicity, so concurrent pushes race on the remote
      manifest and can leave it referencing chunks that were never uploaded —
      and "any subsequent fetch/clone/push propagates the dangling reference."
      It is silent corruption, not an error.
    - **One machine is enough to cause it.** The push does NOT run inside the
      dolt sql-server, so the server does not serialize it: `maybeAutoPush`
      runs in the bd CLI process from `PersistentPostRun` and shells out. The
      debounce does not protect either — load push-state, compare the interval,
      push, save is an unlocked read-modify-write, so two `bd` write commands
      landing in the same project within one push duration (up to the 30s
      timeout) both decide a push is due and both push. Parallel agent sessions
      in one project are therefore a multi-writer setup.
    - So the rule is unconditional rather than a judgement call. I decided
      (2026-09-17) that relying on me to foresee every source of concurrency is
      too thin when the consequence is corrupted remote beads data.
    - **The replacement is `bd sync`, run deliberately.** It pulls, detects
      conflicts positively, recomputes the denormalized `is_blocked` (which a
      bare push does not — a dependency edge merged from elsewhere otherwise
      leaves `bd ready` stale), then pushes with bounded retry on a lost push
      race. Exit codes: 0 synced, 1 error, 2 conflict halted, 3 retries
      exhausted, 4 dirty working set stuck. Note it retries a *rejected* push;
      it does not make simultaneous uploads safe either. A single scheduled
      timer would be one push source by construction, which is the direction to
      automate in eventually — a GitHub ref used as an atomic lock
      (`--force-with-lease=refs/beads/push-lock:` for create-only semantics) is
      the sketch, with stale-lock TTL as the unsolved part.
    - Report that off-machine sync relies on explicit `bd sync`, for every
      project rather than only server-mode ones.
- **Gitignore: let bd own its patterns, and add the one it misses.**
    - **Server mode → `bd doctor --fix --yes`.** bd maintains
      `.beads/.gitignore` and the project `.gitignore` from its own
      `requiredPatterns` list, and it is **append-only** on an existing file —
      `cmd/bd/doctor/gitignore.go` says it "must never rewrite an existing file
      wholesale", with a regression guard (bd-kaaz3) from an incident where a
      full-template rewrite destroyed local rules. So delegating is safe and my
      own additions survive. Don't duplicate bd's list here; it grows between
      versions (1.3.0 added `*.gate.lock*`) and a copy would drift.
      Note `--fix` alone declines non-interactively and tells you to pass
      `--yes`. It also rewrites the PROJECT `.gitignore`, a tracked file — fine
      inside a deliberate audit, but say so in the report.
    - **Then append `dolt-server-config.yaml` to `.beads/.gitignore` myself.**
      bd generates this file in server mode (machine-local: `log_level`,
      `listener.host`) and does NOT ignore it. Its `requiredPatterns` lists five
      siblings — `dolt-server.pid`, `.log`, `.lock`, `.port`, `.activity` — and
      omits this one, and no existing glob catches it (the name is
      `dolt-server-config.yaml`, hyphen not dot, so `dolt-server.*` misses it;
      `*.lock` and `daemon.*` miss it too). Verified on bd 1.3.0: present in
      every server-mode project, ignored in none. Without the pattern a
      `git add .` commits machine-specific server config into a shared repo.
      Guard the append: `bd init` writes these files with no trailing newline,
      so check the last byte first (same trap as `set_auto_push` and the test
      harness's `append_config_line`).
    - **Embedded mode → do it all by hand; there is NO bd mechanism.** Verified
      on 1.3.0: `bd doctor` is still unsupported in embedded mode, and — the
      trap — it prints "not yet supported in embedded mode" and **exits 0**, so
      a script checking `$?` concludes the fix ran when nothing happened. And
      `bd init` is NOT safe to re-run despite doctor's own advice saying so: it
      fails with "Found existing Dolt database" and tops up nothing (measured:
      81 gitignore lines before and after). So on an embedded project, compare
      `.beads/.gitignore` against bd's pattern list by hand and append what is
      missing. Report that bd's suggested remedies do not apply.
    - Afterwards confirm nothing newly-generated is tracked:
      `git status --short -- .beads/` should show no `??` entries for
      `dolt-server-config.yaml`, `*.gate.lock`, or the data directory.
- **Silence the two 1.3.0 warnings that are policy, not drift.** Both are
  advisory and both recur on every project, so suppress them rather than
  re-triaging them 18 times. Slugs are the check name lowercased with spaces
  hyphenated (`CheckNameToSlug` in `cmd/bd/doctor/suppress.go`):

      bd config set doctor.suppress.dolt-remote-vs-git-origin true
      bd config set doctor.suppress.cursor-integration true

  **These two keys do NOT live in `.beads/config.yaml`.** `bd config`'s help
  says configuration is "stored per-project in the beads database", and only
  `export.*`, `import.*` and `lint.*` are annotated as living in the YAML. So
  the duplicate-key grep at the top of this skill finds *nothing* for them,
  and that is not a failed write. Verify with `bd config get`, or read the rows
  directly (`key` is reserved, so it needs backticks):

      bd sql "SELECT * FROM config WHERE \`key\` LIKE '%suppress%'"

  Two consequences. They travel to other machines on `refs/dolt/data`, which is
  what I want for repo-scoped policy — but only after a `bd dolt push`. And
  writing them leaves the `config` table dirty in the Dolt working set, which
  surfaces as two *new* warnings, `Dolt Status` and `Dolt Locks`, both
  "uncommitted changes". Clear them with `bd vc commit -m "..."` and push;
  don't leave them to the "auto-commit on next bd command" that bd offers,
  since a dirty working set is the state that blocks migrations.

    - **`Dolt Remote vs Git Origin`** fires because my Dolt remote *is* the git
      origin, which is the target state above, and bd 1.3.0 started warning
      about it. **Never act on its advice.** Both remedies it offers — removing
      the remote, or `dolt.local-only=true` — destroy the only off-machine copy
      of the beads data, which is far worse than what they prevent. The warning
      is not baseless, but it is cosmetic: the issue data lives on
      `refs/dolt/data`, fully isolated from `refs/heads/*`, so there is no ref
      collision and no corruption path. The real cost is that Dolt plants two
      branches in git's branch namespace — `__dolt_remote_info__` and
      `beads-sync` — where they show up in `git branch -r`, GitHub's branch
      list, and anything that enumerates branches. Worth knowing; not worth
      severing sync over.
    - **`Cursor Integration`** wants `bd setup cursor`. I don't use Cursor.
- **Disable backup git-push:** `bd config set backup.git-push false`, then
  **verify with `bd config get backup.git-push`**. This one auto-re-enables when
  a git remote exists (which step 4 just ensured), and it's the setting that
  stacks `bd: backup …` commits on my working branch — never leave it on. If the
  `set` won't stick, tell me about the env-var workaround rather than looping.
- **Leave `dolt.auto-commit` at bd's default** (`bd config get dolt.auto-commit`
  — **on** in 1.1.0, with no mode distinction). Do **not** force it off, in
  either mode: forcing it off lets writes accumulate uncommitted in the Dolt
  working set, which is the state that blocks migrations and can brick every
  `bd` command. (An older rationale for off-in-server was avoiding "database is
  read only" errors under heavy concurrent writes — but 1.1.0 no longer splits
  this default by mode, and that error hasn't shown up at my scale, whereas the
  dirty-working-set brick has. Leave it on.)

- **`Agent Doc Divergence`: opt out, and check whether `AGENTS.md` is stale.**
  bd 1.3.0 warns when `AGENTS.md` and `CLAUDE.md` differ outside the
  `BEGIN/END BEADS INTEGRATION` markers, and offers four remedies. On my
  projects the first three are **destructive**: `CLAUDE.md` is the real,
  hand-written project instruction file and may carry no bd-managed block at
  all, while `AGENTS.md` is bd's generated agent primer. Symlinking them, or
  regenerating `CLAUDE.md` with `AGENTS.md` as the "source of truth", throws
  away the project instructions. Take option (d) — the divergence is
  intentional — by appending to `AGENTS.md`, **after** the END marker:

      <!-- bd-doctor-divergence: ok -->

  Then check the block's own vintage, because the divergence often means
  `AGENTS.md` has been frozen since an older `bd`. The tell is the BEGIN
  marker: current `bd` writes
  `<!-- BEGIN BEADS INTEGRATION v:N profile:… hash:… -->`
  (`internal/templates/agents/render.go`), so a **bare**
  `<!-- BEGIN BEADS INTEGRATION -->` is the pre-versioned format. A stale block
  can carry instructions bd itself has since retracted — notably a "MANDATORY
  WORKFLOW" mandating `git pull --rebase`, which contradicts my plain-merge
  rule. Compare the live template against the file with
  `bd setup codex --print` (read-only, prints to stdout; do **not** use
  `bd setup claude`, which would add a managed block to a `CLAUDE.md` that has
  none). **Report the drift and propose regenerating; don't regenerate
  unasked** — it replaces user-visible repo content, so it's my call per
  project.

- **Add the memory division-of-labor note to the project's `CLAUDE.md`.**
  `bd prime` is injected at every SessionStart and PreCompact, and its Core
  Rules say *"Do NOT use MEMORY.md files — they fragment across accounts."*
  That line is a hardcoded literal in `cmd/bd/prime.go` — unlike the git and
  profile rules beside it, it is gated on no config — so it cannot be switched
  off and comes back with every `bd` upgrade. My global `CLAUDE.md` already
  overrides it on this machine; the project copy is so the correction travels
  with the repo to other machines and clones. Append a short section like:

  ```markdown
  ## Memory: beads vs. Claude Code auto-memory

  `bd prime` says not to use MEMORY.md files. Disregard that blanket rule and
  split by what the fact is *about*: `bd remember` for knowledge about this
  repo (conventions, gotchas, decisions — it travels on `refs/dolt/data` and
  any agent on any machine can read it; keep the count low, since prime injects
  every memory in full every session), and Claude Code auto-memory under
  `~/.claude/projects/<project>/memory/` for facts about me and how I want you
  to work. Explicit user instructions override the beads block, as it concedes.
  ```

  **Placement matters: put it outside bd's managed block.** That block is
  delimited by `<!-- BEGIN BEADS INTEGRATION v:N profile:… hash:… -->` and
  `<!-- END BEADS INTEGRATION -->`, and bd regenerates everything between the
  markers — anything written inside is lost on the next `bd init` or upgrade.
  Append after the END marker. (Verified on mixmaster3: `bd setup claude`
  rewrote the block and bumped its `hash:` while leaving text after the END
  marker untouched.) If the note is already present, leave it alone; don't
  append a second copy.

### 5. Verify end to end

- `bd list` returns issues, and `bd vc status` shows the expected branch with a
  clean working set — meaning it prints branch and commit and *no*
  uncommitted-changes output (use `bd vc status`, not `bd vc log`/`bd history`
  — see the command-quirks note). **`bd list` shows only OPEN issues**, so on a
  mature project it can legitimately print one line against a database of
  hundreds. That is not truncation and not a broken read path — don't go
  looking for a fault. Use `bd stats` (`Total Issues:`) when you want the total,
  which is also the figure to compare against `bd doctor --server`'s count.
- `bd dolt remote list` shows the remote, its URL is HTTPS (no `ssh://`, no
  `git@`), and a `bd dolt push` succeeds.
- The git working tree is clean afterward — no stray `.beads/` modifications
  left behind.
- The Dolt data directory (the `Data:` path from step 1),
  `.beads-credential-key`, and any legacy `*.db` are gitignored and **not**
  tracked — the database and the machine credential must never be committed.
  `bd init` normally adds these at creation, but verify explicitly: in embedded
  mode `bd doctor --fix` does not run (and exits 0 anyway), and re-running
  `bd init` to top them up does not work either — see the gitignore step.
- The project's `CLAUDE.md` contains the memory division-of-labor note exactly
  once, after the `<!-- END BEADS INTEGRATION -->` marker rather than inside it.
- **`.beads/metadata.json` being tracked in git is fine — don't "fix" it.** bd's
  own config-source listing describes it as "local, gitignored", so it looks
  like drift, but on at least one of my projects it has been committed since
  `bd init` and that is harmless: the contents are machine-independent
  (database name, backend, storage mode, project UUID — no local paths, no
  secrets), it hasn't changed since init so it causes no commit churn, and a
  fresh clone probably wants it in order to `bd bootstrap`. Mention it in the
  report if you like, but don't untrack it without asking me first.

### 6. Report

Summarize concisely: version and mode found (state the mode neutrally — server
and embedded are both acceptable, so the mode itself is never an open
question; include the reminder that auto-push is off on every project, so
off-machine sync of issue data happens only on an explicit `bd sync`),
schema state (and whether you migrated), each config value before/after, the
doctor warning count before and after, and anything that needs my decision — a remote-backed database mid-migration, or a
suspected pre-Dolt project you declined to touch. Do not narrate every command;
give me the deltas and the open questions.
