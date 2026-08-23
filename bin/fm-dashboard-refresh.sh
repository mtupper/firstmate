#!/usr/bin/env bash
# fm-dashboard-refresh.sh - the captain's dashboard refresh trigger, end to end.
#
# ONE manual command that (1) generates a fresh fleet feed from live home state
# with bin/fm-fleet-feed.sh, (2) rebuilds the dashboard's standalone page from
# that feed inside a build checkout this script owns, and (3) publishes the
# result where the page is served. It is a trigger, not a scheduler: it runs
# when invoked and never arms a timer; a future schedule should call this same
# command.
#
# The dashboard project owns the data contract (DOCS/data-contract.md and
# schema/fleet.schema.json in that repository); the feed is validated with the
# dashboard's own `pnpm data:check` before anything is built, and
# `FLEET_DATA=<feed> pnpm build` inlines the feed so the built index.html is
# self-contained.
#
# NEVER WRITES TO A PROJECT (AGENTS.md hard rule 1). The clone under projects/
# is only read: the build runs in a dedicated checkout under this home's data/,
# cloned from that clone and re-synced to its HEAD on every run, so the page
# always shows what the captain's clone shows. Nothing is ever committed there,
# and the feed is passed by absolute path, never dropped into the checkout, so
# no fleet content can reach any repository. The publish and work directories
# are refused if they resolve inside the projects root.
#
# Layout, owned by this script:
#   $FM_HOME/data/dashboard-build/          work root
#     build/                                dedicated dashboard checkout
#     feed.json                             the fresh feed for this run
#     .lock/                                overlap guard (pid inside)
#   $FM_HOME/data/dashboard-preview/        publish dir (default)
#     index.html                            the served page
#     index.html.prev                       the previous page, recoverable
#
# Failure leaves the served page alone. Every step runs to completion before
# the one atomic replace at the end, so a failed generation, validation or
# build keeps the previously published page in place - stale, but carrying its
# own honest generated-at timestamp in the rendered header. The previous page
# survives each successful publish as index.html.prev.
#
# Overlapping runs: the second run REFUSES with the holder's pid while the
# first is alive. A lock whose recorded pid is provably dead is reclaimed, so
# a crashed run never wedges the trigger.
#
# Serving is not this script's job. The publish dir defaults to the location
# already served in this home (data/dashboard-preview, e.g. by
# `python3 -m http.server 3000 --bind 0.0.0.0` reachable at
# http://<host>:3000/); any static file server over the publish dir works, and
# the page also opens directly via file:// because it is self-contained.
#
# Usage:
#   fm-dashboard-refresh.sh                     refresh and publish
#   fm-dashboard-refresh.sh --publish-dir <dir> publish somewhere else
#   fm-dashboard-refresh.sh --project <name>    dashboard clone name (default: dashboard)
#   fm-dashboard-refresh.sh -h | --help         print this usage
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

die() { printf 'fm-dashboard-refresh: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

PROJECT=dashboard
PUBLISH_DIR=
PUBLISH_DIR_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --publish-dir) shift; PUBLISH_DIR=${1:-}; PUBLISH_DIR_GIVEN=1 ;;
    --publish-dir=*) PUBLISH_DIR=${1#--publish-dir=}; PUBLISH_DIR_GIVEN=1 ;;
    --project) shift; PROJECT=${1:-} ;;
    --project=*) PROJECT=${1#--project=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$PROJECT" ] || die "--project needs a name" 2
[ "$PUBLISH_DIR_GIVEN" -eq 1 ] && [ -z "$PUBLISH_DIR" ] && die "--publish-dir needs a path" 2
[ -n "$PUBLISH_DIR" ] || PUBLISH_DIR="$DATA/dashboard-preview"

command -v git >/dev/null 2>&1 || die "git not found"
command -v pnpm >/dev/null 2>&1 || die "pnpm not found; the dashboard builds with pnpm"

CLONE="$PROJECTS/$PROJECT"
[ -e "$CLONE/.git" ] || die "no dashboard clone at $CLONE; clone the project first"
[ -f "$CLONE/package.json" ] || die "$CLONE has no package.json; is $PROJECT the dashboard?"

WORK="$DATA/dashboard-build"

# --- placement guards (AGENTS.md hard rule 1) -------------------------------
# Both writable roots are guarded BEFORE they are created, so a refused path is
# never brought into existence inside a clone. Each is resolved physically from
# its deepest existing ancestor, so a symlink or .. cannot walk a write into
# the projects root. The publish dir must also stay out of the build checkout,
# where a later `git add` by anyone would commit fleet content.
resolve_intent() {  # <path>: physical path the target would occupy once created
  local p=$1 rest=
  while [ ! -d "$p" ]; do
    rest="/$(basename "$p")$rest"
    p=$(dirname "$p")
  done
  p=$(cd "$p" 2>/dev/null && pwd -P) || return 1
  printf '%s%s\n' "${p%/}" "$rest"
}
WORK=$(resolve_intent "$WORK") || die "cannot resolve the work root at $WORK"
PUBLISH_DIR=$(resolve_intent "$PUBLISH_DIR") || die "cannot resolve the publish dir at $PUBLISH_DIR"
if projects_dir=$(cd "$PROJECTS" 2>/dev/null && pwd -P); then
  for dir in "$WORK" "$PUBLISH_DIR"; do
    case "$dir" in
      "$projects_dir"|"$projects_dir"/*)
        die "refusing to write inside the projects root ($projects_dir); firstmate does not write to projects" 2
        ;;
    esac
  done
fi
case "$PUBLISH_DIR" in
  "$WORK/build"|"$WORK/build"/*)
    die "refusing to publish inside the build checkout; fleet content must never reach a repository" 2
    ;;
esac

BUILD="$WORK/build"
FEED="$WORK/feed.json"
LOCK="$WORK/.lock"
mkdir -p "$WORK" || die "cannot create the work root at $WORK"
mkdir -p "$PUBLISH_DIR" || die "cannot create the publish dir at $PUBLISH_DIR"

# --- overlap guard ----------------------------------------------------------
# mkdir is the atomic test-and-set and the pid file inside names the holder; a
# holder that no longer runs cannot finish its publish, so its lock is stale.
# Reclaiming is racy by nature - two runs can both observe the same dead
# holder - so the reclaim is an atomic rename (only one contender's mv wins)
# and taking the lock re-reads the pid file afterwards, so a lock swept from
# under a winner between its mkdir and its pid write is noticed as a refusal,
# never as two concurrent runs sharing the build checkout.
take_lock() {
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || return 1
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]
}
if ! take_lock; then
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    die "another refresh is already running (pid $holder); let it finish" 3
  fi
  STALE="$LOCK.stale.$$"
  mv "$LOCK" "$STALE" 2>/dev/null \
    || die "another refresh grabbed the lock first; let it finish" 3
  # The moved-aside lock may belong to a contender that reclaimed and re-took
  # it between the two reads above; a live pid inside means it was not ours to
  # sweep, so it is put back untouched.
  holder=$(cat "$STALE/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    mv "$STALE" "$LOCK" 2>/dev/null
    die "another refresh is already running (pid $holder); let it finish" 3
  fi
  rm -rf "$STALE"
  take_lock || die "another refresh grabbed the lock first; let it finish" 3
fi
trap 'rm -rf "$LOCK"' EXIT

# --- 1. fresh feed from live home state -------------------------------------
"$SCRIPT_DIR/fm-fleet-feed.sh" --out "$FEED" \
  || die "feed generation failed; the published page is untouched"

# --- 2. sync the build checkout to the clone's HEAD -------------------------
# A plain local clone reads the project and writes only here. `fetch origin
# +HEAD` follows whatever the clone has checked out - branch or not - so the
# page tracks the captain's clone, not a remote this script never contacts.
if [ ! -e "$BUILD/.git" ]; then
  git clone --quiet "$CLONE" "$BUILD" \
    || die "cannot create the build checkout at $BUILD"
fi
# A reused checkout keeps whatever origin it was first cloned from; re-point
# it at the clone selected THIS run, so a different --project never silently
# builds from the previously recorded repository.
git -C "$BUILD" remote set-url origin "$CLONE" \
  || die "cannot point the build checkout at $CLONE"
git -C "$BUILD" fetch --quiet origin +HEAD \
  || die "cannot read the dashboard clone's current state"
# The checkout is disposable by declaration (see header): --force discards
# both tracked leftovers and colliding untracked files from a broken run,
# while gitignored build caches survive.
git -C "$BUILD" checkout --force --quiet --detach FETCH_HEAD \
  || die "cannot check out the dashboard's current state in the build checkout"

# --- 3. validate the feed with the dashboard's own checker ------------------
(cd "$BUILD" \
  && pnpm install --frozen-lockfile --prefer-offline \
  && pnpm data:check "$FEED") \
  || die "the feed failed the dashboard's own contract check; the published page is untouched"

# --- 4. build the self-contained page ---------------------------------------
(cd "$BUILD" && FLEET_DATA="$FEED" pnpm build) \
  || die "the dashboard build failed; the published page is untouched"
PAGE="$BUILD/.output/public/index.html"
[ -s "$PAGE" ] || die "the build produced no page at $PAGE; the published page is untouched"

# --- 5. publish, keeping the previous page recoverable ----------------------
# The new page is staged next to its target so the final replace is a same-
# filesystem rename: the served file is never half-written, and the previous
# page is preserved first, so no failure window loses it.
STAGE="$PUBLISH_DIR/index.html.new"
cp "$PAGE" "$STAGE" || die "cannot stage the new page in $PUBLISH_DIR"
kept=
if [ -f "$PUBLISH_DIR/index.html" ]; then
  cp -p "$PUBLISH_DIR/index.html" "$PUBLISH_DIR/index.html.prev" \
    || die "cannot preserve the previous page; the published page is untouched"
  kept=", previous page kept as index.html.prev"
fi
mv "$STAGE" "$PUBLISH_DIR/index.html" || die "cannot publish the new page"

generated=$(jq -r '.generatedAt // empty' "$FEED" 2>/dev/null || true)
printf 'published %s (feed generated %s%s)\n' \
  "$PUBLISH_DIR/index.html" "${generated:-unknown}" "$kept"
