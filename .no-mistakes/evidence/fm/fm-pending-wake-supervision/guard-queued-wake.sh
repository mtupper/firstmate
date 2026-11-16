#!/usr/bin/env bash
# Shows what the real turn-end guard (bin/fm-turnend-guard.sh) and the real pull
# guard (bin/fm-guard.sh) print for a throwaway home whose ONLY supervision need
# is one unacknowledged queued wake: its one-shot source has already retired, no
# task is in flight, and no watcher is running. Then it empties the queue (the
# post-handling acknowledgement) and runs both guards again.
#
# Usage: guard-queued-wake.sh <firstmate-tree>
set -u

TREE=$(cd "$1" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-repro.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
H="$WORK/home"
export GIT_AUTHOR_NAME=repro GIT_AUTHOR_EMAIL=repro@example.invalid
export GIT_COMMITTER_NAME=repro GIT_COMMITTER_EMAIL=repro@example.invalid

mkdir -p "$H/state" "$H/config" "$H/docs" "$WORK/root"
git init -q "$H"
git -C "$H" commit -q --allow-empty -m init
: > "$H/AGENTS.md"
cp -R "$TREE/bin/." "$H/bin/"
cp -R "$TREE/docs/supervision-protocols" "$H/docs/supervision-protocols"
printf '1794860816\t1\tcheck\tprocevent:when-alert:1\tcheck: procevent when when-alert 1\n' > "$H/state/.wake-queue"

run_guards() {
  local rc
  printf '\n$ printf %s | bin/fm-turnend-guard.sh\n' "'{\"stop_hook_active\":false}'"
  (cd "$H" && printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$H" bash "$H/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  printf '[exit %s: %s]\n' "$rc" "$(case $rc in 0) echo 'turn may end' ;; 2) echo 'turn end BLOCKED' ;; *) echo other ;; esac)"
  printf '\n$ bin/fm-guard.sh   (pull guard, persistent model)\n'
  (cd "$H" && FM_ROOT_OVERRIDE="$WORK/root" FM_HOME="$H" FM_GUARD_GRACE=999 FM_SUPERVISION_MODEL=persistent \
    "$H/bin/fm-guard.sh" 2>&1)
  printf '[exit %s]\n' "$?"
}

printf '=== tree: %s (%s) ===\n' "$TREE" \
  "$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || cat "$TREE/.repro-rev" 2>/dev/null || echo '?')"
printf 'home state: no task.meta, no procevent source, no watcher, one queued wake (seq=1 key=procevent:when-alert:1)\n'
printf '\n##### A. the wake is queued and not yet acknowledged #####\n'
run_guards
: > "$H/state/.wake-queue"
printf '\n##### B. after the post-handling acknowledgement empties the queue #####\n'
run_guards
