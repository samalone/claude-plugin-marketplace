#!/usr/bin/env bats
#
# config-audit: the read-only audit's detection logic.
#
# These tests are about what the audit SEES, not what it changes — the script
# writes nothing, so every case here is safe to assert against a live fixture.
# The cases that earn their keep are the ones where the obvious implementation
# is wrong: grep-based key detection, `[ -L ]` symlink detection, and yq's `//`
# collapsing false into absent.

load helpers/setup

setup() {
    require_tools yq
}

teardown() {
    bdt_teardown
}

# audit [args...] — run the audit in the fixture, no network probe.
audit() {
    run bash -c "cd '$PROJECT' && '$CONFIG_AUDIT' --no-network $*"
}

# finding <id> — the reported line for one check id (empty if not reported).
finding() { printf '%s\n' "$output" | grep -E "^\[[A-Z ]+\] +$1 " || true; }

# status_of <id> — just the status word for one check id.
status_of() {
    printf '%s\n' "$output" \
        | sed -n "s/^\[\([A-Z]*\) *\] *$1 .*/\1/p" | head -1
}

# --- key presence: the case the old grep recipe got wrong --------------------

@test "config-audit: sees a live flat key, not bd's commented-out example" {
    make_project
    # bd's stock config.yaml carries `#   git-push: false` as commented
    # documentation. The skill's old recipe, grep -nE '(^|[[:space:]])git-push:',
    # matches THAT line and misses a live `backup.git-push:` (whose leaf is
    # preceded by '.'), so it inspected comments and scored them as the setting.
    grep -qE '^#.*git-push:' "$PROJECT/.beads/config.yaml"   # the decoy is present

    append_config_line 'backup.git-push: false'
    audit
    [ "$(status_of 'config.backup.git-push')" = "OK" ]

    # And with only the decoy, the key must read as ABSENT rather than as set.
    grep -v '^backup\.git-push:' "$PROJECT/.beads/config.yaml" > "$PROJECT/.beads/c.tmp"
    mv -f "$PROJECT/.beads/c.tmp" "$PROJECT/.beads/config.yaml"
    audit
    [ "$(status_of 'config.backup.git-push')" = "FAIL" ]
    [[ "$(finding 'config.backup.git-push')" == *"not set"* ]]
}

@test "config-audit: distinguishes absent from false (yq // would not)" {
    make_project
    # `."export.auto" // "default"` returns "default" for a key that is present
    # and set to false, because // treats false as empty. The whole "an unset key
    # is an inherited answer, not a stated one" rule depends on telling these
    # apart, so presence must come from has().
    audit
    [ "$(status_of 'config.export.auto')" = "FAIL" ]
    [[ "$(finding 'config.export.auto')" == *"not set"* ]]

    append_config_line 'export.auto: false'
    audit
    [ "$(status_of 'config.export.auto')" = "OK" ]
    [[ "$(finding 'config.export.auto')" == *"false"* ]]
}

@test "config-audit: flags a wrong value distinctly from an absent one" {
    make_project
    append_config_line 'export.auto: true'
    audit
    [ "$(status_of 'config.export.auto')" = "FAIL" ]
    [[ "$(finding 'config.export.auto')" == *"want false"* ]]
    [[ "$(finding 'config.export.auto')" != *"not set"* ]]
}

# --- the flat/nested ambiguity ----------------------------------------------

@test "config-audit: detects a key present as BOTH flat and nested" {
    make_project
    # bd writes a setting either as a flat dotted key or as a child of a nested
    # block depending on what is already in the file, and can leave both at
    # conflicting values. `bd config get` returns only the flat one and looks
    # fine. To YAML these are different keys, so has() on each is exact.
    append_config_line 'dolt.auto-push: false'
    append_config_line 'dolt:'
    printf '    auto-push: true\n' >> "$PROJECT/.beads/config.yaml"

    audit
    [ "$(status_of 'config.dolt.auto-push')" = "FAIL" ]
    [[ "$(finding 'config.dolt.auto-push')" == *"AMBIGUOUS"* ]]
}

@test "config-audit: a nested-only key is read, not reported missing" {
    make_project
    # A project lands in the nested-only form by following the audit's own
    # SSH->HTTPS remote repair: `bd dolt remote remove` comments the flat line
    # out, so bd's next write has no flat line to reuse.
    append_config_line 'dolt:'
    printf '    auto-push: false\n' >> "$PROJECT/.beads/config.yaml"

    audit
    [ "$(status_of 'config.dolt.auto-push')" = "OK" ]
    [[ "$(finding 'config.dolt.auto-push')" == *"nested"* ]]
}

# --- AGENTS.md symlink detection --------------------------------------------

@test "config-audit: detects a symlinked AGENTS.md the way Windows requires" {
    make_project
    printf '# Project\n' > "$PROJECT/CLAUDE.md"
    rm -f "$PROJECT/AGENTS.md"          # bd init writes its own
    ln -s CLAUDE.md "$PROJECT/AGENTS.md"
    git -C "$PROJECT" add CLAUDE.md AGENTS.md
    [ "$(git -C "$PROJECT" ls-files -s AGENTS.md | awk '{print $1}')" = 120000 ]

    audit
    [[ "$(finding 'agents.kind')" == *"symlink"* ]]
    # Nothing to opt out of when there is only one file.
    [ "$(status_of 'agents.optout')" = "OK" ]
}

@test "config-audit: symlink check survives a checkout without core.symlinks" {
    make_project
    printf '# Project\n' > "$PROJECT/CLAUDE.md"
    rm -f "$PROJECT/AGENTS.md"          # bd init writes its own
    ln -s CLAUDE.md "$PROJECT/AGENTS.md"
    git -C "$PROJECT" add CLAUDE.md AGENTS.md

    # Reproduce what Windows produces without core.symlinks=true: the index still
    # records mode 120000, but the working tree holds a REGULAR FILE whose
    # contents are the target path. `[ -L ]` is false here; `git ls-files -s` is
    # not. Without this, the audit takes the "two independent files" branch and
    # calls for an opt-out comment whose own text is a lie.
    rm "$PROJECT/AGENTS.md"
    printf 'CLAUDE.md' > "$PROJECT/AGENTS.md"
    [ ! -L "$PROJECT/AGENTS.md" ]
    [ "$(git -C "$PROJECT" ls-files -s AGENTS.md | awk '{print $1}')" = 120000 ]

    audit
    [[ "$(finding 'agents.kind')" == *"symlink"* ]]
}

@test "config-audit: flags the false opt-out comment on a symlinked pair" {
    make_project
    # The mistake the skill records making twice before it added the check: the
    # comment says "this file is bd's generated primer, CLAUDE.md is hand-
    # written", which is false when they are one file.
    printf '# Project\n\n<!-- bd-doctor-divergence: ok -->\n' > "$PROJECT/CLAUDE.md"
    rm -f "$PROJECT/AGENTS.md"          # bd init writes its own
    ln -s CLAUDE.md "$PROJECT/AGENTS.md"
    git -C "$PROJECT" add CLAUDE.md AGENTS.md

    audit
    [ "$(status_of 'agents.optout')" = "FAIL" ]
    [[ "$(finding 'agents.optout')" == *"only one file"* ]]
}

@test "config-audit: wants the opt-out on a genuine pair of files" {
    make_project
    printf '# Project\n' > "$PROJECT/CLAUDE.md"
    printf '# Agents\n' > "$PROJECT/AGENTS.md"
    git -C "$PROJECT" add CLAUDE.md AGENTS.md

    audit
    [[ "$(finding 'agents.kind')" == *"independent"* ]]
    [ "$(status_of 'agents.optout')" = "FAIL" ]
}

# --- pre-marker residue ------------------------------------------------------

@test "config-audit: reports retracted guidance above the BEGIN marker" {
    make_project
    printf '# Project\n' > "$PROJECT/CLAUDE.md"
    # Regeneration rebuilds content[:begin] + fresh section + content[end:], so
    # everything above BEGIN survives verbatim and a refresh never reaches it.
    cat > "$PROJECT/AGENTS.md" <<'EOF'
# Agents

**MANDATORY WORKFLOW:**
   git pull --rebase

<!-- BEGIN BEADS INTEGRATION v:3 profile:full hash:abc -->
managed
<!-- END BEADS INTEGRATION -->
<!-- bd-doctor-divergence: ok -->
EOF
    git -C "$PROJECT" add CLAUDE.md AGENTS.md

    audit
    [ "$(status_of 'agents.residue')" = "WARN" ]
    [[ "$(finding 'agents.residue')" == *"rebase"* ]]
    [[ "$(finding 'agents.residue')" == *"3:"* ]]   # reported with line numbers
}

@test "config-audit: a bare BEGIN marker is flagged as the pre-versioned format" {
    make_project
    printf '# Project\n' > "$PROJECT/CLAUDE.md"
    cat > "$PROJECT/AGENTS.md" <<'EOF'
<!-- BEGIN BEADS INTEGRATION -->
managed
<!-- END BEADS INTEGRATION -->
<!-- bd-doctor-divergence: ok -->
EOF
    git -C "$PROJECT" add CLAUDE.md AGENTS.md

    audit
    [ "$(status_of 'agents.block')" = "FAIL" ]
    [[ "$(finding 'agents.block')" == *"pre-versioned"* ]]
}

# --- the memory note ---------------------------------------------------------

@test "config-audit: wants the memory note outside bd's managed block" {
    make_project
    cat > "$PROJECT/CLAUDE.md" <<'EOF'
# Project
<!-- BEGIN BEADS INTEGRATION v:3 profile:full hash:abc -->
## Memory: beads vs. Claude Code auto-memory
inside the block, so it is regenerated away
<!-- END BEADS INTEGRATION -->
EOF
    git -C "$PROJECT" add CLAUDE.md
    audit
    [ "$(status_of 'claudemd.memory-note')" = "FAIL" ]
    [[ "$(finding 'claudemd.memory-note')" == *"INSIDE"* ]]

    cat > "$PROJECT/CLAUDE.md" <<'EOF'
# Project
<!-- BEGIN BEADS INTEGRATION v:3 profile:full hash:abc -->
managed
<!-- END BEADS INTEGRATION -->

## Memory: beads vs. Claude Code auto-memory
outside, where it survives
EOF
    audit
    [ "$(status_of 'claudemd.memory-note')" = "OK" ]
}

# --- line endings ------------------------------------------------------------

@test "config-audit: reports CRLF in config.yaml" {
    make_project
    audit
    [ "$(status_of 'config.line-endings')" = "OK" ]

    # yq parses a CRLF file correctly and does not leave \r inside values, but it
    # rewrites the lines it touches as LF while passing comments through with
    # their CRs — leaving a mixed-ending file. Normalize before editing.
    sed 's/$/\r/' "$PROJECT/.beads/config.yaml" > "$PROJECT/.beads/c.tmp"
    mv -f "$PROJECT/.beads/c.tmp" "$PROJECT/.beads/config.yaml"
    audit
    [ "$(status_of 'config.line-endings')" = "FAIL" ]
}

# --- guards ------------------------------------------------------------------

@test "config-audit: refuses a yq that is not mikefarah/yq" {
    make_project
    # `apt install yq` gives kislyuk/yq, a Python jq wrapper with an entirely
    # different CLI. It must fail loudly rather than silently misparse.
    local fake; fake="$(mktemp -d "$BD_TESTS_BASE/bdt-fakebin.XXXXXX")"
    printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$fake/yq"
    chmod +x "$fake/yq"

    run bash -c "cd '$PROJECT' && PATH='$fake:$PATH' '$CONFIG_AUDIT' --no-network"
    safe_rm "$fake"
    [ "$status" -eq 3 ]
    [[ "$output" == *"mikefarah"* ]]
}

@test "config-audit: refuses to run outside a beads project" {
    local bare; bare="$(mktemp -d "$BD_TESTS_BASE/bdt-nobeads.XXXXXX")"
    git init -q "$bare"
    run bash -c "cd '$bare' && '$CONFIG_AUDIT' --no-network"
    safe_rm "$bare"
    [ "$status" -eq 3 ]
}

@test "config-audit: rejects an unknown argument rather than ignoring it" {
    make_project
    run bash -c "cd '$PROJECT' && '$CONFIG_AUDIT' --appply"
    [ "$status" -eq 3 ]
    [[ "$output" == *"unknown argument"* ]]
}

# --- contract ----------------------------------------------------------------

@test "config-audit: changes nothing (read-only contract)" {
    make_project --ready
    local before_cfg before_meta before_git
    before_cfg="$(cksum < "$PROJECT/.beads/config.yaml")"
    before_meta="$(cksum < "$PROJECT/.beads/metadata.json")"
    before_git="$(git -C "$PROJECT" status --short)"

    audit
    [ "$status" -le 2 ]                       # a report, not a crash
    [ "$(cksum < "$PROJECT/.beads/config.yaml")" = "$before_cfg" ]
    [ "$(cksum < "$PROJECT/.beads/metadata.json")" = "$before_meta" ]
    [ "$(git -C "$PROJECT" status --short)" = "$before_git" ]
    [[ "$output" == *"Read-only: nothing was changed."* ]]
}

@test "config-audit: --json emits parseable findings with a summary" {
    make_project
    run bash -c "cd '$PROJECT' && '$CONFIG_AUDIT' --no-network --json"
    [ "$status" -le 2 ]
    printf '%s' "$output" | jq -e '.findings | length > 0' >/dev/null
    printf '%s' "$output" | jq -e '.summary | type == "object"' >/dev/null
    printf '%s' "$output" | jq -e '.project | length > 0' >/dev/null
    # every finding carries the three fields the report renders
    printf '%s' "$output" | jq -e 'all(.findings[]; has("status") and has("id") and has("message"))' >/dev/null
}

@test "config-audit: exit code reflects the worst finding" {
    make_project
    # A bare fixture has drift (export.auto and backup.git-push unset), no STOP.
    audit
    [ "$status" -eq 1 ]
    [[ "$output" != *"STOP conditions present"* ]]
}
