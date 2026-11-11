#!/usr/bin/env bash
# Behavior tests for the home-identity backstop (bin/fm-primary-scope-lib.sh
# fm_home_identity_check) and the entrypoints that enforce it.
#
# Regression for 2026-11-11: after a reboot, Herdr restored a secondmate's agent
# in the environment of the session that had started the server, so the
# secondmate ran in its own home while FM_HOME and FM_STATE_OVERRIDE named the
# main home. Its Stop hooks evaluated the main home and it ran
# bin/fm-wake-drain.sh against the main home, advancing that home's status
# presentation cursor. Each case below runs the real entrypoint twice with the
# same environment: from the home that environment names (it must act) and from
# another home (it must refuse and leave the named home untouched).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-identity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
fm_git_identity fmtest fmtest@example.invalid

# make_home <dir> [secondmate-id]: a firstmate home whose bin/ links every real
# script, so each entrypoint resolves FM_ROOT to this home exactly as a hook
# command anchored on the home's own path does.
make_home() {
  local dir=$1 sm_id=${2:-} entry
  mkdir -p "$dir/bin/backends" "$dir/state" "$dir/data" "$dir/config" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  for entry in "$ROOT"/bin/*; do
    [ -d "$entry" ] || ln -s "$entry" "$dir/bin/$(basename "$entry")"
  done
  for entry in "$ROOT"/bin/backends/*; do
    ln -s "$entry" "$dir/bin/backends/$(basename "$entry")"
  done
  ln -s "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  [ -z "$sm_id" ] || printf '%s\n' "$sm_id" > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

MAIN=$(make_home "$TMP_ROOT/main")
SM=$(make_home "$TMP_ROOT/sm" sm-identity)
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE"

# snapshot <state-dir>: every entry's name and content, for untouched checks.
snapshot() {
  (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s\n' "$f"; fi
  done)
}

# seed_main_state: one in-flight task, an unread note, and no watcher, so every
# entrypoint has real work to do for the main home.
seed_main_state() {
  rm -rf "$MAIN/state"
  mkdir -p "$MAIN/state"
  : > "$MAIN/state/task1.meta"
  printf 'note: something the main firstmate must read\n' > "$MAIN/state/task1.status"
}

# in_dir <dir> <command...>: run with <dir> as the working directory and the
# leaked main-home environment.
in_dir() {
  local dir=$1
  shift
  (cd "$dir" && env FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$@")
}

test_wake_drain_refuses_another_home() {
  local before out rc
  seed_main_state
  before=$(snapshot "$MAIN/state")
  out=$(in_dir "$SM" bash "$SM/bin/fm-wake-drain.sh" 2>&1)
  rc=$?
  expect_code 3 "$rc" "wake drain from another home"
  assert_contains "$out" "refusing to act for home $MAIN" "the refusal must name the other home"
  [ "$(snapshot "$MAIN/state")" = "$before" ] || fail "a refused drain changed the main home's state"

  out=$(in_dir "$MAIN" bash "$MAIN/bin/fm-wake-drain.sh" 2>&1)
  rc=$?
  expect_code 0 "$rc" "wake drain from its own home"
  assert_contains "$out" "something the main firstmate must read" "the main home's own drain must present its unread note"
  [ "$(snapshot "$MAIN/state")" != "$before" ] || fail "the positive control did not advance the main home's cursor"
  pass "fm-wake-drain refuses another home's queue and still drains its own"
}

test_wake_drain_refuses_a_foreign_state_override() {
  local before out rc
  seed_main_state
  before=$(snapshot "$MAIN/state")
  out=$(cd "$SM" && env FM_HOME="$SM" FM_STATE_OVERRIDE="$MAIN/state" bash "$SM/bin/fm-wake-drain.sh" 2>&1)
  rc=$?
  expect_code 3 "$rc" "wake drain with another home's FM_STATE_OVERRIDE"
  assert_contains "$out" "FM_STATE_OVERRIDE" "the refusal must name the state override"
  [ "$(snapshot "$MAIN/state")" = "$before" ] || fail "a refused drain changed the main home's state"
  pass "fm-wake-drain refuses an FM_STATE_OVERRIDE that names another home"
}

test_cross_home_callers_outside_any_home_still_work() {
  local out rc
  seed_main_state
  out=$(in_dir "$OUTSIDE" bash "$MAIN/bin/fm-wake-drain.sh" 2>&1)
  rc=$?
  expect_code 0 "$rc" "wake drain from outside every firstmate checkout"
  assert_contains "$out" "something the main firstmate must read" "a deliberate caller outside every home must still drain"
  mkdir -p "$MAIN/projects"
  [ -d "$MAIN/projects/firstmate-clone" ] || make_home "$MAIN/projects/firstmate-clone" >/dev/null
  seed_main_state
  out=$(in_dir "$MAIN/projects/firstmate-clone" bash "$MAIN/bin/fm-wake-drain.sh" 2>&1)
  rc=$?
  expect_code 0 "$rc" "wake drain from a firstmate clone inside the home's projects/"
  pass "a caller outside every home, or inside the home's own projects/, keeps working"
}

test_turnend_guard_stands_down_for_another_home() {
  local out rc before
  seed_main_state
  before=$(snapshot "$MAIN/state")
  # shellcheck disable=SC2016  # expands in the child shell, not here
  out=$(in_dir "$SM" bash -c 'printf "{\"stop_hook_active\":false}" | bash "$1"' _ "$MAIN/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  expect_code 0 "$rc" "turn-end guard for another home"
  assert_contains "$out" "refusing to act for home $MAIN" "the stand-down must say why"
  [ "$(snapshot "$MAIN/state")" = "$before" ] || fail "a stood-down guard changed the main home's state"

  # shellcheck disable=SC2016  # expands in the child shell, not here
  out=$(in_dir "$MAIN" bash -c 'printf "{\"stop_hook_active\":false}" | bash "$1"' _ "$MAIN/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  expect_code 2 "$rc" "turn-end guard for its own blind home"
  assert_contains "$out" "TURN WOULD END BLIND" "the positive control must block the blind turn"
  pass "the turn-end guard stands down for another home and still guards its own"
}

test_sessionstart_refuses_another_home_in_context() {
  local out rc before
  seed_main_state
  before=$(snapshot "$MAIN/state")
  # shellcheck disable=SC2016  # expands in the child shell, not here
  out=$(in_dir "$SM" bash -c 'printf "{\"source\":\"resume\"}" | bash "$1"' _ "$MAIN/bin/fm-sessionstart-run.sh" 2>&1)
  rc=$?
  expect_code 0 "$rc" "session-start hook must still let the session open"
  assert_contains "$out" "WRONG FIRSTMATE ENVIRONMENT" "the agent must be told in its own context"
  assert_contains "$out" "refusing to act for home $MAIN" "the context must name the other home"
  [ "$(snapshot "$MAIN/state")" = "$before" ] || fail "a refused session start changed the main home's state"
  pass "session start tells a wrong-environment agent to stand down and leaves the other home untouched"
}

test_lock_refuses_another_home() {
  local out rc before
  seed_main_state
  before=$(snapshot "$MAIN/state")
  out=$(in_dir "$SM" bash "$SM/bin/fm-lock.sh" 2>&1)
  rc=$?
  expect_code 1 "$rc" "session lock for another home"
  assert_contains "$out" "refusing to act for home $MAIN" "the lock refusal must say why"
  [ ! -e "$MAIN/state/.lock" ] || fail "a refused lock attempt wrote the main home's lock"
  [ "$(snapshot "$MAIN/state")" = "$before" ] || fail "a refused lock attempt changed the main home's state"
  pass "the session lock refuses to take another home's helm"
}

test_watch_arm_refuses_another_home() {
  local out rc before
  seed_main_state
  before=$(snapshot "$MAIN/state")
  out=$(in_dir "$SM" bash "$SM/bin/fm-watch-arm.sh" 2>&1)
  rc=$?
  expect_code 1 "$rc" "watcher arm for another home"
  assert_contains "$out" "watcher: FAILED - firstmate: refusing to act for home $MAIN" "the arm refusal must say why"
  [ ! -e "$MAIN/state/.watch.lock" ] || fail "a refused arm claimed the main home's watcher"
  [ "$(snapshot "$MAIN/state")" = "$before" ] || fail "a refused arm changed the main home's state"
  pass "watcher arming refuses to claim another home's watcher"
}

test_wake_drain_refuses_another_home
test_wake_drain_refuses_a_foreign_state_override
test_cross_home_callers_outside_any_home_still_work
test_turnend_guard_stands_down_for_another_home
test_sessionstart_refuses_another_home_in_context
test_lock_refuses_another_home
test_watch_arm_refuses_another_home
