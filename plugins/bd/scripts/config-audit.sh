#!/usr/bin/env bash
#
# config-audit.sh — READ-ONLY audit of a Beads (bd) project against the
#                   single-user Dolt preferences described by the
#                   /bd:config-audit skill.
#
#   config-audit.sh                 human-readable report (READ-ONLY)
#   config-audit.sh --json          same findings as JSON  (READ-ONLY)
#   config-audit.sh --no-network    skip the `git ls-remote` probe
#   config-audit.sh --apply         print the repair plan, change nothing
#   config-audit.sh --apply --yes   perform the repairs, then re-audit
#   config-audit.sh --check-version verify the installed bd only; no project needed
#
# WITHOUT --apply THIS SCRIPT WRITES NOTHING. It does not run `bd config set`,
# does not touch .beads/, does not stage or commit, and does not start or stop a
# server. That is deliberate: the audit is meant to be safe to run across every
# project in one sweep before anything acts.
#
# `--apply` repairs only FAIL findings, only those named in REPAIR_ORDER, and
# only when no STOP finding is present. WARN is a judgement call and is never
# acted on. It never makes a git commit — it leaves the working tree for you to
# review — but it does push refs/dolt/data, because the skill's ordering
# requires an off-machine copy to exist before anything is deleted.
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
APPLY=0
ASSUME_YES=0
CHECK_VERSION=0
while [ $# -gt 0 ]; do
    case "$1" in
        --json)       OUT=json ;;
        --no-network) NETWORK=0 ;;
        --apply)      APPLY=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --check-version) CHECK_VERSION=1 ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done
[ "$APPLY" = 1 ] && [ "$OUT" = json ] && die "--json is a reporting mode; it cannot be combined with --apply"

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

# ---------------------------------------------------------------------------
# bd version gate
# ---------------------------------------------------------------------------
# A MINIMUM, not a verified range. Every check here parses bd's output, and bd is
# a fast-moving tool, so an older binary is refused outright rather than allowed
# to produce confidently wrong findings. CI reads BD_MIN straight out of this
# file (`--check-version`), so the workflow's gate cannot drift from the script's.
BD_MIN=1.3.0
# The newest release these checks were actually exercised against. Newer is
# allowed — refusing it would strand the tool on every bd upgrade — but it is
# reported, because "the parsing still works" is an assumption above this line.
BD_VERIFIED=1.3.0

# ver_lt <a> <b> — 0 (true) when a < b, comparing dot-separated numeric fields.
# A non-numeric suffix (1.3.0-rc1) degrades to 0 for that field, which orders a
# prerelease below its release. Good enough for a floor check.
ver_lt() {
    [ "$(awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, A, "."); nb = split(b, B, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            x = (i <= na) ? A[i] + 0 : 0
            y = (i <= nb) ? B[i] + 0 : 0
            if (x < y) { print 1; exit }
            if (x > y) { print 0; exit }
        }
        print 0
    }')" = 1 ]
}

_vraw=$(bd version 2>/dev/null) || _vraw=""
BDVER=$(awk '{print $3; exit}' <<<"$_vraw")
BDVER=${BDVER%$'\r'}
BDVER=${BDVER#v}
[ -n "$BDVER" ] || die "could not read a version out of \`bd version\` (got: ${_vraw:-nothing})"
ver_lt "$BDVER" "$BD_MIN" && die "bd $BDVER is older than the required $BD_MIN.
       These checks parse bd's output and assume 1.3.0 behaviour throughout;
       on an older binary they would report confidently wrong findings.
       Upgrade bd, or use an earlier revision of this script."

if [ "$CHECK_VERSION" = 1 ]; then
    printf 'bd %s (minimum %s, verified through %s)\n' "$BDVER" "$BD_MIN" "$BD_VERIFIED"
    exit 0
fi

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

# --- bd version (the floor was already enforced above) -------------------
if ver_lt "$BD_VERIFIED" "$BDVER"; then
    f_warn "bd.version" "$BDVER is newer than the $BD_VERIFIED these checks were exercised against. They parse bd's output, so re-verify the commands before trusting a surprising finding — and bump BD_VERIFIED once you have."
else
    f_info "bd.version" "$BDVER"
fi

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
# stdout ONLY, and the LAST non-empty line of it. Merging stderr (2>&1) makes any
# warning bd happens to emit first — e.g. "auto-import from .beads/issues.jsonl
# failed: validation failed for issue X" — become the value, so a key reads as
# set to the text of an unrelated complaint. Caught on a fixture carrying a bad
# issues.jsonl, which is exactly the state this audit exists to clean up.
bdcfg() {
    local out
    out=$(bd config get "$1" 2>/dev/null) || out=""
    out=$(awk 'NF { last = $0 } END { printf "%s", last }' <<<"$out")
    out=$(strip_cr "$out")
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
        f_warn "claudemd.memory-note" "present $_n times — should appear exactly once. Not auto-repaired: choosing which copy to keep, and where its section ends, is a content call on a tracked file."
    else
        _endm=$(awk '/<!-- END BEADS INTEGRATION/ { print NR; exit }' "$CLAUDEMD")
        _notel=$(awk -v s="$MEMNOTE" 'index($0, s) { print NR; exit }' "$CLAUDEMD")
        if [ -n "$_endm" ] && [ -n "$_notel" ] && [ "$_notel" -lt "$_endm" ]; then
            f_warn "claudemd.memory-note" "present at line $_notel but INSIDE bd's managed block (END marker at line $_endm) — it will be lost on the next \`bd init\` or upgrade. Not auto-repaired: moving it means deciding where the section ends, which is a content call on a tracked file."
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
else
    # Embedded mode has no doctor, so there is no authoritative cleanliness
    # signal at all. Say so rather than leaving the check silently absent —
    # `bd vc status` under-reports (measured on 1.3.0: it read as clean while
    # doctor reported `config: modified` in the same instant), so its silence
    # here is not evidence of a clean working set.
    f_info "verify.dolt-clean" "not checkable in embedded mode (doctor is unsupported there); \`bd vc status\` under-reports config-table changes, so treat its silence as no signal"
fi

_gst=$(git -C "$REPO_ROOT" status --short 2>/dev/null) || _gst=""
if [ -n "$_gst" ]; then
    f_info "verify.git-tree" "$(printf '%s\n' "$_gst" | wc -l | tr -d ' ') modified path(s) in the working tree"
else
    f_ok "verify.git-tree" "clean"
fi

# ===========================================================================
# 9. Repairs (--apply)
# ===========================================================================
# Only FAIL findings are repaired, and only the ones named in REPAIR_ORDER.
# WARN is a judgement call and STOP means stop, so neither is ever acted on.
#
# THE ORDER IS THE SAFETY PROPERTY, not a convenience. Durability comes first:
# the remote must exist, be on HTTPS, and have taken a real push before anything
# deletes issues.jsonl. That file is not a backup, but on a project with no
# remote yet it can be the only off-machine copy in existence — so the deletion
# step re-checks that the push actually landed and declines if it did not,
# rather than trusting that an earlier step in this same list succeeded.
REPAIR_ORDER='
config.line-endings
remote.present
remote.transport
remote.ref
schema.state
config.export.auto
config.dolt.auto-push
config.backup.git-push
config.doctor.suppress.dolt-remote-vs-git-origin
config.doctor.suppress.cursor-integration
files.issues-jsonl
files.interactions-jsonl
gitignore.dolt-server-config
gitignore.untracked
agents.optout
agents.block
claudemd.memory-note
'

has_fail() { grep -q "^FAIL	$1	" "$FINDINGS" 2>/dev/null; }

# Repair log, rendered after the run.
APPLIED="$WORK/applied.txt"; : > "$APPLIED"
did()     { printf '  ✓ %s\n' "$*" >> "$APPLIED"; }
skipped() { printf '  — %s\n' "$*" >> "$APPLIED"; }

# --- editing helpers -----------------------------------------------------

# Append a line to a file that may not end in a newline. `bd init` writes
# config.yaml and the gitignores with no trailing byte, so a naive >> lands on
# the end of the last line and silently corrupts it.
append_line() {   # <file> <line>
    [ -e "$1" ] || : > "$1"
    if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then printf '\n' >> "$1"; fi
    printf '%s\n' "$2" >> "$1"
}

# Set a YAML key to a bare (unquoted) scalar, collapsing the flat/nested
# ambiguity onto the flat spelling that bd's own precedence prefers.
set_yaml_key() {   # <dotted.key> <bare-value>
    local key=$1 val=$2 ns leaf st pres
    ns=${key%%.*}; leaf=${key#*.}
    st=$(yaml_state "$key"); pres=${st%%$'\t'*}
    if [ "$pres" = nested ] || [ "$pres" = both ]; then
        yq -i "del(.\"$ns\"[\"$leaf\"])" "$CFG"
        # Drop a parent left childless by that delete, so the file returns to
        # exactly one representation. Verified byte-identical to a pristine
        # config; a parent that still has other children is left alone.
        yq -i "del(.\"$ns\" | select(. == null or length == 0))" "$CFG"
    fi
    yq -i ".\"$key\" = $val" "$CFG"
    # Re-read through the same path the audit uses, not through `bd config get`:
    # config routing for some keys has been buggy and a `set` that reports
    # success may not have taken.
    st=$(yaml_state "$key"); pres=${st%%$'\t'*}
    [ "$pres" = flat ] && [ "${st#*$'\t'}" = "$val" ] \
        || die "failed to set $key=$val in $CFG (now: $st)"
}

# scp-style and ssh:// URLs to their https:// equivalent. Only the transport is
# normalized — the git+ prefix is carried through unchanged, because both
# spellings are in use, both work, and bd rewrites it to git+ itself anyway.
to_https() {   # <url>
    local u=$1 pre="" head after
    case "$u" in git+*) pre="git+"; u=${u#git+} ;; esac
    case "$u" in
        https://*) printf '%s%s' "$pre" "$u"; return ;;
        ssh://*)   u=${u#ssh://} ;;
        *) : ;;
    esac
    case "$u" in *@*) u=${u#*@} ;; esac          # drop any user@ prefix
    # A ':' before the first '/' means one of two different things, and the
    # discriminator is whether what follows it is numeric:
    #   scp-style  git@host:me/repo.git   -> ':' separates host from PATH
    #   ssh + port ssh://host:2222/me/... -> ':' introduces a PORT
    # Conflating them corrupts the URL in one direction or the other. Testing
    # only for a '/' anywhere is not enough: the scp-style path contains one, so
    # host:me/repo.git read as a port form and silently lost the "me" segment.
    head=${u%%/*}
    case "$head" in
        *:*)
            after=${head#*:}
            case "$after" in
                ''|*[!0-9]*) u="${u%%:*}/${u#*:}" ;;      # path: promote to '/'
                *)           u="${u%%:*}${u#"$head"}" ;;  # port: drop it
            esac ;;
        *) : ;;
    esac
    printf '%s%s%s' "$pre" "https://" "$u"
}

apply_one() {
    case "$1" in

    config.line-endings)
        # Only the line terminator, never a CR inside a value.
        awk '{ sub(/\r$/, ""); print }' "$CFG" > "$CFG.tmp$$" && mv -f "$CFG.tmp$$" "$CFG"
        did "normalized config.yaml to LF" ;;

    remote.present)
        local gurl hurl
        gurl=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null) || gurl=""
        [ -n "$gurl" ] || { skipped "no remote: git has no 'origin' to derive one from — tell me, do not guess"; return 0; }
        hurl=$(to_https "$gurl")
        case "$hurl" in
            https://*|git+https://*) ;;
            *) skipped "no remote: could not derive an HTTPS URL from origin ($gurl)"; return 0 ;;
        esac
        # --allow-git-origin is REQUIRED, not optional. bd 1.3.0 aborts with
        # "refusing to add ... this URL matches the git origin" for both the
        # https:// and git+https:// spellings — and a Dolt remote that IS the git
        # origin is precisely the target state here, which is why the audit
        # suppresses bd's own Dolt-Remote-vs-Git-Origin warning. Without the flag
        # this repair could never succeed on a normal single-repo layout.
        # `bd dolt remote add` writes the correct sync.remote key itself, so the
        # config is never hand-edited or the key name guessed.
        bd dolt remote add origin "$hurl" --allow-git-origin >/dev/null 2>&1 \
            || { skipped "no remote: \`bd dolt remote add\` failed"; return 0; }
        REMOTE_URL=$hurl
        did "added Dolt remote origin -> $hurl" ;;

    remote.transport)
        [ -n "$REMOTE_URL" ] || { skipped "SSH remote: nothing registered to repair"; return 0; }
        local hurl; hurl=$(to_https "$REMOTE_URL")
        # There is no set-url: `bd dolt remote` offers only add/list/remove.
        # Removing drops the local registration only — it does not touch
        # refs/dolt/data on the server or anything in the local database.
        bd dolt remote remove origin >/dev/null 2>&1 \
            || { skipped "SSH remote: \`bd dolt remote remove\` failed"; return 0; }
        # If the add fails we must put back what we removed. Without this, a
        # refused add leaves the project with NO Dolt remote at all — severing
        # the only off-machine copy of the beads data, which is the exact
        # outcome this whole script exists to prevent. (bd refuses a URL
        # matching the git origin unless --allow-git-origin is passed, so this
        # was not a hypothetical: it failed every time on a normal layout.)
        if bd dolt remote add origin "$hurl" --allow-git-origin >/dev/null 2>&1; then
            did "moved the Dolt remote from SSH to HTTPS: $REMOTE_URL -> $hurl"
            REMOTE_URL=$hurl
        elif bd dolt remote add origin "$REMOTE_URL" --allow-git-origin >/dev/null 2>&1; then
            skipped "SSH remote: could not add the HTTPS URL ($hurl); restored the original SSH remote, nothing lost"
        else
            die "removed the Dolt remote and could not restore it. Re-add it NOW before running anything else:
       bd dolt remote add origin '$REMOTE_URL' --allow-git-origin"
        fi ;;

    remote.ref)
        if bd dolt push >/dev/null 2>&1; then
            did "pushed refs/dolt/data to origin (first off-machine copy)"
        else
            skipped "refs/dolt/data: \`bd dolt push\` failed — nothing that deletes data will run"
        fi ;;

    schema.state)
        # Only ever reached for the zero-registered-migrations case: a metadata
        # version stamp, no DDL and no data rewrite. A real migration is a STOP
        # finding, and --apply refuses to run at all when one is present.
        if bd migrate >/dev/null 2>&1; then
            did "applied the schema version stamp (\`bd migrate\`, 0 registered migrations)"
            bd dolt push >/dev/null 2>&1 && did "pushed the migrated database"
        else
            skipped "schema stamp: \`bd migrate\` failed"
        fi ;;

    config.export.auto)    set_yaml_key export.auto    false; did "set export.auto=false" ;;
    config.dolt.auto-push) set_yaml_key dolt.auto-push false; did "set dolt.auto-push=false (off on every project; sync is a deliberate \`bd sync\`)" ;;
    config.backup.git-push) set_yaml_key backup.git-push false; did "set backup.git-push=false" ;;

    config.doctor.suppress.*)
        # These live in the beads database, not config.yaml, so there is nothing
        # to grep for afterwards and their absence from the YAML is not a failed
        # write. Verify through `bd config get`.
        local key=${1#config.}
        bd config set "$key" true >/dev/null 2>&1 || { skipped "$key: \`bd config set\` failed"; return 0; }
        if [ "$(bdcfg "$key")" = true ]; then
            DB_WROTE=1
            did "set $key=true (db-resident; travels on refs/dolt/data)"
        else
            skipped "$key: set reported success but \`bd config get\` does not agree"
        fi ;;

    files.issues-jsonl)
        # Re-check durability here rather than trusting an earlier step in this
        # list: this is the one repair that destroys data.
        #
        # The guard covers ONLY the deletion. The most common form of this
        # finding is "absent but not gitignored", where there is nothing to
        # delete and the whole repair is one line in .gitignore — returning
        # early there left the finding permanently unfixable on any project
        # without a pushed ref.
        local ref rel
        ref=$(git -C "$REPO_ROOT" ls-remote origin refs/dolt/data 2>/dev/null) || ref=""
        rel=$(relp "$ISSUES")
        if [ -z "$ref" ] && { is_tracked "$rel" || [ -f "$ISSUES" ]; }; then
            skipped "issues.jsonl: origin has no refs/dolt/data, so this file may be the only off-machine copy — NOT removing it (the gitignore entry is still added)"
        elif is_tracked "$rel"; then
            if git -C "$REPO_ROOT" rm -f --quiet -- "$rel" >/dev/null 2>&1; then
                did "git rm'd $rel (staged, not committed)"
            else
                skipped "issues.jsonl: \`git rm\` failed"
            fi
        elif [ -f "$ISSUES" ]; then
            rm -f "$ISSUES" && did "deleted untracked $rel"
        fi
        # Use the repo-relative path the checks use, not a hardcoded
        # ".beads/issues.jsonl": a .beads below the repo root would otherwise get
        # a pattern that never matches the file it is meant to cover.
        is_ignored "$rel" || { append_line "$REPO_ROOT/.gitignore" "$rel"; did "gitignored $rel"; } ;;

    files.interactions-jsonl)
        # NOT the same kind of thing as issues.jsonl: an append-only audit log
        # that survives Dolt GC/flatten, so it is a real recovery trail. Untrack
        # it, never delete it, and never disable the logging.
        local rel; rel=$(relp "$INTER")
        if is_tracked "$rel"; then
            if git -C "$REPO_ROOT" rm --cached --quiet -- "$rel" >/dev/null 2>&1; then
                did "untracked $rel with \`git rm --cached\` (working file kept)"
            else
                skipped "interactions.jsonl: \`git rm --cached\` failed"
            fi
        fi
        is_ignored "$rel" || { append_line "$REPO_ROOT/.gitignore" "$rel"; did "gitignored $rel"; } ;;

    gitignore.dolt-server-config)
        append_line "$BEADS_DIR/.gitignore" 'dolt-server-config.yaml'
        did "added 'dolt-server-config.yaml' to .beads/.gitignore (bd omits it from its own pattern list)" ;;

    gitignore.untracked)
        # bd maintains .beads/.gitignore and the project .gitignore from its own
        # requiredPatterns, append-only on an existing file, so delegating is
        # safe and local rules survive. Don't copy that list here; it grows
        # between versions and a copy would drift.
        if [ "$MODE" = server ]; then
            bd doctor --fix --yes >/dev/null 2>&1 || true
            did "ran \`bd doctor --fix --yes\` to top up bd's gitignore patterns (this rewrites the tracked project .gitignore)"
        else
            skipped "gitignore patterns: no bd mechanism in embedded mode — doctor is unsupported there and exits 0 anyway, and \`bd init\` refuses to re-run. Compare .beads/.gitignore against bd's list by hand."
        fi ;;

    agents.optout)
        if [ "$AG_MODE" = 120000 ]; then
            # One file wearing two names: the comment's own text is false here.
            if awk -v s="$OPTOUT" 'index($0, s) == 0 { print }' "$CLAUDEMD" > "$CLAUDEMD.tmp$$" \
               && mv -f "$CLAUDEMD.tmp$$" "$CLAUDEMD"; then
                did "removed the false divergence opt-out from CLAUDE.md (AGENTS.md is a symlink to it)"
            else
                rm -f "$CLAUDEMD.tmp$$"
                skipped "opt-out: could not rewrite CLAUDE.md"
            fi
        elif [ -f "$AGENTS" ]; then
            append_line "$AGENTS" "$OPTOUT"
            did "appended the divergence opt-out to AGENTS.md"
        else
            skipped "opt-out: no AGENTS.md, and one will not be conjured up just to hold a bd block"
        fi ;;

    agents.block)
        # Only ever reached when a BEGIN marker is already present, so this
        # refreshes rather than creates. `opencode` and `factory` render
        # byte-identical bodies; `codex` writes a second marker pair and `claude`
        # targets CLAUDE.md, so neither is usable here.
        if bd setup opencode >/dev/null 2>&1; then
            did "refreshed the bd-managed block with \`bd setup opencode\`"
        else
            skipped "bd block: \`bd setup opencode\` failed"
        fi ;;

    claudemd.memory-note)
        [ -f "$CLAUDEMD" ] || { skipped "memory note: no CLAUDE.md at the repo root"; return 0; }
        # Append ONLY when the note is genuinely absent. The check also fires for
        # "present N times", and appending there made the duplication worse on
        # every run — two copies became three, three became four.
        if grep -qF "$MEMNOTE" "$CLAUDEMD" 2>/dev/null; then
            skipped "memory note: already present — not appending another copy"
            return 0
        fi
        # Appended at the END, which is after bd's END marker wherever that sits.
        # Anything written between the markers is regenerated away.
        append_line "$CLAUDEMD" ''
        cat >> "$CLAUDEMD" <<'MEMEOF'
## Memory: beads vs. Claude Code auto-memory

`bd prime` says not to use MEMORY.md files. Disregard that blanket rule and
split by what the fact is *about*: `bd remember` for knowledge about this
repo (conventions, gotchas, decisions — it travels on `refs/dolt/data` and
any agent on any machine can read it; keep the count low, since prime injects
every memory in full every session), and Claude Code auto-memory under
`~/.claude/projects/<project>/memory/` for facts about me and how I want you
to work. Explicit user instructions override the beads block, as it concedes.
MEMEOF
        did "appended the memory division-of-labor note to CLAUDE.md, after bd's managed block" ;;

    *) skipped "no automatic repair for $1" ;;
    esac
}

if [ "$APPLY" = 1 ]; then
    PLAN=""
    for _id in $REPAIR_ORDER; do
        has_fail "$_id" && PLAN="$PLAN $_id"
    done
    # FAIL findings with no entry in the table — reported, never silently dropped.
    UNHANDLED=""
    while IFS=$'\t' read -r _st _id _msg; do
        [ "$_st" = FAIL ] || continue
        case " $(printf '%s' "$REPAIR_ORDER" | tr '\n' ' ') " in
            *" $_id "*) ;;
            *) UNHANDLED="$UNHANDLED $_id" ;;
        esac
    done < "$FINDINGS"

    if [ "${N_STOP_PRE:=$(grep -c '^STOP	' "$FINDINGS" 2>/dev/null || true)}" -gt 0 ]; then
        printf '\nREFUSING to apply: %s STOP condition(s) present.\n\n' "$N_STOP_PRE"
        grep '^STOP	' "$FINDINGS" | while IFS=$'\t' read -r _s _i _m; do
            printf '  %-34s %s\n' "$_i" "$_m"
        done
        printf '\nResolve these first; they are the cases that are mine to decide, not the script'"'"'s.\n'
        exit 2
    fi

    if [ -z "$PLAN" ]; then
        printf '\nNothing to apply — no repairable drift found.\n'
        [ -n "$UNHANDLED" ] && printf 'Findings with no automatic repair:%s\n' "$UNHANDLED"
        exit 0
    fi

    if [ "$ASSUME_YES" != 1 ]; then
        printf '\nWould apply, in this order (durability first):\n\n'
        for _id in $PLAN; do
            printf '  %-46s %s\n' "$_id" "$(grep "^FAIL	$_id	" "$FINDINGS" | cut -f3 | cut -c1-70)"
        done
        [ -n "$UNHANDLED" ] && printf '\nNo automatic repair (left for you):%s\n' "$UNHANDLED"
        # Only promise a push when the plan actually contains one. The steps that
        # push are the explicit ones plus any db-resident config write, which
        # dirties the Dolt working set and so draws the commit-and-push post-step
        # behind it. A plan of nothing but YAML keys pushes nothing, and saying
        # otherwise on every run would train the warning to be ignored.
        case " $PLAN " in
            *" remote.ref "*|*" schema.state "*|*" config.doctor.suppress."*)
                printf '\nThis writes to the repo and pushes refs/dolt/data. Re-run with --yes to do it.\n' ;;
            *)
                printf '\nThis writes to the working tree only — no push, no commit. Re-run with --yes to do it.\n' ;;
        esac
        exit 0
    fi

    printf '\nApplying (%s step(s))...\n\n' "$(printf '%s' "$PLAN" | wc -w | tr -d ' ')"
    DB_WROTE=0
    for _id in $PLAN; do apply_one "$_id"; done

    # Clearing the Dolt working set is a consequence of what THIS run wrote, so
    # it cannot be a plan entry: a plan entry is keyed on the PRE-repair audit,
    # and on an otherwise-clean project verify.dolt-clean was not FAIL, so the
    # suppress-key writes were left uncommitted and unpushed — the dirty state
    # that blocks migrations. It also has to run in embedded mode, where there
    # is no `bd doctor` to have raised the finding in the first place.
    if [ "$DB_WROTE" = 1 ]; then
        if bd vc commit -m "config-audit: bring config into the audited state" >/dev/null 2>&1; then
            did "committed the Dolt working set (db-resident config writes)"
            bd dolt push >/dev/null 2>&1 && did "pushed the config commit"
        else
            skipped "Dolt working set: \`bd vc commit\` found nothing to commit, or failed"
        fi
    fi
    cat "$APPLIED"
    [ -n "$UNHANDLED" ] && printf '\nNo automatic repair (left for you):%s\n' "$UNHANDLED"
    printf '\nNothing was committed to git — review and commit the working tree yourself.\n'
    printf '\nRe-auditing...\n'

    REARGS=""
    [ "$NETWORK" = 0 ] && REARGS="--no-network"
    rm -rf "$WORK"; trap - EXIT
    # shellcheck disable=SC2086  # REARGS is a controlled flag, deliberately split
    "$0" $REARGS
    exit $?
fi

# ===========================================================================
# 10. Report
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
