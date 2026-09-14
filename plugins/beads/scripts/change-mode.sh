#!/usr/bin/env bash
#
# change-mode.sh — switch a Beads (bd) project between "embedded" and
#                  "project server" mode, keeping the new install equivalent
#                  to the old.
#
#   change-mode.sh                report the current mode
#   change-mode.sh embedded       switch to embedded mode
#   change-mode.sh server         switch to project-server mode
#
# Invoked by the /beads:change-mode skill; safe to run directly too.
#
# The mode is selected by the `dolt_mode` field in .beads/metadata.json.
# The two modes keep their Dolt database in DIFFERENT directories
# (embedded -> .beads/embeddeddolt/<db>, server -> .beads/dolt/<db>), so a
# switch physically transfers the database rather than just flipping a flag.
#
# This script expects the single-user Dolt preferences enforced by the
# /beads:config-audit skill (a `refs/dolt/data` remote on git origin, auto-export
# off, etc.) and VERIFIES that configuration before changing anything. It:
#   * ensures the remote `refs/dolt/data` ref is up to date (commit + push) first,
#   * makes a temporary local backup of the Dolt database before any change,
#   * transfers state by copying the Dolt data directory (never runs `bd init`),
#     falling back to `bd bootstrap` from the remote if the copy doesn't verify,
#   * flips `dolt.auto-push` to match the target mode (embedded=on, server=off),
#   * rolls back to the original mode on any failure.
#
# Git hooks are NOT this script's business: `bd init` / `bd hooks install` own
# them, and we defer to bd rather than writing our own sync sections.
#
# Tracked files it edits (.beads/metadata.json, .beads/config.yaml) are left
# MODIFIED BUT UNCOMMITTED — committing the mode change is left to you.
#
set -euo pipefail

PROG=change-mode

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
die()  { printf '%s: error: %s\n'   "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# ---------------------------------------------------------------------------
# rollback state (populated as the switch proceeds; consumed by the EXIT trap)
# ---------------------------------------------------------------------------
MUTATED=0            # set to 1 once we begin changing on-disk state (Phase C)
SUCCESS=0            # set to 1 after a verified switch
SAVED_META=""        # backup copy of metadata.json (for rollback)
SAVED_CFG=""         # backup copy of config.yaml   (for rollback)
BACKUP=""            # temp backup dir of the source data dir
DST_DIR=""           # target-mode data dir (removed on rollback)
STARTED_SERVER=0     # we started a target-mode server (stop on rollback)
STOPPED_SERVER=0     # we stopped the source-mode server (restart on rollback)
CUR=""               # current mode (set once metadata is read)

cleanup_trap() {
    local rc=$?
    set +e            # never let a failing recovery step abort the rest of rollback
    [ "$SUCCESS" = 1 ] && exit "$rc"
    if [ "$MUTATED" = 0 ]; then
        # Nothing on-disk changed yet; the only thing to undo is a server we
        # stopped in Phase B before mutating (e.g. backup cp failed).
        [ "$STOPPED_SERVER" = 1 ] && [ "$CUR" = server ] && bd dolt start >/dev/null 2>&1
        exit "$rc"
    fi
    warn "switch failed (exit $rc) — rolling back to '$CUR' mode"
    # Stop a target-mode server we may have started.
    [ "$STARTED_SERVER" = 1 ] && bd dolt stop --force >/dev/null 2>&1
    # Restore the config files we edited.
    [ -n "$SAVED_META" ] && [ -f "$SAVED_META" ] && cp "$SAVED_META" "$META"
    [ -n "$SAVED_CFG"  ] && [ -f "$SAVED_CFG"  ] && cp "$SAVED_CFG"  "$CFG"
    # Remove any partially-written target data dir.
    [ -n "$DST_DIR" ] && [ -d "$DST_DIR" ] && rm -rf "$DST_DIR"
    # Make sure the original data dir is intact; restore from backup if needed.
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
        local src_dir; src_dir=$(data_dir_for "$CUR")
        if [ ! -d "$src_dir/$DB" ]; then
            mkdir -p "$src_dir"
            cp -R "$BACKUP/$(basename "$src_dir")/$DB" "$src_dir/$DB" 2>/dev/null || \
            cp -R "$BACKUP/"*/"$DB" "$src_dir/$DB" 2>/dev/null
        fi
    fi
    # If we were in server mode, bring the server back up.
    [ "$CUR" = server ] && bd dolt start >/dev/null 2>&1
    warn "rolled back to '$CUR' mode. Temporary backup preserved at: ${BACKUP:-<none>}"
    exit "$rc"
}
trap cleanup_trap EXIT

# ---------------------------------------------------------------------------
# locate the beads dir / repo, read metadata
# ---------------------------------------------------------------------------
need bd; need git; need jq


# Keep the full path after "beads dir:" — $NF would truncate a path with spaces.
# Capture then parse (no `bd context | sed | head`): an early-closing head makes
# bd/sed SIGPIPE and, under pipefail, turns this into a flaky 141 abort.
_ctx=$(bd context 2>/dev/null) || _ctx=""
BEADS_DIR=$(sed -n 's/^[[:space:]]*beads dir:[[:space:]]*//p' <<<"$_ctx")
BEADS_DIR=${BEADS_DIR%%$'\n'*}      # first match only
[ -n "$BEADS_DIR" ] && [ -d "$BEADS_DIR" ] || die "could not locate a .beads directory (run inside a beads project)"
REPO_ROOT=$(git -C "$BEADS_DIR" rev-parse --show-toplevel 2>/dev/null) || die "beads dir is not inside a git repository"

META="$BEADS_DIR/metadata.json"
CFG="$BEADS_DIR/config.yaml"
[ -f "$META" ] || die "missing $META"

meta_get() { jq -r ".$1 // empty" "$META"; }

BACKEND=$(meta_get backend)
DB=$(meta_get dolt_database)
CUR=$(meta_get dolt_mode)

# The database name is interpolated into data-dir paths (cp/rm -rf); refuse
# anything that isn't a plain identifier so an empty/crafted value can't make a
# later `rm -rf "$DST/$DB"` escape the beads dir.
[ -n "$DB" ] || die "metadata.json: dolt_database is empty"
case "$DB" in
    *[!A-Za-z0-9._-]*|*..*) die "metadata.json: dolt_database '$DB' has unexpected characters" ;;
esac

# data_dir_for <mode> -> absolute path of that mode's Dolt data directory
data_dir_for() {
    case "$1" in
        embedded) printf '%s/embeddeddolt' "$BEADS_DIR" ;;
        server)   printf '%s/dolt'         "$BEADS_DIR" ;;
        *)        return 1 ;;
    esac
}

# Read sync.remote from config.yaml, tolerating quoted or unquoted values.
# Capture then take the first line via parameter expansion (no `| head`, which
# would SIGPIPE sed under pipefail).
sync_remote() {
    local _sr
    _sr=$(sed -n -E 's/^sync\.remote:[[:space:]]*"?([^"]*[^"[:space:]])"?[[:space:]]*$/\1/p' "$CFG" 2>/dev/null)
    printf '%s' "${_sr%%$'\n'*}"
}

# ---------------------------------------------------------------------------
# fingerprint (for the pre/post equivalence check)
# ---------------------------------------------------------------------------
fingerprint() {
    # Content signal, not just IDs: {id,status,updated_at} per issue (updated_at
    # bumps on ANY edit — status/title/comment) plus the total count. This catches
    # a stale bootstrap that has the same IDs but lost uncommitted content, so we
    # don't delete the source over it. Stable across a byte-identical copy.
    # Guarded so a transient bd/pipefail hiccup can't abort a verified switch.
    local body total
    body=$(bd list --json 2>/dev/null | jq -S -c 'sort_by(.id) | map({id, status, updated_at})' 2>/dev/null) || body=""
    total=$(bd stats 2>/dev/null | awk '/Total Issues:/{print $NF}') || total=""
    printf '%s|%s' "${total:-?}" "$body"
    return 0
}

# ---------------------------------------------------------------------------
# config editors (deterministic; avoid buggy `bd config set` on nested YAML)
# ---------------------------------------------------------------------------
set_dolt_mode() {   # $1 = embedded|server ; preserves bd's no-trailing-newline format
    local out
    out=$(jq --arg m "$1" '.dolt_mode=$m' "$META") || die "jq failed rewriting $META"
    printf '%s' "$out" > "$META.tmp$$" && mv -f "$META.tmp$$" "$META"
}

# Normalize dolt.auto-push to a single flat "dolt.auto-push: <val>" line — the
# same representation the /beads:config-audit skill specifies. Portable (no `sed -i`), and
# verified via `bd config get` since this is a durability-critical setting.
set_auto_push() {   # $1 = true|false
    local tmp="$CFG.tmp$$"
    # drop any existing representation (flat dotted OR nested child)
    awk '!/^dolt\.auto-push:/ && !/^[[:space:]]+auto-push:/' "$CFG" > "$tmp"
    # drop a now-childless "dolt:" header left behind
    awk '{a[NR]=$0}
         END{for(i=1;i<=NR;i++){
                 if(a[i]~/^dolt:[[:space:]]*$/){nx=(i<NR)?a[i+1]:""; if(nx!~/^[[:space:]]/)continue}
                 print a[i]}}' "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
    [ -s "$tmp" ] && [ "$(tail -c1 "$tmp")" != "" ] && printf '\n' >> "$tmp"
    printf 'dolt.auto-push: %s\n' "$1" >> "$tmp"
    mv -f "$tmp" "$CFG"
    # Verify at the file level: exactly one flat line with the intended value.
    # (Not via `bd config get` — this runs mid-switch when dolt_mode is already
    # flipped and bd's store isn't readable yet.)
    { [ "$(grep -cE '^dolt\.auto-push:' "$CFG")" = 1 ] && grep -qxF "dolt.auto-push: $1" "$CFG"; } \
        || die "failed to set dolt.auto-push=$1 (check $CFG)"
}

# ===========================================================================
# report (no args)
# ===========================================================================
cmd_report() {
    info "mode:      $CUR"
    info "database:  $DB"
    info "data dir:  $(data_dir_for "$CUR")"
    local rem; rem=$(sync_remote) || true
    if [ -n "$rem" ]; then info "remote:    $rem"; fi
    if [ "$CUR" = server ]; then
        local st _dss; _dss=$(bd dolt status 2>/dev/null) || _dss=""
        st=$(awk -F': *' '/Dolt server:/{print $2; exit}' <<<"$_dss") || true
        info "server:    ${st:-unknown}"
    fi
}

# ===========================================================================
# switch
# ===========================================================================
cmd_switch() {
    local TGT=$1
    data_dir_for "$TGT" >/dev/null || die "unknown mode: $TGT (use 'embedded' or 'server')"
    if [ "$TGT" = "$CUR" ]; then
        info "Already in '$TGT' mode; nothing to do."
        SUCCESS=1; exit 0
    fi

    local SRC_DIR DST
    SRC_DIR=$(data_dir_for "$CUR")
    DST=$(data_dir_for "$TGT")

    # ---- Phase A: pre-flight verification (read-only) ---------------------
    # Capture bd version once, parse via here-string (never `bd … | awk '…exit'`,
    # whose early close SIGPIPEs bd into a flaky 141 under pipefail).
    local _vraw _ver
    _vraw=$(bd version 2>/dev/null) || _vraw=""
    _ver=$(awk '{print $3; exit}' <<<"$_vraw")
    step "Verifying configuration (embedded/server switch, bd ${_ver:-unknown})"
    # Verified against 1.1.x and 1.2.2: `bd context` ("beads dir:"), `bd migrate
    # --dry-run` ("Version matches"), `bd stats` ("Total Issues:"), `bd list
    # --json`, `bd config get`, `bd bootstrap --yes`, and `bd dolt
    # commit/push/start/stop/status/test/killall` all behave as used below.
    # Refuse anything newer rather than running data-moving commands whose flags
    # or output wording may have shifted.
    case "$_ver" in 1.1.*|1.2.*) ;; *) die "this script is verified for bd 1.1.x-1.2.x; found: ${_ver:-unknown} — re-verify the commands above before widening this gate" ;; esac
    [ "$BACKEND" = dolt ] || die "backend is '$BACKEND', expected 'dolt'"
    case "$CUR" in embedded|server) ;; *) die "unexpected current dolt_mode: '$CUR'";; esac

    git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 || die "no git 'origin' remote"
    [ -n "$(sync_remote)" ] || die "sync.remote is not configured in config.yaml (run /beads:config-audit first)"
    # Capture then test for a non-empty ref (never `| grep -q .`): under pipefail
    # grep -q closes the pipe on the first line, git dies with SIGPIPE, and the
    # pipeline goes non-zero — misreading a present ref as missing.
    _ref=$(git -C "$REPO_ROOT" ls-remote origin refs/dolt/data 2>/dev/null) || _ref=""
    [ -n "$_ref" ] || die "remote has no refs/dolt/data ref — run 'bd dolt push' or the /beads:config-audit skill first"

    # Capture the dry-run output once, then match with a here-string. Piping bd
    # straight into `grep -q` inverts under pipefail (grep closes early -> bd
    # SIGPIPE -> non-zero pipeline -> spurious "schema does not match"). Same
    # deterministic bug as the audit's schema check (see bd-dqp).
    local _schema; _schema=$(bd migrate --dry-run 2>&1) \
        || die "schema does not match this bd binary (pending migration) — resolve before switching"
    grep -q 'Version matches' <<<"$_schema" \
        || die "schema does not match this bd binary (pending migration) — resolve before switching"

    # Soft (audit-preference) checks — warn only.
    [ "$(bd config get export.auto 2>/dev/null)" = false ] || warn "export.auto is not false (audit preference)"

    if [ -d "$DST/$DB" ] && [ -n "$(ls -A "$DST/$DB" 2>/dev/null)" ]; then
        die "target data dir already exists and is non-empty: $DST/$DB (remove or inspect it first)"
    fi

    local BEFORE; BEFORE=$(fingerprint)
    info "current issues: ${BEFORE%%|*} (fingerprint captured)"

    # ---- Phase B: make remote current, quiesce, back up -------------------
    step "Ensuring refs/dolt/data is up to date"
    bd dolt commit -m "change-mode: pre-switch commit" >/dev/null 2>&1 || true   # capture any working set
    bd dolt push >/dev/null 2>&1 || die "bd dolt push failed — off-machine copy not established, aborting"
    _ref=$(git -C "$REPO_ROOT" ls-remote origin refs/dolt/data 2>/dev/null) || _ref=""
    [ -n "$_ref" ] || die "refs/dolt/data missing after push"
    info "pushed; refs/dolt/data is current"

    if [ "$CUR" = server ]; then
        step "Stopping the project server to quiesce the database"
        STOPPED_SERVER=1   # so rollback restarts it even if we fail before MUTATED
        bd dolt stop >/dev/null 2>&1 || true
        sleep 1
        _st=$(bd dolt status 2>/dev/null) || _st=""
        grep -q 'not running' <<<"$_st" || bd dolt stop --force >/dev/null 2>&1 || true
        bd dolt killall >/dev/null 2>&1 || true
    fi
    export BEADS_DOLT_AUTO_START=0   # prevent a stray bd call from relaunching the server mid-switch

    step "Backing up the current Dolt database"
    BACKUP=$(mktemp -d "${TMPDIR:-/tmp}/beads-change-mode-backup-${DB}-${CUR}.XXXXXX")
    cp -R "$SRC_DIR" "$BACKUP"/
    info "backup: $BACKUP"

    # ---- Phase C: flip the mode config (record originals for rollback) ----
    step "Switching mode: $CUR -> $TGT"
    SAVED_META=$(mktemp "${TMPDIR:-/tmp}/beads-change-mode-meta.XXXXXX"); cp "$META" "$SAVED_META"
    SAVED_CFG=$(mktemp  "${TMPDIR:-/tmp}/beads-change-mode-cfg.XXXXXX");  cp "$CFG"  "$SAVED_CFG"
    MUTATED=1
    DST_DIR="$DST"

    set_dolt_mode "$TGT"
    case "$TGT" in
        embedded) set_auto_push true  ;;   # single-writer: background durability on
        server)   set_auto_push false ;;   # multi-writer: avoid concurrent auto-push to git remote
    esac

    # ---- Phase D: transfer state into the new data dir (no bd init) -------
    step "Transferring database into $TGT data directory"
    mkdir -p "$DST"
    # Pre-flight allows an empty/absent target; remove it so `cp -R src dst`
    # can't nest into an existing dir ($DST/$DB/$DB). $DB is validated; $DST is absolute.
    rm -rf "${DST:?}/${DB:?}"
    if cp -R "$SRC_DIR/$DB" "$DST/$DB"; then
        info "copied $SRC_DIR/$DB -> $DST/$DB"
    else
        warn "direct copy failed; falling back to 'bd bootstrap' from remote"
        rm -rf "${DST:?}/${DB:?}"
        transfer_via_bootstrap
    fi

    unset BEADS_DOLT_AUTO_START
    if [ "$TGT" = server ]; then
        step "Starting the project server"
        bd dolt start >/dev/null 2>&1 || die "failed to start dolt server"
        STARTED_SERVER=1
        bd dolt test >/dev/null 2>&1 || die "dolt server did not become reachable"
    fi

    # ---- Phase E: verify equivalence -------------------------------------
    step "Verifying the switched database"
    local AFTER; AFTER=$(fingerprint)
    if [ "$AFTER" != "$BEFORE" ]; then
        # give the copy path one more chance via bootstrap before failing
        warn "issue set differs after copy (before=[$BEFORE] after=[$AFTER]); retrying via bootstrap"
        if [ "$TGT" = server ]; then bd dolt stop --force >/dev/null 2>&1 || true; STARTED_SERVER=0; fi
        rm -rf "${DST:?}/${DB:?}"
        export BEADS_DOLT_AUTO_START=0
        transfer_via_bootstrap
        unset BEADS_DOLT_AUTO_START
        if [ "$TGT" = server ]; then bd dolt start >/dev/null 2>&1 || die "server restart failed"; STARTED_SERVER=1; bd dolt test >/dev/null 2>&1 || die "server unreachable"; fi
        AFTER=$(fingerprint)
        [ "$AFTER" = "$BEFORE" ] || die "database not equivalent after transfer (before=[$BEFORE] after=[$AFTER])"
    fi
    [ "$(meta_get dolt_mode)" = "$TGT" ] || die "dolt_mode did not update to $TGT"
    info "verified: mode=$TGT, issues=${AFTER%%|*}"

    # ---- Phase F: finalize ------------------------------------------------
    SUCCESS=1
    step "Cleaning up"
    rm -rf "${SRC_DIR:?}"                  # remove the now-unused old-mode data dir
    info "removed old data dir: $SRC_DIR"
    if [ "$TGT" = embedded ]; then        # drop stale server runtime files
        rm -f "$BEADS_DIR"/dolt-server.* "$BEADS_DIR"/bd.sock "$BEADS_DIR"/bd.sock.startlock 2>/dev/null || true
    fi
    info "backup kept at:       $BACKUP"

    step "Done — now in '$TGT' mode"
    local cfgdiff; cfgdiff=$(git -C "$REPO_ROOT" --no-pager diff --stat -- "$META" "$CFG" 2>/dev/null) || true
    if [ -n "$cfgdiff" ]; then
        info "Modified (uncommitted) tracked files:"
        printf '%s\n' "$cfgdiff" | sed 's/^/  /'
        info "Review and commit them when ready (this script does not commit)."
    fi
}

# Populate the (current dolt_mode's) data dir from the up-to-date remote.
transfer_via_bootstrap() {
    bd bootstrap --yes >/dev/null 2>&1 || bd bootstrap -y >/dev/null 2>&1 \
        || die "bd bootstrap failed to clone from remote"
}

# ===========================================================================
# main
# ===========================================================================
case "${1-}" in
    "")                 cmd_report ;;
    embedded|server)    cmd_switch "$1" ;;
    -h|--help|help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)                  printf 'usage: %s [embedded|server]\n' "$PROG" >&2; exit 2 ;;
esac
