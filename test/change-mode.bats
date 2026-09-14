#!/usr/bin/env bats
#
# change-mode: embedded<->server switching, rollback, and input guards.

load helpers/setup

setup() {
    require_tools
}

teardown() {
    bdt_teardown
}

# --- round trip -------------------------------------------------------------

@test "change-mode: embedded->server->embedded flips auto-push, preserves issues" {
    make_project --ready
    ( cd "$PROJECT" && bd create --title="round trip" --type=task -p 2 >/dev/null 2>&1 )
    local before; before="$(issue_sig)"
    [ "$(meta dolt_mode)" = embedded ]
    [ "$(autopush_line)" = "dolt.auto-push: true" ]      # embedded: single-writer durability on

    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$CHANGE_MODE' server"
    [ "$status" -eq 0 ]
    [ "$(meta dolt_mode)" = server ]
    [ "$(autopush_line)" = "dolt.auto-push: false" ]     # server: avoid concurrent auto-push
    [ -d "$PROJECT/.beads/dolt" ]
    [ ! -d "$PROJECT/.beads/embeddeddolt" ]              # old-mode data dir removed

    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$CHANGE_MODE' embedded"
    [ "$status" -eq 0 ]
    [ "$(meta dolt_mode)" = embedded ]
    [ "$(autopush_line)" = "dolt.auto-push: true" ]
    [ -d "$PROJECT/.beads/embeddeddolt" ]
    [ ! -d "$PROJECT/.beads/dolt" ]

    # exactly one flat auto-push line, and the issue set is unchanged
    [ "$(grep -cE '^dolt\.auto-push:' "$PROJECT/.beads/config.yaml")" -eq 1 ]
    [ "$(issue_sig)" = "$before" ]
}

# --- config representations -------------------------------------------------

@test "change-mode: reads sync.remote in the nested block form bd also writes" {
    make_project --ready
    nest_sync_remote
    [ -z "$(sync_remote_line)" ]                        # no flat line left to read
    ( cd "$PROJECT" && bd config get sync.remote ) | grep -q "$ORIGIN"   # bd still sees it

    # the report surfaces it...
    run bash -c "cd '$PROJECT' && '$CHANGE_MODE'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"remote:"* ]]

    # ...and pre-flight accepts it rather than aborting with "not configured"
    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$CHANGE_MODE' server"
    [ "$status" -eq 0 ]
    [[ "$output" != *"sync.remote is not configured"* ]]
    [ "$(meta dolt_mode)" = server ]
    # the nested block survived the config rewrite set_auto_push does
    grep -qE '^[[:space:]]+remote:' "$PROJECT/.beads/config.yaml"
}

# --- rollback ---------------------------------------------------------------

@test "change-mode: a failed switch rolls back mode, config, and data" {
    make_project --ready
    ( cd "$PROJECT" && bd create --title="rollback" --type=task -p 2 >/dev/null 2>&1 )
    local before; before="$(issue_sig)"

    # Inject a post-MUTATED failure: pre-create the target data dir as a FILE so
    # `mkdir -p "$DST"` fails after the config/mode were already flipped.
    : > "$PROJECT/.beads/dolt"

    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$CHANGE_MODE' server"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rolling back to 'embedded' mode"* ]]

    # everything restored
    [ "$(meta dolt_mode)" = embedded ]
    [ "$(autopush_line)" = "dolt.auto-push: true" ]
    [ -d "$PROJECT/.beads/embeddeddolt" ]
    [ "$(issue_sig)" = "$before" ]
}

@test "change-mode: a failed switch from server restarts the source server" {
    make_project --ready
    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$CHANGE_MODE' server"  # server mode first
    [ "$status" -eq 0 ]
    [ "$(meta dolt_mode)" = server ]

    # Inject failure on the server->embedded switch (target = embeddeddolt).
    : > "$PROJECT/.beads/embeddeddolt"
    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$CHANGE_MODE' embedded"
    [ "$status" -ne 0 ]
    [ "$(meta dolt_mode)" = server ]                           # rolled back to server
    # the source server was stopped to quiesce, then brought back up on rollback.
    # Exclude the "not running" substring so a down server can't pass this.
    run bd -C "$PROJECT" dolt status
    [[ "$output" == *"running"* && "$output" != *"not running"* ]]
}

# --- guards -----------------------------------------------------------------

@test "change-mode: rejects an empty dolt_database" {
    make_project
    jq '.dolt_database=""' "$PROJECT/.beads/metadata.json" > "$PROJECT/.beads/m.tmp"
    mv "$PROJECT/.beads/m.tmp" "$PROJECT/.beads/metadata.json"
    run bash -c "cd '$PROJECT' && '$CHANGE_MODE'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dolt_database is empty"* ]]
}

@test "change-mode: rejects a traversal-laden dolt_database" {
    make_project
    jq '.dolt_database="../escape"' "$PROJECT/.beads/metadata.json" > "$PROJECT/.beads/m.tmp"
    mv "$PROJECT/.beads/m.tmp" "$PROJECT/.beads/metadata.json"
    run bash -c "cd '$PROJECT' && '$CHANGE_MODE'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected characters"* ]]
}

@test "change-mode: no-op when already in the requested mode" {
    make_project
    run bash -c "cd '$PROJECT' && '$CHANGE_MODE' embedded"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already in 'embedded' mode"* ]]
    [ "$(meta dolt_mode)" = embedded ]
}

@test "change-mode: unknown argument prints usage and exits 2" {
    make_project
    run bash -c "cd '$PROJECT' && '$CHANGE_MODE' bogus"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}
