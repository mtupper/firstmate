#!/usr/bin/env bash
# fm-fleet-feed.sh - render this firstmate home's live state as the dashboard's
# fleet feed.
#
# A thin projection OVER bin/fm-fleet-snapshot.sh, in the same shape as
# bin/fm-bearings-snapshot.sh: it never parses state files itself. It shells out
# to `fm-fleet-snapshot.sh --json`, adds the project registry and a bounded
# read-only look at each clone, and maps that evidence onto the renderer's
# contract. The snapshot already folds status logs through
# bin/fm-classify-lib.sh, so keyed open decisions arrive decided, not re-parsed.
#
# The output contract is owned by the dashboard project, NOT by this script:
#   projects/dashboard/DOCS/data-contract.md
#   projects/dashboard/schema/fleet.schema.json
# They live in a different repository and the renderer is updated in step with
# them, so this script obeys the schema and never extends it. Check output with
# the dashboard's own checker: `pnpm data:check <path>`.
#
# READ-ONLY toward projects. It reads clones under projects/ and writes only the
# feed, and it REFUSES an output path inside the projects root (AGENTS.md hard
# rule 1). It makes no network call, takes no lock, and mutates no fleet state.
#
# Absent is not empty. The renderer draws a missing field as "not recorded" and
# an empty array as "checked, and there was nothing", so this script emits an
# empty array only where it genuinely checked:
#   - decisions, blockers, captainTasks and agentTasks are emitted (possibly
#     empty) when the backlog was readable, and omitted entirely when it was not.
#   - repo, updatedAt, executiveSummary and currentStatus are emitted only when
#     this home holds the evidence behind them.
#   - progress, targets, nextMilestone and sprintReview are ALWAYS omitted:
#     firstmate records no percentage, target, milestone or sprint, and a
#     derived-looking number with no source behind it is the failure this feed
#     exists to prevent.
#
# It fails loudly rather than emitting a half-feed that renders as false calm.
# The whole document is built in memory and written atomically, so a refused run
# leaves the previous feed untouched. Fatal conditions:
#   - jq missing, or the canonical snapshot failing or not matching its schema id
#   - no project registry (nothing could be grounded)
#   - a project name that is not a valid feed id, or a duplicate registry entry
#   - a structured backlog row with no repo, or an unattributable free-form row
#     in the current sections (real work the feed would silently drop)
#   - an output path inside the projects root
#
# Usage:
#   fm-fleet-feed.sh                        write $FM_HOME/data/fleet-feed.json
#   fm-fleet-feed.sh --out <path>           write somewhere else
#   fm-fleet-feed.sh --stdout               print the feed, write nothing
#   fm-fleet-feed.sh --active-days <n>      recency window for active (default 14)
#   fm-fleet-feed.sh -h | --help            print this usage
set -u

CONTRACT_VERSION=1.0.0
SNAPSHOT_SCHEMA=fm-fleet-snapshot.v1
ACTIVE_DAYS_DEFAULT=14
CLONE_READ_TIMEOUT=${FM_FLEET_FEED_CLONE_TIMEOUT:-10}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REGISTRY="$DATA/projects.md"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'fm-fleet-feed: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

OUT=
OUT_GIVEN=0
TO_STDOUT=0
ACTIVE_DAYS=$ACTIVE_DAYS_DEFAULT
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT=${1:-}; OUT_GIVEN=1 ;;
    --out=*) OUT=${1#--out=}; OUT_GIVEN=1 ;;
    --stdout) TO_STDOUT=1 ;;
    --active-days) shift; ACTIVE_DAYS=${1:-} ;;
    --active-days=*) ACTIVE_DAYS=${1#--active-days=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$ACTIVE_DAYS" in
  ''|*[!0-9]*) die "--active-days must be a non-negative integer" 2 ;;
esac
[ "$OUT_GIVEN" -eq 1 ] && [ -z "$OUT" ] && die "--out needs a path" 2
[ "$TO_STDOUT" -eq 1 ] && [ "$OUT_GIVEN" -eq 1 ] && die "--stdout and --out are mutually exclusive" 2
[ -n "$OUT" ] || OUT="$DATA/fleet-feed.json"

command -v jq >/dev/null 2>&1 || die "jq not found"
[ -f "$REGISTRY" ] || die "no project registry at $REGISTRY; nothing can be grounded"

# --- output-path guard (AGENTS.md hard rule 1) ------------------------------
# Firstmate reads projects and crewmates change them. Resolve the output's
# parent physically so a symlink or .. cannot walk the feed into a clone.
if [ "$TO_STDOUT" -eq 0 ]; then
  out_dir=$(dirname "$OUT")
  out_dir=$(cd "$out_dir" 2>/dev/null && pwd -P) \
    || die "output directory does not exist: $(dirname "$OUT")"
  OUT="$out_dir/$(basename "$OUT")"
  if projects_dir=$(cd "$PROJECTS" 2>/dev/null && pwd -P); then
    case "$out_dir" in
      "$projects_dir"|"$projects_dir"/*)
        die "refusing to write inside the projects root ($projects_dir); firstmate does not write to projects" 2
        ;;
    esac
  fi
fi

# --- canonical snapshot -----------------------------------------------------
SNAP=$("$SNAPSHOT" --json) || die "canonical snapshot failed"
printf '%s' "$SNAP" | jq -e --arg want "$SNAPSHOT_SCHEMA" '.schema == $want' >/dev/null 2>&1 \
  || die "canonical snapshot is not $SNAPSHOT_SCHEMA"

GENERATED=$(printf '%s' "$SNAP" | jq -r '.generated // ""')
case "$GENERATED" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
  *) die "canonical snapshot has no usable generated timestamp: '$GENERATED'" ;;
esac

# Recency cutoff, derived from the snapshot's own observation time so a
# deterministic FM_SNAPSHOT_NOW gives a deterministic active/dormant split.
gen_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$GENERATED" +%s 2>/dev/null \
  || date -u -d "$GENERATED" +%s 2>/dev/null) \
  || die "cannot read the snapshot timestamp on this platform: $GENERATED"
cut_epoch=$((gen_epoch - ACTIVE_DAYS * 86400))
CUTOFF=$(date -u -r "$cut_epoch" +%Y-%m-%d 2>/dev/null \
  || date -u -d "@$cut_epoch" +%Y-%m-%d 2>/dev/null) \
  || die "cannot compute the recency cutoff on this platform"

# --- registry ---------------------------------------------------------------
# One record per registered project: its name and its description. The registry
# LINE FORMAT and the delivery-posture mapping are owned by
# bin/fm-project-mode.sh; this only splits name from description and delegates
# the posture, so the two cannot drift.
REGISTRY_TSV=$(awk '
  /^- / {
    line = $0
    sub(/^- +/, "", line)
    name = line
    sub(/[ \t].*$/, "", name)
    rest = line
    sub(/^[^ \t]+[ \t]*/, "", rest)
    if (substr(rest, 1, 1) == "[") {
      i = index(rest, "]")
      if (i > 0) rest = substr(rest, i + 1)
    }
    sub(/^[ \t]*-[ \t]*/, "", rest)
    if (name != "") printf "%s\t%s\n", name, rest
  }
' "$REGISTRY")
[ -n "$REGISTRY_TSV" ] || die "project registry at $REGISTRY lists no projects"

REGISTRY_JSON='[]'
while IFS=$'\t' read -r rname rdesc; do
  [ -n "$rname" ] || continue
  posture=$("$SCRIPT_DIR/fm-project-mode.sh" --raw "$rname" 2>/dev/null) || posture=
  REGISTRY_JSON=$(jq -n \
    --argjson acc "$REGISTRY_JSON" \
    --arg name "$rname" \
    --arg desc "$rdesc" \
    --arg mode "${posture%% *}" \
    --arg yolo "${posture##* }" \
    '$acc + [{name:$name, desc:$desc, mode:(if $mode=="" then null else $mode end),
              yolo:(if $yolo=="" then null else $yolo end)}]')
done <<EOF
$REGISTRY_TSV
EOF

# --- clone facts ------------------------------------------------------------
# Bounded, local, read-only. The home's own repo answers for a project named
# after it, which is how firstmate's own work reaches the feed.
clone_path() {  # <project-name>
  local name=$1
  if [ -e "$PROJECTS/$name/.git" ]; then
    printf '%s\n' "$PROJECTS/$name"
  elif [ "$(basename "$FM_HOME")" = "$name" ] && [ -e "$FM_HOME/.git" ]; then
    printf '%s\n' "$FM_HOME"
  fi
}

# Turn a git remote into a short label: github.com/owner/repo, /path/to/repo.
# The scp-form separator is replaced with prefix/suffix removal rather than
# pattern replacement, whose escaping differs on stock macOS Bash 3.2.
remote_label() {  # <url>
  local u=${1%.git}
  u=${u#*://}
  u=${u#*@}
  case "$u" in
    *:*) u="${u%%:*}/${u#*:}" ;;
  esac
  printf '%s\n' "$u"
}

clone_facts_json() {  # <project-name...>
  local name path url branch dirty acc='[]'
  for name in "$@"; do
    path=$(clone_path "$name")
    if [ -z "$path" ]; then
      acc=$(jq -n --argjson acc "$acc" --arg name "$name" \
        '$acc + [{name:$name, read:"absent", repo:null, branch:null, dirty:null, path:null}]')
      continue
    fi
    url=$(fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" remote get-url origin 2>/dev/null) || url=
    branch=$(fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=
    if fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" diff --quiet HEAD -- >/dev/null 2>&1; then
      dirty=false
    else
      dirty=true
    fi
    [ -n "$branch" ] || dirty=null
    acc=$(jq -n --argjson acc "$acc" \
      --arg name "$name" \
      --arg path "$path" \
      --arg repo "$(if [ -n "$url" ]; then remote_label "$url"; fi)" \
      --arg branch "$branch" \
      --argjson dirty "${dirty:-null}" \
      '$acc + [{name:$name,
                read:(if $branch == "" then "unreadable" else "ok" end),
                path:$path,
                repo:(if $repo == "" then null else $repo end),
                branch:(if $branch == "" then null else $branch end),
                dirty:$dirty}]')
  done
  printf '%s' "$acc"
}

# The feed covers every registered project plus every repository the backlog or
# a live task actually names. Dropping an unregistered repository would hide
# real work behind a registration gap, which is the confident lie this feed is
# meant to prevent; it is disclosed per project instead.
NAMES=$(jq -r -n \
  --argjson reg "$REGISTRY_JSON" \
  --argjson snap "$SNAP" '
  ([$reg[].name]
   + [$snap.backlog.records[]? | select(.structured) | .repo // empty]
   + [$snap.tasks[]? | select(.kind != "secondmate")
      | (.backlog.repo // ((.project // "") | split("/") | last) // empty)])
  | map(select(. != null and . != "")) | unique | .[]')
[ -n "$NAMES" ] || die "no projects found in the registry, the backlog or live task records"

# Every name becomes a URL segment in the report and a path segment in the clone
# read, so it is validated before it reaches either.
NAME_LIST=()
while IFS= read -r project_name; do
  [ -n "$project_name" ] || continue
  case "$project_name" in
    *[!a-z0-9-]*|-*|*-|*--*)
      die "project name is not a usable feed id: \"$project_name\" (needs lower-case words joined by single dashes)" ;;
  esac
  [ "${#project_name}" -le 60 ] \
    || die "project name is too long for a feed id: \"$project_name\" (at most 60 characters)"
  NAME_LIST+=("$project_name")
done <<EOF
$NAMES
EOF

CLONES=$(clone_facts_json "${NAME_LIST[@]}")

# --- projection -------------------------------------------------------------
RESULT=$(printf '%s' "$SNAP" | jq \
  --argjson registry "$REGISTRY_JSON" \
  --argjson clones "$CLONES" \
  --arg names "$NAMES" \
  --arg contract "$CONTRACT_VERSION" \
  --arg generated "$GENERATED" \
  --arg cutoff "$CUTOFF" \
  --arg home "$FM_HOME" \
  --argjson active_days "$ACTIVE_DAYS" '
def trunc($n):
  if . == null then null
  else (tostring | gsub("\\s+"; " ")
        | if length > $n then (.[:$n - 1] + "…") else . end)
  end;
def question: trunc(199) | if endswith("?") then . else . + "?" end;
def clean:
  if type == "object" then with_entries(select(.value != null)) | with_entries(.value |= clean)
  elif type == "array" then map(clean)
  else . end;
def isdate: (. // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
def dateof: if isdate then . else null end;
def held: (.hold_reason != null) or ((.unresolved_blocker_ids // [] | length) > 0);
def n($one; $many): if . == 1 then "\(.) \($one)" else "\(.) \($many)" end;
def proj_of: (.backlog.repo // ((.project // "") | split("/") | last) // "");

. as $snap
| ($names | split("\n") | map(select(. != ""))) as $names
| ($registry | INDEX(.name)) as $reg
| ($clones | INDEX(.name)) as $clone
| ($snap.backlog.present) as $backlog_present
| ([$snap.tasks[]? | select(.kind != "secondmate")]) as $live
| ($snap.main_inventory.orphan_in_flight // []) as $orphans

# --- fatal source problems, collected before anything is emitted ------------
| ([ $registry | group_by(.name)[] | select(length > 1)
       | "duplicate registry entry for \(.[0].name)" ]
   + [ $snap.backlog.records[]? | select(.structured and ((.repo // "") == ""))
       | "backlog item \(.id) records no repo, so its work cannot be attributed to a project" ]
   + (if ($snap.main_inventory.unstructured_current_count // 0) > 0
      then ["\($snap.main_inventory.unstructured_current_count) free-form row(s) in the current backlog sections cannot be attributed to a project; the feed would silently drop that work"]
      else [] end)) as $problems

| if ($problems | length) > 0 then {problems: $problems, feed: null} else

# --- per-project evidence ---------------------------------------------------
([ $names[]
   | . as $name
   | ($reg[$name] // null) as $r
   | ($clone[$name] // {read:"absent"}) as $c
   | ([$snap.backlog.records[]? | select(.structured and .repo == $name)]) as $recs
   | ([$live[] | select(proj_of == $name)]) as $tasks
   | ($recs | map(select(.state == "in_flight"))) as $inflight
   | ($recs | map(select(.state == "queued"))) as $queued
   | ($recs | map(select(.state == "done"))) as $done
   | ($recs | map(select(.state != "done"))) as $open
   | ($open | map(select(.hold_kind == "captain"))) as $captain_holds
   | ($open | map(select((.unresolved_blocker_ids // [] | length) > 0))) as $gated
   | ($open | map(select(.hold_reason != null and .hold_kind != "captain"))) as $other_holds
   | ($queued | map(select((held | not)))) as $ready
   | ([$tasks[] | select(.current_state.state == "working")]) as $working
   # A worker recorded in flight that is neither running nor deliberately
   # paused has stopped without saying so. `paused:` is a declared external
   # wait (bin/fm-classify-lib.sh owns that vocabulary), so it is not a stop.
   | ([$tasks[]
       | select((.backlog.state // "") == "in_flight"
                and .current_state.state != "working"
                and ((.paths.status_log.last_event.state // "") != "paused"))]) as $stopped
   | ([$tasks[] | . as $t | (.hints.open_decisions // [])[]
       | select(.verb == "needs-decision") | . + {task: $t.id}]) as $live_decisions
   | ([$tasks[] | . as $t | (.hints.open_decisions // [])[]
       | select(.verb == "blocked") | . + {task: $t.id}]) as $live_blocked
   | ([$tasks[] | select((.pr.url // "") != "" and (.backlog.state // "") != "done")]) as $open_prs
   | ($inflight | map(select(.id as $i | $orphans | index($i)))) as $orphaned
   | ([$recs[] | (.since | dateof), (.completion.date | dateof)]
      | map(select(. != null)) | sort | last) as $last_date
   | ($done | map(select((.completion.date | isdate)))
      | sort_by(.completion.date) | last) as $last_landed

   | (if (($tasks | length) > 0 and ($inflight | length) > 0) then true
      elif ($inflight | length) > 0 then true
      elif ($last_date != null and $last_date >= $cutoff) then true
      else false end) as $is_active

   | (if ($live_blocked | length) > 0 or ($stopped | length) > 0 then "blocked"
      elif ($open | length) > 0 and ($open | all(held)) then "blocked"
      elif ($captain_holds | length) > 0 or ($live_decisions | length) > 0
           or ($gated | length) > 0 or ($other_holds | length) > 0
           or ($orphaned | length) > 0 then "at-risk"
      elif ($recs | length) == 0 then "not-started"
      elif ($is_active | not) and ($open | length) > 0 then "paused"
      else "on-track" end) as $health

   | (if ($working | length) > 0 then 0
      elif ($inflight | length) > 0 then 1
      elif ($captain_holds | length) > 0 or ($live_decisions | length) > 0 then 2
      elif ($queued | length) > 0 then 3
      elif ($done | length) > 0 then 4
      else 5 end) as $rank

   # --- headline: the single most pressing grounded fact --------------------
   | (if ($recs | length) == 0 then
        (if (($r.desc // "") != "") then $r.desc
         else "No work is recorded for this project." end
         | sub(" *\\((added|corrected|updated)[^()]*\\)$"; ""))
      elif ($live_blocked | length) > 0 then
        "Work has stopped: \($live_blocked[0].summary)"
      elif ($stopped | length) > 0 then
        "\($stopped[0].id) is recorded in flight, but its worker is no longer running."
      elif $health == "blocked" then
        (if ($open | all(.hold_kind == "captain"))
         then "Every open item is waiting on the captain; \($open | length | n("item is"; "items are")) held."
         else "Every open item is held or waiting on other work; nothing can move." end)
      elif ($inflight | length) > 0 then
        "Under way: \($inflight[0].title)"
        + (if ($captain_holds | length) > 0
           then ", and \($captain_holds | length | n("decision waits"; "decisions wait")) on the captain." else "." end)
      elif ($captain_holds | length) > 0 then
        "\($captain_holds | length | n("decision waits"; "decisions wait")) on the captain; nothing is dispatched."
      elif ($queued | length) > 0 then
        "\($queued | length | n("item is"; "items are")) queued and nothing is dispatched"
        + (if $last_landed != null then "; \($last_landed.id) landed \($last_landed.completion.date)." else "." end)
      elif $last_landed != null then
        "Nothing is open. \($last_landed.id) landed \($last_landed.completion.date)."
      else "Nothing is open." end | trunc(200)) as $headline

   # --- decisions the captain owns -----------------------------------------
   | ([ $captain_holds[]
        | {question: (.title | question),
           why: (.hold_reason | trunc(400)),
           owner: "captain",
           urgency: (if .state == "in_flight" then "now"
                     elif .captain_actionable then "soon"
                     else "later" end)}
      ] + [ $live_decisions[]
        | {question: (.summary | question),
           why: ("A worker on \(.task) is parked until this is answered." | trunc(400)),
           owner: "captain",
           urgency: "now"}
      ]
      | sort_by(if .urgency == "now" then 0 elif .urgency == "soon" then 1 else 2 end)
      | .[:8]) as $decisions

   # --- what is actually stopping progress ----------------------------------
   | ([ $live_blocked[]
        | {title: (.summary | trunc(160)),
           detail: ("The worker on \(.task) reported itself blocked and is waiting for help." | trunc(500)),
           severity: "critical", owner: "agents",
           unblockedBy: "Firstmate unblocking the worker or reassigning the work."}
      ] + [ $stopped[]
        | {title: ("the worker on \(.id) is no longer running" | trunc(160)),
           detail: ("The item is recorded in flight, but its worker is gone and no pause was declared." | trunc(500)),
           severity: "critical", owner: "agents",
           unblockedBy: "Restarting the work or returning the item to the queue."}
      ] + [ $captain_holds[] | select(.state == "in_flight")
        | {title: (.title | trunc(160)),
           detail: (.hold_reason | trunc(500)),
           severity: "critical", owner: "captain",
           since: ((.since | dateof) | trunc(60)),
           unblockedBy: "The captain answering this hold."}
      ] + [ $orphaned[]
        | {title: ("\(.id) is recorded in flight with no worker" | trunc(160)),
           severity: "major", owner: "agents",
           since: ((.since | dateof) | trunc(60)),
           unblockedBy: "Dispatching it or returning it to the queue."}
      ] + [ $gated[]
        | {title: (.title | trunc(160)),
           detail: ("Waiting on \(.unresolved_blocker_ids | join(", "))." | trunc(500)),
           severity: "major", owner: "agents",
           since: ((.since | dateof) | trunc(60)),
           unblockedBy: ("\(.unresolved_blocker_ids | join(", ")) landing first." | trunc(300))}
      ] + [ $other_holds[]
        | {title: (.title | trunc(160)),
           detail: (.hold_reason | trunc(500)),
           severity: "major", owner: "shared",
           since: ((.since | dateof) | trunc(60)),
           unblockedBy: "The hold reason clearing."}
      ]
      | sort_by(if .severity == "critical" then 0 elif .severity == "major" then 1 else 2 end)
      | .[:8]) as $blockers

   # --- next three for each side --------------------------------------------
   | ([ $open_prs[]
        | {title: ("Decide on \(.pr.url)" | trunc(160)),
           why: ("The work is finished and waiting for the captain to say whether it lands." | trunc(300))}
      ] + [ $captain_holds[] | select(.state == "in_flight")
        | {title: (.title | trunc(160)),
           detail: (.hold_reason | trunc(400)),
           why: ("Work on \(.id) is stopped until this is answered." | trunc(300))}
      ] + [ $captain_holds[] | select(.state != "in_flight")
        | {title: (.title | trunc(160)),
           detail: (.hold_reason | trunc(400)),
           why: (if .captain_actionable
                 then "It is queued with nothing gating it, so it can be answered now."
                 else "It is queued behind other work." end | trunc(300))}
      ] | .[:3]) as $captain_tasks

   | ([ $ready[]
        | {title: (.title | trunc(160)),
           detail: (.body_excerpt | trunc(400)),
           why: ((if (.priority // "") != "" then "Queued at priority \(.priority) " else "Queued " end)
                 + "with nothing gating it." | trunc(300)),
           order_priority: (.priority // "99"),
           order_since: (.since // "9999-99-99")}
      ] | sort_by([.order_priority, .order_since])
        | map(del(.order_priority, .order_since))
        | .[:3]) as $agent_tasks

   # --- checkable facts behind the summary ----------------------------------
   | ([ {label: "Dispatched work",
         value: (if ($working | length) > 0 then ($working | length | n("worker running"; "workers running"))
                 elif ($inflight | length) > 0 then ($inflight | length | n("item in flight, no worker"; "items in flight, no worker"))
                 else "nothing dispatched" end | trunc(120)),
         state: (if ($stopped | length) > 0 or ($orphaned | length) > 0 then "bad"
                 elif ($working | length) > 0 then "good"
                 elif ($queued | length) > 0 then "watch"
                 else "good" end),
         evidence: (if ($tasks | length) > 0
                    then ("Task records: \([$tasks[].id] | join(", "))." | trunc(300))
                    else null end)},
        {label: "Decisions waiting on the captain",
         value: (if ($decisions | length) > 0 then ($decisions | length | n("open"; "open")) else "none open" end | trunc(120)),
         state: (if ($decisions | any(.urgency == "now")) then "bad"
                 elif ($decisions | length) > 0 then "watch" else "good" end),
         evidence: (if ($captain_holds | length) > 0
                    then ("Held items: \([$captain_holds[].id] | join(", "))." | trunc(300))
                    else null end)},
        {label: "Items waiting on other work",
         value: (if ($gated | length) > 0 then ($gated | length | n("item gated"; "items gated")) else "none gated" end | trunc(120)),
         state: (if ($gated | length) > 0 then "watch" else "good" end),
         evidence: (if ($gated | length) > 0
                    then ("Waiting on \([$gated[].unresolved_blocker_ids[]] | unique | join(", "))." | trunc(300))
                    else null end)},
        {label: "Local copy",
         value: (if $c.read == "ok"
                 then ("\($c.branch)" + (if $c.dirty then ", uncommitted changes" else ", clean" end))
                 elif $c.read == "absent" then "no local copy in this home"
                 else "could not be read" end | trunc(120)),
         state: (if $c.read == "ok" and ($c.dirty | not) then "good"
                 elif $c.read == "ok" then "watch"
                 else "unknown" end),
         evidence: ($c.path | trunc(300))}
      ] + (if $r == null then
        [{label: "Project registry", value: "not registered", state: "watch",
          evidence: "Named by backlog items or live task records but absent from data/projects.md."}]
        else [] end)
      | .[:10]) as $signals

   | (($open | map(select(held)) | map(.since | dateof) | map(select(. != null)) | sort | first)) as $held_since

   | {
       id: $name,
       name: $name,
       status: (if $is_active then "active" else "dormant" end),
       health: $health,
       headline: $headline,
       rank: $rank,
       last_date: $last_date,
       updatedAt: $last_date,
       repo: ($c.repo | trunc(200)),

       executiveSummary: (if ($recs | length) == 0 then null else {
         lede: ("\($name) has \($recs | length | n("item"; "items")) recorded: "
                + "\($inflight | length) in flight, \($queued | length) queued, \($done | length) landed. "
                + (if ($decisions | length) > 0
                   then "\($decisions | length | n("decision waits"; "decisions wait")) on the captain. " else "No decision waits on the captain. " end)
                + (if ($blockers | length) > 0
                   then "\($blockers | length | n("thing is"; "things are")) stopping progress. " else "Nothing is stopping progress. " end)
                + (if $last_date != null then "Last activity \($last_date)." else "No dated activity recorded." end)
                | trunc(600)),
         metrics: [
           {label: "In flight", value: ($inflight | length | tostring),
            tone: (if ($stopped | length) > 0 then "bad" elif ($working | length) > 0 then "good" else "neutral" end)},
           {label: "Queued", value: ($queued | length | tostring), tone: "neutral"},
           {label: "Landed", value: ($done | length | tostring), tone: "good"},
           {label: "Captain decisions", value: ($decisions | length | tostring),
            tone: (if ($decisions | length) > 0 then "warn" else "good" end)},
           {label: "Stopping progress", value: ($blockers | length | tostring),
            tone: (if ($blockers | length) > 0 then "bad" else "good" end)},
           {label: "Last activity", value: (($last_date // "none") | trunc(24)), tone: "neutral"}
         ]
       } end),

       currentStatus: (if ($recs | length) == 0 and $c.read == "absent" and $r != null then null else {
         summary: ($headline
                   + (if $r != null and ($r.mode // "") != ""
                      then " Registered delivery posture: \($r.mode), autonomy \($r.yolo // "off")."
                      else "" end)
                   | trunc(600)),
         since: (if $held_since != null then "held since \($held_since)" else null end | trunc(60)),
         signals: $signals
       } end),

       decisions: (if $backlog_present then $decisions else null end),
       blockers: (if $backlog_present then $blockers else null end),
       captainTasks: (if $backlog_present then $captain_tasks else null end),
       agentTasks: (if $backlog_present then $agent_tasks else null end)
     }
 ]) as $all

# Order within each section: strongest live evidence first, then most recent
# activity, then name. `order` is per-section, so both start at 0.
| ([$all[] | select(.status == "active")]
   | group_by(.rank) | map(sort_by([(.last_date // ""), .name]) | reverse) | add // []
   | to_entries | map(.value + {order: .key})) as $active
| ([$all[] | select(.status == "dormant")]
   | group_by(.rank) | map(sort_by([(.last_date // ""), .name]) | reverse) | add // []
   | to_entries | map(.value + {order: .key})) as $dormant

| {problems: [],
   feed: ({
     contractVersion: $contract,
     generatedAt: $generated,
     source: ("firstmate home \($home | split("/") | .[-2:] | join("/")): project registry, backlog, task records and status logs"
              | trunc(200)),
     generator: "bin/fm-fleet-feed.sh over fm-fleet-snapshot.v1",
     projects: (($active + $dormant) | map(del(.rank, .last_date)))
   } | clean)}
end
') || die "projection failed"

PROBLEMS=$(printf '%s' "$RESULT" | jq -r '.problems[]?')
if [ -n "$PROBLEMS" ]; then
  printf 'fm-fleet-feed: refusing to write a feed that would misreport this home.\n' >&2
  printf '%s\n' "$PROBLEMS" | sed 's/^/  - /' >&2
  exit 1
fi

FEED=$(printf '%s' "$RESULT" | jq '.feed')
DUPES=$(printf '%s' "$FEED" | jq -r '[.projects[].id] | group_by(.)[] | select(length > 1) | .[0]')
[ -n "$DUPES" ] && die "duplicate project id(s) in the feed: $(printf '%s' "$DUPES" | tr '\n' ' ')"
COUNT=$(printf '%s' "$FEED" | jq '.projects | length')
[ "$COUNT" -gt 0 ] || die "the feed came out with no projects; refusing to write a report that says the fleet is empty"

if [ "$TO_STDOUT" -eq 1 ]; then
  printf '%s\n' "$FEED"
  exit 0
fi

# Atomic: a failed write never replaces a good feed with a half one.
TMP=$(mktemp "$OUT.XXXXXX") || die "cannot create a temporary file next to $OUT"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$FEED" > "$TMP" || die "cannot write $TMP"
mv "$TMP" "$OUT" || die "cannot move the new feed into place at $OUT"
trap - EXIT

ACTIVE=$(printf '%s' "$FEED" | jq '[.projects[] | select(.status == "active")] | length')
printf '%s: %s projects - %s active, %s dormant (active window: %s days, since %s)\n' \
  "$OUT" "$COUNT" "$ACTIVE" "$((COUNT - ACTIVE))" "$ACTIVE_DAYS" "$CUTOFF"
