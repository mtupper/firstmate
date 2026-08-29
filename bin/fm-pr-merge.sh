#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh into a provider-tagged
# identity, and the project is addressed from that identity alone.
#
# GitHub and GitLab both go through this one guarded path. Every check - task id
# validation, authority parsing, the yolo=on meta check, PR metadata recording,
# the symlink refusal, the different-PR refusal, and writing and confirming the
# approval record - runs identically for both. Only the execution step differs:
# `gh-axi pr merge` for github, `glab mr merge` for gitlab.
#
# Merge method defaults to --squash when the caller passes no strategy flag of
# its own. On github that is --squash/--merge/--rebase/--method; on gitlab it is
# --squash/-s/--rebase/-r, or any bundled shorthand containing s or r, since
# `glab mr merge` has no --merge or --method flag and expresses a merge commit as
# the absence of a strategy (pass --squash=false to get one). Extra args must not
# redirect the project with --repo or -R, and on gitlab must not override the
# --sha pin or --auto-merge, because both are guard flags rather than choices.
#
# MERGE AUTHORITY IS REQUIRED AND RECORDED. AGENTS.md hard rule 2 - never merge
# without the captain's explicit word - had no runtime backing: this script used
# to merge whatever URL it was handed. --authority now names which of the two
# sanctioned authorities is being exercised, and the choice is written to
# state/<id>.merge-approval before any merge command is called, so every merge
# leaves a durable record of what authorized it rather than only that it happened.
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
# GITLAB: THE HEAD IS PINNED AND THE PIPELINE MUST DESCRIBE IT.
# Before merging, the merge request's own head commit is read from the forge and
# passed to `glab mr merge --sha`, so nothing pushed between review and merge can
# land. The merge request must be open, and its head pipeline is judged only by
# the commit it actually ran on:
#
#   head pipeline on the head commit, status success  -> merge.
#   head pipeline on the head commit, any other status -> refuse. No override.
#   head pipeline on a DIFFERENT commit                -> refuse. No override.
#     A pipeline for another commit says nothing about the one being merged, so
#     it is never read as green. Re-run once the head's own pipeline exists.
#   no head pipeline at all                            -> refuse, unless the
#     caller passes --allow-absent-pipeline, which states that no runnable gate
#     applies here and is recorded in the approval as pipeline=absent-accepted.
#
# Absent CI is the ordinary case on a repository that has none, so refusing it
# outright would make this path unusable exactly where merges have to be made by
# hand instead. Requiring the flag keeps that an explicit, recorded statement.
#
# GitHub carries no equivalent pin. `gh pr merge` has --match-head-commit, but
# gh-axi's documented merge flags do not include it and it neither errors on nor
# honors an unknown flag, so wiring it here would produce an unverifiable no-op.
# Adding passthrough to gh-axi is the prerequisite; docs/gitlab-merge-watch.md
# records that evidence and the glab facts this path depends on.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> --authority <captain|yolo>
#          [--allow-absent-pipeline] [-- <extra forge merge args>]
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
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

# --authority and --allow-absent-pipeline are read before the -- separator, so
# they can never be mistaken for a forge argument and the forge CLI can never be
# handed them.
AUTHORITY=""
ALLOW_ABSENT_PIPELINE=0
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
    --allow-absent-pipeline)
      ALLOW_ABSENT_PIPELINE=1
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

if [ "$ALLOW_ABSENT_PIPELINE" = 1 ] && [ "$PROVIDER" != gitlab ]; then
  echo "error: --allow-absent-pipeline applies only to a GitLab merge request" >&2
  exit 2
fi

[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    if [ "$PROVIDER" = gitlab ]; then
      # glab has no --merge or --method: a merge commit is the absence of a
      # strategy. Bundled shorthand is treated as explicit rather than parsed,
      # so an ambiguous group never collects a conflicting default as well.
      case "$arg" in
        --squash|--squash=*|--rebase|--rebase=*) return 0 ;;
        -[!-]*) case "$arg" in *s*|*r*) return 0 ;; esac ;;
      esac
      continue
    fi
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

# --sha and --auto-merge are guard flags on the gitlab path, not caller choices:
# --sha pins the reviewed head and --auto-merge=false keeps the merge immediate
# rather than deferred to a pipeline result this script did not judge.
reject_guard_overrides() {
  local arg
  [ "$PROVIDER" = gitlab ] || return 0
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*|--auto-merge|--auto-merge=*)
        echo "error: extra merge arguments must not override the head pin or auto-merge" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
reject_guard_overrides "$@" || exit 1

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

# GitLab preflight. Read-only, and ahead of every state write, so a merge request
# that must not be merged is refused without leaving a poll or approval behind.
GITLAB_PROJECT=
PINNED_HEAD=
PIPELINE_RECORD=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || {
    echo "error: merging a GitLab merge request requires glab on PATH" >&2
    exit 1
  }
  # A full project URL carries the host, so this addresses a self-hosted
  # instance as exactly as gitlab.com and ignores any ambient glab repo setting.
  GITLAB_PROJECT="https://$PR_HOST/$PR_PATH"
  MR_FACTS=$(glab mr view "$PR_NUMBER" --repo "$GITLAB_PROJECT" --output json \
    --jq '[.sha, .state, (.head_pipeline.sha // "-"), (.head_pipeline.status // "-")] | join(" ")' 2>/dev/null) || {
    echo "error: could not read merge request $PR_NUMBER from $GITLAB_PROJECT" >&2
    exit 1
  }
  MR_HEAD=; MR_STATE=; PIPELINE_SHA=; PIPELINE_STATUS=
  IFS=' ' read -r MR_HEAD MR_STATE PIPELINE_SHA PIPELINE_STATUS <<< "$MR_FACTS" || true
  fm_pr_head_valid "${MR_HEAD:-}" || {
    echo "error: could not resolve the head commit of $URL; refusing to merge an unpinned merge request" >&2
    exit 1
  }
  if [ "${MR_STATE:-}" != opened ]; then
    echo "error: merge request $URL is ${MR_STATE:-unknown}, not open" >&2
    exit 1
  fi
  if [ "${PIPELINE_SHA:-}" = "-" ] && [ "${PIPELINE_STATUS:-}" = "-" ]; then
    if [ "$ALLOW_ABSENT_PIPELINE" != 1 ]; then
      echo "error: merge request $URL has no pipeline on its head commit $MR_HEAD; an absent pipeline is not a passing one, so pass --allow-absent-pipeline to state that no runnable gate applies here" >&2
      exit 1
    fi
    PIPELINE_RECORD="pipeline=absent-accepted"
  elif [ "${PIPELINE_SHA:-}" != "$MR_HEAD" ]; then
    echo "error: the head pipeline of $URL ran on ${PIPELINE_SHA:-unknown}, not on the head commit $MR_HEAD being merged, so it says nothing about it; re-run once the head's own pipeline exists" >&2
    exit 1
  elif [ "${PIPELINE_STATUS:-}" != success ]; then
    echo "error: the pipeline for head commit $MR_HEAD of $URL is ${PIPELINE_STATUS:-unknown}, not success" >&2
    exit 1
  else
    PIPELINE_RECORD="pipeline=success:$PIPELINE_SHA"
  fi
  PINNED_HEAD=$MR_HEAD
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Durable before destructive: the record of what authorized this merge is written
# and confirmed on disk BEFORE the forge is called, so an interrupted or failed
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
  echo "provider=$PROVIDER"
  echo "authority=$AUTHORITY"
  [ -z "$PINNED_HEAD" ] || echo "pinned_head=$PINNED_HEAD"
  [ -z "$PIPELINE_RECORD" ] || echo "$PIPELINE_RECORD"
  echo "recorded=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$APPROVAL" || {
  echo "error: could not record the merge approval for $ID" >&2
  exit 1
}
grep -qxF "authority=$AUTHORITY" "$APPROVAL" || {
  echo "error: merge approval recording failed for $ID" >&2
  exit 1
}
if [ -n "$PINNED_HEAD" ] && ! grep -qxF "pinned_head=$PINNED_HEAD" "$APPROVAL"; then
  echo "error: merge approval recording failed for $ID" >&2
  exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if [ "$PROVIDER" = gitlab ]; then
  # --yes skips glab's confirmation prompt and --auto-merge=false keeps the
  # merge immediate, so a guarded path can neither hang on a human nor report
  # success for a merge that was only queued behind a pipeline.
  glab mr merge "$PR_NUMBER" --repo "$GITLAB_PROJECT" --sha "$PINNED_HEAD" \
    --auto-merge=false --yes "${merge_args[@]+"${merge_args[@]}"}" "$@"
else
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
fi
