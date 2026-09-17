#!/usr/bin/env bash
#
# config-audit.sh — READ-ONLY audit of a Beads (bd) project against the
#                   single-user Dolt preferences described by the
#                   /bd:config-audit skill.
#
#   config-audit.sh                 human-readable report
#   config-audit.sh --json          same findings as JSON
#   config-audit.sh --no-network    skip the `git ls-remote` probe
#
# THIS SCRIPT NEVER WRITES ANYTHING. It does not run `bd config set`, does not
# touch .beads/, does not stage or commit, and does not start or stop a server.
# Every finding it reports as FAIL is drift that a future --apply pass (or you)
# would repair; the audit itself only looks. That is deliberate: it is meant to
# be safe to run across every project in one sweep before anything acts.
#
# Findings carry a status:
#   OK    matches the preferred state
#   FAIL  drift, mechanically repairable
#   WARN  needs attention, but the repair is a judgement call
#   INFO  worth knowing, no action
#   STOP  do not let an --apply pass near this project until resolved
#
# Exit: 0 clean, 1 drift found (FAIL), 2 a STOP condition, 3 script error.
#
# ---------------------------------------------------------------------------
# Why yq, and which yq
# ---------------------------------------------------------------------------
# .beads/config.yaml is ~95% commented-out documentation (bd's stock template is
# 2.7KB with four live keys at the bottom), so it looks like a file a YAML
# parser would destroy. Measured on mikefarah/yq v4.52.5 against a real config:
# a round-trip edit produces a ONE LINE diff with every comment byte-identical.
#
# The reason to use it rather than grep is that the skill's own recipe
#
#     grep -nE '(^|[[:space:]])<key-leaf>:' .beads/config.yaml
#
# does not work. On a pristine bd config, `git-push` matches only line 44,
# `#   git-push: false    # Disable git push (backup locally only)` — a comment
# — and MISSES the live `backup.git-push:` at line 70, because there the leaf is
# preceded by `.`, which is neither `^` nor whitespace. The check has been
# inspecting comments and reaching the right verdict by way of two cancelling
# errors. yq reads the flat and nested spellings as what they actually are —
# a literal dotted key, and a map — so presence is exact rather than guessed.
#
# There are two unrelated tools named `yq`. mikefarah/yq is the Go single binary
# (brew, winget MikeFarah.yq, scoop, choco); kislyuk/yq is a Python jq wrapper
# with an entirely different CLI that `apt install yq` installs. We gate on the
# version banner so the wrong one fails loudly instead of misbehaving.
#
# NOT used for .beads/metadata.json: yq is faithful there (-I2 preserves key
# order and indentation) but appends a trailing newline where bd writes none,
# and change-mode.sh already carries jq plus the printf idiom that preserves
# bd's format. jq stays the JSON tool.
#
# ---------------------------------------------------------------------------
# Portability (macOS + Windows/Git Bash)
# ---------------------------------------------------------------------------
# * bash 3.2 is the floor (macOS ships it): no associative arrays, no mapfile,
#   no ${var^^}. Findings accumulate in a temp file rather than an array.
# * POSIX awk only. macOS awk is BSD one-true-awk, so no gensub, no \s, no
#   length(array). No grep -P, no sed -i, no stat, no readlink -f.
# * Symlinked AGENTS.md is detected via `git ls-files -s` mode 120000, NOT
#   `[ -L ]`. Without core.symlinks=true (Developer Mode or admin) Windows
#   checks a symlink out as a regular file containing the target path, so -L
#   returns false and the audit would take the "two independent files" branch
#   and want an opt-out comment whose text is false. Verified against entwine
#   and legible, which report mode 120000 and share a blob hash.
# * Paths reported by bd are native, so they go through cygpath -u when it
#   exists before any test or comparison.
# * Never pipe a bd/git command into `grep -q`/`head`/`awk ... exit`: the early
#   close SIGPIPEs the producer and, under pipefail, inverts the result. Every
#   probe below captures first and matches against a here-string.
#
set -euo pipefail

PROG=config-audit

# ---------------------------------------------------------------------------
# immediate output (diagnostics; the report itself is built separately)
# ---------------------------------------------------------------------------
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 3; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
OUT=text
NETWORK=1
while [ $# -gt 0 ]; do
    case "$1" in
        --json)       OUT=json ;;
        --no-network) NETWORK=0 ;;
        -h|--help)
            sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# tooling
# ---------------------------------------------------------------------------
need bd; need git; need jq; need yq; need awk; need sed

_yqv=$(yq --version 2>&1) || _yqv=""
case "$_yqv" in
    *mikefarah/yq*) ;;
    *) die "found a 'yq' that is not mikefarah/yq v4 (got: ${_yqv:-nothing}).
       kislyuk/yq (the Python jq wrapper, what 'apt install yq' gives you) has a
       different CLI and would misbehave rather than fail. Install the Go build:
       brew install yq | winget install MikeFarah.yq" ;;
esac
case "$_yqv" in
    *\ v4.*) ;;
    *) die "yq v4 required; found: $_yqv" ;;
esac

CYGPATH=$(command -v cygpath 2>/dev/null || true)

# Normalize a native path from bd into something this shell can test.
posixpath() {
    if [ -n "$CYGPATH" ]; then
        "$CYGPATH" -u "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# Strip a trailing CR, in case a tool on Windows emitted CRLF.
strip_cr() { printf '%s' "${1%$'\r'}"; }

# ---------------------------------------------------------------------------
# findings
# ---------------------------------------------------------------------------
WORK=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
FINDINGS="$WORK/findings.tsv"
: > "$FINDINGS"

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FINDINGS"; }
f_ok()   { record OK   "$1" "$2"; }
f_fail() { record FAIL "$1" "$2"; }
f_warn() { record WARN "$1" "$2"; }
f_info() { record INFO "$1" "$2"; }
f_stop() { record STOP "$1" "$2"; }

# ===========================================================================
# 1. Locate the project
# ===========================================================================
_ctx=$(bd context 2>/dev/null) || _ctx=""
[ -n "$_ctx" ] || die "\`bd context\` produced nothing — run this inside a beads project"

# Keep the whole path after the label ($NF would truncate a path with spaces).
BEADS_DIR=$(sed -n 's/^[[:space:]]*beads dir:[[:space:]]*//p' <<<"$_ctx")
BEADS_DIR=${BEADS_DIR%%$'\n'*}
BEADS_DIR=$(strip_cr "$BEADS_DIR")
BEADS_DIR=$(posixpath "$BEADS_DIR")
[ -n "$BEADS_DIR" ] && [ -d "$BEADS_DIR" ] || die "could not locate a .beads directory"

REPO_ROOT=$(git -C "$BEADS_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || die "the beads dir is not inside a git repository"

CFG="$BEADS_DIR/config.yaml"
META="$BEADS_DIR/metadata.json"

# Repo-relative path, for git commands and for the report.
relp() { printf '%s' "${1#"$REPO_ROOT"/}"; }

PROJECT=$(basename "$REPO_ROOT")

# --- bd version, and the gate -------------------------------------------
_vraw=$(bd version 2>/dev/null) || _vraw=""
BDVER=$(awk '{print $3; exit}' <<<"$_vraw")
BDVER=$(strip_cr "$BDVER")
case "$BDVER" in
    1.1.*|1.2.*|1.3.*) f_info "bd.version" "${BDVER}" ;;
    *) f_stop "bd.version" "${BDVER:-unknown} is outside the verified range (1.1.x-1.3.x). Every check below parses bd's output, so treat these findings as unverified and re-check the commands before letting anything act." ;;
esac

# --- backend / mode, from metadata.json (the authority change-mode.sh uses)
if [ ! -f "$META" ]; then
    f_stop "project.layout" "no .beads/metadata.json. If the project looks JSONL-centric this is likely a pre-Dolt (0.x) layout, which needs a dedicated migration rather than this audit."
    BACKEND=""; MODE=""; DB=""
else
    BACKEND=$(jq -r '.backend // empty' "$META" 2>/dev/null) || BACKEND=""
    MODE=$(jq -r '.dolt_mode // empty' "$META" 2>/dev/null) || MODE=""
    DB=$(jq -r '.dolt_database // empty' "$META" 2>/dev/null) || DB=""
    case "$BACKEND" in
        dolt) ;;
        "")   f_stop "project.backend" "metadata.json has no backend field" ;;
        *)    f_stop "project.backend" "backend is '$BACKEND', expected 'dolt' — not a project this audit understands" ;;
    esac
    case "$MODE" in
        embedded|server) f_info "project.mode" "$MODE (both modes are acceptable; never drift to fix)" ;;
        *) f_warn "project.mode" "unexpected dolt_mode: '${MODE:-empty}'" ;;
    esac
fi

# --- data directory: read it, never assume the name ----------------------
_dss=$(bd dolt status 2>&1) || _dss=""
DATA_DIR=$(sed -n 's/^[[:space:]]*Data:[[:space:]]*//p' <<<"$_dss")
DATA_DIR=${DATA_DIR%%$'\n'*}
DATA_DIR=$(strip_cr "$DATA_DIR")
[ -n "$DATA_DIR" ] && DATA_DIR=$(posixpath "$DATA_DIR")
if [ -z "$DATA_DIR" ] || [ ! -d "$DATA_DIR" ]; then
    # The name has been embeddeddolt/ on older databases and proxieddb/ on
    # newer ones, and the docs do not always match a given install — probe.
    for _cand in dolt embeddeddolt proxieddb; do
        if [ -d "$BEADS_DIR/$_cand" ]; then DATA_DIR="$BEADS_DIR/$_cand"; break; fi
    done
fi
if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
    f_info "project.data-dir" "$(relp "$DATA_DIR")"
else
    f_stop "project.data-dir" "no Dolt data directory found under $BEADS_DIR — possible pre-Dolt project; stopping rather than guessing"
fi

if [ "$MODE" = server ]; then
    _srv=$(sed -n 's/^Dolt server:[[:space:]]*//p' <<<"$_dss")
    _srv=$(strip_cr "${_srv%%$'\n'*}")
    case "$_srv" in
        running) f_info "server.state" "running" ;;
        "")      f_warn "server.state" "could not read server state from \`bd dolt status\`" ;;
        *)       f_warn "server.state" "$_srv — doctor and \`bd sql\` need it up (\`bd dolt start\`)" ;;
    esac
fi

# ===========================================================================
# 2. Schema / version state
# ===========================================================================
# Capture then match. Piping bd into `grep -q` inverts under pipefail (grep
# closes early -> bd SIGPIPE -> non-zero pipeline), which is the same
# deterministic bug change-mode.sh documents at its own schema gate.
_mi=$(bd migrate --inspect 2>&1) || _mi=""
REGMIG=$(sed -n 's/^[[:space:]]*Registered Migrations:[[:space:]]*//p' <<<"$_mi")
REGMIG=$(strip_cr "${REGMIG%%$'\n'*}")
SCHEMAV=$(sed -n 's/^[[:space:]]*Schema Version:[[:space:]]*//p' <<<"$_mi")
SCHEMAV=$(strip_cr "${SCHEMAV%%$'\n'*}")

case "$_mi" in
    *"mismatch"*) MISMATCH=1 ;;
    *)            MISMATCH=0 ;;
esac

if [ -z "$REGMIG" ]; then
    f_warn "schema.state" "could not read 'Registered Migrations:' from \`bd migrate --inspect\`"
elif [ "$REGMIG" = 0 ] && [ "$MISMATCH" = 0 ]; then
    f_ok "schema.state" "in sync (schema ${SCHEMAV:-?}, 0 registered migrations)"
elif [ "$REGMIG" = 0 ]; then
    f_fail "schema.state" "version stamp only (schema ${SCHEMAV:-?}, 0 registered migrations, version mismatch reported). No DDL and no data rewrite — plain \`bd migrate\` updates the stamp; safe in place even on a remote-backed database."
else
    f_stop "schema.state" "$REGMIG registered migration(s) pending (schema ${SCHEMAV:-?}) — real schema work. Needs the single-designated-migrator path, and any other clone must adopt with \`bd bootstrap\` rather than migrating itself."
fi

# ===========================================================================
# 3. Health checks (mode-aware)
# ===========================================================================
# In embedded mode `bd doctor` prints "not yet supported in embedded mode" and
# EXITS 0, so a script testing $? concludes the run succeeded when nothing
# happened. Match on the text, not the status.
_doc=$(bd doctor 2>&1) || true
case "$_doc" in
    *"not yet supported in embedded mode"*|*"not supported in embedded mode"*)
        f_info "doctor.state" "unsupported in embedded mode (exits 0 regardless — health verified directly below instead)"
        DOCTOR_OK=0 ;;
    *)
        DOCTOR_OK=1
        # Parse the counts off the banner by digits rather than by glyph, so a
        # Windows console that mangles the ✓/⚠/✖ runes does not break it.
        _counts=$(awk '/passed/ && /warnings/ && /errors/ {
                           p=w=e="?"
                           for (i=1; i<=NF; i++) {
                               if ($(i+1) ~ /^passed/)   p=$i
                               if ($(i+1) ~ /^warning/)  w=$i
                               if ($(i+1) ~ /^error/)    e=$i
                           }
                           printf "%s %s %s", p, w, e; exit
                       }' <<<"$_doc")
        if [ -n "$_counts" ]; then
            IFS=' ' read -r _dpass _dwarn _derr <<<"$_counts"
            f_info "doctor.counts" "$_dpass passed, $_dwarn warnings, $_derr errors"
            [ "$_dwarn" = 0 ] || f_warn "doctor.warnings" "$_dwarn warning(s) — see \`bd doctor --verbose\`; check them against the two known-policy suppressions below before acting on any"
        else
            f_warn "doctor.counts" "could not parse the doctor summary line"
        fi
        case "$_doc" in
            *"suppressed via doctor.suppress"*)
                f_info "doctor.suppressed" "$(sed -n 's/.*(\([0-9]*\) warnings suppressed.*/\1/p' <<<"$_doc" | head -1) warning(s) suppressed by config" ;;
        esac ;;
esac

# ===========================================================================
# 4. Config
# ===========================================================================
[ -f "$CFG" ] || f_stop "config.file" "no $CFG"

# --- line endings --------------------------------------------------------
# yq parses a CRLF file correctly and does NOT leave \r inside scalar values —
# the failure a naive sed/awk pass would hit — but it rewrites the data lines it
# touches as LF while passing comment lines through with their CRs, leaving a
# mixed-ending file. Normalizing once, up front, is an --apply action; here we
# only report it.
if [ -f "$CFG" ] && LC_ALL=C grep -q $'\r' "$CFG" 2>/dev/null; then
    f_fail "config.line-endings" "config.yaml contains CR bytes. Normalize to LF before editing, or a yq write leaves the file with mixed endings (data lines LF, comments CRLF)."
else
    [ -f "$CFG" ] && f_ok "config.line-endings" "LF"
fi

# --- YAML-resident keys --------------------------------------------------
# bd writes the same setting either as a flat dotted key (`dolt.auto-push:`) or
# as a child of a nested block, and can end up with BOTH at conflicting values.
# To YAML these are genuinely different keys — a literal dotted scalar key, and
# a map — so has() on each is an exact test. Flat wins when both are present,
# matching bd's own precedence (verified on 1.2.2).
#
# Note: never use yq's `//` to supply a default here. `."export.auto" // "X"`
# returns "X" for a key that is present and set to `false`, because `//` treats
# false as empty — collapsing exactly the absent-vs-false distinction the skill
# depends on ("an unset key is an inherited answer, not a stated one").
yaml_state() {
    local key=$1 ns leaf hf hn pres val
    ns=${key%%.*}; leaf=${key#*.}
    hf=$(yq "has(\"$key\")" "$CFG" 2>/dev/null) || hf=false
    hn=$(yq ".\"$ns\" | has(\"$leaf\")" "$CFG" 2>/dev/null) || hn=false
    if   [ "$hf" = true ] && [ "$hn" = true ]; then pres=both
    elif [ "$hf" = true ];                     then pres=flat
    elif [ "$hn" = true ];                     then pres=nested
    else                                            pres=absent
    fi
    case "$pres" in
        flat|both) val=$(yq ".\"$key\""          "$CFG" 2>/dev/null) || val="" ;;
        nested)    val=$(yq ".\"$ns\".\"$leaf\"" "$CFG" 2>/dev/null) || val="" ;;
        *)         val="" ;;
    esac
    printf '%s\t%s' "$pres" "$val"
}

check_yaml_key() {   # <dotted.key> <wanted-value> <why-explicit>
    local key=$1 want=$2 why=$3 st pres val
    [ -f "$CFG" ] || return 0
    st=$(yaml_state "$key"); pres=${st%%$'\t'*}; val=${st#*$'\t'}
    case "$pres" in
        both)
            f_fail "config.$key" "AMBIGUOUS — present as both a flat dotted key and a nested child (flat='$val' wins, nested differs or duplicates). Repair to a single representation by hand; \`bd config unset\` removes one layer and can uncover a stale shadow value." ;;
        absent)
            f_fail "config.$key" "not set${why:+ — $why}; want an explicit $want" ;;
        *)
            if [ "$val" = "$want" ]; then
                f_ok "config.$key" "$want ($pres)"
            else
                f_fail "config.$key" "'$val' ($pres); want $want"
            fi ;;
    esac
}

check_yaml_key export.auto    false "a past release flipped this on by default"
check_yaml_key dolt.auto-push false "the default has changed before, so an unset key is an inherited answer rather than a stated one"
check_yaml_key backup.git-push false "this one auto-re-enables whenever a git remote exists"

# --- database-resident keys ---------------------------------------------
# `bd config` stores settings "per-project in the beads database"; only export.*,
# import.* and lint.* are annotated as living in the YAML. So doctor.suppress.*
# will NOT appear in config.yaml, and its absence there is not a failed write.
# `bd config get` prints "<key> (not set)" on stdout and exits 0, so presence
# must be read from the text, never from $?.
bdcfg() {
    local out
    out=$(bd config get "$1" 2>&1) || out=""
    out=$(strip_cr "${out%%$'\n'*}")
    case "$out" in
        *"(not set)"*) printf '' ;;
        *)             printf '%s' "$out" ;;
    esac
}

for _sup in doctor.suppress.dolt-remote-vs-git-origin doctor.suppress.cursor-integration; do
    _v=$(bdcfg "$_sup")
    if [ "$_v" = true ]; then
        f_ok "config.$_sup" "true (db-resident)"
    else
        f_fail "config.$_sup" "${_v:-not set} — this warning describes a deliberate choice, not drift; suppress it rather than re-triaging it on every project"
    fi
done

_ac=$(bdcfg dolt.auto-commit)
case "$_ac" in
    on|true) f_ok   "config.dolt.auto-commit" "$_ac (bd's default — leave it)" ;;
    "")      f_info "config.dolt.auto-commit" "not set (inheriting bd's default, which is on)" ;;
    *)       f_warn "config.dolt.auto-commit" "'$_ac' — forcing this off lets writes pile up uncommitted in the Dolt working set, the state that blocks migrations and can brick bd" ;;
esac

# ===========================================================================
# 5. Remote and durability
# ===========================================================================
# `bd dolt show` prints "Remotes: (none)" even when a remote exists (reproduced
# on 1.3.0 against bd-mode, which has one), and the config key is sync.remote,
# so `bd config get sync.git-remote` reporting "not set" is the wrong key rather
# than a missing remote. `bd dolt remote list` is the authority.
_rl=$(bd dolt remote list 2>&1) || _rl=""
REMOTE_URL=""
case "$_rl" in
    *"No remotes"*|"") ;;
    *) REMOTE_URL=$(awk 'NF >= 2 { print $2; exit }' <<<"$_rl")
       REMOTE_URL=$(strip_cr "$REMOTE_URL") ;;
esac

if [ -z "$REMOTE_URL" ]; then
    f_fail "remote.present" "no Dolt remote — this is a durability gap, and nothing that deletes issues.jsonl may run until it is closed"
else
    f_ok "remote.present" "$REMOTE_URL"
    # Only the transport matters. Both `https://` and `git+https://` are in use
    # across these projects and both work; bd writes the git+ prefix itself on
    # current versions, so normalizing between them is not drift.
    case "$REMOTE_URL" in
        https://*|git+https://*)
            f_ok "remote.transport" "HTTPS" ;;
        ssh://*|git+ssh://*|*@*:*)
            f_fail "remote.transport" "SSH ($REMOTE_URL). Background auto-push over SSH depends on 1Password holding the keys, so it succeeds or fails by lock state and the failures are silent. Replace with the https:// equivalent — there is no set-url, so it is remote remove + remote add + push." ;;
        *)
            f_warn "remote.transport" "unrecognized transport: $REMOTE_URL" ;;
    esac
fi

if [ "$NETWORK" = 1 ]; then
    # Capture then test for non-empty; never `| grep -q .`, which closes the
    # pipe on the first line and makes git die with SIGPIPE, misreading a
    # present ref as missing.
    _ref=$(git -C "$REPO_ROOT" ls-remote origin refs/dolt/data 2>/dev/null) || _ref=""
    if [ -n "$_ref" ]; then
        f_ok "remote.ref" "refs/dolt/data exists on origin"
    else
        f_fail "remote.ref" "origin has no refs/dolt/data — the remote is registered but the first \`bd dolt push\` has not landed, so there is no off-machine copy yet"
    fi
else
    f_info "remote.ref" "skipped (--no-network)"
fi

# ===========================================================================
# 6. Files and gitignore
# ===========================================================================
is_tracked() { git -C "$REPO_ROOT" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }
is_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

# issues.jsonl — a regenerable snapshot; remove it entirely.
ISSUES="$BEADS_DIR/issues.jsonl"
_iss_rel=$(relp "$ISSUES")
if is_tracked "$_iss_rel"; then
    f_fail "files.issues-jsonl" "tracked in git. Stopping the export is not enough — a committed copy just freezes a stale, misleading snapshot. \`git rm\` it and gitignore it, but only once remote.ref above is OK."
elif [ -f "$ISSUES" ]; then
    f_fail "files.issues-jsonl" "present but untracked — delete it and gitignore it (regenerable via \`bd export\`)"
elif is_ignored "$_iss_rel"; then
    f_ok "files.issues-jsonl" "absent and gitignored"
else
    f_fail "files.issues-jsonl" "absent but not gitignored — nothing stops it being re-added"
fi

# interactions.jsonl — an append-only audit log that survives Dolt GC/flatten.
# Keep the file, keep the logging; just take it out of git. NOT the same kind of
# thing as issues.jsonl, and never delete it.
INTER="$BEADS_DIR/interactions.jsonl"
_int_rel=$(relp "$INTER")
if is_tracked "$_int_rel"; then
    f_fail "files.interactions-jsonl" "tracked in git — untrack with \`git rm --cached\` (KEEP the working file) and gitignore it, so it stops causing surprise-modification commits"
elif is_ignored "$_int_rel"; then
    f_ok "files.interactions-jsonl" "untracked and gitignored$([ -f "$INTER" ] && printf ' (file present, as it should be)')"
else
    f_fail "files.interactions-jsonl" "not gitignored"
fi

# dolt-server-config.yaml — bd generates it in server mode and does NOT ignore
# it. Its requiredPatterns list covers five siblings (dolt-server.pid, .log,
# .lock, .port, .activity) and omits this one, and no existing glob catches it:
# the name is hyphenated, so `dolt-server.*` misses it, and so do `*.lock` and
# `daemon.*`. Without the pattern a `git add .` commits machine-local server
# config into a shared repo.
DSC="$BEADS_DIR/dolt-server-config.yaml"
_dsc_rel=$(relp "$DSC")
if is_ignored "$_dsc_rel"; then
    f_ok "gitignore.dolt-server-config" "ignored"
elif [ "$MODE" = server ] || [ -f "$DSC" ]; then
    f_fail "gitignore.dolt-server-config" "not ignored — append 'dolt-server-config.yaml' to .beads/.gitignore (bd omits it from its own pattern list)"
else
    f_info "gitignore.dolt-server-config" "not ignored, but embedded mode and no such file"
fi

# The database and the machine credential must never be committed.
for _p in "$DATA_DIR" "$REPO_ROOT/.beads-credential-key" "$BEADS_DIR/.beads-credential-key"; do
    [ -n "$_p" ] || continue
    _rel=$(relp "$_p")
    _label="gitignore.$(basename "$_p")"
    if is_tracked "$_rel"; then
        f_stop "$_label" "TRACKED IN GIT — the Dolt database or the machine credential must never be committed"
    elif [ -e "$_p" ] && ! is_ignored "$_rel"; then
        f_fail "$_label" "present and not gitignored"
    elif [ -e "$_p" ]; then
        f_ok "$_label" "ignored, not tracked"
    fi
done

# Untracked leftovers under .beads/ that should have been caught by a pattern.
_st=$(git -C "$REPO_ROOT" status --short -- "$(relp "$BEADS_DIR")" 2>/dev/null) || _st=""
_untracked=$(awk '/^\?\?/ { sub(/^\?\? */, ""); print }' <<<"$_st")
if [ -n "$_untracked" ]; then
    f_fail "gitignore.untracked" "untracked files under .beads/ that no pattern covers: $(tr '\n' ' ' <<<"$_untracked")"
else
    f_ok "gitignore.untracked" "nothing untracked under .beads/"
fi

# metadata.json being tracked looks like drift — bd's own config-source listing
# calls it "local, gitignored" — but it is harmless and probably wanted: the
# contents are machine-independent (database name, backend, mode, project UUID;
# no local paths, no secrets), it does not change after init so it causes no
# churn, and a fresh clone wants it in order to `bd bootstrap`.
if is_tracked "$(relp "$META")"; then
    f_info "files.metadata-json" "tracked in git — fine, do not 'fix' this without asking"
fi

# ===========================================================================
# 7. Agent docs
# ===========================================================================
AGENTS="$REPO_ROOT/AGENTS.md"
CLAUDEMD="$REPO_ROOT/CLAUDE.md"
OPTOUT='<!-- bd-doctor-divergence: ok -->'

# The symlink test that survives a Windows checkout. `[ -L ]` is NOT usable:
# without core.symlinks=true git materializes the link as a regular file whose
# contents are the target path, so -L is false and the audit would take the
# "two independent files" branch and call for an opt-out comment whose own text
# ("this file is bd's generated primer, CLAUDE.md is hand-written") is a lie
# when they are one file.
_agls=$(git -C "$REPO_ROOT" ls-files -s -- AGENTS.md 2>/dev/null) || _agls=""
AG_MODE=$(awk '{print $1; exit}' <<<"$_agls")

if [ "$AG_MODE" = 120000 ]; then
    f_info "agents.kind" "AGENTS.md is a symlink to CLAUDE.md (git mode 120000) — the divergence is resolved, not suppressed"
    if [ -f "$CLAUDEMD" ] && grep -qF "$OPTOUT" "$CLAUDEMD" 2>/dev/null; then
        f_fail "agents.optout" "the divergence opt-out comment is present, but there is only one file — its text is false here and a later reader will act on it. Remove it."
    else
        f_ok "agents.optout" "absent, correctly (nothing to opt out of)"
    fi
    f_info "agents.writes" "every write 'to AGENTS.md' lands in CLAUDE.md; stage CLAUDE.md, and expect no AGENTS.md entry in git status"
    AGENTS_TARGET="$CLAUDEMD"
elif [ ! -e "$AGENTS" ]; then
    f_info "agents.kind" "no AGENTS.md — nothing to refresh, and do not conjure one up just to hold a bd block"
    AGENTS_TARGET=""
else
    f_info "agents.kind" "AGENTS.md is an independent file"
    AGENTS_TARGET="$AGENTS"
    if grep -qF "$OPTOUT" "$AGENTS" 2>/dev/null; then
        f_ok "agents.optout" "opt-out comment present"
    else
        f_fail "agents.optout" "no opt-out comment. bd's first three remedies for Agent Doc Divergence are destructive here — they would overwrite the hand-written CLAUDE.md. Take option (d): append '$OPTOUT' after the END marker."
    fi
fi

if [ -n "$AGENTS_TARGET" ] && [ -f "$AGENTS_TARGET" ]; then
    _beg=$(awk '/<!-- BEGIN BEADS INTEGRATION/ { print NR; exit }' "$AGENTS_TARGET")
    if [ -z "$_beg" ]; then
        f_info "agents.block" "no BEADS INTEGRATION marker — hand-written for a different reader; do not inject a managed block"
    else
        _begline=$(sed -n "${_beg}p" "$AGENTS_TARGET")
        case "$_begline" in
            *"v:"*) f_ok   "agents.block" "versioned marker at line $_beg" ;;
            *)      f_fail "agents.block" "bare '<!-- BEGIN BEADS INTEGRATION -->' at line $_beg — the pre-versioned format, so the block has been frozen since an older bd and may carry guidance bd has since retracted. Refresh with \`bd setup opencode\` (NOT \`codex\`, which writes a second marker pair, and NOT \`claude\`, which targets CLAUDE.md)." ;;
        esac
        # Regeneration rebuilds content[:begin] + fresh section + content[end:],
        # so everything ABOVE the BEGIN marker survives verbatim and is never
        # updated. On life-balance that residue was a duplicate of the whole
        # "Landing the Plane / MANDATORY WORKFLOW / git pull --rebase" section —
        # so a refresh fixed the copy inside the block and silently left the
        # copy outside it, which contradicts the plain-merge rule.
        if [ "$_beg" -gt 1 ]; then
            _residue=$(awk -v lim="$_beg" '
                NR >= lim { exit }
                /rebase|MANDATORY|Landing the Plane/ { printf "%d:%s ", NR, $0 }
            ' "$AGENTS_TARGET")
            if [ -n "$_residue" ]; then
                f_warn "agents.residue" "retracted or duplicated guidance ABOVE the BEGIN marker, where a refresh will never reach it: ${_residue}— deleting this is a content decision about a tracked, human-readable file. Propose it; do not do it unasked."
            else
                f_ok "agents.residue" "nothing retracted above the BEGIN marker"
            fi
        fi
    fi
fi

# --- the memory division-of-labor note ----------------------------------
# bd prime's Core Rules say "Do NOT use MEMORY.md files"; that line is a
# hardcoded literal in cmd/bd/prime.go, gated on no config, so it cannot be
# switched off and returns with every upgrade. The global CLAUDE.md overrides it
# on this machine; the project copy is so the correction travels with the repo.
MEMNOTE='## Memory: beads vs. Claude Code auto-memory'
if [ ! -f "$CLAUDEMD" ]; then
    f_warn "claudemd.memory-note" "no CLAUDE.md at the repo root to carry the memory division-of-labor note"
else
    _n=$(grep -cF "$MEMNOTE" "$CLAUDEMD" 2>/dev/null || true)
    if [ "${_n:-0}" -eq 0 ]; then
        f_fail "claudemd.memory-note" "absent — append it AFTER the '<!-- END BEADS INTEGRATION -->' marker (anything between the markers is regenerated away)"
    elif [ "${_n:-0}" -gt 1 ]; then
        f_fail "claudemd.memory-note" "present $_n times — should appear exactly once"
    else
        _endm=$(awk '/<!-- END BEADS INTEGRATION/ { print NR; exit }' "$CLAUDEMD")
        _notel=$(awk -v s="$MEMNOTE" 'index($0, s) { print NR; exit }' "$CLAUDEMD")
        if [ -n "$_endm" ] && [ -n "$_notel" ] && [ "$_notel" -lt "$_endm" ]; then
            f_fail "claudemd.memory-note" "present at line $_notel but INSIDE bd's managed block (END marker at line $_endm) — it will be lost on the next \`bd init\` or upgrade"
        else
            f_ok "claudemd.memory-note" "present once, outside the managed block"
        fi
    fi
fi

# ===========================================================================
# 8. End-to-end verification
# ===========================================================================
# `bd list` shows only OPEN issues, so one line against a database of hundreds
# is legitimate rather than truncation. `bd stats` carries the total.
if bd list >/dev/null 2>&1; then
    _tot=$(bd stats 2>/dev/null | awk '/Total Issues:/ { print $NF; exit }') || _tot=""
    f_ok "verify.read-path" "bd list works${_tot:+ (total issues: $_tot)}"
else
    f_stop "verify.read-path" "\`bd list\` failed — resolve before anything writes"
fi

# Trust doctor's Dolt Status over `bd vc status` for cleanliness: measured on
# 1.3.0, right after a config write vc status printed branch and commit with no
# changes line (reading as clean) while doctor reported 'config: modified' in
# the same instant and `bd vc commit` went on to make a real commit.
_vc=$(bd vc status 2>&1) || _vc=""
_branch=$(sed -n 's/^[[:space:]]*Branch:[[:space:]]*//p' <<<"$_vc")
_branch=$(strip_cr "${_branch%%$'\n'*}")
[ -n "$_branch" ] && f_info "verify.dolt-branch" "$_branch"
if [ "$DOCTOR_OK" = 1 ]; then
    # Scope this to the two checks that actually speak for the Dolt working set.
    # A substring search of the whole report for "uncommitted" matches the
    # unrelated `Git Working Tree: Uncommitted changes present` — entwine
    # carries exactly that, over a stray untracked file at the repo root, and a
    # loose match would report its Dolt store as dirty when `Dolt Status: Clean
    # working set` and `Dolt Locks: No locks or uncommitted changes` both pass.
    # Plain (non-verbose) doctor prints only checks that did NOT pass, so a
    # `Dolt Status`/`Dolt Locks` line appearing here IS the failure signal.
    _doltdirty=$(awk '/Dolt Status:|Dolt Locks:/ { print }' <<<"$_doc")
    if [ -n "$_doltdirty" ]; then
        f_fail "verify.dolt-clean" "doctor reports Dolt working-set dirt — clear with \`bd vc commit\` and push; a dirty working set is the state that blocks migrations. ($(tr '\n' ' ' <<<"$_doltdirty"))"
    else
        f_ok "verify.dolt-clean" "Dolt Status and Dolt Locks both pass"
    fi
fi

_gst=$(git -C "$REPO_ROOT" status --short 2>/dev/null) || _gst=""
if [ -n "$_gst" ]; then
    f_info "verify.git-tree" "$(printf '%s\n' "$_gst" | wc -l | tr -d ' ') modified path(s) in the working tree"
else
    f_ok "verify.git-tree" "clean"
fi

# ===========================================================================
# 9. Report
# ===========================================================================
n_of() { grep -c "^$1	" "$FINDINGS" 2>/dev/null || true; }
N_OK=$(n_of OK);   N_FAIL=$(n_of FAIL); N_WARN=$(n_of WARN)
N_INFO=$(n_of INFO); N_STOP=$(n_of STOP)

if [ "$OUT" = json ]; then
    jq -Rs --arg project "$PROJECT" --arg root "$REPO_ROOT" \
          --arg bd "$BDVER" --arg mode "$MODE" --arg db "$DB" '
        {
          project: $project, repo_root: $root, bd_version: $bd,
          mode: $mode, database: $db,
          findings: (split("\n") | map(select(length > 0) | split("\t")
                     | {status: .[0], id: .[1], message: .[2]})),
        }
        | .summary = (reduce .findings[] as $f ({};
              .[$f.status] = ((.[$f.status] // 0) + 1)))
    ' "$FINDINGS"
else
    printf '\n%s — bd %s, %s mode%s\n' \
        "$PROJECT" "${BDVER:-?}" "${MODE:-?}" "${DB:+, database $DB}"
    printf '%s\n' "----------------------------------------------------------------------"
    while IFS=$'\t' read -r st id msg; do
        printf '[%-4s] %-38s %s\n' "$st" "$id" "$msg"
    done < "$FINDINGS"
    printf '%s\n' "----------------------------------------------------------------------"
    printf 'ok %s · drift %s · warn %s · stop %s · info %s\n' \
        "$N_OK" "$N_FAIL" "$N_WARN" "$N_STOP" "$N_INFO"
    if [ "${N_STOP:-0}" -gt 0 ]; then
        printf '\nSTOP conditions present — do not let a repair pass run here until they are resolved.\n'
    fi
    printf '\nRead-only: nothing was changed.\n'
fi

[ "${N_STOP:-0}" -gt 0 ] && exit 2
[ "${N_FAIL:-0}" -gt 0 ] && exit 1
exit 0
