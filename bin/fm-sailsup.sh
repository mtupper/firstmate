#!/usr/bin/env bash
# fm-sailsup.sh - carry out the captain's /sailsup: put this home's Claude
# direct reports that a restore left in reduced permission mode back into
# bypass mode, for the current session only.
#
# Usage: fm-sailsup.sh
#        fm-sailsup.sh --delegated <parent-approval-id>
#
# Run it ONLY when the captain has invoked /sailsup in this session
# (.agents/skills/sailsup/SKILL.md owns that trigger). Firstmate never runs it
# on its own initiative, away mode never grants it, and a secondmate runs the
# --delegated form only on its parent's forwarded request.
#
# What it does, in order:
#   1. Refuses outright under away mode (state/.afk), inside a no-mistakes gate
#      agent, or outside the session that holds this home's fleet lock.
#   2. Writes a durable private approval record under state/sailsup/
#      (bin/fm-sailsup-lib.sh owns its format and session scope).
#   3. Reads every Claude direct report's live permission mode
#      (bin/fm-permission-mode-lib.sh). Each reduced worker with a resumable
#      session is restored through bin/fm-control.sh <id> restore-bypass, which
#      continues the same conversation and verifies bypass mode afterwards.
#      Unknown, unresumable, and already-bypass workers are recorded, never
#      touched.
#   4. Primary home only: sends each secondmate one routed request (through
#      bin/fm-send.sh, which marks it) carrying the approval id, so the
#      secondmate restores its own reduced crewmates with
#      `fm-sailsup.sh --delegated <id>` and reports through its status.
#
# Output: one `SAILSUP: <id> <outcome>` line per worker or forwarded
# secondmate, then `SAILSUP_RECORD: <path>`. Exit 0 when every acted-on worker
# reached bypass mode and every forward was sent; 1 when anything failed or
# could not be read; 2 on a refusal before any record was written.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

DELEGATED=
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --delegated)
    DELEGATED=${2:-}
    [ -n "$DELEGATED" ] && [ $# -eq 2 ] || { usage >&2; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name this firstmate home explicitly; /sailsup refuses to guess which home's workers it covers" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-permission-mode-lib.sh
. "$SCRIPT_DIR/fm-permission-mode-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-sailsup-lib.sh
. "$SCRIPT_DIR/fm-sailsup-lib.sh"

refuse() {
  echo "refused: $1" >&2
  exit 2
}

[ ! -e "$STATE/.afk" ] || refuse "away mode is active; away mode never grants /sailsup, so the captain must run it after returning"
SESSION=$(fm_sailsup_session_id "$STATE") \
  || refuse "this process is not running inside the session that holds this home's fleet lock; /sailsup is the captain's approval for that session only"
PARENT_HOME=
if [ -n "$DELEGATED" ]; then
  PARENT_HOME=$(fm_sailsup_parent_approval_check "$FM_HOME" "$DELEGATED") \
    || refuse "$PARENT_HOME"
fi

DIR=$(fm_sailsup_record_dir "$STATE")
if ! mkdir -p "$DIR" || ! chmod 700 "$DIR"; then
  refuse "cannot create the approval record directory $DIR"
fi
APPROVAL_ID="sailsup-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
RECORD="$DIR/$APPROVAL_ID.approval"
(
  umask 077
  {
    echo v1
    echo "approval=$APPROVAL_ID"
    echo "approved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "home=$FM_HOME"
    echo "session=$SESSION"
    if [ -n "$DELEGATED" ]; then
      echo "invoked_by=delegated"
      echo "parent_approval=$DELEGATED"
      echo "parent_home=$PARENT_HOME"
    else
      echo "invoked_by=captain"
    fi
  } > "$RECORD"
) || refuse "cannot write the approval record $RECORD"

FAILED=0
report() {  # <line-for-record> <summary>
  printf '%s\n' "$1" >> "$RECORD"
  printf 'SAILSUP: %s\n' "$2"
}

# Pass 1: classify every Claude direct report and name each covered worker in
# the record before any of them is touched, so fm-control can verify coverage.
WORKERS=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  fm_task_id_creation_valid "$id" || continue
  [ "$(fm_meta_get "$meta" harness)" = claude ] || continue
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  verdict=$(fm_permission_mode_task "$meta" "$id")
  case "$verdict" in
    reduced*)
      if [ "$(fm_permission_verdict_field "$verdict" session)" = none ]; then
        report "worker=$id kind=$kind before=reduced outcome=skipped-no-session" \
          "$id reduced, not restored: its live arguments carry no resumable session id"
        FAILED=1
      else
        printf 'worker=%s kind=%s before=reduced outcome=pending\n' "$id" "$kind" >> "$RECORD"
        WORKERS+=("$id")
      fi
      ;;
    bypass*)
      report "worker=$id kind=$kind before=bypass outcome=already-bypass" "$id already in bypass mode"
      ;;
    unknown*)
      report "worker=$id kind=$kind before=unknown outcome=skipped-unknown reason=$(fm_permission_verdict_field "$verdict" reason)" \
        "$id permission mode unknown ($(fm_permission_verdict_field "$verdict" reason)), not touched"
      FAILED=1
      ;;
  esac
done

# Pass 2: restore each covered worker through the one guarded path.
for id in "${WORKERS[@]:+${WORKERS[@]}}"; do
  kind=$(fm_meta_get "$STATE/$id.meta" kind)
  [ -n "$kind" ] || kind=ship
  if out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" restore-bypass --approval "$RECORD" 2>&1); then
    report "worker=$id kind=$kind before=reduced outcome=restored" \
      "$id restored to bypass mode ($(printf '%s\n' "$out" | grep -E '^(bypass-restored|already-bypass) ' | tail -1))"
  else
    report "worker=$id kind=$kind before=reduced outcome=failed" "$id NOT restored: $(printf '%s' "$out" | tail -1)"
    FAILED=1
  fi
done

# Pass 3 (primary only): forward the approval to each secondmate so it restores
# its own crewmates. A secondmate never forwards further.
if [ -z "$DELEGATED" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    id=$(basename "$meta" .meta)
    fm_task_id_creation_valid "$id" || continue
    grep -q '^window=' "$meta" 2>/dev/null || continue
    printf 'forwarded=%s outcome=pending\n' "$id" >> "$RECORD"
    msg="The captain approved /sailsup for this session (approval $APPROVAL_ID). Run 'bin/fm-sailsup.sh --delegated $APPROVAL_ID' in your home now to restore bypass mode on your reduced Claude workers, then report its SAILSUP outcome lines through your status."
    if out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$id" "$msg" 2>&1); then
      report "forwarded=$id outcome=sent" "$id asked to restore its own workers"
    else
      report "forwarded=$id outcome=send-failed" "$id request NOT delivered: $(printf '%s' "$out" | tail -1)"
      FAILED=1
    fi
  done
fi

printf 'SAILSUP_RECORD: %s\n' "$RECORD"
exit "$FAILED"
