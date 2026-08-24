#!/usr/bin/env bash
# Behavior tests for the dashboard refresh trigger.
#
# Covers the full manual path with a fake pnpm standing in for the dashboard's
# toolchain: a first publish, a second publish that keeps the previous page
# recoverable, a failed generation, a failed build, and an empty build each
# leaving the served page untouched, the overlap lock refusing a live holder
# and reclaiming a dead one, the projects-root and build-checkout publish
# refusals, and the project
# clone staying byte-for-byte untouched throughout.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-dashboard-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-refresh)
# Keep the disposable home outside the snapshot's fixture repo boundary even
# when TMPDIR sits inside an isolated source worktree.
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

NOW=2026-08-22T18:00:00Z
fm_git_identity

# The snapshot behind fm-fleet-feed.sh shells out to tmux and no-mistakes; the
# trigger itself needs a pnpm. The fake pnpm honors the three calls the trigger
# makes: install is a no-op, data:check demands a readable feed, and build
# writes a page that embeds the feed FLEET_DATA points at plus a per-run nonce,
# so two builds never collide byte-for-byte. FM_FAKE_PNPM_FAIL_BUILD simulates
# a broken build; FM_FAKE_PNPM_EMPTY_BUILD simulates a build that exits 0
# without writing a page.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  fm_fake_exit0 "$fb" no-mistakes tmux
  cat > "$fb/pnpm" <<'SH'
#!/usr/bin/env bash
cmd=${1:-}
shift || true
case "$cmd" in
  install) exit 0 ;;
  data:check)
    [ -s "${1:-}" ] || { echo "fake pnpm: no feed at ${1:-<none>}" >&2; exit 1; }
    grep -q '"contractVersion"' "$1" || { echo "fake pnpm: not a feed" >&2; exit 1; }
    exit 0 ;;
  build)
    [ -n "${FLEET_DATA:-}" ] || { echo "fake pnpm: FLEET_DATA unset" >&2; exit 1; }
    [ -s "$FLEET_DATA" ] || { echo "fake pnpm: FLEET_DATA missing" >&2; exit 1; }
    [ -n "${FM_FAKE_PNPM_FAIL_BUILD:-}" ] && { echo "fake pnpm: build broken" >&2; exit 1; }
    [ -n "${FM_FAKE_PNPM_EMPTY_BUILD:-}" ] && exit 0
    mkdir -p .output/public
    { printf 'STANDALONE %s%s\n' "$$" "$RANDOM"; cat "$FLEET_DATA"; } > .output/public/index.html
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/pnpm"
  printf '%s\n' "$fb"
}

HOME_A=$TMP_ROOT/home-a
mkdir -p "$HOME_A/state" "$HOME_A/data" "$HOME_A/projects" "$HOME_A/config"
FAKEBIN=$(make_fakebin "$HOME_A")

cat > "$HOME_A/data/projects.md" <<'EOF'
# Projects

- dash [direct-PR] - The fixture dashboard (added 2026-08-22)
EOF

cat > "$HOME_A/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] dash-item - Keep the fixture attributable (repo: dash) (kind: ship) (since 2026-08-22)

## Done
EOF

# The fixture dashboard clone: the trigger demands a package.json, and the
# build checkout is cloned from this clone, so the file must be committed.
fm_git_init_commit "$HOME_A/projects/dash"
printf '{"name": "fixture-dashboard"}\n' > "$HOME_A/projects/dash/package.json"
git -C "$HOME_A/projects/dash" add package.json
git -C "$HOME_A/projects/dash" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'add package.json'
git -C "$HOME_A/projects/dash" remote add origin 'git@github.com:acme/dash.git'
CLONE_HEAD=$(git -C "$HOME_A/projects/dash" rev-parse HEAD)

PUBLISH="$HOME_A/data/dashboard-preview"
PAGE="$PUBLISH/index.html"
PREV="$PUBLISH/index.html.prev"

run() {  # <args...>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_A" FM_SNAPSHOT_NOW="$NOW" \
    "$REFRESH" --project dash "$@"
}

# --- first run publishes a page built from the fresh feed --------------------
OUT=$(run 2>&1) || fail "the first refresh failed: $OUT"
[ -s "$PAGE" ] || fail "the first refresh published no page at $PAGE"
grep -q '"contractVersion"' "$PAGE" \
  || fail "the published page does not embed the feed the build was pointed at"
grep -q '"generatedAt": *"2026-08-22T18:00:00Z"' "$PAGE" \
  || fail "the published page does not carry the feed's observation time"
[ -e "$PREV" ] && fail "a first publish has no previous page to keep, but $PREV exists"
printf '%s' "$OUT" | grep -q 'index.html.prev' \
  && fail "the first publish must not claim a previous page was kept: $OUT"
[ "$(git -C "$HOME_A/data/dashboard-build/build" rev-parse HEAD)" = "$CLONE_HEAD" ] \
  || fail "the build checkout is not at the clone's HEAD"
pass "the first refresh publishes a page built from the fresh feed at the clone's HEAD"

# --- the second run replaces the page and keeps the previous one -------------
FIRST=$(cat "$PAGE")
OUT=$(run 2>&1) || fail "the second refresh failed: $OUT"
[ "$(cat "$PAGE")" != "$FIRST" ] || fail "the second refresh did not replace the page"
[ "$(cat "$PREV")" = "$FIRST" ] || fail "the previous page was not kept recoverable at $PREV"
printf '%s' "$OUT" | grep -q 'index.html.prev' \
  || fail "a replacing publish should say the previous page was kept: $OUT"
pass "the second refresh replaces the page and keeps the previous one recoverable"

# --- a failed generation leaves the published page untouched -----------------
SECOND=$(cat "$PAGE")
mv "$HOME_A/data/projects.md" "$HOME_A/data/projects.md.away"
OUT=$(run 2>&1) && fail "the refresh must fail when the feed cannot be generated"
mv "$HOME_A/data/projects.md.away" "$HOME_A/data/projects.md"
printf '%s' "$OUT" | grep -q 'published page is untouched' \
  || fail "a failed generation should say the page is untouched: $OUT"
[ "$(cat "$PAGE")" = "$SECOND" ] || fail "a failed generation replaced the published page"
[ "$(cat "$PREV")" = "$FIRST" ] || fail "a failed generation disturbed the previous page"
pass "a failed generation leaves the published page and its previous copy alone"

# --- a failed build leaves the published page untouched ----------------------
OUT=$(FM_FAKE_PNPM_FAIL_BUILD=1 run 2>&1) && fail "the refresh must fail when the build fails"
printf '%s' "$OUT" | grep -q 'published page is untouched' \
  || fail "a failed build should say the page is untouched: $OUT"
[ "$(cat "$PAGE")" = "$SECOND" ] || fail "a failed build replaced the published page"
pass "a failed build leaves the published page alone"

# --- an empty build is refused, not papered over by stale output -------------
# The build checkout keeps its gitignored .output/ across runs, so an earlier
# successful build can leave a page there. Seed such a leftover, then drive a
# build that exits 0 without writing a new page: the no-page guard must still
# fail instead of republishing the stale page.
mkdir -p "$HOME_A/data/dashboard-build/build/.output/public"
printf 'STALE PAGE FROM AN EARLIER RUN\n' \
  > "$HOME_A/data/dashboard-build/build/.output/public/index.html"
OUT=$(FM_FAKE_PNPM_EMPTY_BUILD=1 run 2>&1) && fail "the refresh must fail when the build writes no page"
printf '%s' "$OUT" | grep -q 'produced no page' \
  || fail "an empty build should be reported as producing no page: $OUT"
[ "$(cat "$PAGE")" = "$SECOND" ] || fail "an empty build replaced the published page"
pass "an empty build is refused even when stale output survives from a previous run"

# --- overlapping runs: a live holder refuses, a dead one never blocks --------
# The lock is the flock on data/dashboard-build/.lock named in the script's
# header - part of its documented layout. A fixture holder takes the same
# flock and keeps it while it lives; killing it must release it. The holder
# waits for the lock (no LOCK_NB) so the probe below, which grabs and releases
# it on every poll, can never race the holder's one attempt into a failure.
LOCKFILE="$HOME_A/data/dashboard-build/.lock"
perl -e 'open(my $fh, ">>", $ARGV[0]) or exit 2; flock($fh, 2) or exit 3; sleep 60' "$LOCKFILE" &
HOLDER=$!
# Wait until the holder provably has the lock: a non-blocking probe stops
# succeeding. The probe's own lock is released when the probe exits.
tries=0
until ! perl -e 'open(my $fh, ">>", $ARGV[0]) or exit 2; exit(flock($fh, 6) ? 0 : 1)' "$LOCKFILE"; do
  tries=$((tries + 1))
  [ "$tries" -lt 100 ] || fail "the fixture holder never took the lock"
  sleep 0.1
done
OUT=$(run 2>&1)
STATUS=$?
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
[ "$STATUS" -eq 3 ] || fail "a live holder should be refused with exit 3, got $STATUS: $OUT"
printf '%s' "$OUT" | grep -q 'already running' \
  || fail "the refusal should say a refresh is already running: $OUT"
# The holder is dead and the kernel has released its lock; nothing to reclaim.
run >/dev/null 2>&1 || fail "a dead holder must not block the next refresh"
pass "an overlapping run is refused while the holder lives and never blocked by a dead one"

# --- writes are refused where they could reach a repository ------------------
OUT=$(run --publish-dir "$HOME_A/projects/dash/served" 2>&1)
STATUS=$?
[ "$STATUS" -eq 2 ] || fail "publishing into the projects root should be refused with exit 2, got $STATUS: $OUT"
printf '%s' "$OUT" | grep -q 'projects root' \
  || fail "the projects-root refusal should say why: $OUT"
[ -e "$HOME_A/projects/dash/served" ] && fail "the refused publish dir was still created inside the clone"
# A '..' past a nonexistent component must not survive resolution and let
# mkdir -p re-expand it into the projects root behind the prefix guard.
OUT=$(run --publish-dir "$HOME_A/data/missing/../../projects/dash/inner" 2>&1)
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "a publish dir using '..' past a nonexistent component must be refused: $OUT"
[ -e "$HOME_A/projects/dash/inner" ] && fail "the '..' publish dir was still created inside the clone"
[ -e "$HOME_A/data/missing" ] && fail "the refused '..' publish dir left a partial path behind"
OUT=$(run --publish-dir "$HOME_A/data/dashboard-build/build/served" 2>&1)
STATUS=$?
[ "$STATUS" -eq 2 ] || fail "publishing into the build checkout should be refused with exit 2, got $STATUS: $OUT"
# A '.' in a not-yet-existing remainder must not slip past the lexical
# build-checkout guard: on a home whose work root does not exist yet,
# publishing to dashboard-build/./build must still be refused, before
# anything is created.
FRESH_DATA="$TMP_ROOT/fresh-data"
mkdir -p "$FRESH_DATA"
OUT=$(FM_DATA_OVERRIDE="$FRESH_DATA" run --publish-dir "$FRESH_DATA/dashboard-build/./build" 2>&1)
STATUS=$?
[ "$STATUS" -eq 2 ] || fail "a '.' publish dir into the not-yet-created build checkout should be refused with exit 2, got $STATUS: $OUT"
printf '%s' "$OUT" | grep -q 'build checkout' \
  || fail "the '.' build-checkout refusal should say why: $OUT"
[ -e "$FRESH_DATA/dashboard-build" ] && fail "the refused '.' publish dir still created the work root"
OUT=$(run --publish-dir 2>&1)
STATUS=$?
[ "$STATUS" -eq 2 ] || fail "--publish-dir with no value should die with exit 2, not fall back silently, got $STATUS: $OUT"
OUT=$(run --publish-dir '' 2>&1)
STATUS=$?
[ "$STATUS" -eq 2 ] || fail "--publish-dir with an empty value should die with exit 2, got $STATUS: $OUT"
pass "a publish dir that reaches the projects root or the build checkout, even via '..' or '.', or an empty one, is refused"

# --- a reused checkout follows the clone selected this run -------------------
fm_git_init_commit "$HOME_A/projects/dash2"
printf '{"name": "second-dashboard"}\n' > "$HOME_A/projects/dash2/package.json"
git -C "$HOME_A/projects/dash2" add package.json
git -C "$HOME_A/projects/dash2" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'add package.json'
DASH2_HEAD=$(git -C "$HOME_A/projects/dash2" rev-parse HEAD)
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_A" FM_SNAPSHOT_NOW="$NOW" \
  "$REFRESH" --project dash2 >/dev/null 2>&1 \
  || fail "refreshing against a second project failed"
[ "$(git -C "$HOME_A/data/dashboard-build/build" rev-parse HEAD)" = "$DASH2_HEAD" ] \
  || fail "a reused build checkout still built the previously selected project"
pass "a reused build checkout is re-pointed at the clone selected this run"

# --- a leftover untracked file cannot wedge the disposable checkout ----------
printf 'leftover from a broken run\n' > "$HOME_A/data/dashboard-build/build/newfile.txt"
printf 'the committed version\n' > "$HOME_A/projects/dash/newfile.txt"
git -C "$HOME_A/projects/dash" add newfile.txt
git -C "$HOME_A/projects/dash" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'add newfile.txt'
CLONE_HEAD=$(git -C "$HOME_A/projects/dash" rev-parse HEAD)
run >/dev/null 2>&1 \
  || fail "a colliding untracked leftover wedged the disposable build checkout"
[ "$(cat "$HOME_A/data/dashboard-build/build/newfile.txt")" = "the committed version" ] \
  || fail "the checkout kept the leftover instead of the committed file"
pass "a colliding untracked leftover is discarded, keeping the checkout disposable"

# --- the project clone is read, never written --------------------------------
[ -z "$(git -C "$HOME_A/projects/dash" status --porcelain)" ] \
  || fail "the project clone is no longer clean after refreshing"
[ "$(git -C "$HOME_A/projects/dash" rev-parse HEAD)" = "$CLONE_HEAD" ] \
  || fail "the project clone's HEAD moved"
# Nothing may stage fleet content in the build checkout either: the feed is
# passed by path from outside it, so its tracked tree stays clean.
if git -C "$HOME_A/data/dashboard-build/build" status --porcelain | grep -v '^??' | grep -q .; then
  fail "the build checkout has tracked changes; fleet content could be committed"
fi
pass "the project clone stays untouched and the build checkout stays clean"

echo "all fm-dashboard-refresh tests passed"
