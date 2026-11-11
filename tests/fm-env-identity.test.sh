#!/usr/bin/env bash
# Behavior tests for the agent and multiplexer-server identity boundary
# (bin/fm-env-scrub-lib.sh, bin/fm-agent-env.sh, and every server start that
# uses them).
#
# Regression for 2026-11-11: a Herdr server started from inside a firstmate
# session kept that session's FM_HOME, FM_STATE_OVERRIDE, CLAUDE_PROJECT_DIR,
# and CLAUDE_CODE_CHILD_SESSION, and gave them to every pane it created or
# restored. A restored secondmate then acted for the main home, and a fresh
# Claude worker started with transcript saving off. The real-Herdr restore is
# reproduced in tests/fm-herdr-restore-identity-e2e.test.sh; this suite pins the
# portable halves with real processes and fake multiplexers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-env-identity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
BASH_BIN=$(command -v bash)

# A polluted environment shaped like the live Herdr server's on 2026-11-11.
POLLUTED_HOME="$TMP_ROOT/main-home"
mkdir -p "$POLLUTED_HOME/state"
POLLUTED=(
  FM_HOME="$POLLUTED_HOME"
  FM_STATE_OVERRIDE="$POLLUTED_HOME/state"
  FM_SESSION_START_STAGE_FILE="$TMP_ROOT/stage"
  FM_PROJECT_WRITE_APPROVED=1
  FM_FLEET_PRUNE=0
  CLAUDECODE=1
  CLAUDE_CODE_CHILD_SESSION=1
  CLAUDE_CODE_ENTRYPOINT=cli
  CLAUDE_CODE_SESSION_ID=00000000-0000-0000-0000-000000000000
  CLAUDE_PID=4242
  CLAUDE_PROJECT_DIR="$POLLUTED_HOME"
  CLAUDE_ENV_FILE="$TMP_ROOT/env-file"
  CLAUDE_EFFORT=xhigh
  GROK_AGENT=1
  PI_CODING_AGENT=true
  CURSOR_AGENT=1
  TRACEPARENT=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
  GOTMPDIR=/tmp/fm-other/gotmp
  "TMUX=/tmp/tmux-fake/default,1,0"
  TMUX_PANE=%9
  HERDR_ENV=1
  HERDR_PANE_ID=w9:p9
  HERDR_SOCKET_PATH=/tmp/herdr-default.sock
  CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config"
  OPERATOR_SETTING=kept
)

# Leaked names every scope must clear.
IDENTITY_NAMES='FM_HOME FM_STATE_OVERRIDE FM_SESSION_START_STAGE_FILE FM_PROJECT_WRITE_APPROVED CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_EFFORT GROK_AGENT PI_CODING_AGENT CURSOR_AGENT'
# Names only a multiplexer server start clears.
DAEMON_ONLY_NAMES='TRACEPARENT GOTMPDIR TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH'

assert_env_lacks() {  # <env-dump-file> <names> <label>
  local name
  for name in $2; do
    if grep -q "^$name=" "$1"; then
      fail "$3: $name survived ($(grep "^$name=" "$1"))"
    fi
  done
}

assert_env_has() {  # <env-dump-file> <name=value> <label>
  grep -qxF "$2" "$1" || fail "$3: expected $2"$'\n'"$(cat "$1")"
}

test_agent_wrapper_clears_inherited_identity_and_applies_own() {
  local dump="$TMP_ROOT/agent-env.txt"
  env -i PATH="$BASE_PATH" HOME="$TMP_ROOT" "${POLLUTED[@]}" \
    "$ROOT/bin/fm-agent-env.sh" FM_HOME=/own/home FM_SUPERVISION_MODEL=autoarm \
    env > "$dump" \
    || fail "fm-agent-env.sh did not run its command"
  assert_env_lacks "$dump" "FM_STATE_OVERRIDE FM_SESSION_START_STAGE_FILE FM_PROJECT_WRITE_APPROVED CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_EFFORT GROK_AGENT PI_CODING_AGENT CURSOR_AGENT" \
    "agent launch"
  assert_env_has "$dump" "FM_HOME=/own/home" "agent launch must apply its own FM_HOME after the scrub"
  assert_env_has "$dump" "FM_SUPERVISION_MODEL=autoarm" "agent launch must apply its own assignments"
  # The pane's own identity and per-task exports belong to this agent.
  assert_env_has "$dump" "HERDR_PANE_ID=w9:p9" "agent launch must keep its own pane identity"
  assert_env_has "$dump" "GOTMPDIR=/tmp/fm-other/gotmp" "agent launch must keep the task's pane exports"
  assert_env_has "$dump" "CLAUDE_CONFIG_DIR=$TMP_ROOT/claude-config" "operator config store must survive"
  assert_env_has "$dump" "OPERATOR_SETTING=kept" "operator settings must survive"
  assert_env_has "$dump" "FM_FLEET_PRUNE=0" "firstmate operator tuning knobs must survive"
  pass "fm-agent-env.sh clears inherited firstmate and harness-session identity and applies the launch's own"
}

test_agent_wrapper_refuses_without_command() {
  local out rc
  out=$("$ROOT/bin/fm-agent-env.sh" 2>&1)
  rc=$?
  expect_code 2 "$rc" "fm-agent-env.sh without a command"
  assert_contains "$out" "Usage: fm-agent-env.sh" "fm-agent-env.sh without a command should print usage"
  pass "fm-agent-env.sh refuses to run without a command"
}

test_daemon_scope_clears_identity_pane_and_cwd() {
  local dump="$TMP_ROOT/daemon-env.txt" cwd_file="$TMP_ROOT/daemon-cwd.txt" daemon_home="$TMP_ROOT/daemon-home"
  mkdir -p "$daemon_home"
  # shellcheck disable=SC2016  # expands in the child shell, not here
  (cd "$POLLUTED_HOME" && env -i PATH="$BASE_PATH" HOME="$daemon_home" "${POLLUTED[@]}" \
    "$BASH_BIN" -c '. "$1"; fm_env_scrub_daemon_exec "$2" -c '\''env > "$1"; pwd -P > "$2"'\'' _ "$3" "$4"' \
    _ "$ROOT/bin/fm-env-scrub-lib.sh" "$BASH_BIN" "$dump" "$cwd_file") \
    || fail "fm_env_scrub_daemon_exec did not run its command"
  assert_env_lacks "$dump" "$IDENTITY_NAMES $DAEMON_ONLY_NAMES" "daemon start"
  assert_env_has "$dump" "CLAUDE_CONFIG_DIR=$TMP_ROOT/claude-config" "daemon start must keep the operator config store"
  assert_env_has "$dump" "OPERATOR_SETTING=kept" "daemon start must keep operator settings"
  assert_env_has "$dump" "FM_FLEET_PRUNE=0" "daemon start must keep firstmate operator tuning knobs"
  [ "$(cat "$cwd_file")" = "$(cd "$daemon_home" && pwd -P)" ] \
    || fail "daemon start must run from \$HOME, got $(cat "$cwd_file")"
  pass "a multiplexer server start clears identity, foreign pane identity, and the launching cwd"
}

test_unknown_scope_refuses() {
  local out rc
  # shellcheck disable=SC2016  # expands in the child shell, not here
  out=$("$BASH_BIN" -c '. "$1"; fm_env_scrub_exec bogus true' _ "$ROOT/bin/fm-env-scrub-lib.sh" 2>&1)
  rc=$?
  expect_code 2 "$rc" "unknown scrub scope"
  assert_contains "$out" "unknown scope" "unknown scope should be named"
  pass "an unknown scrub scope refuses rather than running unscrubbed"
}

# A fake multiplexer that records the environment and cwd of the process that
# starts its server, and reports the server running only after that start.
make_server_fakebin() {  # <dir> <tool>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/$2" <<'SH'
#!/usr/bin/env bash
set -u
started="$FAKE_MUX_DIR/started"
record() { env > "$FAKE_MUX_DIR/server-env.txt"; pwd -P > "$FAKE_MUX_DIR/server-cwd.txt"; : > "$started"; }
case "$(basename "$0")" in
  herdr)
    case "$*" in
      *"status --json"*)
        if [ -e "$started" ]; then printf '{"server":{"running":true}}\n'; else printf '{"server":{"running":false}}\n'; fi
        exit 0 ;;
      "server --session "*) record; exit 0 ;;
    esac ;;
  tmux)
    case "${1:-}" in
      has-session) [ -e "$started" ]; exit $? ;;
      new-session) record; exit 0 ;;
    esac ;;
  zellij)
    case "$*" in
      *"list-sessions"*) [ -e "$started" ] && printf '%s\n' "$FAKE_ZELLIJ_SESSION"; exit 0 ;;
      "attach -b "*) record; exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fakebin/$2"
  printf '%s\n' "$fakebin"
}

run_server_start() {  # <name> <tool> <bash snippet run with backend sourced>
  local name=$1 tool=$2 snippet=$3 dir fakebin daemon_home
  dir="$TMP_ROOT/$name"
  daemon_home="$dir/home"
  mkdir -p "$dir" "$daemon_home"
  fakebin=$(make_server_fakebin "$dir" "$tool")
  (cd "$POLLUTED_HOME" && env -i PATH="$fakebin:$BASE_PATH" HOME="$daemon_home" "${POLLUTED[@]}" \
    FAKE_MUX_DIR="$dir" FAKE_ZELLIJ_SESSION=fm-identity FM_ZELLIJ_SESSION=fm-identity \
    FM_ROOT_OVERRIDE="$ROOT" "$BASH_BIN" -c ". \"\$1\"; $snippet" _ "$ROOT/bin/fm-backend.sh") \
    >"$dir/out.txt" 2>&1 || fail "$name server start failed"$'\n'"$(cat "$dir/out.txt")"
  for _ in $(seq 1 50); do
    [ -s "$dir/server-cwd.txt" ] && break
    sleep 0.1
  done
  [ -s "$dir/server-env.txt" ] || fail "$name: the fake server was never started"
  assert_env_lacks "$dir/server-env.txt" "$IDENTITY_NAMES $DAEMON_ONLY_NAMES" "$name server"
  [ "$(cat "$dir/server-cwd.txt")" = "$(cd "$daemon_home" && pwd -P)" ] \
    || fail "$name server must start from \$HOME, got $(cat "$dir/server-cwd.txt")"
}

test_herdr_server_start_is_scrubbed() {
  run_server_start herdr herdr 'fm_backend_source herdr && fm_backend_herdr_server_ensure fm-lab-identity'
  assert_env_has "$TMP_ROOT/herdr/server-env.txt" "HERDR_SESSION=fm-lab-identity" "herdr server must keep its own session name"
  pass "fm_backend_herdr_server_ensure starts the Herdr server without the caller's identity"
}

test_tmux_server_start_is_scrubbed() {
  run_server_start tmux tmux 'unset TMUX; fm_backend_source tmux && fm_backend_tmux_container_ensure >/dev/null'
  pass "fm_backend_tmux_container_ensure starts the tmux server without the caller's identity"
}

test_zellij_server_start_is_scrubbed() {
  run_server_start zellij zellij 'fm_backend_source zellij && fm_backend_zellij_server_ensure fm-identity'
  pass "fm_backend_zellij_server_ensure starts the zellij session without the caller's identity"
}

# A fake tmux that records the literal launch fm-spawn types (send-keys -l) and
# reports the endpoint shell in FM_FAKE_PANE_PATH, plus a fake harness binary
# that dumps the environment it was launched with.
make_launch_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then printf '%s\n' "$arg" > "$FM_FAKE_LAUNCH_FILE"; break; fi
      prev=$arg
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/codex" <<'SH'
#!/bin/sh
env > "$FAKE_AGENT_ENV_DUMP"
pwd -P > "$FAKE_AGENT_CWD_DUMP"
SH
  chmod +x "$fakebin/codex"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# run_typed_launch <launch-file> <cwd> <dump-prefix> <fakebin>: run the exact
# typed launch in a pane-like shell that carries the polluted environment.
run_typed_launch() {
  local launch
  launch=$(cat "$1")
  (cd "$2" && env -i PATH="$4:$BASE_PATH" HOME="$TMP_ROOT" "${POLLUTED[@]}" \
    FAKE_AGENT_ENV_DUMP="$3.env" FAKE_AGENT_CWD_DUMP="$3.cwd" \
    "$BASH_BIN" -c "$launch") || fail "the typed launch did not run: $launch"
}

test_spawned_crewmate_runs_with_only_its_own_identity() {
  local dir="$TMP_ROOT/crew-launch" home proj wt fakebin id=identity-crew-z1 out
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  fakebin=$(make_launch_fakebin "$dir")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-identity"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_FILE="$dir/launch.txt" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --harness codex \
    --mode no-mistakes --yolo off 2>&1) || fail "crewmate spawn failed"$'\n'"$out"
  run_typed_launch "$dir/launch.txt" "$wt" "$dir/agent" "$fakebin"
  assert_env_lacks "$dir/agent.env" "$IDENTITY_NAMES" "spawned crewmate"
  assert_env_has "$dir/agent.env" "CLAUDE_CONFIG_DIR=$TMP_ROOT/claude-config" "spawned crewmate must keep the operator config store"
  pass "a spawned crewmate's launch clears inherited firstmate and harness-session identity"
}

test_spawned_secondmate_runs_with_its_own_home() {
  local dir="$TMP_ROOT/sm-launch" primary sm fakebin id=identity-sm-z2 out
  primary="$dir/primary"; sm="$dir/sm"
  fakebin=$(make_launch_fakebin "$dir")
  mkdir -p "$primary/data/$id" "$primary/state" "$primary/config" "$primary/projects" "$sm/bin" "$sm/data"
  printf 'charter brief\n' > "$primary/data/$id/brief.md"
  touch "$primary/state/.last-watcher-beat"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
    FM_DATA_OVERRIDE="$primary/data" FM_PROJECTS_OVERRIDE="$primary/projects" \
    FM_CONFIG_OVERRIDE="$primary/config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$sm" FM_FAKE_LAUNCH_FILE="$dir/launch.txt" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$sm" --harness codex --secondmate 2>&1) \
    || fail "secondmate spawn failed"$'\n'"$out"
  run_typed_launch "$dir/launch.txt" "$sm" "$dir/agent" "$fakebin"
  assert_env_lacks "$dir/agent.env" "FM_STATE_OVERRIDE FM_SESSION_START_STAGE_FILE FM_PROJECT_WRITE_APPROVED CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR CLAUDE_PID" \
    "spawned secondmate"
  assert_env_has "$dir/agent.env" "FM_HOME=$sm" "spawned secondmate must act for its own home"
  assert_env_has "$dir/agent.env" "FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$primary" "spawned secondmate must know its primary"
  pass "a spawned secondmate's launch names its own home and drops the inherited one"
}

test_agent_wrapper_clears_inherited_identity_and_applies_own
test_agent_wrapper_refuses_without_command
test_daemon_scope_clears_identity_pane_and_cwd
test_unknown_scope_refuses
test_herdr_server_start_is_scrubbed
test_tmux_server_start_is_scrubbed
test_zellij_server_start_is_scrubbed
test_spawned_crewmate_runs_with_only_its_own_identity
test_spawned_secondmate_runs_with_its_own_home
