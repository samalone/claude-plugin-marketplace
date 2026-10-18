#!/usr/bin/env bats
#
# bd-sync: the lock around `bd sync`, and the guidance that points agents at it.
#
# `bd` here is a stub that logs its arguments and exits with $BDS_RC, so these
# tests need no Dolt fixture and run in seconds. What they pin down is the lock:
# that it serializes, that worktrees share it, and that a dead holder cannot
# wedge every later sync.

load helpers/setup

BD_SYNC="$REPO_ROOT/plugins/bd/scripts/bd-sync.sh"
INJECT="$REPO_ROOT/plugins/bd/scripts/inject-beads-workflow.sh"

setup() {
    command -v git >/dev/null 2>&1 || skip "required tool not found: git"
    FIXTURE="$(mktemp -d "$BD_TESTS_BASE/bdt-sync.XXXXXX")"
    REPO="$FIXTURE/repo"
    git init -q "$REPO"
    fixture_identity "$REPO"
    git -C "$REPO" commit -q --allow-empty -m "init test fixture"
    LOCK="$REPO/.git/bd-sync.lock"

    mkdir "$FIXTURE/bin"
    cat > "$FIXTURE/bin/bd" <<'EOF'
#!/usr/bin/env bash
[ "$1" = sync ] || exit 99
shift
echo "start $$ $*" >> "$BDS_LOG"
sleep "${BDS_SLEEP:-0}"
echo "end $$" >> "$BDS_LOG"
exit "${BDS_RC:-0}"
EOF
    chmod +x "$FIXTURE/bin/bd"
    export PATH="$FIXTURE/bin:$PATH"
    export BDS_LOG="$FIXTURE/bd.log"
}

teardown() {
    cd "$BD_TESTS_BASE" 2>/dev/null || cd / || true
    safe_rm "${FIXTURE:-}"
}

sync_in() { run bash -c "cd '$1' && '$BD_SYNC' ${*:2}"; }

# dead_pid — a PID that just exited, so `kill -0` on it fails.
dead_pid() { sh -c 'exit 0' & local p=$!; wait "$p"; echo "$p"; }

@test "bd-sync: passes flags through to bd sync and releases the lock" {
    sync_in "$REPO" --attempts 5
    [ "$status" -eq 0 ]
    grep -q -- "^start [0-9]* --attempts 5$" "$BDS_LOG"
    [ ! -e "$LOCK" ]
}

@test "bd-sync: returns bd sync's exit status, with what to do about it" {
    local rc
    for rc in 1 2 3 4; do
        BDS_RC=$rc sync_in "$REPO"
        [ "$status" -eq "$rc" ]
        [ ! -e "$LOCK" ]
        case $rc in
            2) [[ "$output" == *"merge conflict"* ]] ;;
            3) [[ "$output" == *"transient"* ]] ;;
            4) [[ "$output" == *"stuck"* ]] ;;
            1) [[ "$output" == *"failed (exit 1)"* ]] ;;
        esac
    done
}

@test "bd-sync: concurrent runs never overlap" {
    export BDS_SLEEP=1
    ( cd "$REPO" && "$BD_SYNC" ) 2>/dev/null &
    local a=$!
    ( cd "$REPO" && "$BD_SYNC" ) 2>/dev/null &
    local b=$!
    wait "$a"; wait "$b"
    # strictly alternating start/end: no second start before the first end
    [ "$(cut -d' ' -f1 "$BDS_LOG" | tr '\n' ' ')" = "start end start end " ]
}

@test "bd-sync: a worktree waits on the main checkout's lock, then gives up with 3" {
    git -C "$REPO" worktree add -q "$FIXTURE/wt"
    mkdir "$LOCK"; echo $$ > "$LOCK/pid"           # held by a live process (bats)
    BD_SYNC_LOCK_WAIT=1 sync_in "$FIXTURE/wt"
    [ "$status" -eq 3 ]
    [[ "$output" == *"still holds"* ]]
    [ ! -e "$BDS_LOG" ]                             # bd sync never ran
    [ "$(cat "$LOCK/pid")" = "$$" ]                 # and the holder's lock is untouched
}

@test "bd-sync: reclaims a lock whose holder is dead" {
    mkdir "$LOCK"; dead_pid > "$LOCK/pid"
    sync_in "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reclaimed a stale lock"* ]]
    [ -e "$BDS_LOG" ]
    [ ! -e "$LOCK" ]
}

@test "bd-sync: a PID-less lock is respected while fresh, reclaimed once old" {
    mkdir "$LOCK"                                   # a holder between mkdir and pid write
    BD_SYNC_LOCK_WAIT=1 sync_in "$REPO"
    [ "$status" -eq 3 ]
    touch -t 202001010000 "$LOCK"
    sync_in "$REPO"
    [ "$status" -eq 0 ]
    [ ! -e "$LOCK" ]
}

@test "bd-sync: refuses to run outside a git repository" {
    mkdir "$FIXTURE/nogit"
    GIT_CEILING_DIRECTORIES="$FIXTURE" sync_in "$FIXTURE/nogit"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not inside a git repository"* ]]
    [ ! -e "$BDS_LOG" ]
}

@test "inject-beads-workflow: names bd-sync.sh by the plugin's absolute path" {
    mkdir -p "$FIXTURE/proj/.beads"
    run bash -c "echo '{}' | CLAUDE_PLUGIN_ROOT='$REPO_ROOT/plugins/bd' CLAUDE_PROJECT_DIR='$FIXTURE/proj' '$INJECT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"$BD_SYNC\""* ]]
    [[ "$output" != *"@BD_PLUGIN_ROOT@"* ]]
}

@test "bd-sync: a lock is live while its bd child is, even if the wrapper died" {
    sleep 30 & local child=$!
    mkdir "$LOCK"; { dead_pid; echo "$child"; } > "$LOCK/pid"
    BD_SYNC_LOCK_WAIT=1 sync_in "$REPO"
    kill "$child" 2>/dev/null || true
    [ "$status" -eq 3 ]
    [ ! -e "$BDS_LOG" ]
}

@test "bd-sync: records bd's PID in the lock beside its own" {
    cat > "$FIXTURE/bin/bd" <<'STUB'
#!/usr/bin/env bash
wc -l < "$(git rev-parse --path-format=absolute --git-common-dir)/bd-sync.lock/pid" > "$BDS_LOG"
STUB
    sync_in "$REPO"
    [ "$status" -eq 0 ]
    [ "$(tr -d ' ' < "$BDS_LOG")" = 2 ]
}

@test "bd-sync: a lock it cannot create is an error, not contention" {
    [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
    chmod a-w "$REPO/.git"
    BD_SYNC_LOCK_WAIT=30 sync_in "$REPO"
    chmod u+w "$REPO/.git"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot create"* ]]
    [ ! -e "$BDS_LOG" ]
}

@test "bd-sync: rejects a non-numeric BD_SYNC_LOCK_WAIT" {
    BD_SYNC_LOCK_WAIT=5s sync_in "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"whole number"* ]]
    [ ! -e "$BDS_LOG" ]
}
