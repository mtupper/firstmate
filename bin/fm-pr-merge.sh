#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# MERGE AUTHORITY IS REQUIRED AND RECORDED. AGENTS.md hard rule 2 - never merge
# without the captain's explicit word - had no runtime backing: this script used
# to merge whatever URL it was handed. --authority now names which of the two
# sanctioned authorities is being exercised, and the choice is written to
# state/<id>.merge-approval before gh-axi is called, so every merge leaves a
# durable record of what authorized it rather than only that it happened.
#
#   --authority captain   the captain explicitly said to merge this PR.
#   --authority yolo      the project's standing yolo posture covers it. Allowed
#                         ONLY when this task's own meta records yolo=on. That is
#                         the posture resolved at intake and passed to fm-spawn,
#                         so a task dispatched with yolo off cannot have standing
#                         authority claimed for it after the fact.
#
# This is a seatbelt against a confused agent, not a wall against a determined
# one - the same threat model bin/fm-gate-refuse-lib.sh states. Its value is that
# merge authority must be named and recorded, so an unauthorized merge requires a
# deliberate false statement rather than an omission.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> --authority <captain|yolo>
#          [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

# --authority is read before the -- separator, so it can never be mistaken for a
# gh-axi argument and gh-axi can never be handed it.
AUTHORITY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority)
      [ "$#" -gt 1 ] || { echo "error: --authority requires a value" >&2; exit 2; }
      AUTHORITY=$2
      shift 2
      ;;
    --authority=*)
      AUTHORITY=${1#--authority=}
      shift
      ;;
    *) break ;;
  esac
done

case "$AUTHORITY" in
  captain|yolo) ;;
  "")
    echo "error: refusing to merge without --authority <captain|yolo>; a PR merge needs the captain's explicit word, or this task's standing yolo posture" >&2
    exit 2
    ;;
  *)
    echo "error: --authority must be captain or yolo (got '$AUTHORITY')" >&2
    exit 2
    ;;
esac

[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Standing yolo authority is only as good as the posture this task was actually
# dispatched under, which fm-spawn recorded in the meta at intake. Anything other
# than a recorded yolo=on - off, absent, or a scout that never had a posture -
# means there is no standing authority to exercise, so the captain must say so.
if [ "$AUTHORITY" = yolo ]; then
  TASK_YOLO=$(sed -n 's/^yolo=//p' "$META" | head -n 1)
  if [ "$TASK_YOLO" != "on" ]; then
    echo "error: refusing to merge on standing authority: task $ID records yolo=${TASK_YOLO:-<unset>}, so it has none; merge with --authority captain once the captain approves" >&2
    exit 1
  fi
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Durable before destructive: the record of what authorized this merge is written
# and confirmed on disk BEFORE gh-axi is called, so an interrupted or failed
# merge still leaves evidence of the decision that was made.
APPROVAL="$STATE/$ID.merge-approval"
if [ -L "$APPROVAL" ]; then
  echo "error: merge approval record for $ID is a symlink; refusing" >&2
  exit 1
fi
if [ -f "$APPROVAL" ] && ! grep -qxF "pr=$URL" "$APPROVAL"; then
  echo "error: task $ID already carries a merge approval for a different PR; resolve that before merging $URL" >&2
  exit 1
fi
{
  echo "task=$ID"
  echo "pr=$URL"
  echo "authority=$AUTHORITY"
  echo "recorded=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$APPROVAL" || {
  echo "error: could not record the merge approval for $ID" >&2
  exit 1
}
grep -qxF "authority=$AUTHORITY" "$APPROVAL" || {
  echo "error: merge approval recording failed for $ID" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
