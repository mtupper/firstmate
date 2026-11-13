#!/usr/bin/env bash
# fm-claude-permission-hook.sh - turn a Claude worker parked on a tool
# permission prompt into a keyed captain-relevant blocker in its status log.
#
# Usage (wired by bin/fm-spawn.sh into the agent directory's
# .claude/settings.local.json; never run by hand):
#   fm-claude-permission-hook.sh request <state-dir> <task-id>   PermissionRequest
#   fm-claude-permission-hook.sh clear <state-dir> <task-id>     UserPromptSubmit, Stop
#
# Why. A Herdr restore resumes a Claude worker without its launch
# --dangerously-skip-permissions flag (bin/fm-permission-mode-lib.sh), so the
# worker can stop at a "Do you want to proceed?" prompt. Without this hook that
# wait looks like an ordinary busy turn and surfaces, at best, as a generic
# possible wedge minutes later. Claude Code fires PermissionRequest the moment
# the prompt renders, with the session's live permission_mode in the payload
# (verified on Claude Code 2.1.311). This hook records that once as
#   blocked: [key=permission-prompt] ...
# so the existing status classifier, open-decision fold, and fast blocked
# escalation carry it to firstmate with no parallel detector.
#
# When the payload's permission_mode is not bypassPermissions, the line says
# the worker runs below its launch mode and names /sailsup, the captain's
# per-session approval to restore bypass mode (.agents/skills/sailsup/SKILL.md).
# A prompt in bypass mode is still a captain question, so it is surfaced
# without that pointer.
#
# The marker state/<id>.permission-wait makes one prompt produce one blocker.
# `clear` runs at the next prompt submission or turn end; when a marker exists
# it removes it and appends the matching keyed `resolved:` line, and otherwise
# it does nothing, so ordinary turns never touch the status log.
#
# Contract with Claude Code: this hook prints NOTHING to stdout and always
# exits 0. A PermissionRequest hook's stdout can carry an allow/deny decision,
# and firstmate must never answer a permission prompt on the captain's behalf.
set -u

ACTION=${1:-}
STATE=${2:-}
ID=${3:-}
case "$ACTION" in request|clear) ;; *) exit 0 ;; esac
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -n "$STATE" ] && [ -d "$STATE" ] || exit 0

MARKER="$STATE/$ID.permission-wait"
STATUS="$STATE/$ID.status"

if [ "$ACTION" = clear ]; then
  [ -e "$MARKER" ] || exit 0
  rm -f "$MARKER" 2>/dev/null || exit 0
  printf '%s\n' "resolved: [key=permission-prompt] the permission prompt was answered and the worker moved on" >> "$STATUS" 2>/dev/null || true
  exit 0
fi

payload=$(cat 2>/dev/null || true)
mode=
tool=
if command -v jq >/dev/null 2>&1; then
  mode=$(printf '%s' "$payload" | jq -r '.permission_mode // empty | tostring' 2>/dev/null || true)
  tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty | tostring' 2>/dev/null || true)
fi
case "$mode" in *[!A-Za-z]*) mode= ;; esac
case "$tool" in *[!A-Za-z0-9_.:-]*) tool= ;; esac

# noclobber makes the marker create atomic, so concurrent prompts in one
# worker still write one blocker.
( set -C; printf 'mode=%s\ntool=%s\nts=%s\n' "${mode:-unknown}" "${tool:-unknown}" "$(date +%s)" > "$MARKER" ) 2>/dev/null || exit 0

what="a tool-permission prompt${tool:+ for $tool}"
if [ "$mode" = bypassPermissions ]; then
  line="blocked: [key=permission-prompt] waiting at $what even in bypass mode; only the captain can answer it in the worker's pane"
else
  line="blocked: [key=permission-prompt] waiting at $what; it runs in ${mode:-an unknown} permission mode, below its launch bypass mode, so the captain's /sailsup approves restoring bypass mode for this session"
fi
printf '%s\n' "$line" >> "$STATUS" 2>/dev/null || true
exit 0
