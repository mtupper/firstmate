#!/usr/bin/env bash
# End-to-end check of the process-source claim owner, the third durable record
# this change fixes.
#
# The claim root is MACHINE-GLOBAL and shared by every firstmate home, so the
# claim's `home` field is the only thing that tells one home's sources from
# another's. A home recorded under a symlink alias walks past its own claims.
# (An isolated FM_PROCEVENT_CLAIM_ROOT is used throughout; the real machine
# claim root is never touched.)
set -u
REPO=${1:?worktree path}
cd "$REPO" || exit 1
PROCEVENT="$REPO/bin/fm-procevent.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/fm-evidence-procevent.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/captain/dgh"
ln -s dgh "$T/captain/dev-github"
HOME_REAL="$T/captain/dgh/firstmate"
HOME_ALIAS="$T/captain/dev-github/firstmate"
mkdir -p "$HOME_REAL/state" "$T/claims"

run_pe() {  # <fm-home> <args...>
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$HOME_REAL/state" \
    FM_PROCEVENT_CLAIM_ROOT="$T/claims" "$PROCEVENT" "$@"
}
claim_owner() { sed -n 1p "$T/claims/demo-source.claim" 2>/dev/null; }
claim_pid()   { sed -n 2p "$T/claims/demo-source.claim" 2>/dev/null; }
show() { printf '%s\n' "$1" | sed "s#$T#\$TMP#g"; }
banner() { printf '\n=== %s ===\n' "$1"; }

start_through_alias() {
  run_pe "$HOME_ALIAS" register when demo-source -- /bin/sleep 300 >/dev/null
  run_pe "$HOME_ALIAS" start demo-source >/dev/null 2>&1 &
  local i=0
  while [ "$i" -lt 100 ] && [ ! -s "$T/claims/demo-source.claim" ]; do sleep 0.1; i=$((i+1)); done
}
cleanup_run() {
  local p; p=$(claim_pid)
  [ -z "$p" ] || kill -- -"$p" 2>/dev/null || kill "$p" 2>/dev/null || true
  rm -f "$T/claims"/*.claim "$HOME_REAL/state/procevent"/* 2>/dev/null || true
  wait 2>/dev/null || true
}

banner "1. the claim a home writes when it is entered through the alias"
cp "$PROCEVENT" "$T/pe.keep"
# Emulate the pre-fix write: the claim owner is FM_HOME verbatim.
sed -i '' 's/^FM_HOME_CANON=$(fm_canonical_path "$FM_HOME")$/FM_HOME_CANON=$FM_HOME/' "$PROCEVENT"
start_through_alias
printf 'BEFORE the fix, claim owner: '; show "$(claim_owner)"
printf '  -> the alias spelling, in a claim root every home shares.\n'
RUNNER_BEFORE=$(claim_pid)

banner "2. can the same home, entered physically, still find that claim?"
printf 'pre-fix read (plain string compare), `retire` from %s:\n' "$(printf %s "$HOME_REAL" | sed "s#$T#\$TMP#")"
sed -i '' 's/^    if fm_same_path "$FM_PROCEVENT_CLAIM_HOME" "$FM_HOME_CANON"; then$/    if [ "$FM_PROCEVENT_CLAIM_HOME" = "$FM_HOME_CANON" ]; then/' "$PROCEVENT"
run_pe "$HOME_REAL" retire demo-source | sed "s#$T#\$TMP#g"
if [ -e "$T/claims/demo-source.claim" ]; then
  printf '  claim left behind:          yes\n'
else
  printf '  claim left behind:          no\n'
fi
if kill -0 "$RUNNER_BEFORE" 2>/dev/null; then
  printf '  runner still alive:         yes  <- ORPHANED: registration gone, process still running\n'
else
  printf '  runner still alive:         no\n'
fi
cp "$T/pe.keep" "$PROCEVENT"
cleanup_run

banner "3. the change as committed"
cp "$PROCEVENT" "$T/pe.keep2"
sed -i '' 's/^FM_HOME_CANON=$(fm_canonical_path "$FM_HOME")$/FM_HOME_CANON=$FM_HOME/' "$PROCEVENT"
start_through_alias
RUNNER_AFTER=$(claim_pid)
printf 'a claim left on disk by the old code still holds the alias: '; show "$(claim_owner)"
cp "$T/pe.keep2" "$PROCEVENT"
printf 'fixed read side, `retire` from the physical home:\n'
run_pe "$HOME_REAL" retire demo-source | sed "s#$T#\$TMP#g"
if [ -e "$T/claims/demo-source.claim" ]; then
  printf '  claim left behind:          yes\n'
else
  printf '  claim left behind:          no   <- recognized as its own and released\n'
fi
if kill -0 "$RUNNER_AFTER" 2>/dev/null; then
  printf '  runner still alive:         yes\n'
else
  printf '  runner still alive:         no   <- stopped with its claim\n'
fi
cleanup_run

banner "4. and a home entered through the alias now records itself physically"
start_through_alias
printf 'AFTER the fix, claim owner:  '; show "$(claim_owner)"
printf '  -> the physical path, whichever spelling firstmate was entered through.\n'
cleanup_run
printf '\n'
