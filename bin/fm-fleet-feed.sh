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
# SECOND MATES. Work routed to a registered secondmate lives in that mate's own
# home, so this home's backlog and task records cannot see it. The snapshot's
# secondmate_current records carry each readable mate's durable work with
# per-item project attribution, and this projection folds that work into the
# owning project's card: MERGED by default, because the captain thinks in
# projects, not in who does the work. The fold is expressed entirely inside the
# existing dashboard contract - mate items raise the same counts, metrics,
# decisions, blockers, tasks and headline branches as this home's own work - so
# no contract change is needed. The distinction stays available rather than
# prominent: a "Second mate" signal names the mate and its share, and folded
# decisions, blockers and tasks name the mate in their supporting text.
# The fold is read-only toward the mate homes and reads only what the snapshot
# already collected. A mate summary reports a held in-flight item on both its
# in-flight and its queued surface, so the fold deduplicates and counts each item
# once, on its state, and reads that item's hold the same way this home reads its
# own.
#
# Disclosure, so a quiet card never silently hides routed work. A mate that could
# not be read leaves evidence of a home but none of work, so it is disclosed on
# every project the fleet records it serving. A mate that was only partially read
# is disclosed where its own rows land. A mate whose records predate per-project
# reporting, and rows a bounded read cut off, are work this home knows exists but
# cannot place on any project - those rows are precisely the ones whose project is
# unknown, so they are disclosed on EVERY card rather than guessed onto a subset,
# and an otherwise empty card says so instead of claiming nothing is recorded.
# None of those is fatal: refusing the whole feed because one remote mate has not
# self-updated would blind every other project's card. Only a mate reporting
# per-project attribution and still naming no project for an item is fatal,
# exactly like this home's own unattributable work.
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
#   - a second mate that reports per-project attribution and still names no
#     project for an item, or a mate outside the snapshot's own read window
#   - an output path inside the projects root
#
# Usage:
#   fm-fleet-feed.sh                        write $FM_HOME/data/fleet-feed.json
#   fm-fleet-feed.sh --out <path>           write somewhere else
#   fm-fleet-feed.sh --stdout               print the feed, write nothing
#   fm-fleet-feed.sh --active-days <n>      recency window for active (default 14)
#   fm-fleet-feed.sh -h | --help            print this usage
#
# Environment:
#   FM_FLEET_FEED_CLONE_TIMEOUT   seconds bounding each read of a project clone
#                                 (default 10); must be a positive integer
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
# bin/fm-timeout-lib.sh puts the obligation on the caller: `timeout 0` and the
# perl fallback's `alarm 0` both DISABLE the deadline, so a non-positive bound
# is not a bound and must be refused before any read runs unguarded.
case "$CLONE_READ_TIMEOUT" in
  ''|*[!0-9]*) die "FM_FLEET_FEED_CLONE_TIMEOUT must be a positive integer of seconds" 2 ;;
esac
[ "$CLONE_READ_TIMEOUT" -gt 0 ] \
  || die "FM_FLEET_FEED_CLONE_TIMEOUT must be a positive integer of seconds; 0 would disable the bound it exists to enforce" 2
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

# A push URL is usable when it still names somewhere a push could go: any URL,
# scp or local-path form qualifies. A remote whose push URL was deliberately
# broken (e.g. set to "DISABLED-no-push-to-upstream" on a fork's upstream) has
# none of a git URL's separators and is refused.
push_url_usable() {  # <push-url>
  case "$1" in
    '') return 1 ;;
    *://*|*:*|*/*) return 0 ;;
    *) return 1 ;;
  esac
}

# The label names the repository this home can actually push to, because that
# is where its work lands. Origin wins when its push URL is usable; otherwise
# the first other remote with a usable push URL answers; and with no pushable
# remote at all, origin's fetch URL still names where the code came from.
pushable_remote_url() {  # <clone-path>
  local path=$1 url remote remotes
  url=$(fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" remote get-url --push origin 2>/dev/null) || url=
  if push_url_usable "$url"; then printf '%s\n' "$url"; return 0; fi
  remotes=$(fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" remote 2>/dev/null) || remotes=
  while IFS= read -r remote; do
    [ -n "$remote" ] && [ "$remote" != origin ] || continue
    url=$(fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" remote get-url --push "$remote" 2>/dev/null) || continue
    if push_url_usable "$url"; then printf '%s\n' "$url"; return 0; fi
  done <<EOF
$remotes
EOF
  fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" remote get-url origin 2>/dev/null
}

clone_facts_json() {  # <project-name...>
  local name path url branch dirty diff_rc read_state acc='[]'
  for name in "$@"; do
    path=$(clone_path "$name")
    if [ -z "$path" ]; then
      acc=$(jq -n --argjson acc "$acc" --arg name "$name" \
        '$acc + [{name:$name, read:"absent", repo:null, branch:null, dirty:null, path:null}]')
      continue
    fi
    url=$(pushable_remote_url "$path") || url=
    branch=$(fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=
    # `git diff --quiet` answers 0 for clean and 1 for dirty; anything else -
    # 124 for the bound being hit (bin/fm-timeout-lib.sh), or a git error - is
    # not an answer, so the read reports itself unreadable rather than claiming
    # a working-tree state it never saw.
    diff_rc=0
    fm_run_timed "$CLONE_READ_TIMEOUT" git -C "$path" diff --quiet HEAD -- >/dev/null 2>&1 \
      || diff_rc=$?
    case "$diff_rc" in
      0) dirty=false ;;
      1) dirty=true ;;
      *) dirty=null ;;
    esac
    [ -n "$branch" ] || dirty=null
    if [ -n "$branch" ] && [ "$dirty" != null ]; then read_state=ok; else read_state=unreadable; fi
    acc=$(jq -n --argjson acc "$acc" \
      --arg name "$name" \
      --arg path "$path" \
      --arg repo "$(if [ -n "$url" ]; then remote_label "$url"; fi)" \
      --arg branch "$branch" \
      --arg read "$read_state" \
      --argjson dirty "${dirty:-null}" \
      '$acc + [{name:$name,
                read:$read,
                path:$path,
                repo:(if $repo == "" then null else $repo end),
                branch:(if $branch == "" then null else $branch end),
                dirty:$dirty}]')
  done
  printf '%s' "$acc"
}

# The feed covers every registered project plus every repository the backlog, a
# live task, or a readable second mate's work actually names, plus the projects
# a mate that needs disclosure serves. Dropping an unregistered repository would
# hide real work behind a registration gap, which is the confident lie this feed
# is meant to prevent; it is disclosed per project instead.
NAMES=$(jq -r -n \
  --argjson reg "$REGISTRY_JSON" \
  --argjson snap "$SNAP" '
  ([$reg[].name]
   + [$snap.backlog.records[]? | select(.structured) | .repo // empty]
   + [$snap.tasks[]? | select(.kind != "secondmate")
      | (.backlog.repo // ((.project // "") | split("/") | last) // empty)]
   + [$snap.secondmate_current.records[]? | select(.provenance.selected == "structured-home")
      | ((.in_flight // [])[], (.queued // [])[], (.landed // [])[], (.decisions_open // [])[])
      | .repo // empty]
   + [$snap.secondmate_current.records[]?
      | select((.provenance.selected != "structured-home")
               or (.provenance.summary_valid != true)
               or (.in_flight == null))
      | (.projects // [])[]])
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
# ONE rule for the whole document. A worker is called gone, missing or stopped
# ONLY where positive evidence says so: its run reached a terminal failure, or
# nothing could speak for it AND its endpoint is absent or dead. The absence of
# a `working` state is never itself that evidence - `unknown` on a live endpoint
# is bin/fm-crew-state.sh declining to claim anything, and `parked` and `paused`
# are declared waits. Every sentence, title, detail, metric, signal and health
# branch below reads worker_gone rather than re-deriving its own test.
def worker_gone:
  (.current_state.state == "failed")
  or (.current_state.state == "unknown"
      and ((.endpoint.status // "") == "absent"
           or (.endpoint.status // "") == "dead"));
# A finished run whose backlog row still says in flight is bookkeeping drift,
# not a departure: the run declared its own completion, so the remedy is to
# mark the item done, never to restart or requeue finished work.
def run_finished: (.current_state.state == "done");
# A mate summary bounds several surfaces, only four of which carry work this feed
# folds. Truncating the other surfaces costs the feed nothing, so a disclosure
# that fired on them would be a false alarm on an otherwise complete card.
def work_surface: (.surface | IN("in_flight", "queued", "landed", "decisions_open"));
# The card is read by the captain, so an omitted surface is named in the words
# the rest of the card uses, never by its record field name.
def surface_words:
  {"in_flight": "in flight", "queued": "queued", "landed": "landed",
   "decisions_open": "waiting on a decision"}[.surface] // .surface;

. as $snap
| ($names | split("\n") | map(select(. != ""))) as $names
| ($registry | INDEX(.name)) as $reg
| ($clones | INDEX(.name)) as $clone
| ($snap.backlog.present) as $backlog_present
| ([$snap.tasks[]? | select(.kind != "secondmate")]) as $live
| ($snap.main_inventory.orphan_in_flight // []) as $orphans
| ($snap.secondmate_current.records // []) as $mates
| ([$mates[] | select(.provenance.selected == "structured-home")]) as $mates_read
| ([$mates[] | select(.provenance.selected != "structured-home")]) as $mates_unread
# A mate whose summary predates per-item project attribution reports no in_flight
# surface at all, and none of its rows can carry a repo. Its work is DISCLOSED,
# never folded and never fatal: refusing the whole feed because one remote mate
# has not self-updated yet would blind every other card in the feed, which is the
# failure this feed exists to prevent.
| ([$mates_read[] | select(.in_flight != null)]) as $mates_folded
| ([$mates_read[] | select(.in_flight == null)]) as $mates_blind

# --- fatal source problems, collected before anything is emitted ------------
| ([ $registry | group_by(.name)[] | select(length > 1)
       | "duplicate registry entry for \(.[0].name)" ]
   + [ $snap.backlog.records[]? | select(.structured and ((.repo // "") == ""))
       | "backlog item \(.id) records no repo, so its work cannot be attributed to a project" ]
   + (if ($snap.main_inventory.unstructured_current_count // 0) > 0
      then ["\($snap.main_inventory.unstructured_current_count) free-form row(s) in the current backlog sections cannot be attributed to a project; the feed would silently drop that work"]
      else [] end)
   + (if ($snap.secondmate_current.truncated // 0) > 0
      then ["\($snap.secondmate_current.truncated) second mate(s) fall outside the snapshot window (FM_SNAPSHOT_SECONDMATES); their work would be silently invisible"]
      else [] end)
   + ([ $mates_folded[] | . as $m
        | ((.in_flight // [])[], (.queued // [])[], (.landed // [])[], (.decisions_open // [])[])
        | select((.repo // "") == "")
        | "the \($m.id) second mate records work that names no project (\(.id // "unnamed item")); the feed would silently drop that work" ]
      | unique)) as $problems

| if ($problems | length) > 0 then {problems: $problems, feed: null} else

# --- per-project evidence ---------------------------------------------------
([ $names[]
   | . as $name
   | ($reg[$name] // null) as $r
   | ($clone[$name] // {read:"absent"}) as $c
   | ([$snap.backlog.records[]? | select(.structured and .repo == $name)]) as $recs
   | ([$live[] | select(proj_of == $name)]) as $tasks

   # --- the work carried by the second mates serving this project -----------
   # Read from the structured mate records in the snapshot, never from mate chat.
   | ([ $mates_folded[] | . as $m | (.in_flight // [])[]
        | select(.repo == $name) | . + {mate:$m.id} ]) as $m_inflight
   # A mate summary reports a HELD in-flight item on BOTH its in_flight and its
   # queued surface, because in_flight is the state of the item while queued is
   # its current role. Fold it once, on its state, so a single item is never
   # counted as both in flight and queued the way rows from this home never are.
   | ([$m_inflight[] | "\(.mate) \(.id)"]) as $m_inflight_keys
   | ([ $mates_folded[] | . as $m | (.queued // [])[]
        | select(.repo == $name) | . + {mate:$m.id}
        | ("\(.mate) \(.id)") as $k
        | select(($m_inflight_keys | index($k)) == null) ]) as $m_queued
   | ([ $mates_folded[] | . as $m | (.landed // [])[]
        | select(.repo == $name) | . + {mate:$m.id} ]) as $m_landed
   | ([ $mates_folded[] | . as $m | (.decisions_open // [])[]
        | select(.repo == $name) | . + {mate:$m.id} ]) as $m_dec_all
   # The holds carried by those deduplicated in-flight rows. This home reads the
   # same holds straight off its own in-flight rows, so read them here too rather
   # than losing them along with the duplicate.
   | ($m_inflight | map(select(.hold_reason != null and .hold_kind != null))) as $m_inflight_held
   | ($m_dec_all | map(select(.verb == "blocked"))) as $m_blocked
   | (($m_dec_all | map(select(.verb != "blocked")))
      + ($m_inflight_held | map(select(.hold_kind == "captain")
          | {id, key: .id, verb: "captain-hold", summary: .title,
             reason: .hold_reason, mate}))) as $m_decisions
   | ($m_inflight | map(select(.child_state == "working"))) as $m_working
   # The same raised-PR rule as this home: a running worker may be mid-CI, so
   # only a not-working item with a PR is offered to the captain.
   | ([$m_inflight[] | select((.pr_url // "") != "" and .child_state != "working")]) as $m_open_prs
   | ($m_queued | map(select((.unresolved_blocker_ids // []) | length > 0))) as $m_gated
   | (($m_queued | map(select(((.unresolved_blocker_ids // []) | length) == 0
        and .hold_reason != null and ((.hold_kind // "") != "captain"))))
      + ($m_inflight_held | map(select((.hold_kind // "") != "captain")))) as $m_other_holds
   | ($m_queued | map(select(((.unresolved_blocker_ids // []) | length) == 0
        and .hold_reason == null and ((.hold_kind // "") != "captain")
        and ((.captain_actionable // false) | not)))) as $m_ready
   | (($m_inflight | length) + ($m_queued | length) + ($m_landed | length)) as $m_items
   | ([$m_inflight[].mate, $m_queued[].mate, $m_landed[].mate, $m_dec_all[].mate] | unique) as $m_ids

   # --- mates that owe this project a disclosure -----------------------------
   # A quiet card must never silently hide routed work.
   # A mate this home could not reach at all leaves no evidence of work, only of
   # a home, so it is disclosed against the projects the fleet records it serving.
   | ([ $mates_unread[] | select((.projects // []) | index($name)) ]) as $m_unread_here
   | ([ $mates_folded[] | select(.provenance.summary_valid != true)
        | select(((.projects // []) | index($name))
                 or ([((.in_flight // [])[], (.queued // [])[], (.landed // [])[], (.decisions_open // [])[])
                     | .repo] | index($name))) ]) as $m_partial_here
   # Work this home knows exists but CANNOT place on any project: rows from a
   # summary that predates per-project reporting, and rows the bounded read cut
   # off. Those rows are precisely the ones whose project is unknown, so the only
   # honest placement is every card; guessing a subset would leave the silent
   # card this fold exists to remove. Both disclose, neither is fatal.
   | ([ $mates_blind[]
        | (([(.queued // [])[], (.landed // [])[], (.decisions_open // [])[]]) | length) as $n
        | select($n > 0) | {mate: .id, items: $n} ]) as $m_blind_here
   | ([ $mates_folded[] | . as $m
        | ((.omitted // []) | map(select(work_surface)))
        | select(length > 0) | {mate: $m.id, omitted: .} ]) as $m_truncated_here
   | ((($m_blind_here | length) + ($m_truncated_here | length)) > 0) as $m_unplaced
   | ((if $m_items > 0 then
        [{label: "Second mate",
          value: ("with \($m_ids | join(", ")): \($m_inflight | length) under way, \($m_queued | length) queued, \($m_landed | length) landed"
                  | trunc(120)),
          state: (if ($m_blocked | length) > 0 then "bad"
                  elif ($m_decisions | length) + ($m_gated | length) + ($m_other_holds | length) > 0 then "watch"
                  else "good" end),
          evidence: ("Durable records of \($m_ids | join(", ")): \([($m_inflight + $m_queued + $m_landed)[].id] | join(", "))."
                     | trunc(300))}]
      else [] end)
      + [ $m_unread_here[]
        | {label: "Second mate",
           value: ("the \(.id) mate could not be read" | trunc(120)),
           state: "unknown",
           evidence: ((.current.reason // "no readable record") | trunc(300))} ]
      + [ $m_partial_here[]
        | {label: "Second mate",
           value: ("activity from the \(.id) mate may be incomplete" | trunc(120)),
           state: "unknown",
           evidence: ((.current.reason // "its records could not be fully read") | trunc(300))} ]
      + [ $m_blind_here[]
        | {label: "Second mate",
           value: ("work with the \(.mate) mate cannot be placed on a project" | trunc(120)),
           state: "unknown",
           evidence: ("Its records predate per-project reporting, so \(.items | n("item is"; "items are")) counted on no card here. Update that mate to a current firstmate."
                      | trunc(300))} ]
      + [ $m_truncated_here[]
        | {label: "Second mate",
           value: ("the \(.mate) mate carries more work than this feed could read" | trunc(120)),
           state: "unknown",
           evidence: ("Past the bounded read and counted on no card here: "
                      + ([.omitted[] | "\(.count) more \(surface_words)"] | join(", ")) + "."
                      | trunc(300))} ]) as $m_signals
   | ($recs | map(select(.state == "in_flight"))) as $inflight
   | ($recs | map(select(.state == "queued"))) as $queued
   | ($recs | map(select(.state == "done"))) as $done
   | ($recs | map(select(.state != "done"))) as $open
   | ($open | map(select(.hold_kind == "captain"))) as $captain_holds
   | ($open | map(select((.unresolved_blocker_ids // [] | length) > 0))) as $gated
   | ($open | map(select(.hold_reason != null and .hold_kind != "captain"))) as $other_holds
   | ($queued | map(select((held | not)))) as $ready
   | ([$tasks[] | select(.current_state.state == "working")]) as $working
   | ([$tasks[]
       | select((.backlog.state // "") == "in_flight")
       | select(worker_gone)]) as $stopped
   | ([$tasks[]
       | select((.backlog.state // "") == "in_flight")
       | select(run_finished)]) as $drifted
   | ([$tasks[] | . as $t | (.hints.open_decisions // [])[]
       | select(.verb == "needs-decision") | . + {task: $t.id}]) as $live_decisions
   | ([$tasks[] | . as $t | (.hints.open_decisions // [])[]
       | select(.verb == "blocked") | . + {task: $t.id}]) as $live_blocked
   # A raised PR is not finished work. While a worker is still running on the
   # item its pipeline may be mid-CI, so there is nothing for the captain to
   # decide yet and it is not offered as a decision.
   | ([$tasks[] | select((.pr.url // "") != "" and (.backlog.state // "") != "done"
                         and .current_state.state != "working")]) as $open_prs
   | ($inflight | map(select(.id as $i | $orphans | index($i)))) as $orphaned
   | ([$recs[] | (.since | dateof), (.completion.date | dateof)]
      + [$m_inflight[] | (.since | dateof)]
      + [$m_landed[] | (.completion.date | dateof)]
      | map(select(. != null)) | sort | last) as $last_date
   | (($done + $m_landed) | map(select((.completion.date | isdate)))
      | sort_by(.completion.date) | last) as $last_landed

   | (if ($inflight | length) + ($m_inflight | length) > 0 then true
      elif ($working | length) > 0 then true
      elif ($last_date != null and $last_date >= $cutoff) then true
      else false end) as $is_active

   | (if ($live_blocked | length) > 0 or ($stopped | length) > 0
        or ($m_blocked | length) > 0 then "blocked"
      elif ($open | length) > 0 and ($open | all(held))
           and ($m_inflight | length) == 0 and ($m_ready | length) == 0 then "blocked"
      elif ($captain_holds | length) > 0 or ($live_decisions | length) > 0
           or ($gated | length) > 0 or ($other_holds | length) > 0
           or ($m_decisions | length) > 0 or ($m_gated | length) > 0
           or ($m_other_holds | length) > 0
           or ($orphaned | length) > 0 then "at-risk"
      elif ($recs | length) == 0 and $m_items == 0 then "not-started"
      elif ($is_active | not)
           and (($open | length) > 0 or ($m_inflight | length) + ($m_queued | length) > 0) then "paused"
      else "on-track" end) as $health

   | (if ($working | length) + ($m_working | length) > 0 then 0
      elif ($inflight | length) + ($m_inflight | length) > 0 then 1
      elif ($captain_holds | length) > 0 or ($live_decisions | length) > 0
           or ($m_decisions | length) > 0 then 2
      elif ($queued | length) + ($m_queued | length) > 0 then 3
      elif ($done | length) + ($m_landed | length) > 0 then 4
      else 5 end) as $rank

   # --- headline: the single most pressing grounded fact --------------------
   | (($captain_holds | length) + ($m_decisions | length)) as $captain_wait_n
   | (if ($recs | length) == 0 and $m_items == 0 then
        # An empty card may not claim nothing is recorded while a second mate
        # holds work this home read but could not place on any project.
        (if $m_unplaced then
           "No work is recorded here, and a second mate holds work this home could not place."
         elif (($r.desc // "") != "") then $r.desc
         else "No work is recorded for this project." end
         | sub(" *\\((added|corrected|updated)[^()]*\\)$"; ""))
      elif ($live_blocked | length) > 0 then
        "Work has stopped: \($live_blocked[0].summary)"
      elif ($m_blocked | length) > 0 then
        "Work has stopped with the \($m_blocked[0].mate) second mate: \($m_blocked[0].summary)"
      elif ($stopped | length) > 0 then
        "\($stopped[0].id) is recorded in flight, but its worker is no longer running."
      elif $health == "blocked" then
        (if ($open | all(.hold_kind == "captain"))
         then "Every open item is waiting on the captain; \($open | length | n("item is"; "items are")) held."
         else "Every open item is held or waiting on other work; nothing can move." end)
      elif ($drifted | length) > 0 then
        "\($drifted[0].id) has finished, but the backlog still records it in flight."
      elif ($inflight | length) > 0 then
        "Under way: \($inflight[0].title)"
        + (if $captain_wait_n > 0
           then ", and \($captain_wait_n | n("decision waits"; "decisions wait")) on the captain." else "." end)
      elif ($m_inflight | length) > 0 then
        "Under way with the \($m_inflight[0].mate) second mate: \($m_inflight[0].title)"
        + (if $captain_wait_n > 0
           then ", and \($captain_wait_n | n("decision waits"; "decisions wait")) on the captain." else "." end)
      elif $captain_wait_n > 0 then
        "\($captain_wait_n | n("decision waits"; "decisions wait")) on the captain; nothing is dispatched."
      elif ($queued | length) + ($m_queued | length) > 0 then
        "\(($queued | length) + ($m_queued | length) | n("item is"; "items are")) queued and nothing is dispatched"
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
      ] + [ $open_prs[]
        | {question: ("Should \(.pr.url) land?" | trunc(199)),
           owner: "captain",
           urgency: (if run_finished then "soon" else "later" end)}
      ] + [ $m_decisions[]
        | {question: (.summary | question),
           why: ((if .verb == "captain-hold"
                  then (.reason // "A hold with the \(.mate) second mate awaits the captain.")
                  else "A worker with the \(.mate) second mate is parked until this is answered." end)
                 | trunc(400)),
           owner: "captain",
           urgency: (if .verb == "needs-decision" then "now" else "soon" end)}
      ] + [ $m_open_prs[]
        | {question: ("Should \(.pr_url) land?" | trunc(199)),
           owner: "captain",
           urgency: "later"}
      ]
      | sort_by(if .urgency == "now" then 0 elif .urgency == "soon" then 1 else 2 end))
      as $decisions_all
   # The emitted list is capped for display; every COUNT below is taken from the
   # uncapped total, because reporting a display cap as the total would under-
   # report real work.
   | ($decisions_all[:8]) as $decisions

   # --- what is actually stopping progress ----------------------------------
   | ([ $live_blocked[]
        | {title: (.summary | trunc(160)),
           detail: ("The worker on \(.task) reported itself blocked and is waiting for help." | trunc(500)),
           severity: "critical", owner: "agents",
           unblockedBy: "Firstmate unblocking the worker or reassigning the work."}
      ] + [ $stopped[]
        | {title: ("the worker on \(.id) is no longer running" | trunc(160)),
           detail: ((if .current_state.state == "failed"
                     then "Its run reported itself failed while the item is still recorded in flight."
                     else "The item is recorded in flight and its endpoint is gone, so nothing is left running it."
                     end) | trunc(500)),
           severity: "critical", owner: "agents",
           unblockedBy: "Restarting the work or returning the item to the queue."}
      ] + [ $drifted[]
        | {title: ("\(.id) has finished but is still recorded in flight" | trunc(160)),
           detail: ("Its run reported itself done; only the backlog row is out of date." | trunc(500)),
           severity: "minor", owner: "shared",
           unblockedBy: "Marking the item done in the backlog."}
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
      ] + [ $m_blocked[]
        | {title: (.summary | trunc(160)),
           detail: ("A worker with the \(.mate) second mate reported itself blocked and is waiting for help." | trunc(500)),
           severity: "critical", owner: "agents",
           unblockedBy: "The second mate unblocking the worker or reassigning the work."}
      ] + [ $m_gated[]
        | {title: (.title | trunc(160)),
           detail: ("Waiting on \((.unresolved_blocker_ids // []) | join(", ")) with the \(.mate) second mate." | trunc(500)),
           severity: "major", owner: "agents",
           unblockedBy: ("\((.unresolved_blocker_ids // []) | join(", ")) landing first." | trunc(300))}
      ] + [ $m_other_holds[]
        | {title: (.title | trunc(160)),
           detail: ((.hold_reason // "held") | trunc(500)),
           severity: "major", owner: "shared",
           unblockedBy: "The hold reason clearing."}
      ]
      | sort_by(if .severity == "critical" then 0 elif .severity == "major" then 1 else 2 end))
      as $blockers_all
   | ($blockers_all[:8]) as $blockers

   # --- next three for each side --------------------------------------------
   | ([ $open_prs[]
        | {title: ("Decide on \(.pr.url)" | trunc(160)),
           why: ((if run_finished
                  then "The work is finished and waiting for the captain to say whether it lands."
                  else null end) | trunc(300))}
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
      ] + [ $m_open_prs[]
        | {title: ("Decide on \(.pr_url)" | trunc(160))}
      ] + [ $m_decisions[]
        | {title: (.summary | trunc(160)),
           detail: (.reason | trunc(400)),
           why: ("It waits with the \(.mate) second mate." | trunc(300))}
      ] | .[:3]) as $captain_tasks

   | ([ $ready[]
        | {title: (.title | trunc(160)),
           detail: (.body_excerpt | trunc(400)),
           why: ((if (.priority // "") != "" then "Queued at priority \(.priority) " else "Queued " end)
                 + "with nothing gating it." | trunc(300)),
           order_priority: (.priority // "99"),
           order_since: (.since // "9999-99-99")}
      ] + [ $m_ready[]
        | {title: (.title | trunc(160)),
           why: ("Queued with the \(.mate) second mate with nothing gating it." | trunc(300)),
           order_priority: "99",
           order_since: "9999-99-99"}
      ] | sort_by([.order_priority, .order_since])
        | map(del(.order_priority, .order_since))
        | .[:3]) as $agent_tasks

   # --- checkable facts behind the summary ----------------------------------
   | ([ {label: "Dispatched work",
         value: (if ($working | length) + ($m_working | length) > 0
                   then (($working | length) + ($m_working | length) | n("worker running"; "workers running"))
                 elif ($inflight | length) + ($m_inflight | length) == 0 then "nothing dispatched"
                 elif ($inflight | length) == 0
                   then ($m_inflight | length | n("item under way with a second mate"; "items under way with second mates"))
                 elif ($tasks | length) == 0
                   then ($inflight | length | n("item in flight, no worker"; "items in flight, no worker"))
                 elif ($stopped | length) > 0
                   then ($stopped | length | n("item in flight, worker no longer running"; "items in flight, worker no longer running"))
                 elif ($drifted | length) > 0
                   then ($drifted | length | n("item in flight whose run has finished"; "items in flight whose run has finished"))
                 else ($inflight | length | n("item in flight, worker state not reported"; "items in flight, worker state not reported"))
                 end | trunc(120)),
         state: (if ($stopped | length) > 0 or ($orphaned | length) > 0 then "bad"
                 elif ($working | length) + ($m_working | length) > 0 then "good"
                 elif ($inflight | length) > 0 and ($tasks | length) > 0 and ($drifted | length) == 0
                   then "unknown"
                 elif ($inflight | length) == 0 and ($m_inflight | length) > 0 then "watch"
                 elif ($queued | length) + ($m_queued | length) > 0 then "watch"
                 else "good" end),
         evidence: (if ($tasks | length) > 0
                    then ("Task records: \([$tasks[].id] | join(", "))." | trunc(300))
                    else null end)},
        {label: "Decisions waiting on the captain",
         value: (if ($decisions_all | length) > 0 then ($decisions_all | length | n("open"; "open")) else "none open" end | trunc(120)),
         state: (if ($decisions_all | any(.urgency == "now")) then "bad"
                 elif ($decisions_all | length) > 0 then "watch" else "good" end),
         evidence: (if ($captain_holds | length) > 0
                    then ("Held items: \([$captain_holds[].id] | join(", "))." | trunc(300))
                    else null end)},
        {label: "Items waiting on other work",
         value: (if ($gated | length) + ($m_gated | length) > 0
                 then (($gated | length) + ($m_gated | length) | n("item gated"; "items gated"))
                 else "none gated" end | trunc(120)),
         state: (if ($gated | length) + ($m_gated | length) > 0 then "watch" else "good" end),
         evidence: (if ($gated | length) + ($m_gated | length) > 0
                    then ("Waiting on \([$gated[].unresolved_blocker_ids[], ($m_gated[].unresolved_blocker_ids // [])[]] | unique | join(", "))." | trunc(300))
                    else null end)},
        {label: "Local copy",
         value: (if $c.read == "ok"
                 then ("\($c.branch)" + (if $c.dirty then ", uncommitted changes" else ", clean" end))
                 elif $c.read == "absent" then "no local copy in this home"
                 else "could not be read" end | trunc(120)),
         state: (if $c.read == "ok" and ($c.dirty | not) then "good"
                 elif $c.read == "ok" then "watch"
                 else "unknown" end),
         # Trimmed to its last two segments exactly as `source` trims the home
         # below, so a rendered card never carries the local username or the
         # directory layout of the machine that generated it.
         evidence: (if $c.path == null then null
                    else ($c.path | split("/") | .[-2:] | join("/") | trunc(300)) end)}
      ] + $m_signals
      + (if $r == null then
        [{label: "Project registry", value: "not registered", state: "watch",
          evidence: "Named by backlog items, live task records or second mate work but absent from data/projects.md."}]
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

       executiveSummary: (if ($recs | length) == 0 and $m_items == 0 then null else {
         lede: ("\($name) has \((($recs | length) + $m_items) | n("item"; "items")) recorded: "
                + "\(($inflight | length) + ($m_inflight | length)) in flight, \(($queued | length) + ($m_queued | length)) queued, \(($done | length) + ($m_landed | length)) landed. "
                + (if $m_items > 0
                   then "Of these, \($m_items | n("item is"; "items are")) with \(if ($m_ids | length) == 1 then "the \($m_ids[0]) second mate" else "second mates \($m_ids | join(", "))" end). "
                   else "" end)
                + (if ($decisions_all | length) > 0
                   then "\($decisions_all | length | n("decision waits"; "decisions wait")) on the captain. " else "No decision waits on the captain. " end)
                + (if ($blockers_all | length) > 0
                   then "\($blockers_all | length | n("thing is"; "things are")) stopping progress. " else "Nothing is stopping progress. " end)
                + (if $last_date != null then "Last activity \($last_date)." else "No dated activity recorded." end)
                | trunc(600)),
         metrics: [
           {label: "In flight", value: (($inflight | length) + ($m_inflight | length) | tostring),
            tone: (if ($stopped | length) > 0 then "bad" elif ($working | length) + ($m_working | length) > 0 then "good" else "neutral" end)},
           {label: "Queued", value: (($queued | length) + ($m_queued | length) | tostring), tone: "neutral"},
           {label: "Landed", value: (($done | length) + ($m_landed | length) | tostring), tone: "good"},
           {label: "Captain decisions", value: ($decisions_all | length | tostring),
            tone: (if ($decisions_all | length) > 0 then "warn" else "good" end)},
           {label: "Stopping progress", value: ($blockers_all | length | tostring),
            tone: (if ($blockers_all | length) > 0 then "bad" else "good" end)},
           {label: "Last activity", value: (($last_date // "none") | trunc(24)), tone: "neutral"}
         ]
       } end),

       currentStatus: (if ($recs | length) == 0 and $c.read == "absent" and $r != null
                          and $m_items == 0 and ($m_signals | length) == 0 then null else {
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
   | group_by(.rank)
   | map(sort_by(.name) | group_by(.last_date // "") | reverse | add // []) | add // []
   | to_entries | map(.value + {order: .key})) as $active
| ([$all[] | select(.status == "dormant")]
   | group_by(.rank)
   | map(sort_by(.name) | group_by(.last_date // "") | reverse | add // []) | add // []
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
