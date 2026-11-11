#!/usr/bin/env bash
# Real-Herdr regression for the 2026-11-11 reboot restore.
#
# After a reboot the first firstmate read of a Herdr endpoint started the server
# from inside a firstmate session, so the server kept that session's FM_HOME,
# FM_STATE_OVERRIDE, CLAUDE_PROJECT_DIR, and CLAUDE_CODE_CHILD_SESSION. Herdr
# restores each pane as a fresh shell in the pane's recorded directory and types
# the agent's resume command into it (verified live: `claude --resume <id>` as a
# child of that restored shell), so every restored agent inherited the starting
# session's identity, and a crewmate whose pane had been created in its project
# came back in the PRIMARY clone instead of its worktree.
#
# This suite reproduces that path in one guarded named lab: a server started
# from a polluted environment, a crewmate and a secondmate spawned through the
# real bin/fm-spawn.sh, a stop and restore, and then the restored shells - the
# exact environment and directory a resumed agent gets - are inspected. The
# resumed harness itself is covered by the opt-in live guard
# tests/fm-herdr-restore-identity-live-e2e.test.sh. Every Herdr call goes through
# bin/fm-herdr-lab.sh, and teardown verifies the default session is untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found (required by fm-spawn.sh)'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# The lab is its own session; this process's own Herdr pane, if any, must not
# follow spawn into it as a parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-restore-identity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN="$TMP_ROOT/fakebin"
PRIMARY="$TMP_ROOT/primary-home"
SM_HOME="$TMP_ROOT/secondmate-home"
PROJ="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$PRIMARY/state" "$PRIMARY/data/rc-crew" "$PRIMARY/config" \
  "$SM_HOME/state" "$SM_HOME/data" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$PRIMARY/config/herdr-presentation-spaces"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# lab secondmate home\n' > "$SM_HOME/AGENTS.md"
printf 'rc-mate\n' > "$SM_HOME/.fm-secondmate-home"
printf 'charter\n' > "$SM_HOME/data/charter.md"
printf 'Delivery contract: mode=direct-PR\nbrief\n' > "$PRIMARY/data/rc-crew/brief.md"
fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$PROJ.origin.git"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name restore-identity)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
WT=
cleanup() {
  local status=$?
  if [ -n "$WT" ]; then (cd "$PROJ" && treehouse return --force "$WT") >/dev/null 2>&1 || true; fi
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT

# The environment of a firstmate session that starts the server, pointed at this
# lab's own primary fixture rather than any real home.
POLLUTED=(
  FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state"
  FM_SESSION_START_STAGE_FILE="$TMP_ROOT/stage"
  CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_PROJECT_DIR="$PRIMARY"
  CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PID=4242
)
IDENTITY_NAMES='FM_HOME FM_STATE_OVERRIDE FM_SESSION_START_STAGE_FILE CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR CLAUDE_CODE_ENTRYPOINT CLAUDE_PID'

provision_polluted() {
  (cd "$PRIMARY" && env "${POLLUTED[@]}" PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION") \
    || fail 'could not provision the named lab from the polluted environment'
}
provision_polluted

# Route the production adapter through the lab helper: strip the exact trailing
# lab session pair, refuse any other session, and delegate to helper run.
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

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# proc_env_value <pid> <name>: the named variable from a live process's
# environment, or nothing.
proc_env_value() {
  if [ -r "/proc/$1/environ" ]; then
    tr '\0' '\n' < "/proc/$1/environ" | sed -n "s/^$2=//p" | head -1
  else
    ps -E -ww -p "$1" -o command= 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
  fi
}

# An empty read proves nothing: macOS ps -E prints no environment for a system
# shell such as /bin/zsh, so every absence check first requires a readable PATH.
assert_proc_lacks_identity() {  # <pid> <label>
  local name value
  [ -n "$(proc_env_value "$1" PATH)" ] \
    || fail "$2 (pid $1): its environment is unreadable, so an identity check would pass blind"
  for name in $IDENTITY_NAMES; do
    value=$(proc_env_value "$1" "$name")
    [ -z "$value" ] || fail "$2 inherited $name=$value"
  done
}

# shell_dump <pane> <file>: have the pane's shell write its own environment and
# then its physical working directory, the exact inputs a resumed agent typed
# into that shell inherits. Polls until the trailing directory line lands.
dump_written() { grep -q '^PWD_P=' "$1" 2>/dev/null; }
shell_dump() {
  local q
  q=$(printf '%q' "$2")
  lab pane send-text "$1" "{ env; printf 'PWD_P=%s\\n' \"\$(pwd -P)\"; } > $q.tmp && mv $q.tmp $q" >/dev/null \
    || fail "could not type into pane $1"
  lab pane send-keys "$1" enter >/dev/null || fail "could not submit to pane $1"
  fm_test_wait_until --seconds 20 dump_written "$2" || fail "pane $1's shell never wrote its environment"
}

assert_dump_lacks_identity() {  # <file> <label>
  local name
  grep -q '^PATH=' "$1" || fail "$2: the shell's environment dump is empty, so an identity check would pass blind"
  for name in $IDENTITY_NAMES; do
    ! grep -q "^$name=" "$1" || fail "$2 inherited $(grep "^$name=" "$1" | head -1)"
  done
}

# Spawn through the real fm-spawn with a raw launch that records the launched
# process's environment, then keeps the pane busy like an agent.
spawn() {  # <id> <dump> <fm-spawn args...>
  local id=$1 dump=$2
  shift 2
  (cd "$PRIMARY" && env -u FM_STATE_OVERRIDE PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$id" "$@" \
    "sh -c 'env > $dump; exec sleep 600'") > "$TMP_ROOT/spawn-$id.out" 2>&1 \
    || fail "spawn of $id failed"$'\n'"$(cat "$TMP_ROOT/spawn-$id.out")"
}

spawn rc-crew "$TMP_ROOT/crew.env" "$PROJ" --mode direct-PR --yolo off --backend herdr
WT=$(sed -n 's/^worktree=//p' "$PRIMARY/state/rc-crew.meta")
spawn rc-mate "$TMP_ROOT/mate.env" "$SM_HOME" --secondmate --backend herdr
CREW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/rc-crew.meta")
MATE_PANE=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/rc-mate.meta")
[ -n "$WT" ] && [ -n "$CREW_PANE" ] && [ -n "$MATE_PANE" ] || fail 'spawn did not record worktree and panes'

agents_started() { [ -s "$TMP_ROOT/crew.env" ] && [ -s "$TMP_ROOT/mate.env" ]; }
fm_test_wait_until --seconds 20 agents_started \
  || fail 'the spawned agents never started'
for name in $IDENTITY_NAMES; do
  case "$name" in FM_HOME) continue ;; esac
  ! grep -q "^$name=" "$TMP_ROOT/crew.env" || fail "fresh crewmate inherited $name from the server"
  ! grep -q "^$name=" "$TMP_ROOT/mate.env" || fail "fresh secondmate inherited $name from the server"
done
! grep -q '^FM_HOME=' "$TMP_ROOT/crew.env" || fail 'fresh crewmate inherited FM_HOME from the server'
grep -qxF "FM_HOME=$SM_HOME" "$TMP_ROOT/mate.env" || fail 'fresh secondmate did not get its own FM_HOME'
pass 'real named lab: fresh agents launched under a polluted server carry only their own identity'

SERVER_PID=$(pgrep -f "herdr server --session $HERDR_LAB_SESSION" | head -1)
[ -n "$SERVER_PID" ] || fail 'could not find the lab server process'
assert_proc_lacks_identity "$SERVER_PID" 'the lab server'
pass 'real named lab: a server started from a firstmate session carries none of its identity'

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the lab for the restore'
provision_polluted

# restored_shell <pane>: the pid of the fresh shell Herdr restored into <pane>.
restored_shell() {
  lab pane process-info --pane "$1" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty'
}
panes_restored() { [ -n "$(restored_shell "$CREW_PANE")" ] && [ -n "$(restored_shell "$MATE_PANE")" ]; }
fm_test_wait_until --seconds 30 panes_restored \
  || fail 'Herdr did not restore both task panes'
CREW_CWD=$(lab pane get "$CREW_PANE" | jq -r '.result.pane.cwd // empty')
MATE_CWD=$(lab pane get "$MATE_PANE" | jq -r '.result.pane.cwd // empty')
shell_dump "$CREW_PANE" "$TMP_ROOT/crew-restored.env"
shell_dump "$MATE_PANE" "$TMP_ROOT/mate-restored.env"
WT_REAL=$(cd "$WT" && pwd -P)
SM_REAL=$(cd "$SM_HOME" && pwd -P)

# Herdr restores a pane into the directory its top-level shell had when the
# server stopped; a spawn that entered the worktree only in a subshell came back
# in the primary clone. Check Herdr's record and the restored shell itself.
[ "$(cd "$CREW_CWD" && pwd -P)" = "$WT_REAL" ] \
  || fail "restored crewmate pane is in '$CREW_CWD', not its worktree '$WT' (primary clone: $PROJ)"
grep -qxF "PWD_P=$WT_REAL" "$TMP_ROOT/crew-restored.env" \
  || fail "restored crewmate shell runs in '$(sed -n 's/^PWD_P=//p' "$TMP_ROOT/crew-restored.env")', not its worktree '$WT'"
[ "$(cd "$MATE_CWD" && pwd -P)" = "$SM_REAL" ] \
  || fail "restored secondmate pane is in '$MATE_CWD', not its home '$SM_HOME'"
grep -qxF "PWD_P=$SM_REAL" "$TMP_ROOT/mate-restored.env" \
  || fail "restored secondmate shell runs in '$(sed -n 's/^PWD_P=//p' "$TMP_ROOT/mate-restored.env")', not its home '$SM_HOME'"
pass 'real named lab: a restored crewmate comes back in its worktree, a secondmate in its home'

assert_dump_lacks_identity "$TMP_ROOT/crew-restored.env" 'the restored crewmate shell'
assert_dump_lacks_identity "$TMP_ROOT/mate-restored.env" 'the restored secondmate shell'
pass 'real named lab: restored shells, where a resumed agent starts, carry no other session identity'

STATUS=$(lab status --json) || fail 'could not read final lab version evidence'
printf 'evidence: herdr=%s protocol=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" \
  "$(printf '%s' "$STATUS" | jq -r '.server.protocol')"
