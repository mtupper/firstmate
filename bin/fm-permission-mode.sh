#!/usr/bin/env bash
# fm-permission-mode.sh - read the live permission mode of this home's Claude
# direct reports (crewmates, scouts, and secondmate agents).
#
# Usage: fm-permission-mode.sh scan [--all]
#        fm-permission-mode.sh task <task-id>
#
#   scan    One line per Claude direct report that does NOT provably run in
#           its launch bypass mode, and silence when every one does:
#             PERMISSION_MODE: reduced <id> kind=<kind> session=<id|none>
#             PERMISSION_MODE: unknown <id> kind=<kind> reason=<token>
#           --all also prints `PERMISSION_MODE_OK: <id> kind=<kind> bypass`
#           for each verified bypass agent. Tasks on other harnesses, and tasks
#           with no running agent, are skipped. bin/fm-bootstrap.sh prints the
#           scan in the session-start digest; the bootstrap-diagnostics skill
#           owns what firstmate does with each line.
#   task    The single verdict line for one task, as owned by
#           bin/fm-permission-mode-lib.sh's fm_permission_mode_task.
#
# Read-only: nothing here changes any agent or record. Restoring bypass mode
# is bin/fm-sailsup.sh's job and needs the captain's /sailsup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-permission-mode-lib.sh
. "$SCRIPT_DIR/fm-permission-mode-lib.sh"

scan() {  # [--all]
  local all=${1:-} meta id kind verdict
  [ -d "$STATE" ] || return 0
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
        echo "PERMISSION_MODE: reduced $id kind=$kind session=$(fm_permission_verdict_field "$verdict" session)"
        ;;
      unknown*)
        echo "PERMISSION_MODE: unknown $id kind=$kind reason=$(fm_permission_verdict_field "$verdict" reason)"
        ;;
      bypass*)
        [ "$all" != --all ] || echo "PERMISSION_MODE_OK: $id kind=$kind bypass"
        ;;
    esac
  done
  return 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  scan)
    case "${2:-}" in ''|--all) ;; *) usage >&2; exit 2 ;; esac
    scan "${2:-}"
    ;;
  task)
    id=${2:-}
    if [ -z "$id" ] || ! fm_task_id_creation_valid "$id"; then
      echo "error: task needs a valid task id" >&2
      exit 2
    fi
    [ -f "$STATE/$id.meta" ] || { echo "error: no task '$id' in $STATE" >&2; exit 1; }
    fm_permission_mode_task "$STATE/$id.meta" "$id"
    ;;
  *) usage >&2; exit 2 ;;
esac
