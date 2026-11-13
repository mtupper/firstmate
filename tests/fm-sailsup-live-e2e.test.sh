#!/usr/bin/env bash
# Opt-in live guard for /sailsup with a REAL Claude Code under a guarded Herdr lab.
#
# The deterministic half lives in tests/fm-sailsup.test.sh. Three facts only the
# vendors can supply stay load-bearing here:
#   1. A Herdr restore resumes a Claude agent with a bare `claude --resume <id>`,
#      so the restored agent's own arguments no longer carry
#      --dangerously-skip-permissions and it runs in the account default mode.
#   2. Claude Code fires PermissionRequest when a tool-permission prompt renders,
#      which bin/fm-claude-permission-hook.sh turns into a keyed blocker.
#   3. `claude --resume <id> --dangerously-skip-permissions` continues the SAME
#      conversation in bypass mode, which bin/fm-control.sh restore-bypass relies
#      on.
# The guard spawns real Claude crewmates through bin/fm-spawn.sh, restarts the
# named lab, proves the restored crewmate is reduced, runs bin/fm-sailsup.sh
# inside a fixture session that holds the fixture home's fleet lock, and proves
# bypass mode on the same session id afterwards. A second crewmate launched in
# Claude's default permission mode proves the permission-prompt blocker. It
# spends a few tokens per run and refuses a pass that checked nothing. Refresh
# docs/verification/runtime-backends.md from its output after any Herdr or
# Claude Code upgrade.
#
# Usage:
#   FM_SAILSUP_LIVE_E2E=1 tests/fm-sailsup-live-e2e.test.sh
set -u

if [ "${FM_SAILSUP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SAILSUP_LIVE_E2E=1 to run the live /sailsup restore guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found (required by fm-spawn.sh)'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo 'not ok - claude is not installed, so the live /sailsup guard checked nothing' >&2; exit 1; }
herdr integration status 2>/dev/null | grep -Eq '^claude: (current|outdated)' \
  || { echo 'not ok - the Herdr claude integration is not installed, so Herdr cannot resume a Claude pane' >&2; exit 1; }
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)

herdr_forget_inherited_pane

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-sailsup-live)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/sl-crew" "$HOME_DIR/data/sl-ask"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf 'Delivery contract: mode=direct-PR\nLive /sailsup probe only. Remember the word HALYARD. Reply with the single word READY. Do not run any tools or commands.\n' \
  > "$HOME_DIR/data/sl-crew/brief.md"
printf 'Delivery contract: mode=direct-PR\nLive permission-prompt probe only. Use the Bash tool to run exactly: touch sailsup-probe.txt\n' \
  > "$HOME_DIR/data/sl-ask/brief.md"
fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$PROJ.origin.git"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name sailsup-live)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
WTS=()
cleanup() {
  local status=$? wt
  for wt in "${WTS[@]:+${WTS[@]}}"; do
    (cd "$PROJ" && treehouse return --force "$wt") >/dev/null 2>&1 || true
  done
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT

provision() {
  (cd "$HOME" && env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION") \
    || fail 'could not provision the named lab'
}
provision

# Route the production adapter through the lab helper, exactly like
# tests/fm-herdr-restore-identity-live-e2e.test.sh.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
# A fixture session process: a bash symlink named claude, so the fleet-lock
# ancestry check finds a Claude harness that holds THIS fixture home's lock.
mkdir -p "$FAKEBIN/session" && ln -s /bin/bash "$FAKEBIN/session/claude"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab_screen() { lab pane read "$1" --source visible 2>/dev/null; }
fm() {  # <script> <args...>: a firstmate script against the fixture home and lab
  local script=$1
  shift
  env -u FM_STATE_OVERRIDE PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/$script" "$@"
}

# run_sailsup <out>: run /sailsup inside a fixture session. The claude-named bash
# records its own pid as the fixture home's fleet-lock holder, then runs
# bin/fm-sailsup.sh as its child, exactly like a primary session does.
run_sailsup() {  # <out>
  # shellcheck disable=SC2016 # expands inside the fixture session
  env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" ROOT="$ROOT" OUT="$1" \
    "$FAKEBIN/session/claude" -c 'echo $$ > "$FM_HOME/state/.lock"; "$ROOT/bin/fm-sailsup.sh" > "$OUT" 2>&1; echo "rc=$?" >> "$OUT"'
}

accept_dialog() {
  local screen tries=0
  screen=$(lab_screen "$1")
  case "$screen" in *"Enter to confirm"*) ;; *) return 0 ;; esac
  case "$screen" in *"Yes, I trust this folder"*|*"Yes, I accept"*) ;; *) return 0 ;; esac
  while [ "$tries" -lt 4 ]; do
    case "$screen" in
      *"❯ Yes"*|*"❯ 2."*) lab pane send-keys "$1" enter >/dev/null 2>&1; return 0 ;;
    esac
    lab pane send-keys "$1" down >/dev/null 2>&1
    sleep 0.8
    screen=$(lab_screen "$1")
    tries=$((tries + 1))
  done
}

spawn() {  # <id> <fm-spawn args...>
  local id=$1
  shift
  fm fm-spawn.sh "$id" "$@" > "$TMP_ROOT/spawn-$id.out" 2>&1 \
    || fail "spawn of $id failed"$'\n'"$(cat "$TMP_ROOT/spawn-$id.out")"
  WTS+=("$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")")
}

# --- 1. a fresh launch runs in bypass mode ------------------------------------
spawn sl-crew "$PROJ" --mode direct-PR --yolo off --backend herdr --harness claude --model haiku
CREW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/sl-crew.meta")
[ -n "$CREW_PANE" ] || fail 'spawn did not record the crewmate pane'
crew_ready() { accept_dialog "$CREW_PANE"; lab_screen "$CREW_PANE" | grep -q 'READY'; }
fm_test_wait_until --seconds 180 crew_ready || fail "the live crewmate never answered (claude $CLAUDE_VERSION)"
fresh=$(fm fm-permission-mode.sh task sl-crew)
case "$fresh" in bypass*) ;; *) fail "a fresh fm-spawn launch did not read as bypass: $fresh" ;; esac
pass "live: a fresh Claude launch reads as bypass mode ($fresh)"
sleep 8

# --- 2. a restore leaves it reduced, and session start says so ----------------
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the lab for the restore'
provision
crew_reduced() { fm fm-permission-mode.sh task sl-crew | grep -q '^reduced session='; }
fm_test_wait_until --seconds 120 crew_reduced \
  || fail "the restored crewmate never read as reduced: $(fm fm-permission-mode.sh task sl-crew) ($HERDR_VERSION, claude $CLAUDE_VERSION)"
reduced=$(fm fm-permission-mode.sh task sl-crew)
SESSION=${reduced#*session=}
case "$SESSION" in none|'') fail "the restored crewmate's arguments carry no session id: $reduced" ;; esac
scan=$(fm fm-permission-mode.sh scan)
assert_contains "$scan" "PERMISSION_MODE: reduced sl-crew kind=ship session=$SESSION" 'the session-start scan names the restored worker'
crew_redrawn() { lab_screen "$CREW_PANE" | grep -q 'READY'; }
fm_test_wait_until --seconds 60 crew_redrawn || fail 'the restored crewmate never redrew its conversation'
sleep 3
! lab_screen "$CREW_PANE" | grep -q 'bypass permissions on' || fail 'the restored crewmate still shows bypass permissions'
pass "live: a Herdr restore resumes the worker below bypass mode and the scan reports it ($reduced)"

# --- 3. /sailsup restores bypass mode on the same conversation ----------------
SAILSUP_OUT="$TMP_ROOT/sailsup.out"
run_sailsup "$SAILSUP_OUT"
grep -q '^rc=0$' "$SAILSUP_OUT" || fail "fm-sailsup did not succeed"$'\n'"$(cat "$SAILSUP_OUT")"
assert_contains "$(cat "$SAILSUP_OUT")" 'SAILSUP: sl-crew restored to bypass mode' 'sailsup reports the restored worker'
after=$(fm fm-permission-mode.sh task sl-crew)
[ "$after" = "bypass session=$SESSION" ] || fail "after /sailsup the worker reads '$after', not bypass on session $SESSION"
crew_bypass_footer() { lab_screen "$CREW_PANE" | grep -q 'bypass permissions on'; }
fm_test_wait_until --seconds 30 crew_bypass_footer || fail 'the resumed worker does not show bypass permissions on'
lab_screen "$CREW_PANE" | grep -q 'READY' || fail 'the resumed worker does not show its earlier conversation'
record=$(sed -n 's/^SAILSUP_RECORD: //p' "$SAILSUP_OUT")
grep -q '^worker=sl-crew kind=ship before=reduced outcome=restored$' "$record" \
  || fail "the approval record does not show the restored worker: $(cat "$record")"
pass "live: /sailsup resumed the same Claude session $SESSION in bypass mode ($HERDR_VERSION, claude $CLAUDE_VERSION)"

# --- 4. a worker parked on a permission prompt becomes a keyed blocker --------
# shellcheck disable=SC2016 # the raw launch command expands in the agent pane
spawn sl-ask "$PROJ" --mode direct-PR --yolo off --backend herdr \
  --harness 'claude --permission-mode default --model haiku "$(cat '"$HOME_DIR"'/data/sl-ask/brief.md)"'
ASK_PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/sl-ask.meta")
ask_blocked() { accept_dialog "$ASK_PANE"; grep -q '^blocked: \[key=permission-prompt\]' "$HOME_DIR/state/sl-ask.status" 2>/dev/null; }
fm_test_wait_until --seconds 180 ask_blocked \
  || fail "a worker parked on a permission prompt raised no keyed blocker (claude $CLAUDE_VERSION)"$'\n'"$(lab_screen "$ASK_PANE" | tail -15)"
line=$(grep '^blocked: \[key=permission-prompt\]' "$HOME_DIR/state/sl-ask.status")
assert_contains "$line" '/sailsup' 'the reduced-mode blocker names /sailsup'
lab_screen "$ASK_PANE" | grep -q 'Do you want to proceed' || fail 'the blocker fired without a visible permission prompt'
[ ! -e "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/sl-ask.meta")/sailsup-probe.txt" ] || fail 'the hook let the tool run without an answer'
pass "live: a parked permission prompt became a keyed blocker naming /sailsup ($line)"

# --- 5. /sailsup restores a restored worker parked mid-turn on a prompt -------
# A fixture-only settings key makes the restored worker resume in Claude's
# default mode on any account, so it parks on its next Bash call. The product
# never writes this key: firstmate deliberately carries no permission setting
# across a restore.
ASK_WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/sl-ask.meta")
if ! jq '.permissions = {"defaultMode": "default"}' "$ASK_WT/.claude/settings.local.json" > "$TMP_ROOT/ask-settings.json" \
  || ! mv "$TMP_ROOT/ask-settings.json" "$ASK_WT/.claude/settings.local.json"; then
  fail 'could not pin the fixture default mode'
fi
sleep 5
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the lab for the second restore'
provision
ask_resumed() { fm fm-permission-mode.sh task sl-ask | grep -q '^reduced session=[0-9a-f]'; }
fm_test_wait_until --seconds 120 ask_resumed \
  || fail "the restored prompt worker never read as reduced with a session: $(fm fm-permission-mode.sh task sl-ask)"
ASK_SESSION=$(fm fm-permission-mode.sh task sl-ask)
ASK_SESSION=${ASK_SESSION#*session=}
sleep 8
lab pane run "$ASK_PANE" "Use the Bash tool to run exactly: touch sailsup-parked.txt" >/dev/null 2>&1 \
  || fail 'could not prompt the restored worker'
ask_parked() {
  [ "$(grep -c '^blocked: \[key=permission-prompt\]' "$HOME_DIR/state/sl-ask.status" 2>/dev/null)" -ge 2 ] \
    && lab_screen "$ASK_PANE" | grep -q 'Do you want to proceed'
}
fm_test_wait_until --seconds 120 ask_parked \
  || fail "the restored worker did not park on a permission prompt"$'\n'"$(lab_screen "$ASK_PANE" | tail -15)"
grep -q '^resolved: \[key=permission-prompt\]' "$HOME_DIR/state/sl-ask.status" \
  || fail 'the earlier permission blocker was not resolved by the next prompt'
SAILSUP_OUT2="$TMP_ROOT/sailsup2.out"
run_sailsup "$SAILSUP_OUT2"
grep -q '^rc=0$' "$SAILSUP_OUT2" || fail "fm-sailsup did not succeed for the parked worker"$'\n'"$(cat "$SAILSUP_OUT2")"
assert_contains "$(cat "$SAILSUP_OUT2")" 'SAILSUP: sl-ask restored to bypass mode' 'sailsup restores the parked worker'
# The second restart reduced the first worker again: an earlier /sailsup never
# carries over a restore, so this one restores it again.
assert_contains "$(cat "$SAILSUP_OUT2")" 'SAILSUP: sl-crew restored to bypass mode' 'a later restore needs, and gets, a new restore'
[ "$(fm fm-permission-mode.sh task sl-ask)" = "bypass session=$ASK_SESSION" ] \
  || fail "the parked worker did not come back in bypass mode on session $ASK_SESSION: $(fm fm-permission-mode.sh task sl-ask)"
parked_done() { [ -e "$ASK_WT/sailsup-parked.txt" ]; }
fm_test_wait_until --seconds 120 parked_done \
  || fail "the resumed worker did not continue its interrupted task in bypass mode"$'\n'"$(lab_screen "$ASK_PANE" | tail -15)"
[ ! -e "$HOME_DIR/state/sl-ask.permission-wait" ] || fail 'the permission-wait marker outlived the restored worker'
pass "live: /sailsup declined the parked prompt, resumed session $ASK_SESSION in bypass mode, and the worker finished its turn"
