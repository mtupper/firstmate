#!/usr/bin/env bash
# /sailsup: reading a Claude worker's live permission mode, surfacing a parked
# permission prompt, and restoring bypass mode only under the captain's
# per-session approval.
#
# Hermetic: a stubbed tmux session provider and a stubbed process table stand in
# for the panes and agents, and a bash symlink named claude stands in for the
# firstmate session that holds the fixture home's fleet lock. The live half, with
# a real Claude Code and a real Herdr restore, is
# tests/fm-sailsup-live-e2e.test.sh.
#
#   1. Detection reads the live process arguments: a fresh launch is bypass, a
#      bare restore is reduced with its session id, and anything unreadable is
#      unknown, never safe.
#   2. The session-start scan is silent when every worker is at its launch mode
#      and names each reduced or unknown worker otherwise.
#   3. The permission hook turns one parked prompt into one keyed blocker that
#      names /sailsup, resolves it at the next prompt, and never writes stdout.
#   4. restore-bypass continues the same session in bypass mode, notes an
#      interrupted turn, and verifies the result.
#   5. Nothing restores bypass mode without an approval from the current
#      session, outside away mode, covering that worker.
#   6. /sailsup records every outcome, forwards the approval to secondmates, and
#      a secondmate acts only on a fresh parent approval forwarded to it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sailsup)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

REAL_PS=$(command -v ps)
SID_A=0caf573c-fe40-4108-98e5-aae323589297
SID_B=7eb22333-7117-4f55-893a-df7c6bd4d7d8

# make_stubs <dir>: a tmux whose panes are files under <dir>/fake, and a ps
# whose per-pane process table comes from the same files. Each window W has a
# tty named tty-W, a foreground table procs.W ("pid pgid tpgid comm"), and one
# args.<pid> file per process. Submitting the exit command leaves a bare shell;
# typing a claude --resume launch starts a claude whose arguments carry the
# bypass flag and that session, unless FM_FAKE_RESUME_DROPS_FLAG is set.
make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb" "$1/session"
  ln -s /bin/bash "$1/session/claude"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
cmd=${1:-}
shift || true
target=
literal=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -t) target=$2; shift 2 ;;
    -l) literal=1; shift ;;
    -p) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
w=${target#*:}
case "$cmd" in
  send-keys)
    payload=${args[0]:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit)
          printf 'zsh' > "$D/cmd.$w"
          printf '800100 800100 800100 zsh\n' > "$D/procs.$w"
          printf 'zsh\n' > "$D/args.800100"
          ;;
        *claude*--resume*)
          sid=$(printf '%s' "$payload" | sed -n "s/.*--resume '\([0-9a-f-]*\)'.*/\1/p")
          line="claude"
          [ -n "${FM_FAKE_RESUME_DROPS_FLAG:-}" ] || line="$line --dangerously-skip-permissions"
          line="$line --resume $sid"
          case "$payload" in *'encode launch-brief'*) line="$line NOTE" ;; esac
          printf 'claude' > "$D/cmd.$w"
          printf '800200 800200 800200 claude\n' > "$D/procs.$w"
          printf '%s\n' "$line" > "$D/args.800200"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        "cd -- '"*"'") t=${payload#cd -- \'}; printf '%s' "${t%\'}" > "$D/cwd" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "${args[@]}"; do
      case "$a" in
        *pane_tty*) printf 'tty-%s\n' "$w"; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/cmd.$w" 2>/dev/null; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$D/windows" 2>/dev/null; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/ps" <<SH
#!/usr/bin/env bash
D=\${FM_FAKE_DIR:-/nonexistent}
prev=; tty=; pid=
for a in "\$@"; do
  [ "\$prev" = -t ] && tty=\$a
  [ "\$prev" = -p ] && pid=\$a
  prev=\$a
done
case "\$tty" in
  tty-*) cat "\$D/procs.\${tty#tty-}" 2>/dev/null; exit 0 ;;
esac
if [ -n "\$pid" ] && [ -f "\$D/args.\$pid" ]; then
  case " \$* " in
    *args=*) cat "\$D/args.\$pid"; exit 0 ;;
    *comm=*) awk -v p="\$pid" '\$1 == p { print \$4 }' "\$D"/procs.* 2>/dev/null | head -1; exit 0 ;;
  esac
fi
exec $REAL_PS "\$@"
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/ps" "$fb/sleep"
}

# new_case <name>: an empty home plus stubs. Echoes the case dir.
new_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/windows"
  make_stubs "$dir"
  printf '%s\n' "$dir"
}

# add_worker <dir> <id> <pid> <argv> [kind] [harness]: a recorded Claude worker
# whose live agent runs with <argv>. An empty <argv> means a bare shell pane.
add_worker() {  # <dir> <id> <pid> <argv> [kind] [harness]
  local dir=$1 id=$2 pid=$3 argv=$4 kind=${5:-ship} harness=${6:-claude} wt
  wt="$dir/wt-$id"
  if [ "$kind" = secondmate ]; then
    mkdir -p "$wt/state"
    printf '%s\n' "$id" > "$wt/.fm-secondmate-home"
    git init -q "$wt" && git -C "$wt" commit -q --allow-empty -m init
  else
    if [ -d "$dir/proj/.git" ]; then
      git -C "$dir/proj" worktree add --quiet -b "task-$id" "$wt"
    else
      fm_git_worktree "$dir/proj" "$wt" "task-$id"
    fi
    mkdir -p "$dir/home/data/$id"
    printf 'Delivery contract: mode=direct-PR\nDo the thing.\n' > "$dir/home/data/$id/brief.md"
  fi
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$dir/proj" \
    "harness=$harness" "kind=$kind" "mode=direct-PR" "yolo=off" "tasktmp=$dir/tmp-$id" \
    "model=default" "effort=default" "home=$wt"
  printf 'fm-%s\n' "$id" >> "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  if [ -n "$argv" ]; then
    printf '%s %s %s %s\n' "$pid" "$pid" "$pid" "${argv%% *}" > "$dir/fake/procs.fm-$id"
    printf '%s\n' "$argv" > "$dir/fake/args.$pid"
    printf '%s' "${argv%% *}" > "$dir/fake/cmd.fm-$id"
  else
    printf '%s %s %s zsh\n' "$pid" "$pid" "$pid" > "$dir/fake/procs.fm-$id"
    printf 'zsh\n' > "$dir/fake/args.$pid"
    printf 'zsh' > "$dir/fake/cmd.fm-$id"
  fi
}

fixture_env() {  # <dir>: the environment every fixture command runs in
  printf '%s\n' "PATH=$1/fakebin:$PATH" "FM_HOME=$1/home" "FM_FAKE_DIR=$1/fake" \
    "FM_SPAWN_NO_GUARD=1" "GROK_HOME=$1/grokhome" "FM_CONTROL_POLL=0.01" \
    "FM_CONTROL_EXIT_WAIT=0.2" "FM_CONTROL_LAUNCH_WAIT=0.2"
}

run_fm() {  # <dir> <script> <args...>: outside any session
  local dir=$1 script=$2 envs=()
  shift 2
  while IFS= read -r line; do envs+=("$line"); done < <(fixture_env "$dir")
  env -u FM_STATE_OVERRIDE -u CLAUDECODE "${envs[@]}" "$ROOT/bin/$script" "$@" 2>&1
}

# run_in_session <dir> <script> <args...>: inside a fresh fixture session, which
# holds the fixture home's fleet lock exactly as a firstmate primary does. Each
# call is a new session. When FM_RECORD_WORKERS names workers, the session
# first writes an approval record covering them, bound to its own identity, at
# state/sailsup/sailsup-test.approval - the shape bin/fm-sailsup.sh writes.
run_in_session() {  # <dir> <script> <args...>
  local dir=$1 script=$2 envs=()
  shift 2
  while IFS= read -r line; do envs+=("$line"); done < <(fixture_env "$dir")
  # shellcheck disable=SC2016 # expands inside the fixture session
  env -u FM_STATE_OVERRIDE -u CLAUDECODE "${envs[@]}" FM_SCRIPT="$ROOT/bin/$script" ROOT="$ROOT" \
    FM_RECORD_WORKERS="${FM_RECORD_WORKERS:-}" \
    "$dir/session/claude" -c '
      echo $$ > "$FM_HOME/state/.lock"
      if [ -n "$FM_RECORD_WORKERS" ]; then
        . "$ROOT/bin/fm-session-lock-lib.sh"; . "$ROOT/bin/fm-sailsup-lib.sh"
        mkdir -p "$FM_HOME/state/sailsup"
        { echo v1; echo approval=sailsup-test
          echo "session=$(fm_sailsup_session_id "$FM_HOME/state")"; echo invoked_by=captain
          for w in $FM_RECORD_WORKERS; do echo "worker=$w kind=ship before=reduced outcome=pending"; done
        } > "$FM_HOME/state/sailsup/sailsup-test.approval"
      fi
      # Not the last command, so bash never execs it in place of the session.
      "$FM_SCRIPT" "$@"; rc=$?; exit "$rc"' fm-session "$@" 2>&1
}

# session_record <dir> [session]: a hand-made approval record naming every
# argument worker, bound to <session> (default: the fixture session's identity).
session_record() {  # <dir> <session> <worker>...
  local dir=$1 session=$2 rec
  shift 2
  mkdir -p "$dir/home/state/sailsup"
  rec="$dir/home/state/sailsup/sailsup-test.approval"
  { echo v1; echo approval=sailsup-test; echo "session=$session"; echo invoked_by=captain
    for w in "$@"; do echo "worker=$w kind=ship before=reduced outcome=pending"; done
  } > "$rec"
  printf '%s\n' "$rec"
}

# current_session <dir>: the fixture session's identity, as the lib computes it.
current_session() {  # <dir>
  local dir=$1 envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(fixture_env "$dir")
  # shellcheck disable=SC2016 # expands inside the fixture session
  env -u FM_STATE_OVERRIDE -u CLAUDECODE "${envs[@]}" ROOT="$ROOT" "$dir/session/claude" -c '
    echo $$ > "$FM_HOME/state/.lock"
    . "$ROOT/bin/fm-session-lock-lib.sh"; . "$ROOT/bin/fm-sailsup-lib.sh"
    fm_sailsup_session_id "$FM_HOME/state"' 2>/dev/null
}

# --- 1. detection --------------------------------------------------------------

test_detection_reads_live_arguments() {
  local dir out
  dir=$(new_case detect)
  add_worker "$dir" fresh 900101 "claude --dangerously-skip-permissions --effort high FIRSTMATE_OP: v1 launch-brief: do the thing"
  add_worker "$dir" restored 900102 "claude --resume $SID_A"
  add_worker "$dir" pmode 900103 "claude --permission-mode bypassPermissions --resume=$SID_B"
  add_worker "$dir" conflict 900104 "claude --dangerously-skip-permissions --permission-mode default"
  add_worker "$dir" prompt 900105 "claude explain --dangerously-skip-permissions please"
  add_worker "$dir" shell 900106 ""
  add_worker "$dir" other 900107 "codex --dangerously-bypass-approvals-and-sandbox" ship codex
  out=$(run_fm "$dir" fm-permission-mode.sh task fresh)
  [ "$out" = "bypass session=none" ] || fail "a fresh bypass launch should read bypass, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task restored)
  [ "$out" = "reduced session=$SID_A" ] || fail "a bare restore should read reduced with its session, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task pmode)
  [ "$out" = "bypass session=$SID_B" ] || fail "--permission-mode bypassPermissions should read bypass, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task conflict)
  [ "$out" = "reduced session=none" ] || fail "an explicit non-bypass --permission-mode must win, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task prompt)
  [ "$out" = "reduced session=none" ] || fail "a flag inside the prompt must not count, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task shell)
  [ "$out" = "n/a reason=no-agent" ] || fail "an agent-free pane is not a worker, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task other)
  [ "$out" = "n/a reason=harness-codex" ] || fail "a non-Claude worker is out of scope, got '$out'"
  pass "detection: the verdict comes from the live agent's own arguments"
}

test_detection_reports_unknown_never_safe() {
  local dir out
  dir=$(new_case unknown)
  add_worker "$dir" twin 900201 "claude --dangerously-skip-permissions"
  printf '900202 900201 900201 claude\n' >> "$dir/fake/procs.fm-twin"
  printf 'claude --dangerously-skip-permissions\n' > "$dir/fake/args.900202"
  add_worker "$dir" remote 900203 "claude --dangerously-skip-permissions"
  printf 'remote_host=box\n' >> "$dir/home/state/remote.meta"
  add_worker "$dir" zj 900204 "claude --dangerously-skip-permissions"
  printf 'backend=zellij\n' >> "$dir/home/state/zj.meta"
  out=$(run_fm "$dir" fm-permission-mode.sh task twin)
  [ "$out" = "unknown reason=argv-unreadable" ] || fail "two claude processes must not be attributed, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task remote)
  [ "$out" = "unknown reason=remote-host" ] || fail "a remote secondmate cannot be read here, got '$out'"
  out=$(run_fm "$dir" fm-permission-mode.sh task zj)
  case "$out" in unknown*) ;; *) fail "a backend without an argument reader must be unknown, got '$out'" ;; esac
  pass "detection: an unreadable worker is unknown, never safe"
}

# --- 2. the session-start scan -------------------------------------------------

test_scan_is_silent_when_every_worker_is_at_launch_mode() {
  local dir out
  dir=$(new_case quiet)
  add_worker "$dir" good 900301 "claude --dangerously-skip-permissions"
  add_worker "$dir" idle 900302 ""
  fm_write_meta "$dir/home/state/released.meta" "harness=claude" "kind=ship"
  out=$(run_fm "$dir" fm-permission-mode.sh scan)
  [ -z "$out" ] || fail "the scan must stay silent when no worker runs below launch mode, got: $out"
  out=$(run_fm "$dir" fm-permission-mode.sh scan --all)
  assert_contains "$out" "PERMISSION_MODE_OK: good kind=ship bypass" "--all names verified bypass workers"
  pass "scan: silent when every worker runs at its launch mode"
}

test_scan_names_reduced_and_unknown_workers() {
  local dir out
  dir=$(new_case loud)
  add_worker "$dir" good 900401 "claude --dangerously-skip-permissions"
  add_worker "$dir" mate 900402 "claude --resume $SID_A" secondmate
  add_worker "$dir" lost 900403 "claude --dangerously-skip-permissions"
  printf 'remote_host=box\n' >> "$dir/home/state/lost.meta"
  out=$(run_fm "$dir" fm-permission-mode.sh scan)
  assert_contains "$out" "PERMISSION_MODE: reduced mate kind=secondmate session=$SID_A" "a restored secondmate is named"
  assert_contains "$out" "PERMISSION_MODE: unknown lost kind=ship reason=remote-host" "an unreadable worker is named as unknown"
  assert_not_contains "$out" "good" "a bypass worker is not named"
  pass "scan: names each reduced or unknown worker with its session"
}

# --- 3. the permission-prompt hook ---------------------------------------------

test_permission_hook_raises_and_resolves_one_keyed_blocker() {
  local state="$TMP_ROOT/hook/state" out hook="$ROOT/bin/fm-claude-permission-hook.sh"
  mkdir -p "$state"
  out=$(printf '{"permission_mode":"auto","tool_name":"Bash"}' | "$hook" request "$state" w1)
  [ -z "$out" ] || fail "the hook must print nothing, because hook stdout can answer the prompt; got '$out'"
  printf '{"permission_mode":"auto","tool_name":"Bash"}' | "$hook" request "$state" w1 >/dev/null
  [ "$(grep -c '^blocked: \[key=permission-prompt\]' "$state/w1.status")" = 1 ] \
    || fail "one parked prompt must produce exactly one blocker"$'\n'"$(cat "$state/w1.status")"
  assert_grep "auto permission mode, below its launch bypass mode, so the captain's /sailsup" "$state/w1.status" \
    "a reduced-mode blocker names /sailsup"
  "$hook" clear "$state" w1 </dev/null
  assert_grep 'resolved: [key=permission-prompt]' "$state/w1.status" "the next prompt resolves the blocker"
  assert_absent "$state/w1.permission-wait" "the marker is gone after clear"
  "$hook" clear "$state" w1 </dev/null
  [ "$(grep -c '^resolved:' "$state/w1.status")" = 1 ] || fail "clear without a parked prompt must not touch the status log"
  printf '{"permission_mode":"bypassPermissions","tool_name":"Edit"}' | "$hook" request "$state" w2
  assert_not_contains "$(cat "$state/w2.status")" "/sailsup" "a bypass-mode prompt does not point at /sailsup"
  assert_grep "even in bypass mode" "$state/w2.status" "a bypass-mode prompt is still surfaced"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  status_is_captain_relevant "$(head -1 "$state/w2.status")" || fail "the blocker must be captain-relevant to the classifier"
  pass "permission hook: one keyed captain-relevant blocker per parked prompt, resolved at the next prompt"
}

test_spawn_wires_the_permission_hook() {
  local dir out wt settings
  dir=$(new_case wiring)
  add_worker "$dir" wired 900501 "claude --dangerously-skip-permissions"
  printf 'zsh' > "$dir/fake/cmd.fm-wired"
  printf '900501 900501 900501 zsh\n' > "$dir/fake/procs.fm-wired"
  printf 'zsh\n' > "$dir/fake/args.900501"
  out=$(run_fm "$dir" fm-spawn.sh wired --relaunch --harness claude)
  expect_code 0 "$?" "relaunch failed: $out"
  wt="$dir/wt-wired"
  settings="$wt/.claude/settings.local.json"
  jq -e '.hooks.PermissionRequest[0].hooks[0].command | contains("fm-claude-permission-hook.sh") and contains(" request ")' "$settings" >/dev/null \
    || fail "a Claude worktree must carry the PermissionRequest hook: $(cat "$settings")"
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | contains("fm-claude-permission-hook.sh") and contains(" clear ")' "$settings" >/dev/null \
    || fail "the next prompt must clear a parked-prompt blocker"
  jq -e '.hooks.Stop[0].hooks[0].command | contains(" clear ")' "$settings" >/dev/null \
    || fail "a turn end must clear a parked-prompt blocker"
  jq -e '.permissions == null' "$settings" >/dev/null \
    || fail "firstmate must carry no permission setting across a restore"
  pass "spawn: a Claude worktree carries the permission-prompt hooks and no permission carrier"
}

# --- 4. restore-bypass ----------------------------------------------------------

test_restore_bypass_continues_the_same_session() {
  local dir out rec
  dir=$(new_case restore)
  add_worker "$dir" r1 900601 "claude --resume $SID_A"
  rec="$dir/home/state/sailsup/sailsup-test.approval"
  out=$(FM_RECORD_WORKERS=r1 run_in_session "$dir" fm-control.sh r1 restore-bypass --approval "$rec")
  expect_code 0 "$?" "restore-bypass should succeed"$'\n'"$out"
  assert_contains "$out" "bypass-restored r1 session=$SID_A interrupted-turn=no" "the outcome names the same session"
  assert_grep 'Escape' "$dir/fake/keys" "one interrupt declines any parked prompt before exit"
  assert_grep '/exit' "$dir/fake/literal" "the reduced agent is exited"
  assert_grep "claude --dangerously-skip-permissions --resume '$SID_A'" "$dir/fake/literal" \
    "the same session resumes with the bypass flag"
  assert_no_grep "encode launch-brief < '$dir/home/data/r1/brief.md'" "$dir/fake/literal" \
    "the brief must not be replayed into a continued conversation"
  [ "$(run_fm "$dir" fm-permission-mode.sh task r1)" = "bypass session=$SID_A" ] || fail "the worker must read bypass afterwards"
  pass "restore-bypass: the same Claude session resumes in bypass mode"
}

test_restore_bypass_notes_an_interrupted_turn() {
  local dir out rec
  dir=$(new_case busy)
  add_worker "$dir" b1 900701 "claude --resume $SID_A"
  printf 'mode=auto\n' > "$dir/home/state/b1.permission-wait"
  rec="$dir/home/state/sailsup/sailsup-test.approval"
  out=$(FM_RECORD_WORKERS=b1 run_in_session "$dir" fm-control.sh b1 restore-bypass --approval "$rec")
  expect_code 0 "$?" "restore-bypass of a parked worker should succeed"$'\n'"$out"
  assert_contains "$out" "interrupted-turn=yes" "a parked worker's turn was interrupted"
  assert_grep "encode launch-brief < '$dir/home/state/b1.control-relaunch.note'" "$dir/fake/literal" \
    "the resumed worker is told to continue"
  assert_grep "Continue your task" "$dir/home/state/b1.control-relaunch.note" "the note says to continue"
  assert_absent "$dir/home/state/b1.permission-wait" "the parked-prompt marker is cleared"
  assert_grep 'resolved: [key=permission-prompt]' "$dir/home/state/b1.status" "the parked-prompt blocker is resolved"
  pass "restore-bypass: a parked worker is interrupted, resumed in bypass mode, and told to continue"
}

test_restore_bypass_fails_when_bypass_is_not_proven() {
  local dir out rec rc
  dir=$(new_case unproven)
  add_worker "$dir" u1 900801 "claude --resume $SID_A"
  rec="$dir/home/state/sailsup/sailsup-test.approval"
  out=$(FM_FAKE_RESUME_DROPS_FLAG=1 FM_RECORD_WORKERS=u1 run_in_session "$dir" fm-control.sh u1 restore-bypass --approval "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "a resume that did not prove bypass mode must fail"$'\n'"$out"
  assert_contains "$out" "do not prove bypass mode" "the failure names the missing proof"
  pass "restore-bypass: an unproven bypass mode is a failure, not a success"
}

# --- 5. refusals ----------------------------------------------------------------

test_restore_bypass_refusals() {
  local dir out rc rec session
  dir=$(new_case refuse)
  add_worker "$dir" f1 900901 "claude --resume $SID_A"
  add_worker "$dir" f2 900902 "claude --resume $SID_B"
  add_worker "$dir" f3 900903 "claude --continue"
  rec="$dir/home/state/sailsup/sailsup-test.approval"

  out=$(run_in_session "$dir" fm-control.sh f1 restore-bypass); rc=$?
  [ "$rc" -ne 0 ] || fail "restore-bypass without an approval must refuse"
  assert_contains "$out" "requires --approval" "no approval, no restore"

  # An approval made in one session, presented by the next one.
  session=$(current_session "$dir")
  [ -n "$session" ] || fail "the fixture session must have an identity"
  session_record "$dir" "$session" f1 >/dev/null
  out=$(run_in_session "$dir" fm-control.sh f1 restore-bypass --approval "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "an earlier session's approval must refuse"
  assert_contains "$out" "belongs to an earlier session" "an earlier session's approval never carries over"

  out=$(run_fm "$dir" fm-control.sh f1 restore-bypass --approval "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "a process outside the lock-holding session must refuse"
  assert_contains "$out" "not running inside the session" "only the approving session may act"

  out=$(FM_RECORD_WORKERS=f1 run_in_session "$dir" fm-control.sh f2 restore-bypass --approval "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "a worker the approval does not name must refuse"
  assert_contains "$out" "does not cover task f2" "an approval covers only the workers it names"

  : > "$dir/home/state/.afk"
  out=$(FM_RECORD_WORKERS=f1 run_in_session "$dir" fm-control.sh f1 restore-bypass --approval "$rec"); rc=$?
  rm -f "$dir/home/state/.afk"
  [ "$rc" -ne 0 ] || fail "away mode must refuse"
  assert_contains "$out" "away mode never grants /sailsup" "away mode never grants it"

  out=$(FM_RECORD_WORKERS=f3 run_in_session "$dir" fm-control.sh f3 restore-bypass --approval "$rec"); rc=$?
  [ "$rc" -ne 0 ] || fail "a reduced worker with no session id must refuse"
  assert_contains "$out" "no resumable session id" "an unresumable worker is refused, not relaunched fresh"

  out=$(FM_RECORD_WORKERS=f1 run_in_session "$dir" fm-control.sh f1 restore-bypass --approval "$rec" --note x); rc=$?
  [ "$rc" -ne 0 ] || fail "restore-bypass must refuse relaunch axes"
  assert_no_grep '/exit' "$dir/fake/literal" "no refusal may touch an agent"
  pass "restore-bypass: refuses without a current-session approval covering the worker, under away mode, or without a session"
}

test_sailsup_refuses_outside_the_session_and_under_away_mode() {
  local dir out rc
  dir=$(new_case sailsup-refuse)
  add_worker "$dir" s1 901001 "claude --resume $SID_A"
  out=$(run_fm "$dir" fm-sailsup.sh); rc=$?
  expect_code 2 "$rc" "sailsup outside the lock-holding session must refuse"$'\n'"$out"
  assert_contains "$out" "is the captain's approval for that session only" "the refusal names the session scope"
  : > "$dir/home/state/.afk"
  out=$(run_in_session "$dir" fm-sailsup.sh); rc=$?
  rm -f "$dir/home/state/.afk"
  expect_code 2 "$rc" "sailsup under away mode must refuse"$'\n'"$out"
  assert_absent "$dir/home/state/sailsup" "a refused /sailsup writes no approval record"
  assert_no_grep '/exit' "$dir/fake/literal" "a refused /sailsup touches no agent"
  pass "sailsup: refuses outside the lock-holding session and under away mode"
}

# --- 6. /sailsup orchestration --------------------------------------------------

test_sailsup_restores_records_and_forwards() {
  local dir out rc rec
  dir=$(new_case sailsup)
  add_worker "$dir" crew 901101 "claude --resume $SID_A"
  add_worker "$dir" good 901102 "claude --dangerously-skip-permissions"
  add_worker "$dir" stray 901103 "claude --continue"
  add_worker "$dir" pimate 901104 "pi --thinking high" secondmate pi
  out=$(run_in_session "$dir" fm-sailsup.sh); rc=$?
  rec=$(printf '%s\n' "$out" | sed -n 's/^SAILSUP_RECORD: //p')
  [ -f "$rec" ] || fail "sailsup must write its approval record"$'\n'"$out"
  assert_grep 'invoked_by=captain' "$rec" "the record names the captain's approval"
  assert_grep "session=$(cat "$dir/home/state/.lock")@" "$rec" "the record is bound to the session that ran /sailsup"
  assert_grep 'worker=crew kind=ship before=reduced outcome=restored' "$rec" "the reduced worker is restored"
  assert_grep 'worker=good kind=ship before=bypass outcome=already-bypass' "$rec" "a bypass worker is only recorded"
  assert_grep 'worker=stray kind=ship before=reduced outcome=skipped-no-session' "$rec" "an unresumable worker is recorded, not touched"
  assert_grep 'forwarded=pimate ' "$rec" "every secondmate receives the approval, whatever its own harness"
  assert_contains "$out" "SAILSUP: crew restored to bypass mode" "the summary names the restored worker"
  expect_code 1 "$rc" "an unrestored worker makes the run report failure"
  [ "$(run_fm "$dir" fm-permission-mode.sh task crew)" = "bypass session=$SID_A" ] || fail "the restored worker reads bypass"
  pass "sailsup: restores reduced workers, records every outcome, and forwards to each secondmate"
}

test_delegated_sailsup_needs_a_fresh_forwarded_parent_approval() {
  local dir parent out rc mate rec
  dir=$(new_case delegated)
  parent="$dir/parent"
  mkdir -p "$parent/state/sailsup"
  mate="$dir/home"
  printf 'helm\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  printf 'v1\napproval=sailsup-p1\nforwarded=other outcome=sent\n' > "$parent/state/sailsup/sailsup-p1.approval"
  out=$(run_in_session "$dir" fm-sailsup.sh --delegated sailsup-p1); rc=$?
  expect_code 2 "$rc" "an approval not forwarded to this secondmate must refuse"$'\n'"$out"
  assert_contains "$out" "was not forwarded to secondmate helm" "the refusal names the missing forward"
  printf 'forwarded=helm outcome=sent\n' >> "$parent/state/sailsup/sailsup-p1.approval"
  touch -t 202001010000 "$parent/state/sailsup/sailsup-p1.approval"
  out=$(run_in_session "$dir" fm-sailsup.sh --delegated sailsup-p1); rc=$?
  expect_code 2 "$rc" "a stale parent approval must refuse"$'\n'"$out"
  assert_contains "$out" "is older than" "a stale approval never carries over"
  touch "$parent/state/sailsup/sailsup-p1.approval"
  out=$(run_in_session "$dir" fm-sailsup.sh --delegated sailsup-p1); rc=$?
  expect_code 0 "$rc" "a fresh forwarded approval is accepted"$'\n'"$out"
  rec=$(printf '%s\n' "$out" | sed -n 's/^SAILSUP_RECORD: //p')
  assert_grep 'invoked_by=delegated' "$rec" "the secondmate records a delegated approval"
  assert_grep 'parent_approval=sailsup-p1' "$rec" "the secondmate records its parent's approval"
  assert_no_grep 'forwarded=' "$rec" "a secondmate never forwards further"
  pass "sailsup --delegated: acts only on a fresh parent approval forwarded to this secondmate"
}

test_detection_reads_live_arguments
test_detection_reports_unknown_never_safe
test_scan_is_silent_when_every_worker_is_at_launch_mode
test_scan_names_reduced_and_unknown_workers
test_permission_hook_raises_and_resolves_one_keyed_blocker
test_spawn_wires_the_permission_hook
test_restore_bypass_continues_the_same_session
test_restore_bypass_notes_an_interrupted_turn
test_restore_bypass_fails_when_bypass_is_not_proven
test_restore_bypass_refusals
test_sailsup_refuses_outside_the_session_and_under_away_mode
test_sailsup_restores_records_and_forwards
test_delegated_sailsup_needs_a_fresh_forwarded_parent_approval
