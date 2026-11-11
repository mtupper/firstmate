#!/usr/bin/env bash
# Opt-in live guard for the 2026-11-11 reboot restore with a REAL Claude Code.
#
# tests/fm-herdr-restore-identity-e2e.test.sh pins the portable half: Herdr
# restores each pane as a fresh shell in the pane's recorded directory, and that
# shell carries no other session's identity. Two facts only the vendors can
# supply stay load-bearing here: Herdr's restore resumes the agent by typing
# `claude --resume <id>` into that restored shell, and a Claude agent launched
# with an inherited CLAUDE_CODE_CHILD_SESSION saves no transcript, so it cannot
# be resumed at all. This guard spawns a real Claude crewmate and secondmate
# through bin/fm-spawn.sh under a server started from a polluted environment,
# restarts the guarded named lab, and requires each agent to come back as a
# resumed Claude process in its own worktree or home with no other session's
# identity. It spends a few tokens per run and refuses a pass that resumed
# nothing. Refresh docs/verification/runtime-backends.md from its output after
# any Herdr or Claude Code upgrade.
#
# Usage:
#   FM_HERDR_RESTORE_LIVE_E2E=1 tests/fm-herdr-restore-identity-live-e2e.test.sh
set -u

if [ "${FM_HERDR_RESTORE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_RESTORE_LIVE_E2E=1 to run the live Herdr restore identity guard"
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
command -v claude >/dev/null 2>&1 || { echo 'not ok - claude is not installed, so the live restore guard checked nothing' >&2; exit 1; }
herdr integration status 2>/dev/null | grep -Eq '^claude: (current|outdated)' \
  || { echo 'not ok - the Herdr claude integration is not installed, so Herdr cannot resume a Claude pane' >&2; exit 1; }
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)

# The lab is its own session; this process's own Herdr pane, if any, must not
# follow spawn into it as a parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-restore-live)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN="$TMP_ROOT/fakebin"
PRIMARY="$TMP_ROOT/primary-home"
SM_HOME="$TMP_ROOT/secondmate-home"
PROJ="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$PRIMARY/state" "$PRIMARY/data/rl-crew" "$PRIMARY/config" \
  "$SM_HOME/state" "$SM_HOME/data" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$PRIMARY/config/herdr-presentation-spaces"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# lab secondmate home\n' > "$SM_HOME/AGENTS.md"
printf 'rl-mate\n' > "$SM_HOME/.fm-secondmate-home"
PROBE='Live restore probe only. Reply with the single word READY. Do not run any tools or commands.'
printf '%s\n' "$PROBE" > "$SM_HOME/data/charter.md"
printf 'Delivery contract: mode=direct-PR\n%s\n' "$PROBE" > "$PRIMARY/data/rl-crew/brief.md"
fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$PROJ.origin.git"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name restore-live)
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

lab_screen() { lab pane read "$1" --source visible 2>/dev/null; }

# accept_dialog <pane>: select the accepting option of Claude's first-run trust
# or bypass-permissions dialog, whose default selection exits (verified on
# Claude Code 2.1.311), and confirm it.
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

# claude_under <pane>: the pid of the Claude process running under the pane's
# shell, or nothing.
claude_under() {
  local shell_pid queue p kids
  shell_pid=$(lab pane process-info --pane "$1" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty')
  [ -n "$shell_pid" ] || return 0
  queue=$shell_pid
  while [ -n "$queue" ]; do
    p=${queue%% *}
    [ "$p" = "$queue" ] && queue= || queue=${queue#* }
    case "$(ps -o command= -p "$p" 2>/dev/null)" in claude*|*/claude\ *) printf '%s\n' "$p"; return 0 ;; esac
    kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
    queue="$queue $kids"
    queue=${queue# }
    queue=${queue% }
  done
}

proc_cwd() {
  if [ -e "/proc/$1/cwd" ]; then readlink "/proc/$1/cwd"; else lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; fi
}

spawn_claude() {  # <id> <fm-spawn args...>
  local id=$1
  shift
  (cd "$PRIMARY" && env -u FM_STATE_OVERRIDE PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$id" "$@" --harness claude) \
    > "$TMP_ROOT/spawn-$id.out" 2>&1 \
    || fail "spawn of $id failed"$'\n'"$(cat "$TMP_ROOT/spawn-$id.out")"
}

spawn_claude rl-crew "$PROJ" --mode direct-PR --yolo off --backend herdr
WT=$(sed -n 's/^worktree=//p' "$PRIMARY/state/rl-crew.meta")
spawn_claude rl-mate "$SM_HOME" --secondmate --backend herdr
CREW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/rl-crew.meta")
MATE_PANE=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/rl-mate.meta")
[ -n "$WT" ] && [ -n "$CREW_PANE" ] && [ -n "$MATE_PANE" ] || fail 'spawn did not record worktree and panes'

answered() {  # <pane>
  accept_dialog "$1"
  lab_screen "$1" | grep -q 'READY'
}
both_answered() { answered "$CREW_PANE" && answered "$MATE_PANE"; }
fm_test_wait_until --seconds 180 both_answered \
  || fail "the live Claude agents never answered (claude $CLAUDE_VERSION)"
# Herdr records the resumable session reference from the integration hook; give
# the transcript and that report a moment to land before the restart.
sleep 10

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the lab for the restore'
provision_polluted

both_resumed() { [ -n "$(claude_under "$CREW_PANE")" ] && [ -n "$(claude_under "$MATE_PANE")" ]; }
fm_test_wait_until --seconds 120 both_resumed \
  || fail "Herdr did not resume both Claude panes after the restart ($(herdr --version 2>/dev/null), claude $CLAUDE_VERSION)"
CREW_PID=$(claude_under "$CREW_PANE")
MATE_PID=$(claude_under "$MATE_PANE")
case "$(ps -o command= -p "$CREW_PID")" in *--resume*) ;; *) fail "the restored crewmate is not a resumed Claude session: $(ps -o command= -p "$CREW_PID")" ;; esac
case "$(ps -o command= -p "$MATE_PID")" in *--resume*) ;; *) fail "the restored secondmate is not a resumed Claude session: $(ps -o command= -p "$MATE_PID")" ;; esac
pass "live: Herdr resumed both Claude agents ($(herdr --version 2>/dev/null), claude $CLAUDE_VERSION)"

[ "$(cd "$(proc_cwd "$CREW_PID")" && pwd -P)" = "$(cd "$WT" && pwd -P)" ] \
  || fail "the resumed crewmate runs in '$(proc_cwd "$CREW_PID")', not its worktree '$WT'"
[ "$(cd "$(proc_cwd "$MATE_PID")" && pwd -P)" = "$(cd "$SM_HOME" && pwd -P)" ] \
  || fail "the resumed secondmate runs in '$(proc_cwd "$MATE_PID")', not its home '$SM_HOME'"
assert_proc_lacks_identity "$CREW_PID" 'the resumed crewmate'
assert_proc_lacks_identity "$MATE_PID" 'the resumed secondmate'
pass 'live: resumed agents run in their own worktree or home with no other session identity'
