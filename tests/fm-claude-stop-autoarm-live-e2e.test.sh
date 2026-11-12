#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock can run fm-session-start.sh first; session start reclaims the
# dead owner; at least two tokenless auto-arm and rewake cycles then complete
# with zero model-issued arm commands; the cooperative guard consumes no
# forced continuation while the hook's launch is healthy; and, under a hook
# timeout scaled down to 30 seconds, quiet real watcher cycles renew before
# Claude kills the hook tree.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Stop auto-arm regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart nudge,
# Stop guard, and asyncRewake auto-arm registration.
# The only local hook records model-issued Bash calls without acquiring the
# session lock or otherwise changing lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: session start drains too, both from the SessionStart hook and
# from the model's own session-start call, so count only model-issued drains,
# which the PreToolUse logger records before each one runs. The model's second
# wake drain ends the in-flight need after two complete Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
echo "drain-run" >> "$FM_HOME/state/drain-ran"
N=$(grep -c 'fm-wake-drain.sh' "$FM_HOME/state/tool-calls.log" 2>/dev/null || true)
if [ "${N:-0}" -ge 2 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='Run exactly `bin/fm-session-start.sh` with Bash as your first tool call. After reading its complete digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
MODEL_DRAINS=$(grep -c 'fm-wake-drain.sh' "$HOME_DIR/state/tool-calls.log" 2>/dev/null || true)
[ "${MODEL_DRAINS:-0}" = 2 ] || fail "expected exactly two model wake drains, got ${MODEL_DRAINS:-0}: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
REWAKES=$(grep -c 'Stop hook feedback' "$TRANSCRIPT" 2>/dev/null || true)
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ "$(sed -n '1p' "$HOME_DIR/state/tool-calls.log" 2>/dev/null)" = 'bin/fm-session-start.sh' ] \
  || fail "fresh Claude session did not run session start first: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 3; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

# Renewal before the hook timeout: the real hook, arm, and watcher run in an
# isolated home whose tracked Stop registration is scaled from 8 hours to 30
# seconds. Claude TERMs the whole hook tree at that timeout and ignores anything
# the hook does afterward, so every quiet cycle must renew before then. The need
# is removed after about three cycles so the final renewal closes quietly.
RENEW_HOME="$LAB/renewal"
RENEW_TRANSCRIPT="$LAB/renewal.jsonl"
git clone -q "$ROOT" "$RENEW_HOME"
cp -R "$ROOT/bin/." "$RENEW_HOME/bin/"
jq '{hooks: {Stop: [.hooks.Stop[0] | .hooks |= map(if ((.command // "") | contains("fm-claude-stop-autoarm.sh")) then .timeout = 30 else . end)]}}' \
  "$ROOT/.claude/settings.json" > "$RENEW_HOME/.claude/settings.json"
mkdir -p "$RENEW_HOME/state" "$RENEW_HOME/config" "$RENEW_HOME/data"
: > "$RENEW_HOME/state/task.meta"
printf '9999999\n' > "$RENEW_HOME/state/.lock"
printf '%s\n' fm-pr-check-migration-scan-v1 > "$RENEW_HOME/state/.pr-check-migration-scan-v1"
printf '%s\n' fm-pr-check-migration-v1 > "$RENEW_HOME/state/.pr-check-migration-v1"
chmod 0600 "$RENEW_HOME/state/.pr-check-migration-scan-v1" "$RENEW_HOME/state/.pr-check-migration-v1"
( sleep 80; rm -f "$RENEW_HOME/state/task.meta" ) >/dev/null 2>&1 &
RENEW_TIMER=$!
RENEW_PROMPT='Reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, follow its instructions exactly using Bash (run bin/fm-wake-drain.sh, then the exact WAKE_ACK_REQUIRED command it printed on stderr), then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh and never use shell &.'
(
  cd "$RENEW_HOME" || exit 1
  env -u FM_HOME FM_POLL=2 FM_HEARTBEAT=999999 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$RENEW_PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$RENEW_TRANSCRIPT" 2>&1 || fail "Claude renewal session failed: $(tail -20 "$RENEW_TRANSCRIPT")"
kill "$RENEW_TIMER" 2>/dev/null || true
wait "$RENEW_TIMER" 2>/dev/null || true
RENEW_LEDGER="$RENEW_HOME/state/.watch-cycle-exits.log"
RENEWALS=$(grep -c 'reason=lifetime-renewal' "$RENEW_LEDGER" 2>/dev/null || true)
[ "${RENEWALS:-0}" -ge 2 ] || fail "expected at least 2 quiet cycles to renew before the 30s timeout: $(cat "$RENEW_LEDGER" 2>/dev/null)"
! grep -q 'reason=arm-interrupted' "$RENEW_LEDGER" || fail "a quiet cycle was killed by the hook timeout instead of renewing: $(cat "$RENEW_LEDGER")"
[ "$(grep -c 'firstmate watcher renewal' "$RENEW_TRANSCRIPT")" -ge 2 ] || fail "expected at least 2 renewal rewakes in the transcript"
! grep -q 'rearm-resurface' "$RENEW_TRANSCRIPT" || fail "a handled renewal resurfaced as a wake"
! pgrep -f "$RENEW_HOME/bin/fm-watch.sh" >/dev/null 2>&1 || fail "a renewal watcher outlived the session"

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, preserved the competing-live-owner boundary, and renewed %s quiet cycles before a 30s hook timeout\n' "$CLAUDE_VERSION" "$RENEWALS"
