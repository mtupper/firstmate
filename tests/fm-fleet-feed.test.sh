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

printf '%s' "$R" | jq -e '.captainTasks | length == 3' >/dev/null \
  || fail "captainTasks is capped at the next three"
printf '%s' "$R" | jq -e '.captainTasks[0].title == "Decide on https://github.com/acme/rich/pull/9"' >/dev/null \
  || fail "a finished PR waiting on the captain should lead their list"
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
