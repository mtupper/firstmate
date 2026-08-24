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
#     .lock                                 overlap guard (kernel-held flock)
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
# Overlapping runs: the second run REFUSES while the first is alive. The lock
# is a kernel-held flock released the moment its holder exits, however it
# exits, so a crashed run never wedges the trigger and two runs can never
# proceed concurrently.
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
# A flag where a value belongs means the intended value was never typed: the
# next flag was consumed as the value instead. Refusing it here is the only
# place that can tell the difference - further down it is just a relative path
# that would resolve against the current directory.
[ -n "$PROJECT" ] || die "--project needs a name" 2
case "$PROJECT" in
  -*) die "--project needs a name; got the flag $PROJECT" 2 ;;
esac
[ "$PUBLISH_DIR_GIVEN" -eq 1 ] && [ -z "$PUBLISH_DIR" ] && die "--publish-dir needs a path" 2
case "$PUBLISH_DIR" in
  -*) die "--publish-dir needs a path; got the flag $PUBLISH_DIR" 2 ;;
esac
[ -n "$PUBLISH_DIR" ] || PUBLISH_DIR="$DATA/dashboard-preview"

command -v git >/dev/null 2>&1 || die "git not found"
command -v pnpm >/dev/null 2>&1 || die "pnpm not found; the dashboard builds with pnpm"
command -v perl >/dev/null 2>&1 || die "perl not found; the overlap lock is taken with perl's flock"

CLONE="$PROJECTS/$PROJECT"
[ -e "$CLONE/.git" ] || die "no dashboard clone at $CLONE; clone the project first"
[ -f "$CLONE/package.json" ] || die "$CLONE has no package.json; is $PROJECT the dashboard?"

WORK="$DATA/dashboard-build"

# --- placement guards (AGENTS.md hard rule 1) -------------------------------
# EVERY root this script writes to - the work root, the build checkout inside
# it, and the publish dir - is guarded BEFORE it is created, so a refused path
# is never brought into existence inside a clone. A path is resolved from its
# deepest EXISTING ancestor through getcwd (/bin/pwd -P, NOT the shell builtin,
# which reports back the spelling the caller typed). getcwd reports the entry
# names the filesystem itself stores, so a symlink, a '..', or a case or
# unicode alias of an existing directory is already canonical before any prefix
# is compared; only a remainder that exists nowhere on disk is carried through
# as written, and such a remainder cannot alias its way out of an ancestor that
# is already inside the protected tree.
#
# The publish dir must also stay out of the build checkout, where a later
# `git add` by anyone would commit fleet content. That checkout may not exist
# yet on a fresh work root, and a name that does not exist has no on-disk
# identity to compare against - so the guard runs twice: once before anything
# is created, then again once the checkout's own directory is on disk, which is
# still before the publish dir is created and before any feed, clone, build or
# publish happens. The second pass is also what settles the checkout itself: a
# symlink planted at the checkout's name resolves to wherever it points, and a
# checkout that lands in the projects root is refused there, before any git or
# pnpm command reaches it.
physical_dir() {  # <existing dir>: the path the filesystem itself stores for it
  (cd "$1" 2>/dev/null && /bin/pwd -P)
}
resolve_intent() {  # <path>: physical path the target would occupy once created
  local p=$1 rest='' leaf
  while [ ! -d "$p" ]; do
    leaf=$(basename -- "$p") || return 1
    case "$leaf" in
      ..) return 1 ;;
      .) ;;
      *) rest="/$leaf$rest" ;;
    esac
    p=$(dirname -- "$p") || return 1
  done
  p=$(physical_dir "$p") || return 1
  printf '%s%s\n' "${p%/}" "$rest"
}
# The projects root certainly exists by now - the clone under it was checked
# above - so failing to resolve it is an error, never a reason to skip the
# guard that depends on it.
PROJECTS_ROOT=$(physical_dir "$PROJECTS") || die "cannot resolve the projects root at $PROJECTS"
guard_placement() {  # refuse the resolved roots wherever a write could reach a repository
  local dir
  for dir in "$WORK" "$BUILD" "$PUBLISH_DIR"; do
    case "$dir" in
      "$PROJECTS_ROOT"|"$PROJECTS_ROOT"/*)
        die "refusing to write inside the projects root ($PROJECTS_ROOT); firstmate does not write to projects" 2
        ;;
    esac
  done
  case "$PUBLISH_DIR" in
    "$BUILD"|"$BUILD"/*)
      die "refusing to publish inside the build checkout; fleet content must never reach a repository" 2
      ;;
  esac
}

intent=$WORK
WORK=$(resolve_intent "$intent") || die "cannot resolve the work root at $intent"
intent=$PUBLISH_DIR
PUBLISH_DIR=$(resolve_intent "$intent") || die "cannot resolve the publish dir at $intent"
BUILD="$WORK/build"
guard_placement

FEED="$WORK/feed.json"
LOCKFILE="$WORK/.lock"
mkdir -p "$WORK" || die "cannot create the work root at $WORK"
mkdir -p "$BUILD" || die "cannot create the build checkout at $BUILD"
intent=$BUILD
BUILD=$(resolve_intent "$intent") || die "cannot resolve the build checkout at $intent"
intent=$PUBLISH_DIR
PUBLISH_DIR=$(resolve_intent "$intent") || die "cannot resolve the publish dir at $intent"
guard_placement
mkdir -p "$PUBLISH_DIR" || die "cannot create the publish dir at $PUBLISH_DIR"

# --- overlap guard ----------------------------------------------------------
# A kernel-held flock on a plain lock file, taken without blocking. flock(2)
# locks the open file description; perl reaches this shell's descriptor 9 by
# duplicating it, so the lock it takes stays held by the shell's own open
# descriptor after perl exits, for the rest of the run. The kernel releases
# it the moment this process exits, however it exits, so a dead holder never
# blocks the next run and there is no pid bookkeeping, no staleness test, no
# reclaim, and no cleanup to trap. 6 is LOCK_EX|LOCK_NB.
exec 9>>"$LOCKFILE" || die "cannot open the lock file at $LOCKFILE"
perl -e 'open(my $fh, ">>&=", $ARGV[0]) or exit 2; exit(flock($fh, 6) ? 0 : 3)' 9
case $? in
  0) ;;
  3) die "another refresh is already running; let it finish" 3 ;;
  *) die "cannot take the refresh lock on $LOCKFILE" ;;
esac

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
# The install is guarded separately from the check it enables, so a toolchain
# or lockfile problem is never reported as a fault in the feed.
(cd "$BUILD" && pnpm install --frozen-lockfile --prefer-offline) \
  || die "cannot install the dashboard's dependencies in the build checkout; the published page is untouched"
(cd "$BUILD" && pnpm data:check "$FEED") \
  || die "the feed failed the dashboard's own contract check; the published page is untouched"

# --- 4. build the self-contained page ---------------------------------------
rm -rf "$BUILD/.output" \
  || die "cannot clear the previous build output at $BUILD/.output"
(cd "$BUILD" && FLEET_DATA="$FEED" pnpm build) \
  || die "the dashboard build failed; the published page is untouched"
PAGE="$BUILD/.output/public/index.html"
[ -s "$PAGE" ] || die "the build produced no page at $PAGE; the published page is untouched"

# --- 5. publish, keeping the previous page recoverable ----------------------
# The new page is staged next to its target so the final replace is a same-
# filesystem rename: the served file is never half-written, and the previous
# page is preserved first, so no failure window loses it. The publish dir is
# what a static server exposes, so the stage only ever lives between the copy
# and the replace: any exit in between takes it away again, leaving the served
# directory exactly as this step found it.
STAGE="$PUBLISH_DIR/index.html.new"
trap 'rm -f "$STAGE"' EXIT
cp "$PAGE" "$STAGE" || die "cannot stage the new page in $PUBLISH_DIR"
kept=
if [ -f "$PUBLISH_DIR/index.html" ]; then
  cp -p "$PUBLISH_DIR/index.html" "$PUBLISH_DIR/index.html.prev" \
    || die "cannot preserve the previous page; the published page is untouched"
  kept=", previous page kept as index.html.prev"
fi
mv "$STAGE" "$PUBLISH_DIR/index.html" || die "cannot publish the new page"
trap - EXIT

generated=$(jq -r '.generatedAt // empty' "$FEED" 2>/dev/null || true)
printf 'published %s (feed generated %s%s)\n' \
  "$PUBLISH_DIR/index.html" "${generated:-unknown}" "$kept"
