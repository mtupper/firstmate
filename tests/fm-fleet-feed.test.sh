#!/usr/bin/env bash
# Behavior tests for the dashboard fleet-feed projection.
#
# Covers a fully populated project, a sparse one carrying only the five required
# fields, the absent-versus-empty distinction the renderer draws differently, the
# always-omitted sections firstmate has no source for, the projects-root write
# refusal, and every malformed source failing loudly WITHOUT replacing a good
# feed with a partial one.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FEED="$ROOT/bin/fm-fleet-feed.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-feed)
# Keep disposable homes outside the snapshot's fixture repo boundary even when
# TMPDIR sits inside an isolated source worktree.
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

NOW=2026-07-11T18:00:00Z

# A window named dead-* is reported gone, which is how a fixture task reaches the
# "recorded in flight, worker no longer running" reading without a real backend.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

# Drive a fixture task's semantic busy state through its only writer, so the
# canonical snapshot reads a real working/idle verdict rather than a guess.
record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 want=$3 gen event
  case "$want" in
    busy) event=user-prompt-submit ;;
    idle) event=stop ;;
    *) fail "unsupported fixture state: $want" ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$want" --gen "$gen" \
    --source claude-hook --event "$event"
}

new_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# A clone with a recognizable remote, so the repo label and local-copy signal
# have something real behind them.
make_clone() {  # <home> <name> <remote-url> [dirty]
  local home=$1 name=$2 url=$3 dirty=${4:-}
  fm_git_init_commit "$home/projects/$name"
  git -C "$home/projects/$name" remote add origin "$url"
  [ -n "$dirty" ] && printf 'changed\n' >> "$home/projects/$name/README.md"
  return 0
}

run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" "$FEED" "$@"
}

# --- home A: a populated project, a sparse one, and a stuck one -------------
HOME_A=$(new_home home-a)
FAKEBIN_A=$(make_fakebin "$HOME_A")
fm_git_identity

cat > "$HOME_A/data/projects.md" <<'EOF'
# Projects

- rich [no-mistakes +yolo] - The fully populated fixture project (added 2026-07-01)
- sparse [local-only] - Registered, never cloned, nothing recorded (added 2026-07-01)
- stuck [direct-PR] - Fixture project whose worker reported itself blocked (added 2026-07-01)
EOF

cat > "$HOME_A/data/backlog.md" <<'EOF'
## In flight
- [ ] rich-ship - Ship the populated thing (repo: rich) (kind: ship) (priority: 1) (since 2026-07-05)
- [ ] rich-hold - Choose the storage format (repo: rich) (kind: ship) (since 2026-07-06) (hold: the captain must pick a format before the schema is written) (hold-kind: captain)
- [ ] stuck-ship - Ship the stuck thing (repo: stuck) (kind: ship) (since 2026-07-07)

## Queued
- [ ] rich-decision - Approve the outward-facing copy (repo: rich) (kind: captain) (since 2026-07-06) (hold: the copy goes to real users) (hold-kind: captain)
- [ ] rich-gated - Wire the exporter blocked-by: rich-missing (repo: rich) (kind: ship) (priority: 2) (since 2026-07-06)
- [ ] rich-next - Add the importer (repo: rich) (kind: ship) (priority: 1) (since 2026-07-06)
- [ ] rich-later - Tidy the fixtures (repo: rich) (kind: ship) (priority: 3) (since 2026-07-06)

## Done
- [x] rich-landed - Landed the groundwork https://github.com/acme/rich/pull/4 (repo: rich) (kind: ship) (merged 2026-07-04)
EOF

make_clone "$HOME_A" rich 'git@github.com:acme/rich.git'
make_clone "$HOME_A" stuck 'https://gitlab.com/acme/stuck.git' dirty

fm_write_meta "$HOME_A/state/rich-ship.meta" \
  "window=firstmate:fm-rich-ship" \
  "worktree=$HOME_A/projects/rich" \
  "project=$HOME_A/projects/rich" \
  "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=on" \
  "pr=https://github.com/acme/rich/pull/9"
record_claude_state "$HOME_A/state" rich-ship busy
printf 'working: building it\n' > "$HOME_A/state/rich-ship.status"

# A declared external wait, so the held item reads as held rather than as a
# worker that vanished (bin/fm-classify-lib.sh owns that vocabulary).
fm_write_meta "$HOME_A/state/rich-hold.meta" \
  "window=firstmate:fm-rich-hold" \
  "worktree=$HOME_A/projects/rich" \
  "project=$HOME_A/projects/rich" \
  "harness=claude" "kind=ship" "mode=no-mistakes"
record_claude_state "$HOME_A/state" rich-hold idle
printf 'paused: standing by for the captain on the storage format\n' > "$HOME_A/state/rich-hold.status"

fm_write_meta "$HOME_A/state/stuck-ship.meta" \
  "window=firstmate:dead-fm-stuck-ship" \
  "worktree=$HOME_A/projects/stuck" \
  "project=$HOME_A/projects/stuck" \
  "harness=claude" "kind=ship" "mode=direct-PR"
printf 'blocked [key=creds]: the deploy credential is rejected\n' > "$HOME_A/state/stuck-ship.status"

FEED_A=$(run "$HOME_A" "$FAKEBIN_A" --stdout) || fail "generating the home-a feed failed"

# --- the document itself ----------------------------------------------------
printf '%s' "$FEED_A" | jq -e '.contractVersion | test("^1\\.[0-9]+\\.[0-9]+$")' >/dev/null \
  || fail "contractVersion is not in the 1.x range the renderer accepts"
printf '%s' "$FEED_A" | jq -e '.generatedAt == "2026-07-11T18:00:00Z"' >/dev/null \
  || fail "generatedAt does not carry the observation time"
printf '%s' "$FEED_A" | jq -e '.projects | length == 3' >/dev/null \
  || fail "expected the three registered projects"
printf '%s' "$FEED_A" | jq -e '[.projects[].id] | (unique | length) == length' >/dev/null \
  || fail "project ids are not unique"
pass "the document carries a 1.x contract version, the observation time and unique ids"

R=$(printf '%s' "$FEED_A" | jq '.projects[] | select(.id == "rich")')

# --- a project with everything populated ------------------------------------
printf '%s' "$R" | jq -e '.status == "active" and .health == "at-risk"' >/dev/null \
  || fail "rich should be active and at-risk: $(printf '%s' "$R" | jq -c '{status,health}')"
printf '%s' "$R" | jq -e '.repo == "github.com/acme/rich"' >/dev/null \
  || fail "rich should carry its remote as a label: $(printf '%s' "$R" | jq -c '.repo')"
printf '%s' "$R" | jq -e '.updatedAt == "2026-07-06"' >/dev/null \
  || fail "rich should be dated by its most recent recorded activity"
printf '%s' "$R" | jq -e '(.headline | length) > 0 and (.headline | length) <= 200' >/dev/null \
  || fail "rich needs a headline within the contract's limit"
printf '%s' "$R" | jq -e '.executiveSummary.metrics | length == 6' >/dev/null \
  || fail "rich should carry its six derived metrics"
printf '%s' "$R" | jq -e '[.executiveSummary.metrics[] | select(.label == "Landed")][0].value == "1"' >/dev/null \
  || fail "the landed metric should count the one done item"
printf '%s' "$R" | jq -e '.currentStatus.signals | length >= 4' >/dev/null \
  || fail "rich should carry its checkable signals"
printf '%s' "$R" | jq -e '[.currentStatus.signals[] | select(.label == "Local copy")][0]
                          | .state == "good" and (.value | endswith(", clean"))' >/dev/null \
  || fail "a clean clone should read as a good local copy"
pass "a fully populated project carries every field this home has evidence for"

# --- a rendered card must not carry this operator's directory layout ---------
printf '%s' "$R" | jq -e '[.currentStatus.signals[] | select(.label == "Local copy")][0].evidence
                          == "projects/rich"' >/dev/null \
  || fail "the local copy evidence should be trimmed like the source field: $(printf '%s' "$R" | jq -c '[.currentStatus.signals[] | select(.label == "Local copy")][0].evidence')"
printf '%s' "$FEED_A" | jq -e --arg home "$HOME_A" 'tostring | contains($home) | not' >/dev/null \
  || fail "no part of the feed may carry the absolute home path"
pass "the feed carries no absolute local path into a rendered card"

# --- in-flight work with a raised PR is not finished work -------------------
# rich-ship carries pr=.../pull/9 and its worker is running, so its pipeline may
# still be mid-CI; the captain has nothing to decide about it yet.
printf '%s' "$R" | jq -e '[.captainTasks[].title] | any(contains("pull/9")) | not' >/dev/null \
  || fail "a PR whose worker is still running must not be offered as a captain decision"
printf '%s' "$R" | jq -e '[.captainTasks[].why] | any(contains("The work is finished")) | not' >/dev/null \
  || fail "running work must never be described to the captain as finished"
pass "a PR raised by a still-running worker is not presented as finished work"

# --- decisions, blockers and the next three on each side --------------------
printf '%s' "$R" | jq -e '.decisions | length == 2' >/dev/null \
  || fail "rich has two captain holds open: $(printf '%s' "$R" | jq -c '.decisions')"
printf '%s' "$R" | jq -e '.decisions[0].urgency == "now" and (.decisions[0].question | endswith("?"))' >/dev/null \
  || fail "the hold that stopped in-flight work should lead, stated as a question"
printf '%s' "$R" | jq -e '[.decisions[].owner] | all(. == "captain")' >/dev/null \
  || fail "captain holds are the captain's decisions"

printf '%s' "$R" | jq -e '[.blockers[] | select(.severity == "critical" and .owner == "captain")] | length == 1' >/dev/null \
  || fail "the in-flight captain hold should be a critical blocker"
printf '%s' "$R" | jq -e '[.blockers[] | select(.title | startswith("Wire the exporter"))][0]
                          | .severity == "major" and (.unblockedBy | startswith("rich-missing"))' >/dev/null \
  || fail "an item gated by unfinished work should name what would clear it"

printf '%s' "$R" | jq -e '.captainTasks | length == 2' >/dev/null \
  || fail "rich has exactly its two captain holds to decide: $(printf '%s' "$R" | jq -c '.captainTasks')"
printf '%s' "$R" | jq -e '.captainTasks[0].title == "Choose the storage format"' >/dev/null \
  || fail "the hold that stopped in-flight work should lead the captain's list"
printf '%s' "$R" | jq -e '.agentTasks | length == 2' >/dev/null \
  || fail "only the two ungated queued items are dispatchable"
printf '%s' "$R" | jq -e '[.agentTasks[].title] == ["Add the importer", "Tidy the fixtures"]' >/dev/null \
  || fail "dispatchable work should come out in priority order"
pass "decisions, blockers and the next three on each side come from real queue state"

# --- the sections firstmate has no source for stay omitted ------------------
printf '%s' "$FEED_A" | jq -e '[.projects[]
  | has("progress"), has("targets"), has("nextMilestone"), has("sprintReview")]
  | all(. == false)' >/dev/null \
  || fail "a section with no source behind it must be omitted, not invented"
pass "progress, targets, milestones and sprint reviews stay omitted rather than invented"

# --- a project whose worker reported itself blocked -------------------------
S=$(printf '%s' "$FEED_A" | jq '.projects[] | select(.id == "stuck")')
printf '%s' "$S" | jq -e '.health == "blocked"' >/dev/null \
  || fail "a worker that reported itself blocked should not read as healthy"
printf '%s' "$S" | jq -e '[.blockers[] | select(.title | contains("deploy credential"))] | length == 1' >/dev/null \
  || fail "the still-open keyed status decision should surface as a blocker"
printf '%s' "$S" | jq -e '[.currentStatus.signals[] | select(.label == "Local copy")][0]
                          | .state == "watch" and (.value | endswith(", uncommitted changes"))' >/dev/null \
  || fail "a dirty clone should read as something to watch"
pass "a blocked worker and a dirty local copy both reach the report"

# --- a sparse project: the five required fields, and empty means checked ----
P_A=$(printf '%s' "$FEED_A" | jq '.projects[] | select(.id == "sparse")')
printf '%s' "$P_A" | jq -e '.id and .name and .status and .health and .headline' >/dev/null \
  || fail "a sparse project still needs the five required fields"
printf '%s' "$P_A" | jq -e '.status == "dormant" and .health == "not-started"' >/dev/null \
  || fail "a registered project with nothing recorded is dormant and not started"
printf '%s' "$P_A" | jq -e '[has("repo"), has("updatedAt"), has("executiveSummary"), has("currentStatus")]
                            | all(. == false)' >/dev/null \
  || fail "a project with no clone and no records must omit what it cannot ground"
printf '%s' "$P_A" | jq -e '.decisions == [] and .blockers == [] and .captainTasks == [] and .agentTasks == []' >/dev/null \
  || fail "with a readable backlog, a project with nothing open reports empty, not absent"
pass "a sparse project carries the required five and reports empty where it checked"

# --- absent is not empty ----------------------------------------------------
# The same project in a home whose backlog could not be read must OMIT the four
# queue-derived fields, so the renderer says "not recorded" instead of drawing
# the positive "checked, and there was nothing" it draws for an empty array.
HOME_B=$(new_home home-b)
FAKEBIN_B=$(make_fakebin "$HOME_B")
cp "$HOME_A/data/projects.md" "$HOME_B/data/projects.md"
assert_absent "$HOME_B/data/backlog.md" "home-b must have no backlog for this case"

FEED_B=$(run "$HOME_B" "$FAKEBIN_B" --stdout) || fail "generating the home-b feed failed"
P_B=$(printf '%s' "$FEED_B" | jq '.projects[] | select(.id == "sparse")')

printf '%s' "$P_B" | jq -e '[has("decisions"), has("blockers"), has("captainTasks"), has("agentTasks")]
                            | all(. == false)' >/dev/null \
  || fail "an unreadable backlog must leave the queue-derived fields absent, not empty"
printf '%s' "$P_B" | jq -e '[keys[]] | sort == ["headline", "health", "id", "name", "order", "status"]' >/dev/null \
  || fail "with no backlog the entry should be the required five plus its sort key: $(printf '%s' "$P_B" | jq -c 'keys')"
printf '%s' "$P_A" | jq -e 'has("blockers") and (.blockers | length) == 0' >/dev/null \
  || fail "the checked case must still emit an empty array"
pass "absent and empty are distinguished: checked reports [], unreadable omits the field"

# --- the repo label names the remote work can actually push to --------------
# A fork clone keeps the upstream as origin with its push URL deliberately
# disabled; the card must name the fork the work lands on, not the upstream.
# With no pushable remote at all, origin's fetch URL still names the source.
HOME_F=$(new_home home-f)
FAKEBIN_F=$(make_fakebin "$HOME_F")
cat > "$HOME_F/data/projects.md" <<'EOF'
# Projects

- forked [direct-PR] - Fork whose upstream origin refuses pushes (added 2026-07-01)
- unpushable [local-only] - Only a disabled push URL, nowhere to push (added 2026-07-01)
EOF
make_clone "$HOME_F" forked 'https://github.com/acme-upstream/forked.git'
git -C "$HOME_F/projects/forked" remote set-url --push origin DISABLED-no-push-to-upstream
git -C "$HOME_F/projects/forked" remote add fork 'git@github.com:acme/forked.git'
make_clone "$HOME_F" unpushable 'https://github.com/acme-upstream/unpushable.git'
git -C "$HOME_F/projects/unpushable" remote set-url --push origin DISABLED-no-push-to-upstream

FEED_F=$(run "$HOME_F" "$FAKEBIN_F" --stdout) || fail "generating the home-f feed failed"
printf '%s' "$FEED_F" | jq -e '.projects[] | select(.id == "forked") | .repo == "github.com/acme/forked"' >/dev/null \
  || fail "a fork with a disabled origin push URL should be labelled by its pushable remote: $(printf '%s' "$FEED_F" | jq -c '.projects[] | select(.id == "forked") | .repo')"
printf '%s' "$FEED_F" | jq -e '.projects[] | select(.id == "unpushable") | .repo == "github.com/acme-upstream/unpushable"' >/dev/null \
  || fail "with no pushable remote the label should fall back to origin's fetch URL: $(printf '%s' "$FEED_F" | jq -c '.projects[] | select(.id == "unpushable") | .repo')"
pass "the repo label names the pushable remote, with origin as the fallback"

# --- home C: what "the worker stopped" may and may not be read from ---------
# A worker that has not spoken yet, one whose window is gone, one whose run
# failed, one that is running with no in-flight row, one with a finished pull
# request, and one with more open holds than the display cap.
HOME_C=$(new_home home-c)
FAKEBIN_C=$(make_fakebin "$HOME_C")

cat > "$HOME_C/data/projects.md" <<'EOF'
# Projects

- quiet [local-only] - Its worker is live but has written no status line yet (added 2026-07-01)
- gone [local-only] - Its worker's window is gone (added 2026-07-01)
- halted [local-only] - Its worker's run failed (added 2026-07-01)
- busy [local-only] - A running worker and only old recorded dates (added 2026-05-01)
- landing [local-only] - A finished pull request waiting on the captain (added 2026-07-01)
- parked [local-only] - A live worker parked at a gate with a pull request open (added 2026-07-01)
- adhoc [local-only] - A crew with a pull request and no backlog row at all (added 2026-07-01)
- requeued [local-only] - A queued row whose pull request is still open (added 2026-07-01)
- crowded [local-only] - More open holds than the display cap (added 2026-07-01)
EOF

cat > "$HOME_C/data/backlog.md" <<'EOF'
## In flight
- [ ] quiet-ship - Ship the quiet thing (repo: quiet) (kind: ship) (since 2026-07-08)
- [ ] gone-ship - Ship the gone thing (repo: gone) (kind: ship) (since 2026-07-08)
- [ ] halted-ship - Ship the halted thing (repo: halted) (kind: ship) (since 2026-07-08)
- [ ] landing-ship - Ship the landing thing (repo: landing) (kind: ship) (since 2026-07-08)
- [ ] parked-ship - Ship the parked thing (repo: parked) (kind: ship) (since 2026-07-08)

## Queued
- [ ] busy-next - Add the busy thing (repo: busy) (kind: ship) (since 2026-05-01)
- [ ] requeued-ship - Ship the requeued thing (repo: requeued) (kind: ship) (since 2026-07-06)
EOF

# Twelve captain holds and nine gated items, both over the eight-item display cap.
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  printf -- '- [ ] crowded-hold-%s - Decide item %s (repo: crowded) (kind: captain) (since 2026-07-06) (hold: the captain must choose option %s) (hold-kind: captain)\n' \
    "$i" "$i" "$i" >> "$HOME_C/data/backlog.md"
done
for i in 1 2 3 4 5 6 7 8 9; do
  printf -- '- [ ] crowded-gated-%s - Wire item %s blocked-by: crowded-missing-%s (repo: crowded) (kind: ship) (since 2026-07-06)\n' \
    "$i" "$i" "$i" >> "$HOME_C/data/backlog.md"
done

for p in quiet gone halted busy landing parked adhoc requeued; do
  make_clone "$HOME_C" "$p" "https://github.com/acme/$p.git"
done

# Live pane, idle harness, no status line yet: crew state reads `unknown`, which
# upstream means "I cannot tell", not "the worker is gone".
fm_write_meta "$HOME_C/state/quiet-ship.meta" \
  "window=firstmate:fm-quiet-ship" \
  "worktree=$HOME_C/projects/quiet" "project=$HOME_C/projects/quiet" \
  "harness=claude" "kind=ship" "mode=local-only"
record_claude_state "$HOME_C/state" quiet-ship idle

fm_write_meta "$HOME_C/state/gone-ship.meta" \
  "window=firstmate:dead-fm-gone-ship" \
  "worktree=$HOME_C/projects/gone" "project=$HOME_C/projects/gone" \
  "harness=claude" "kind=ship" "mode=local-only"

fm_write_meta "$HOME_C/state/halted-ship.meta" \
  "window=firstmate:fm-halted-ship" \
  "worktree=$HOME_C/projects/halted" "project=$HOME_C/projects/halted" \
  "harness=claude" "kind=ship" "mode=local-only"
record_claude_state "$HOME_C/state" halted-ship idle
printf 'failed: the build could not be repaired\n' > "$HOME_C/state/halted-ship.status"

# A running worker whose only backlog row is queued and long out of the window.
fm_write_meta "$HOME_C/state/busy-probe.meta" \
  "window=firstmate:fm-busy-probe" \
  "worktree=$HOME_C/projects/busy" "project=$HOME_C/projects/busy" \
  "harness=claude" "kind=ship" "mode=local-only"
record_claude_state "$HOME_C/state" busy-probe busy
printf 'working: still going\n' > "$HOME_C/state/busy-probe.status"

fm_write_meta "$HOME_C/state/landing-ship.meta" \
  "window=firstmate:fm-landing-ship" \
  "worktree=$HOME_C/projects/landing" "project=$HOME_C/projects/landing" \
  "harness=claude" "kind=ship" "mode=local-only" \
  "pr=https://github.com/acme/landing/pull/3"
record_claude_state "$HOME_C/state" landing-ship idle
printf 'done: the checks are green\n' > "$HOME_C/state/landing-ship.status"

# A live worker parked at a gate: its pane is alive, its process is running, and
# it has a pull request open. Nothing here says the worker went away.
fm_write_meta "$HOME_C/state/parked-ship.meta" \
  "window=firstmate:fm-parked-ship" \
  "worktree=$HOME_C/projects/parked" "project=$HOME_C/projects/parked" \
  "harness=claude" "kind=ship" "mode=no-mistakes" \
  "pr=https://github.com/acme/parked/pull/7"
record_claude_state "$HOME_C/state" parked-ship idle
printf 'needs-decision [key=fmt]: which format should the exporter write\n' \
  > "$HOME_C/state/parked-ship.status"

# A pull request on work that nothing records in flight: one crew with no
# backlog row at all, and one whose row sits in Queued.
fm_write_meta "$HOME_C/state/adhoc-probe.meta" \
  "window=firstmate:fm-adhoc-probe" \
  "worktree=$HOME_C/projects/adhoc" "project=$HOME_C/projects/adhoc" \
  "harness=claude" "kind=ship" "mode=no-mistakes" \
  "pr=https://github.com/acme/adhoc/pull/5"
record_claude_state "$HOME_C/state" adhoc-probe idle
printf 'needs-decision [key=api]: which endpoint should it call\n' \
  > "$HOME_C/state/adhoc-probe.status"

fm_write_meta "$HOME_C/state/requeued-ship.meta" \
  "window=firstmate:fm-requeued-ship" \
  "worktree=$HOME_C/projects/requeued" "project=$HOME_C/projects/requeued" \
  "harness=claude" "kind=ship" "mode=no-mistakes" \
  "pr=https://github.com/acme/requeued/pull/6"
record_claude_state "$HOME_C/state" requeued-ship idle
printf 'needs-decision [key=scope]: how wide should the change go\n' \
  > "$HOME_C/state/requeued-ship.status"

FEED_C=$(run "$HOME_C" "$FAKEBIN_C" --stdout) || fail "generating the home-c feed failed"

Q=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "quiet")')
printf '%s' "$Q" | jq -e '[.blockers[] | select(.title | contains("no longer running"))] | length == 0' >/dev/null \
  || fail "a worker that has not spoken yet must not be reported as gone: $(printf '%s' "$Q" | jq -c '.blockers')"
printf '%s' "$Q" | jq -e '.health == "on-track"' >/dev/null \
  || fail "a quiet worker must not force the project to blocked: $(printf '%s' "$Q" | jq -c '.health')"
printf '%s' "$Q" | jq -e '.headline | contains("no longer running") | not' >/dev/null \
  || fail "the headline must not claim a live worker has stopped"

G=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "gone")')
printf '%s' "$G" | jq -e '[.blockers[] | select(.title | contains("no longer running"))] | length == 1' >/dev/null \
  || fail "a worker whose window is gone should still be reported as stopped"
H=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "halted")')
printf '%s' "$H" | jq -e '[.blockers[] | select(.title | contains("no longer running"))] | length == 1' >/dev/null \
  || fail "a worker whose run failed should still be reported as stopped"
printf '%s' "$H" | jq -e '[.blockers[] | select(.title | contains("no longer running"))][0].detail
                          | contains("reported itself failed")' >/dev/null \
  || fail "the detail should name the evidence, not the absence of a pause: $(printf '%s' "$H" | jq -c '.blockers')"
printf '%s' "$G" | jq -e '[.blockers[] | select(.title | contains("no longer running"))][0].detail
                          | contains("endpoint is gone")' >/dev/null \
  || fail "a gone endpoint should be named as the evidence: $(printf '%s' "$G" | jq -c '.blockers')"
pass "a live but quiet worker is not called vanished, while a gone or failed one is"

# --- a signal may not deny the worker its own evidence field lists -----------
QD=$(printf '%s' "$Q" | jq '[.currentStatus.signals[] | select(.label == "Dispatched work")][0]')
printf '%s' "$QD" | jq -e '.value | contains("no worker") | not' >/dev/null \
  || fail "the dispatched-work value must not deny a worker: $(printf '%s' "$QD" | jq -c '{value,evidence}')"
printf '%s' "$QD" | jq -e '.value == "1 item in flight, worker state not reported"' >/dev/null \
  || fail "an unreported worker state should be reported as unreported: $(printf '%s' "$QD" | jq -c '.value')"
printf '%s' "$QD" | jq -e '.evidence | contains("quiet-ship")' >/dev/null \
  || fail "the evidence should still list the task record behind the value"
printf '%s' "$QD" | jq -e '.state == "unknown"' >/dev/null \
  || fail "a signal whose value says the state is not reported may not read green: $(printf '%s' "$QD" | jq -c '{value,state}')"
pass "the dispatched-work value never denies a worker its own evidence lists"

B=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "busy")')
printf '%s' "$B" | jq -e '.status == "active"' >/dev/null \
  || fail "a project with a running worker is not dormant: $(printf '%s' "$B" | jq -c '{status,headline}')"
printf '%s' "$B" | jq -e '[.currentStatus.signals[] | select(.label == "Dispatched work")][0].value == "1 worker running"' >/dev/null \
  || fail "the card and the status must agree that a worker is running"
pass "a project with a running worker reads as active, not dormant"

C=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "crowded")')
printf '%s' "$C" | jq -e '(.decisions | length) == 8 and (.blockers | length) == 8' >/dev/null \
  || fail "the emitted lists stay capped at eight: $(printf '%s' "$C" | jq -c '{d:(.decisions|length),b:(.blockers|length)}')"
printf '%s' "$C" | jq -e '[.executiveSummary.metrics[] | select(.label == "Captain decisions")][0].value == "12"' >/dev/null \
  || fail "the captain-decisions metric must count all twelve holds, not the eight shown"
printf '%s' "$C" | jq -e '[.executiveSummary.metrics[] | select(.label == "Stopping progress")][0].value == "9"' >/dev/null \
  || fail "the stopping-progress metric must count all nine blockers, not the eight shown"
printf '%s' "$C" | jq -e '[.currentStatus.signals[] | select(.label == "Decisions waiting on the captain")][0].value == "12 open"' >/dev/null \
  || fail "the decisions signal must report the true number waiting"
printf '%s' "$C" | jq -e '.executiveSummary.lede
                          | contains("12 decisions wait on the captain")
                            and contains("9 things are stopping progress")' >/dev/null \
  || fail "the lede must state the true totals: $(printf '%s' "$C" | jq -c '.executiveSummary.lede')"
pass "counts report the uncapped totals while the displayed lists stay capped"

L=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "landing")')
printf '%s' "$L" | jq -e '.captainTasks[0].title == "Decide on https://github.com/acme/landing/pull/3"' >/dev/null \
  || fail "a finished pull request should lead the captain's list: $(printf '%s' "$L" | jq -c '.captainTasks')"
printf '%s' "$L" | jq -e '.captainTasks[0].why | startswith("The work is finished")' >/dev/null \
  || fail "work whose run reported done is finished, and may be described that way"
pass "a pull request whose run finished still reaches the captain as a decision"

# --- a finished run with a stale row is drift, not a vanished worker ---------
# The same card may not call one item finished and call its worker gone.
printf '%s' "$L" | jq -e '[.blockers[] | select(.title | contains("no longer running"))] | length == 0' >/dev/null \
  || fail "a finished run must not be reported as a vanished worker: $(printf '%s' "$L" | jq -c '.blockers')"
printf '%s' "$L" | jq -e '[.blockers[] | select(.severity == "critical")] | length == 0' >/dev/null \
  || fail "bookkeeping drift must not raise a critical blocker"
printf '%s' "$L" | jq -e '.health == "on-track"' >/dev/null \
  || fail "bookkeeping drift must not force health to blocked: $(printf '%s' "$L" | jq -c '.health')"
printf '%s' "$L" | jq -e '[.blockers[] | select(.title | contains("still recorded in flight"))][0]
                          | .severity == "minor"
                            and .unblockedBy == "Marking the item done in the backlog."' >/dev/null \
  || fail "drift should be a minor item whose remedy is to mark it done: $(printf '%s' "$L" | jq -c '.blockers')"
printf '%s' "$L" | jq -e '[.blockers[].unblockedBy] | any(test("(?i)restart|queue")) | not' >/dev/null \
  || fail "finished work must never be offered a restart or requeue remedy"
printf '%s' "$L" | jq -e '.headline | contains("has finished, but the backlog still records it in flight")' >/dev/null \
  || fail "the headline should state the drift: $(printf '%s' "$L" | jq -c '.headline')"
pass "a finished run with a stale backlog row is drift, not a vanished worker"

# --- a card may not deny the decision it is asking the captain to make -------
printf '%s' "$L" | jq -e '.decisions | length == 1' >/dev/null \
  || fail "the open pull request is a decision waiting on the captain: $(printf '%s' "$L" | jq -c '.decisions')"
printf '%s' "$L" | jq -e '.decisions[0].question == "Should https://github.com/acme/landing/pull/3 land?"' >/dev/null \
  || fail "the decision should be the one captainTasks names: $(printf '%s' "$L" | jq -c '.decisions[0]')"
printf '%s' "$L" | jq -e '[.executiveSummary.metrics[] | select(.label == "Captain decisions")][0].value == "1"' >/dev/null \
  || fail "the metric must count the decision the card is asking for"
printf '%s' "$L" | jq -e '[.currentStatus.signals[] | select(.label == "Decisions waiting on the captain")][0].value == "1 open"' >/dev/null \
  || fail "the signal must count the decision the card is asking for"
printf '%s' "$L" | jq -e '.executiveSummary.lede | contains("No decision waits on the captain") | not' >/dev/null \
  || fail "the lede must not deny a decision the same card asks for: $(printf '%s' "$L" | jq -c '.executiveSummary.lede')"
pass "a card never denies the decision its own captainTasks asks the captain to make"

# --- a pull request on work that nothing records in flight ------------------
AD=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "adhoc")')
printf '%s' "$AD" | jq -e '.captainTasks[0].title == "Decide on https://github.com/acme/adhoc/pull/5"' >/dev/null \
  || fail "a crew with no backlog row should still reach the captain: $(printf '%s' "$AD" | jq -c '.captainTasks')"
printf '%s' "$AD" | jq -e '.captainTasks[0] | has("why") | not' >/dev/null \
  || fail "nothing records this in flight, so the card must not say it is: $(printf '%s' "$AD" | jq -c '.captainTasks[0]')"
RQ=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "requeued")')
printf '%s' "$RQ" | jq -e '.captainTasks[0].title == "Decide on https://github.com/acme/requeued/pull/6"' >/dev/null \
  || fail "a queued row with an open pull request should still reach the captain: $(printf '%s' "$RQ" | jq -c '.captainTasks')"
printf '%s' "$RQ" | jq -e '.captainTasks[0] | has("why") | not' >/dev/null \
  || fail "a queued row is not in flight, so the card must not say it is: $(printf '%s' "$RQ" | jq -c '.captainTasks[0]')"
printf '%s' "$FEED_C" | jq -e '[.projects[].captainTasks[]?.why // ""] | any(contains("recorded in flight")) | not' >/dev/null \
  || fail "no captain task may assert a recorded state that nothing records"
pass "an open pull request claims nothing about where the work is recorded"

# --- a parked worker is a live worker ---------------------------------------
P=$(printf '%s' "$FEED_C" | jq '.projects[] | select(.id == "parked")')
printf '%s' "$P" | jq -e '.captainTasks[0].title == "Decide on https://github.com/acme/parked/pull/7"' >/dev/null \
  || fail "an open pull request should still reach the captain: $(printf '%s' "$P" | jq -c '.captainTasks')"
printf '%s' "$P" | jq -e '.captainTasks[0] | has("why") | not' >/dev/null \
  || fail "a parked worker is running; the card must claim nothing about it: $(printf '%s' "$P" | jq -c '.captainTasks[0]')"
printf '%s' "$P" | jq -e '[.blockers[] | select(.title | contains("no longer running"))] | length == 0' >/dev/null \
  || fail "a parked worker must not be reported as gone"
printf '%s' "$P" | jq -e '[.currentStatus.signals[] | select(.label == "Dispatched work")][0].value
                          | contains("no worker") | not' >/dev/null \
  || fail "the dispatched-work value must not deny a parked worker"
pass "a parked worker with an open pull request is never described as absent"

# --- a clone read that never completed claims nothing about the working tree -
# `git diff --quiet` answering 124 is the bound being hit (bin/fm-timeout-lib.sh),
# not a verdict, so the Local copy signal must say less rather than assert a
# working-tree state it never saw.
STALL_DIR="$TMP_ROOT/stalled-diff"
mkdir -p "$STALL_DIR"
FAKEBIN_STALL=$(make_fakebin "$STALL_DIR")
REAL_GIT=$(command -v git)
cat > "$FAKEBIN_STALL/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = diff ] && exit 124
done
exec $REAL_GIT "\$@"
SH
chmod +x "$FAKEBIN_STALL/git"

FEED_STALL=$(run "$HOME_A" "$FAKEBIN_STALL" --stdout) \
  || fail "generating the feed with a stalled diff read failed"
SL=$(printf '%s' "$FEED_STALL" | jq '.projects[] | select(.id == "rich")
                                    | [.currentStatus.signals[] | select(.label == "Local copy")][0]')
printf '%s' "$SL" | jq -e '.value | contains("uncommitted changes") | not' >/dev/null \
  || fail "a read that hit its bound must not assert uncommitted changes: $(printf '%s' "$SL" | jq -c '.')"
printf '%s' "$SL" | jq -e '.value == "could not be read" and .state == "unknown"' >/dev/null \
  || fail "an incomplete read should report itself unread: $(printf '%s' "$SL" | jq -c '{value,state}')"
pass "a clone read that hit its bound claims nothing about the working tree"

# --- ties sort by name, as the ordering comment says ------------------------
HOME_D=$(new_home home-d)
cat > "$HOME_D/data/projects.md" <<'EOF'
# Projects

- gamma [local-only] - Registered, nothing recorded (added 2026-07-01)
- alpha [local-only] - Registered, nothing recorded (added 2026-07-01)
- beta [local-only] - Registered, nothing recorded (added 2026-07-01)
EOF

FEED_D=$(run "$HOME_D" "$FAKEBIN_A" --stdout) || fail "generating the home-d feed failed"
printf '%s' "$FEED_D" | jq -e '[.projects[] | select(.status == "dormant")]
                               | sort_by(.order) | map(.id) == ["alpha", "beta", "gamma"]' >/dev/null \
  || fail "projects tied on rank and date should be ordered by name: $(printf '%s' "$FEED_D" | jq -c '[.projects[] | {id, order}]')"
pass "projects tied on evidence and date are ordered by name, not against it"

# --- firstmate never writes into a project ----------------------------------
GOOD="$TMP_ROOT/good-feed.json"
run "$HOME_A" "$FAKEBIN_A" --out "$GOOD" >/dev/null || fail "writing a feed to a normal path failed"
assert_present "$GOOD" "the feed should have been written"
BEFORE=$(cat "$GOOD")

set +e
OUT=$(run "$HOME_A" "$FAKEBIN_A" --out "$HOME_A/projects/rich/fleet.json" 2>&1)
CODE=$?
set -e
expect_code 2 "$CODE" "writing inside the projects root"
assert_contains "$OUT" "refusing to write inside the projects root" "the refusal should say why"
assert_absent "$HOME_A/projects/rich/fleet.json" "no file may be written under projects/"
pass "an output path inside the projects root is refused"

# The traversal leg is resolved physically, not by comparing the literal string.
set +e
OUT=$(run "$HOME_A" "$FAKEBIN_A" --out "$HOME_A/data/../projects/rich/fleet.json" 2>&1)
CODE=$?
set -e
expect_code 2 "$CODE" "traversing into the projects root"
assert_contains "$OUT" "refusing to write inside the projects root" "the refusal should say why"
assert_absent "$HOME_A/projects/rich/fleet.json" "no file may be written under projects/ through .."
pass "an output path that traverses into the projects root is refused"

# --- an unbounded clone read is refused rather than run unguarded -----------
# `timeout 0` and the perl fallback's `alarm 0` both DISABLE the deadline, so a
# non-positive bound must never reach the clone reads.
for bad in 0 -1 soon; do
  set +e
  OUT=$(PATH="$FAKEBIN_A:$PATH" FM_HOME="$HOME_A" FM_SNAPSHOT_NOW="$NOW" \
    FM_FLEET_FEED_CLONE_TIMEOUT="$bad" "$FEED" --stdout 2>&1)
  CODE=$?
  set -e
  expect_code 2 "$CODE" "a clone read timeout of '$bad'"
  assert_contains "$OUT" "FM_FLEET_FEED_CLONE_TIMEOUT" "the refusal should name the variable"
done
pass "a clone read timeout that would not bound anything is refused"

# --- malformed sources fail loudly, and never leave a partial feed ----------
# <label> <expected fragment> <mutation applied to a throwaway copy of home A>
refuses() {  # <label> <fragment> <mutate-fn>
  local label=$1 fragment=$2 mutate=$3 home out code
  home=$TMP_ROOT/bad-$RANDOM$RANDOM
  mkdir -p "$home"
  cp -R "$HOME_A/." "$home/"
  rm -rf "$home/state/"*.status.lock 2>/dev/null || true
  "$mutate" "$home"
  cp "$GOOD" "$home/feed.json"
  set +e
  out=$(PATH="$FAKEBIN_A:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" \
    "$FEED" --out "$home/feed.json" 2>&1)
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "$label: expected a refusal, got exit 0"
  assert_contains "$out" "$fragment" "$label: the refusal should name the problem"
  [ "$(cat "$home/feed.json")" = "$BEFORE" ] \
    || fail "$label: a refused run replaced the previous feed with a partial one"
  pass "$label"
}

mutate_no_registry() { rm -f "$1/data/projects.md"; }
mutate_no_repo() {
  printf -- '- [ ] orphan-row - Work with no repository recorded (kind: ship) (since 2026-07-08)\n' \
    >> "$1/data/backlog.md"
}
mutate_freeform() {
  awk '{ print } /^## Queued$/ { print "- a free-form note that names no task" }' \
    "$1/data/backlog.md" > "$1/data/backlog.md.new"
  mv "$1/data/backlog.md.new" "$1/data/backlog.md"
}
mutate_bad_name() {
  printf -- '- Not_A_Slug [local-only] - A name the renderer cannot address (added 2026-07-01)\n' \
    >> "$1/data/projects.md"
}
mutate_duplicate() {
  printf -- '- rich [local-only] - A second entry for the same project (added 2026-07-02)\n' \
    >> "$1/data/projects.md"
}

refuses "a missing project registry is refused, not reported as an empty fleet" \
  "no project registry at" mutate_no_registry
refuses "a backlog row with no repository is refused rather than dropped" \
  "records no repo" mutate_no_repo
refuses "an unattributable free-form row in a current section is refused" \
  "cannot be attributed to a project" mutate_freeform
refuses "a project name that cannot be a feed id is refused" \
  "not a usable feed id" mutate_bad_name
refuses "a duplicate registry entry is refused" \
  "duplicate registry entry" mutate_duplicate

echo "ok - fm-fleet-feed"
