#!/usr/bin/env bash
# Regression test for symlinked path aliases leaking into durable records
# (bin/fm-spawn.sh's project= / home= writes into state/<id>.meta, and
# bin/fm-watch.sh's fm-home / watcher-path writes into state/.watch.lock).
#
# A directory reachable under two spellings - its real path and a symlink alias
# pointing at it - is one directory, but a record keyed on the literal string is
# two. A shell entered through the alias keeps the alias spelling in $PWD, so a
# logical `pwd` read hands back the alias and firstmate writes it into the task
# record. Records written under one spelling are then invisible to a session
# running under the other.
#
# Each case below drives a real spawn through an aliased spelling and asserts
# the recorded path is the resolved physical one. The last case pins the
# read-side tolerance that keeps already-recorded alias paths working.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-path-spelling)
# The fixture root itself can sit under a symlinked prefix (macOS /tmp ->
# /private/tmp), so resolve it once and compare every expectation against the
# physical form rather than against whatever mktemp handed back.
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# make_fakebin <dir>: a tmux that always reports the worktree as the pane cwd,
# plus a no-op treehouse. Enough for a spawn to reach its meta write.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a firstmate home holding one project clone under
# projects/, a worktree for it, and an "alias" symlink beside the home pointing
# at the home. Mirrors the captain's dev-github -> dgh compatibility symlink.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$home/projects/demo"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  ln -s home "$case_dir/aliashome"
  ln -s demo "$home/projects/aliasdemo"
  CASE_DIR=$case_dir
  CASE_HOME=$home
  CASE_PROJ=$proj
  CASE_WT=$wt
  CASE_FAKEBIN=$fakebin
}

run_spawn() {  # <home> <project-arg> <id>
  local home=$1 project_arg=$2 id=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$CASE_WT" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$project_arg" --mode no-mistakes --yolo off 2>&1
}

# The captain's exact chain: firstmate itself is entered through the alias, so
# FM_HOME carries the alias spelling and every path derived from it - including
# the projects/ root the relative project argument resolves against - inherits
# it. This is the shape that produced project=/Users/mtupper/dev-github/...
test_aliased_home_does_not_leak_into_project_record() {
  local id out status meta
  id=spelling-viahome-p1
  make_case viahome "$id"
  out=$(run_spawn "$CASE_DIR/aliashome" "projects/demo" "$id")
  status=$?
  expect_code 0 "$status" "spawn through an aliased home should succeed: $out"
  meta="$CASE_HOME/state/$id.meta"
  assert_grep "project=$CASE_PROJ" "$meta" \
    "meta did not record the resolved project path"
  assert_no_grep "alias" "$meta" \
    "meta leaked the aliased home spelling into a durable record"
  pass "an aliased firstmate home does not leak into the recorded project path"
}

# The same defect reached through the project argument itself rather than
# through the home: an absolute path whose own final component is a symlink.
test_aliased_project_argument_is_resolved() {
  local id out status meta
  id=spelling-viaproj-p2
  make_case viaproj "$id"
  out=$(run_spawn "$CASE_HOME" "$CASE_HOME/projects/aliasdemo" "$id")
  status=$?
  expect_code 0 "$status" "spawn through an aliased project path should succeed: $out"
  meta="$CASE_HOME/state/$id.meta"
  assert_grep "project=$CASE_PROJ" "$meta" \
    "meta did not record the resolved project path"
  assert_no_grep "alias" "$meta" \
    "meta leaked the aliased project spelling into a durable record"
  pass "an aliased project argument is recorded as its resolved physical path"
}

# The relative-argument form (projects/<name>) through an aliased home, where
# the alias sits on the project component rather than the home component.
test_aliased_relative_project_argument_is_resolved() {
  local id out status meta
  id=spelling-viarel-p3
  make_case viarel "$id"
  out=$(run_spawn "$CASE_DIR/aliashome" "projects/aliasdemo" "$id")
  status=$?
  expect_code 0 "$status" "spawn through an aliased relative project should succeed: $out"
  meta="$CASE_HOME/state/$id.meta"
  assert_grep "project=$CASE_PROJ" "$meta" \
    "meta did not record the resolved project path"
  assert_no_grep "alias" "$meta" \
    "meta leaked an aliased spelling into a durable record"
  pass "an aliased relative project argument is recorded as its resolved physical path"
}

# --- read-side tolerance ---------------------------------------------------
#
# Canonicalizing what firstmate WRITES is only half the fix. Records already on
# disk - a watcher lock, a process-source claim - still hold whatever spelling
# was current when they were written. If the live home stopped recognizing
# those, a running fleet would look unowned: the guard would disown its own
# watcher and arm a second supervision cycle, and a home would walk past its
# own claims and orphan their runners. These pin that both spellings match.

LIB="$ROOT/bin/fm-wake-lib.sh"

same_path() {  # <a> <b>: exit status of fm_same_path
  bash -c '. "$1"; fm_same_path "$2" "$3"' _ "$LIB" "$1" "$2"
}

canonical_path() {  # <path>
  bash -c '. "$1"; fm_canonical_path "$2"' _ "$LIB" "$1"
}

test_recorded_alias_still_matches_the_live_home() {
  local case_dir home alias_home
  case_dir="$TMP_ROOT/tolerance"
  home="$case_dir/home"
  alias_home="$case_dir/aliashome"
  mkdir -p "$home"
  ln -s home "$alias_home"

  # The record holds the alias (written before canonicalization); the live home
  # is spelled physically. They are one directory and must compare equal.
  same_path "$alias_home" "$home" \
    || fail "a home recorded under an alias no longer matches its physical spelling"
  same_path "$home" "$alias_home" \
    || fail "path matching is not symmetric between spellings"
  # Both spellings canonicalize to the one physical directory.
  [ "$(canonical_path "$alias_home")" = "$(canonical_path "$home")" ] \
    || fail "the two spellings did not canonicalize to the same directory"
  pass "a record holding the old aliased spelling still matches the live home"
}

# A durable record holds file paths as well as directory paths - the watcher
# lock's watcher-path is one - and a canonicalizer that only knows how to enter
# a directory returns a file path unchanged with no signal. That silent no-op is
# what left an aliased watcher-path in the lock, so pin both shapes here.
test_a_file_path_canonicalizes_like_a_directory_path() {
  local case_dir home alias_home
  case_dir="$TMP_ROOT/tolerance"
  home="$case_dir/home"
  alias_home="$case_dir/aliashome"
  mkdir -p "$home"
  : > "$home/record"

  [ "$(canonical_path "$alias_home/record")" = "$home/record" ] \
    || fail "a file reached through an aliased directory was not resolved"
  same_path "$alias_home/record" "$home/record" \
    || fail "a recorded file path under an alias no longer matches its physical spelling"
  pass "a file path canonicalizes and compares like a directory path"
}

test_distinct_paths_still_compare_unequal() {
  local case_dir
  case_dir="$TMP_ROOT/tolerance"
  mkdir -p "$case_dir/other"
  # Tolerance must not become "everything matches": two genuinely different
  # directories, two files sharing a parent, and a path that cannot be resolved
  # at all, all stay distinct.
  same_path "$case_dir/home" "$case_dir/other" \
    && fail "two different directories compared as the same path"
  same_path "$case_dir/home/record" "$case_dir/home/other-record" \
    && fail "two files in the same directory compared as the same path"
  same_path "$case_dir/home" "$case_dir/does-not-exist" \
    && fail "an unresolvable path matched an existing directory"
  # A final component that does not exist keeps its own spelling rather than
  # failing; only its parent resolves.
  [ "$(canonical_path "$case_dir/does-not-exist")" = "$case_dir/does-not-exist" ] \
    || fail "a path with an unresolvable final component was not returned unchanged"
  # Nothing resolvable at all still comes back exactly as given.
  [ "$(canonical_path "$case_dir/no-such-dir/no-such-file")" = "$case_dir/no-such-dir/no-such-file" ] \
    || fail "a wholly unresolvable path was not returned unchanged"
  pass "spelling tolerance does not collapse genuinely different paths"
}

# --- the watcher lock ------------------------------------------------------
#
# state/.watch.lock is a durable record too, and it holds a PAIR of paths:
# fm-home and watcher-path. fm_watcher_lock_matches_pid keys "is this watcher
# mine?" on both, so one aliased field is enough. watcher-path comes from the
# running watcher's own SCRIPT_DIR - a logical `pwd` - so a watcher armed
# through an aliased spelling of the firstmate checkout records the alias, a
# guard invoked through the other spelling then reads its own live watcher as
# down, and fm-watch-arm.sh --restart arms a second supervision cycle beside it.

WATCH_REAL="$(cd "$ROOT" && pwd -P)/bin/fm-watch.sh"

make_watch_case() {  # <name>: a state dir, a fakebin, and an aliased checkout
  local name=$1 dir state fakebin
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$state"
  fm_fake_exit0 "$fakebin" tmux
  # The watcher runs its PR-check migration before the supervision loop;
  # pre-complete it so these cases stay about the lock record.
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  # The compatibility symlink, pointed at the real firstmate checkout: running
  # bin/fm-watch.sh through it is what puts the alias in the watcher's own
  # SCRIPT_DIR.
  ln -s "$ROOT" "$dir/aliasroot"
  WATCH_CASE_DIR=$dir
  WATCH_CASE_STATE=$state
  WATCH_CASE_FAKEBIN=$fakebin
}

test_aliased_watcher_path_does_not_leak_into_the_watch_lock() {
  local out pid recorded i
  make_watch_case watchlock
  out="$WATCH_CASE_DIR/watch.out"
  PATH="$WATCH_CASE_FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$WATCH_CASE_DIR" \
    FM_HOME="$WATCH_CASE_DIR" FM_STATE_OVERRIDE="$WATCH_CASE_STATE" \
    FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_CASE_DIR/aliasroot/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$WATCH_CASE_STATE/.watch.lock/watcher-path" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  recorded=$(cat "$WATCH_CASE_STATE/.watch.lock/watcher-path" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -n "$recorded" ] \
    || fail "watcher never recorded a watcher-path: $(cat "$out" 2>/dev/null)"
  [ "$recorded" = "$WATCH_REAL" ] \
    || fail "watch lock did not record the resolved watcher path: $recorded"
  case "$recorded" in
    *alias*) fail "watch lock leaked an aliased spelling into a durable record: $recorded" ;;
  esac
  pass "a watcher armed through an aliased checkout records its resolved path"
}

test_recorded_alias_watcher_path_still_matches_the_live_watcher() {
  local lock pid identity err
  make_watch_case watchtolerance
  lock="$WATCH_CASE_STATE/.watch.lock"
  printf 'project=x\n' > "$WATCH_CASE_STATE/task.meta"
  # A stand-in for the live watcher process: the guard only needs a live pid
  # whose identity matches the one the lock recorded.
  sleep 60 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") \
    || fail "could not identify the stand-in watcher process"
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$WATCH_CASE_DIR" > "$lock/fm-home"
  # The single field under test, as a watcher armed before this change wrote it.
  printf '%s\n' "$WATCH_CASE_DIR/aliasroot/bin/fm-watch.sh" > "$lock/watcher-path"
  printf '%s\n' "$identity" > "$lock/pid-identity"
  touch "$WATCH_CASE_STATE/.last-watcher-beat"
  err="$WATCH_CASE_DIR/guard.err"
  # The guard runs through the physical spelling, so its own watcher path is
  # canonical while the lock's is not. A non-git FM_ROOT keeps the
  # worktree-tangle check inert, leaving stderr a pure watcher-state signal.
  # The persistent supervision model is pinned because only it asks the
  # PID-strict question that reads the lock's recorded paths; under the
  # auto-arm model the verdict is beacon freshness alone and this case would
  # assert nothing, whatever harness the suite happens to run under.
  FM_ROOT_OVERRIDE="$WATCH_CASE_DIR" FM_HOME="$WATCH_CASE_DIR" \
    FM_STATE_OVERRIDE="$WATCH_CASE_STATE" FM_GUARD_GRACE=300 \
    FM_SUPERVISION_MODEL=persistent \
    "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null \
    || fail "guard failed: $(cat "$err")"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] \
    || fail "guard disowned a live watcher whose lock held the old spelling: $(cat "$err")"
  pass "a lock holding the old aliased watcher path still matches the live watcher"
}

test_aliased_home_does_not_leak_into_project_record
test_aliased_project_argument_is_resolved
test_aliased_relative_project_argument_is_resolved
test_aliased_watcher_path_does_not_leak_into_the_watch_lock
test_recorded_alias_still_matches_the_live_home
test_a_file_path_canonicalizes_like_a_directory_path
test_distinct_paths_still_compare_unequal
test_recorded_alias_watcher_path_still_matches_the_live_watcher

echo "# all fm-path-spelling tests passed"
