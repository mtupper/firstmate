#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's leased-worktree endpoint contract.
#
# A fresh ship or scout spawn leases its pooled worktree with
# `treehouse get --lease` BEFORE it creates the endpoint, creates the endpoint
# inside that worktree, and proves the endpoint's shell is there before it types
# anything. The endpoint's own directory is what a multiplexer restores a pane
# into after a restart: on 2026-11-11 a Herdr restore brought crewmates back in
# their PRIMARY clone, because the endpoint had been created in the project and
# only a `treehouse get` subshell had entered the worktree.
#
# The proof must also survive a brand-new tmux window that transiently reports
# an unrelated stale path (seen live on some tmux/WSL setups), and an aborted
# spawn must give back a clean lease but never discard a worktree with changes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# make_settle_fakebin <dir> builds a fake tmux that logs every new-window call
# and whose `#{pane_current_path}` query returns FM_FAKE_PANE_STALE for the
# first FM_FAKE_PANE_STALE_READS calls, then FM_FAKE_PANE_PATH forever after.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  new-window) printf '%s\n' "$*" >> "$FM_FAKE_TMUX_NEW_WINDOW_LOG"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the lease treehouse hands out), and a separate real git
# repo standing in for the stale path.
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/new-window.log"
  : > "$case_dir/treehouse.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$stale_reads"
}

# assert_line <line> <file> <msg>: the exact line must be present.
assert_line() {
  grep -qxF -- "$1" "$2" || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2")"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {  # <id> [pane-path]
  local id=$1 pane_path=${2:-$WT_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_SPAWN_WORKTREE_POLLS=6 \
    FM_FAKE_TREEHOUSE_LEASE="$WT_DIR" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TMUX_NEW_WINDOW_LOG="$CASE_DIR/new-window.log" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$CASE_DIR/pane-call-count" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The endpoint is created inside the leased worktree, and a single stale first
# read is waited out rather than recorded.
test_endpoint_is_created_in_the_leased_worktree() {
  local rec id out status
  id=settle-leased-z1
  rec=$(make_settle_case settle-leased "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the endpoint shell reports its worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_line "get --lease --lease-holder fm-$id" "$CASE_DIR/treehouse.log" \
    "spawn did not lease its worktree before launch"
  assert_grep "-c $WT_DIR" "$CASE_DIR/new-window.log" \
    "the endpoint was not created inside the leased worktree"
  assert_no_grep "-c $PROJ_DIR" "$CASE_DIR/new-window.log" \
    "the endpoint was created in the primary clone"
  assert_line "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  assert_no_grep "return" "$CASE_DIR/treehouse.log" \
    "a successful spawn must keep its lease"
  pass "a fresh spawn leases its worktree, creates the endpoint inside it, and waits out a stale read"
}

# An endpoint whose shell never reports the leased worktree refuses before any
# launch and gives the clean lease back.
test_endpoint_outside_the_worktree_refuses_and_releases_the_lease() {
  local rec id out status
  id=settle-wrong-cwd-z2
  rec=$(make_settle_case settle-wrong-cwd "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn must refuse an endpoint outside its leased worktree"
  assert_contains "$out" "not its leased worktree '$WT_DIR'" "refusal did not name the leased worktree"
  assert_line "return --force $WT_DIR" "$CASE_DIR/treehouse.log" \
    "an aborted spawn did not give back its clean lease"
  assert_absent "$HOME_DIR/state/$id.meta" "an aborted spawn must not publish a task record"
  pass "an endpoint outside its leased worktree refuses before launch and releases the clean lease"
}

# An aborted spawn never discards a leased worktree that has changes.
test_aborted_spawn_keeps_a_dirty_lease() {
  local rec id out status
  id=settle-dirty-z3
  rec=$(make_settle_case settle-dirty "$id" 0)
  read_settle_record "$rec"
  printf 'unexpected\n' > "$WT_DIR/untracked.txt"

  out=$(run_settle_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "spawn must refuse an endpoint outside its leased worktree"
  assert_no_grep "return" "$CASE_DIR/treehouse.log" \
    "an aborted spawn must not return a leased worktree that has changes"
  assert_contains "$out" "stays leased" "the kept lease was not named"
  pass "an aborted spawn keeps and names a leased worktree that has changes"
}

# A treehouse that reports no worktree refuses before any endpoint exists.
test_empty_lease_refuses_before_any_endpoint() {
  local rec id out status
  id=settle-empty-lease-z4
  rec=$(make_settle_case settle-empty-lease "$id" 0)
  read_settle_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TMUX_NEW_WINDOW_LOG="$CASE_DIR/new-window.log" \
    FM_FAKE_PANE_COUNTFILE="$CASE_DIR/pane-call-count" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn must refuse when treehouse reports no lease"
  assert_contains "$out" "reported no worktree" "refusal did not explain the missing lease"
  [ ! -s "$CASE_DIR/new-window.log" ] || fail "an endpoint was created without a leased worktree"
  pass "a missing lease refuses before any endpoint is created"
}

# A lease that names the primary clone is refused and never cleaned or reset.
test_lease_of_the_primary_clone_is_refused_and_never_returned() {
  local rec id out status
  id=settle-primary-lease-z5
  rec=$(make_settle_case settle-primary-lease "$id" 0)
  read_settle_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_SPAWN_WORKTREE_POLLS=2 \
    FM_FAKE_TREEHOUSE_LEASE="$PROJ_DIR" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TMUX_NEW_WINDOW_LOG="$CASE_DIR/new-window.log" \
    FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_PANE_COUNTFILE="$CASE_DIR/pane-call-count" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn must refuse a lease that names the primary clone"
  assert_contains "$out" "did not yield an isolated worktree" "refusal did not explain the isolation failure"
  assert_no_grep "return" "$CASE_DIR/treehouse.log" "the primary clone must never be returned (cleaned and reset)"
  [ ! -s "$CASE_DIR/new-window.log" ] || fail "an endpoint was created for a non-isolated lease"
  pass "a lease that names the primary clone is refused and never cleaned"
}

test_endpoint_is_created_in_the_leased_worktree
test_endpoint_outside_the_worktree_refuses_and_releases_the_lease
test_aborted_spawn_keeps_a_dirty_lease
test_empty_lease_refuses_before_any_endpoint
test_lease_of_the_primary_clone_is_refused_and_never_returned

echo "# all fm-spawn-worktree-settle tests passed"
