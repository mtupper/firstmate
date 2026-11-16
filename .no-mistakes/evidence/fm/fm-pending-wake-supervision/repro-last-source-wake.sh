#!/usr/bin/env bash
# End-to-end reproduction of the "last source's own wake is not delivered" gap.
#
# Builds a throwaway firstmate home from the scripts in <firstmate-tree>, never a
# live home. It registers a real one-shot condition watch (fm-procevent-when.sh)
# that fires at once, then fires the real Claude Stop auto-arm
# (fm-claude-stop-autoarm.sh) under a fake "claude" parent. The auto-arm starts
# the real watcher (fm-watch-arm.sh -> fm-watch.sh), which reconciles the runner,
# captures the fire, retires the source, and queues the wake.
#
# Usage: repro-last-source-wake.sh <firstmate-tree> <scenario>
#   last-source-only    the one-shot watch is the home's only registered source
#   with-second-source  a second never-firing watch stays registered (the mask)
#   idle                no source and an empty wake queue (no endless loop)
set -u

TREE=$(cd "$1" && pwd)
SCENARIO=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-repro.XXXXXX")
H="$WORK/home"
export GIT_AUTHOR_NAME=repro GIT_AUTHOR_EMAIL=repro@example.invalid
export GIT_COMMITTER_NAME=repro GIT_COMMITTER_EMAIL=repro@example.invalid

mkdir -p "$WORK/fakebin" "$H/state" "$H/.claude"
ln -s /bin/bash "$WORK/fakebin/claude"
git init -q "$H"
git -C "$H" commit -q --allow-empty -m init
: > "$H/AGENTS.md"
cp -R "$TREE/bin/." "$H/bin/"
cat > "$H/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"},
  {"type":"command","command":"exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh","asyncRewake":true,"timeout":120}
]}]}}
JSON
printf '%s\n' fm-pr-check-migration-scan-v1 > "$H/state/.pr-check-migration-scan-v1"
printf '%s\n' fm-pr-check-migration-v1 > "$H/state/.pr-check-migration-v1"
chmod 0600 "$H/state/.pr-check-migration-scan-v1" "$H/state/.pr-check-migration-v1"

export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999

arm_when() {  # <name> <condition>
  (cd "$H" && FM_HOME="$H" "$H/bin/fm-procevent-when.sh" arm "$1" --interval 0.2 --stable 1 \
    --condition "$2" --action /usr/bin/true) >/dev/null 2>&1
}

sources() {
  local s out=
  for s in "$H"/state/procevent/*.source; do
    [ -e "$s" ] && out="$out $(basename "$s")"
  done
  printf '%s\n' "${out:- (none)}"
}

ackable_queue_rows() {
  awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/' "$H/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}

watcher_alive() {
  local pid
  pid=$(cat "$H/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "yes (pid $pid)"; return; }
  echo no
}

# Fire one Claude Stop: the auto-arm runs as a child of the fake harness that
# holds the home's session lock, inside its own process group with a timeout.
fire_stop() {  # <label> <timeout-seconds>
  local label=$1 timeout=$2 pid killer started
  printf '%s\n' '{"session_id":"sess-repro","stop_hook_active":false}' > "$H/payload"
  started=$(date +%s)
  (
    cd "$H" || exit 1
    FM_HOME="$H" exec perl -e 'setpgrp(0, 0) or exit 125; exec @ARGV' "$WORK/fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$FM_HOME/payload"
    '
  ) > "$H/hook.out" 2>&1 &
  pid=$!
  ( sleep "$timeout"; kill -TERM -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer=$!
  RC=0
  wait "$pid" || RC=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  local deadline=$(( $(date +%s) + 10 ))
  while [ -e "$H/state/.claude-autoarm.lock" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.1; done
  printf '\n--- Stop hook: %s ---\n' "$label"
  printf 'exit code          : %s (%s)\n' "$RC" "$(case $RC in 0) echo 'turn ends, no rewake' ;; 2) echo 'asyncRewake: session is woken' ;; *) echo other ;; esac)"
  printf 'elapsed            : %ss\n' "$(( $(date +%s) - started ))"
  printf 'epoch record       : %s\n' "$(cat "$H/state/.claude-autoarm-epoch" 2>/dev/null || echo '(none)')"
  printf 'sources registered :%s\n' "$(sources)"
  printf 'queued wake rows   : %s\n' "$(ackable_queue_rows)"
  awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { printf "    queued: seq=%s kind=%s key=%s\n", $2, $3, $4 }' \
    "$H/state/.wake-queue" 2>/dev/null
  printf 'watcher alive      : %s\n' "$(watcher_alive)"
  printf 'hook output (model-facing rewake text, first 6 lines):\n'
  sed -n '1,6p' "$H/hook.out" | sed 's/^/    | /'
}

drain_and_ack() {
  local err="$H/drain.err" seq gen
  (cd "$H" && FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$H/bin/fm-wake-drain.sh") > "$H/drain.out" 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  printf '\n--- handling turn: bin/fm-wake-drain.sh, then --ack-through %s ---\n' "$seq"
  sed -n '1,4p' "$H/drain.out" | sed 's/^/    | /'
  (cd "$H" && FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$H/bin/fm-wake-drain.sh" --ack-through "$seq" \
    --recovery-generation "$gen") >/dev/null 2>&1 || return 1
  printf 'queued wake rows after ack: %s\n' "$(ackable_queue_rows)"
  printf 'sources registered after ack:%s\n' "$(sources)"
}

cleanup() {
  (cd "$H" && FM_HOME="$H" "$H/bin/fm-procevent.sh" sweep-home) >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '=== tree: %s (%s) | scenario: %s ===\n' "$TREE" \
  "$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || cat "$TREE/.repro-rev" 2>/dev/null || echo '?')" "$SCENARIO"
case "$SCENARIO" in
  last-source-only)
    arm_when alert /usr/bin/true || { echo 'arm failed'; exit 1; }
    ;;
  with-second-source)
    arm_when alert /usr/bin/true || { echo 'arm failed'; exit 1; }
    arm_when never /usr/bin/false || { echo 'arm failed'; exit 1; }
    ;;
  idle) ;;
  *) echo "unknown scenario: $SCENARIO"; exit 64 ;;
esac
printf 'before Stop: sources registered :%s\n' "$(sources)"

if [ "$SCENARIO" = idle ]; then
  fire_stop "first Stop in an idle home (no source, no queued wake)" 90
else
  fire_stop "first Stop after the one-shot watch is armed" 90
fi
FIRST_RC=$RC

if [ "$SCENARIO" = last-source-only ] && [ "$FIRST_RC" -eq 0 ]; then
  fire_stop "a later Stop while the wake is still queued" 30
fi
if [ "$SCENARIO" = last-source-only ] && [ "$FIRST_RC" -eq 2 ]; then
  drain_and_ack || echo 'drain/ack FAILED'
  fire_stop "next Stop after the handling turn acknowledged the wake" 30
fi
