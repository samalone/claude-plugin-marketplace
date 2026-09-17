# Shared harness for the beads plugin's bats suite.
#
# Every test runs against a throwaway `bd init` project with a bare git origin —
# never a live repo. bd refuses to operate in "unsafe" temp locations (/tmp,
# /var/tmp), so fixtures live under $HOME by default; override with
# BD_TESTS_TMPDIR pointing at any bd-safe directory.
#
# Teardown stops only the fixture's own Dolt server, project-scoped
# (`bd -C <proj> dolt stop --force`). Note on killall: `bd dolt killall` is
# ALSO project-scoped in standalone mode — per `bd dolt killall --help`, it only
# reaps servers using the current project's Dolt data directory and "Other
# projects' servers are preserved." So change-mode's server-quiesce killall,
# which runs in the fixture's own context, cannot touch a developer's unrelated
# live server (verified: the suite runs with other live project servers
# untouched). Only under an orchestrator ($GT_ROOT) is killall broader, and the
# tests never set that up.

# This file is sourced via bats `load`; the vars/functions below are the harness
# API consumed by the .bats files, which shellcheck can't see across the load.
# shellcheck disable=SC2034  # CHANGE_MODE/CONFIG_AUDIT are used by the sourcing tests

# Absolute path to the tool under test (BATS_TEST_DIRNAME = the test/ dir).
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CHANGE_MODE="$REPO_ROOT/plugins/bd/scripts/change-mode.sh"
CONFIG_AUDIT="$REPO_ROOT/plugins/bd/scripts/config-audit.sh"

# bd-safe base for fixtures (not /tmp or /var/tmp).
BD_TESTS_BASE="${BD_TESTS_TMPDIR:-$HOME}"

# Skip the whole test cleanly if a required tool is missing. Extra tool names
# may be passed for suites that need more than the common three (config-audit
# needs yq).
require_tools() {
    local t
    for t in bd git jq "$@"; do
        command -v "$t" >/dev/null 2>&1 || skip "required tool not found: $t"
    done
}

# fixture_identity <repo> — set a repo-local git identity so commits (bd init's
# own and the tests') succeed on a machine with no global git config, e.g. CI.
fixture_identity() {
    git -C "$1" config user.name  "beads plugin tests"
    git -C "$1" config user.email "beads-plugin-tests@example.invalid"
}

# make_project [--ready]
#   Create an isolated embedded bd project with a bare origin already pushed.
#   Sets PROJECT and ORIGIN. With --ready, also establishes the preconditions
#   change-mode verifies in its read-only pre-flight (see prepare_for_switch).
make_project() {
    export BEADS_DOLT_AUTO_START=0            # never auto-start a server during setup
    PROJECT="$(mktemp -d "$BD_TESTS_BASE/bdt-proj.XXXXXX")"
    ORIGIN="$PROJECT.origin.git"              # sibling of PROJECT, not nested inside it
    git init -q "$PROJECT"
    git init -q --bare "$ORIGIN"
    fixture_identity "$PROJECT"
    git -C "$PROJECT" remote add origin "$ORIGIN"
    # A committed HEAD before pushing: CI runners have no global git identity, so
    # bd init's own auto-commit is skipped there and HEAD would be unborn —
    # `git push -u origin HEAD` then fails and the bare origin gets no branch (so
    # `bd dolt push` can't run either, since it needs an initial branch). The
    # explicit identity + initial commit make setup work on a clean machine.
    git -C "$PROJECT" commit -q --allow-empty -m "init test fixture"
    ( cd "$PROJECT" && bd init >/dev/null 2>&1 )
    git -C "$PROJECT" push -u origin HEAD >/dev/null 2>&1
    # Capture the Dolt database name here so teardown can always sweep this
    # fixture's temp backups. Leaving it to each test to set BDT_DB meant a test
    # that forgot silently leaked backup dirs into TMPDIR.
    BDT_DB="$(meta dolt_database)"
    if [ "${1:-}" = "--ready" ]; then
        prepare_for_switch
    fi
}

# prepare_for_switch — bring the fixture to the state change-mode's pre-flight
# requires. This deliberately reimplements only the handful of preconditions the
# script checks, rather than shelling out to the /bd:config-audit skill: that
# audit is a *skill* (instructions for Claude), not a script, so it cannot be
# invoked from a test. Keep this in sync with cmd_switch's Phase A.
#
#   * sync.remote      — already written by `bd init` from the git origin URL.
#   * refs/dolt/data   — must exist on origin; created by the first `bd dolt push`.
#   * export.auto      — false (bd's default; asserted here so a default change
#                        surfaces as a test failure rather than a silent warning).
#   * dolt.auto-push   — false, as a single flat line. The audit now specifies
#                        false on EVERY project regardless of mode (the push is
#                        client-side with an unlocked debounce, so even one
#                        machine with parallel sessions races the remote
#                        manifest), and set_auto_push writes false in both
#                        directions. Seeded false so the round-trip test proves
#                        the value is NORMALIZED rather than merely unchanged.
prepare_for_switch() {
    ( cd "$PROJECT" && bd dolt commit -m "fixture: initial" >/dev/null 2>&1 ) || true
    ( cd "$PROJECT" && bd dolt push >/dev/null 2>&1 ) \
        || { echo "fixture: 'bd dolt push' failed; cannot establish refs/dolt/data" >&2; return 1; }
    git -C "$PROJECT" ls-remote origin refs/dolt/data 2>/dev/null | grep -q . \
        || { echo "fixture: origin has no refs/dolt/data after push" >&2; return 1; }

    [ -n "$(sync_remote_line)" ] \
        || { echo "fixture: bd init did not write sync.remote" >&2; return 1; }

    append_config_line 'export.auto: false'
    append_config_line 'dolt.auto-push: false'
}

# append_config_line <line> — append to the fixture's config.yaml, first ensuring
# it ends in a newline. `bd init` writes config.yaml with NO trailing newline, so
# a naive `>>` lands on the end of the last line (sync.remote) and corrupts it —
# the script then reports "sync.remote is not configured". The script's own
# set_auto_push guards the same way; the command substitution is empty exactly
# when the last byte is already a newline.
append_config_line() {
    local cfg="$PROJECT/.beads/config.yaml"
    if [ -s "$cfg" ] && [ -n "$(tail -c1 "$cfg")" ]; then
        printf '\n' >> "$cfg"
    fi
    printf '%s\n' "$1" >> "$cfg"
}

# Read a scalar from the fixture's metadata.json.
meta() { jq -r ".$1 // empty" "$PROJECT/.beads/metadata.json"; }

# The single flat dolt.auto-push line (empty if absent/duplicated).
autopush_line() { grep -E '^dolt\.auto-push:' "$PROJECT/.beads/config.yaml" || true; }

# The sync.remote line from the fixture's config.yaml (empty if absent).
sync_remote_line() { grep -E '^sync\.remote:' "$PROJECT/.beads/config.yaml" || true; }

# Rewrite the fixture's flat `sync.remote:` line into the nested block form —
# what `bd config set sync.remote` writes when no flat line exists to reuse,
# which is where a project ends up after the audit's SSH->HTTPS remote repair
# (`bd dolt remote remove` comments the flat line out). bd reads both; so must
# the script.
nest_sync_remote() {
    local cfg="$PROJECT/.beads/config.yaml" url
    url=$(sed -n -E 's/^sync\.remote:[[:space:]]*"?([^"]*[^"[:space:]])"?[[:space:]]*$/\1/p' "$cfg")
    [ -n "$url" ] || { echo "fixture: no flat sync.remote line to nest" >&2; return 1; }
    sed -e 's/^sync\.remote:/# sync.remote:/' "$cfg" > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
    append_config_line "sync:"
    printf '    remote: "%s"\n' "$url" >> "$cfg"
}

# Content signature of the issue set, stable across a byte-identical DB copy.
issue_sig() { ( cd "$PROJECT" && bd list --json 2>/dev/null | jq -Sc 'sort_by(.id) | map({id, status})' ); }

# Guarded recursive delete — refuses empty / root / $HOME and any parent-
# traversal path (a future bad fixture var must not delete outside test dirs).
safe_rm() {
    local path="${1:-}"
    case "$path" in
        ""|/|.|..|"$HOME"|"$HOME"/|../*|*/..|*/../*) return 0 ;;
        *) rm -rf -- "$path" ;;
    esac
}

# Standard teardown: stop the fixture server (scoped), remove PROJECT + ORIGIN,
# and sweep any change-mode temp backups this run left in TMPDIR.
bdt_teardown() {
    cd "$BD_TESTS_BASE" 2>/dev/null || cd / || true   # never sit inside the dir we delete
    if [ -n "${PROJECT:-}" ] && [ -d "$PROJECT/.beads" ]; then
        ( cd "$PROJECT" && bd dolt stop --force >/dev/null 2>&1 ) || true
    fi
    safe_rm "${PROJECT:-}"
    safe_rm "${ORIGIN:-}"
    # change-mode writes backups to ${TMPDIR:-/tmp}/beads-change-mode-backup-<db>-<mode>.XXXX
    local db="${BDT_DB:-}"
    if [ -n "$db" ]; then
        rm -rf "${TMPDIR:-/tmp}"/beads-change-mode-backup-"$db"-* 2>/dev/null || true
    fi
}
