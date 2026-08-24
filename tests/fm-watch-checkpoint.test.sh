#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

# Budget for a checkpoint that is EXPECTED to be woken. It is a hang tripwire,
# not the expected end of the run: the checkpoint returns as soon as its watcher
# surfaces a wake. A watcher's startup is not instant and dilates with machine
# load - it has been measured taking many seconds on a loaded runner - so a
# budget sized on an idle machine reported a correct wake as a timeout.
WOKEN_CHECKPOINT_SECONDS=${FM_TEST_WAIT_SECONDS:-90}

# A home whose legacy-check migration still has to run, which is what a real
# first checkpoint in a home looks like.
make_unmigrated_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

make_home() {
  local name=$1 home
  home=$(make_unmigrated_home "$name")
  # The check migration runs before the watcher takes its lock and is the
  # slowest part of startup. Every case below is about the checkpoint, not about
  # migrating legacy checks, so declare the migration already done and let the
  # watcher reach its poll loop promptly. The migration's own interaction with
  # the checkpoint has its own case, which uses make_unmigrated_home.
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  printf '%s\n' "$home"
}

# Succeeds once the checkpoint's watcher has reached its poll loop. The beacon is
# touched at the top of every iteration, ahead of the check sweep and the signal
# scan, so observing it proves a trigger written now is seen by this cycle or the
# next one rather than racing an unfinished startup.
watcher_armed() {  # <home>
  [ -e "$1/state/.last-watcher-beat" ]
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  # Unconditional, at any point the timeout can land: the checkpoint must not
  # return until the watcher it started has released the singleton. A lock left
  # behind here refuses every later arm for the whole stale-lock window, so this
  # is the case that catches a checkpoint which reaps its watcher without
  # letting it clean up.
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  # The trigger is written only once the watcher is provably in its poll loop,
  # rather than after a fixed sleep that guesses when that happened.
  (
    fm_test_wait_until watcher_armed "$home" \
      || printf 'watcher never armed\n' > "$home/trigger.err"
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds "$WOKEN_CHECKPOINT_SECONDS" >"$out" 2>"$err" || status=$?
  [ ! -s "$home/trigger.err" ] || fail "checkpoint watcher never reached its poll loop"
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds "$WOKEN_CHECKPOINT_SECONDS" >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

# The watcher lock is taken twice during startup: first by the legacy-check
# migration as its watcher-exclusion window, then by the watcher itself. A
# checkpoint that expires while either holds it must still return with the lock
# released, or the next arm in that home is refused for the whole stale-lock
# window even though nothing is running. The short budget is the point: it puts
# the timeout inside startup, where the holder is most likely to be the
# migration rather than a settled watcher.
test_timeout_during_startup_leaves_no_watcher_lock() {
  local home out err status attempt
  home=$(make_unmigrated_home startup-timeout)
  out="$home/out.txt"
  err="$home/err.txt"
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    rm -rf "$home/state"
    mkdir -p "$home/state"
    status=0
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
      "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
    expect_code 124 "$status" "startup-timeout checkpoint exit"
    assert_absent "$home/state/.watch.lock/pid" \
      "a checkpoint that expired during startup left the watcher lock behind"
    attempt=$((attempt + 1))
  done
  pass "a checkpoint expiring during watcher startup never strands the watcher lock"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 \
    "$CHECKPOINT" --seconds "$WOKEN_CHECKPOINT_SECONDS" >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_timeout_during_startup_leaves_no_watcher_lock
test_existing_singleton_watcher_is_not_success
