## Personal project

This is a personal project with a single maintainer. There is no need for PRs.
Make changes on a temporary branch without being asked. It is okay to include
multiple issues in a single branch if the user requests additional changes.

### Automatic code reviews

After finishing work on an issue, use your judgement about whether the changes
would benefit from a code review and/or a simplification pass. If you think they
would, commit your work and run either or both of `/code-review medium --fix`
and `/simplify` automatically. If you run both, run them in that order.

If a code review includes findings the review left unfixed as out of scope, ask
the user whether to fix them now or file new issues. For a personal project,
deferred issues are often a bigger problem than scope creep.

### Merging

Do not merge without user approval. Use a simple `git merge` for merging
temporary branches.

### After merge

After merge, delete the temporary branch and push `main` or `master` upstream.
These steps are implied and should be performed automatically when the user asks
for or approves the merging of a temporary branch.
