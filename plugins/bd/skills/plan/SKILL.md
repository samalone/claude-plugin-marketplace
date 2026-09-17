---
name: plan
description: Plan the implementation of one bead and write the approved plan into that bead's design field for a different session to execute. Invoked by typing `/bd:plan <bead-id>`; it plans only and never implements.
model: fable
disable-model-invocation: true
argument-hint: <bead-id>
---

# Planning a bead for another session to implement

This skill runs a full plan-mode session against **one** bead and stores the
approved plan in that bead's `design` field. Beads live in a shared Dolt DB that
is not partitioned by branch or worktree, so the plan is visible in every other
worktree the moment it is written — no commit, no PR, no merge.

## The one rule

**Never implement the plan. Never write code, run a formatter, or touch a source
file.** This skill runs in a planning worktree whose entire job is producing
plans. Approving a plan normally means "start building" — here it means "write
the plan to the bead and stop." When the user approves, do exactly that, report
the bead ID, and end the turn. If they then want it built, that is a different
session in a different worktree.

The only writes this skill performs are `bd` writes and the plan file.

## Sequence

Order matters: plan mode is read-only, so every `bd` write must happen before
entering it or after exiting it.

**1. Read the bead, before plan mode.**

```bash
bd show <id> --json
```

Stop and ask the user how to proceed if any of these hold:

- The bead is closed.
- It already has a `design` field (the JSON omits the key entirely when unset, so
  test with `.get('design')`, not indexing). Do not silently overwrite a plan —
  ask whether to replace it or leave it.
- It is an epic. Epics are groupings; plan their children instead.
- The description is too thin to plan from. Say what is missing rather than
  inventing requirements.

**2. Claim it and record the base commit, before plan mode.**

```bash
bd update <id> --claim --assignee "$(git config user.name)"
git rev-parse --short HEAD
```

If the claim fails because another session holds it, stop and report that — do
not plan a bead someone else is working.

**3. Plan.** Call `EnterPlanMode`, then explore the codebase and design the
approach. Use `AskUserQuestion` freely for genuine forks in the approach; this
interactive clarification is most of what makes the stored plan better than the
bare description, and it is a confirmed preference — do not skip it to save a
round-trip. Recommend an option and say why rather than presenting a neutral
menu, but ask when the answer would change the plan. Write the plan to the plan file named in the plan-mode system
message, then call `ExitPlanMode`.

Write the plan for a reader who has none of this session's context: name real
file paths and symbols, say why the approach was chosen over the alternatives
considered, and note what was ruled out. A plan that only makes sense to someone
who watched it being written is a failed plan.

Immediately before calling `ExitPlanMode`, say in plain text what approving will
and will not do — that no code will be written, that the next step is writing the
plan to the bead and stopping, and that either approval choice is therefore safe.
The approval UI is harness-provided and worded for the normal plan-then-build
flow, so its options both read as "start coding" here. Left unexplained, that
wording makes the gate look riskier than it is.

**4. On approval — do not implement.** Approval may arrive through the gate *or*
as a plain instruction ("save it to the bead", "looks good, store it") — treat
both the same way. Prepend this header to the plan file, then write it to the
bead:

```
> **Implementation plan** — /bd:plan, <YYYY-MM-DD> · base commit `<short-sha>`
> Verify the cited paths and symbols still exist at HEAD before following this.
> If HEAD has moved substantially past that commit, re-verify the affected steps
> or re-plan rather than following it blindly.
```

```bash
bd update <id> --design-file <plan-file>
```

The header makes the plan self-describing, so the implementing session needs no
counterpart skill and no convention to remember.

**5. Release and report.** The planning session is not the implementer, so do not
leave the bead claimed:

```bash
bd update <id> --assignee ""
```

Then report the bead ID, a one-line summary of the approach, and any open
questions the plan deliberately left for the implementer. Stop there.

## If the plan is rejected

If the user rejects the plan at the approval gate, revise and re-present. Do not
write a rejected or partial plan into the bead — a half-plan in the `design`
field is worse than an empty one, because the next session will trust it.

## Filing discovered work

Planning surfaces adjacent problems. File them as their own beads
(`bd create ... --deps discovered-from:<id>`) with the right area label rather
than widening the plan to cover them. Keeping the plan scoped to its bead is what
makes it executable in one sitting.
