#!/usr/bin/env bash
# fm-sailsup-lib.sh - the ONE owner of the captain's /sailsup approval record
# and its session scope.
#
# /sailsup is the captain's explicit, per-session approval to put Claude
# workers that a restore left in reduced permission mode back into bypass mode
# (.agents/skills/sailsup/SKILL.md owns when it runs; bin/fm-sailsup.sh owns
# the orchestration). This library owns what makes that approval safe to act
# on:
#
#   Session scope. An approval is bound to the session that holds this home's
#   fleet lock (state/.lock, owned by bin/fm-lock.sh), identified by the lock
#   holder's pid plus that process's start time, so a reused pid can never
#   inherit it. Only a process running inside that same session may create or
#   use one (bin/fm-session-lock-lib.sh's fm_session_lock_owned_by_self). A new
#   session - including the one a restart or a Herdr restore brings up - has a
#   new identity, so an older approval never authorizes anything there.
#
#   Away mode. While state/.afk exists, no approval can be created or used:
#   away mode never grants /sailsup.
#
#   Record. state/sailsup/<approval-id>.approval is private, append-only, and
#   durable:
#     v1
#     approval=<id>
#     approved_at=<UTC ISO-8601>
#     home=<FM_HOME>
#     session=<lock-pid>@<start-time>
#     invoked_by=captain|delegated
#     parent_approval=<id>          (delegated only)
#     parent_home=<path>            (delegated only)
#     worker=<task-id> kind=<kind> before=<verdict> outcome=<result>
#     forwarded=<secondmate-id> outcome=<result>
#   A worker line names each worker the approval covers; bin/fm-control.sh
#   restore-bypass refuses a worker the record does not name.
#
#   Delegation. A secondmate acts on its parent's approval only when the
#   parent's own record is readable through the secondmate's local parent
#   binding, names this secondmate on a forwarded= line, and is younger than
#   FM_SAILSUP_DELEGATION_MAX_AGE seconds (default 1800). A remote-route
#   secondmate cannot read its parent's record and is refused.
#
# Sourcing: requires bin/fm-session-lock-lib.sh and bin/fm-secondmate-parent-lib.sh;
# set -u safe; no side effects.

FM_SAILSUP_DELEGATION_MAX_AGE_DEFAULT=1800

# fm_sailsup_session_id <state>: the identity of the session holding this
# home's fleet lock, printed only when the calling process runs inside it.
fm_sailsup_session_id() {  # <state>
  local state=$1 pid start
  pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_session_lock_owned_by_self "$state" || return 1
  start=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' \t' '__') || return 1
  start=${start#_}
  start=${start%_}
  [ -n "$start" ] || return 1
  printf '%s@%s\n' "$pid" "$start"
}

fm_sailsup_record_dir() {  # <state>
  printf '%s/sailsup' "$1"
}

# fm_sailsup_record_field <record> <key>: the first value of a top-level field.
fm_sailsup_record_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# fm_sailsup_approval_check <state> <record> [<worker-id>]: 0 when <record> is
# a /sailsup approval of this home, made in the current session, outside away
# mode, and - when a worker is named - covering that worker. Prints the reason
# on refusal.
fm_sailsup_approval_check() {  # <state> <record> [<worker-id>]
  local state=$1 record=$2 worker=${3:-} dir real session
  if [ -e "$state/.afk" ]; then
    echo "away mode is active; away mode never grants /sailsup"
    return 1
  fi
  dir=$(cd "$(fm_sailsup_record_dir "$state")" 2>/dev/null && pwd -P) || {
    echo "this home has no /sailsup approval records"
    return 1
  }
  [ -f "$record" ] && [ ! -L "$record" ] || {
    echo "approval record '$record' is not a regular file"
    return 1
  }
  real="$(cd "$(dirname "$record")" 2>/dev/null && pwd -P)/$(basename "$record")"
  case "$real" in
    "$dir"/*.approval) ;;
    *) echo "approval record '$record' is not one of this home's /sailsup records"; return 1 ;;
  esac
  [ "$(head -1 "$record")" = v1 ] || {
    echo "approval record '$record' is not a v1 /sailsup record"
    return 1
  }
  session=$(fm_sailsup_session_id "$state") || {
    echo "this process is not running inside the session that holds this home's fleet lock, and /sailsup covers that session only"
    return 1
  }
  [ "$(fm_sailsup_record_field "$record" session)" = "$session" ] || {
    echo "approval record '$record' belongs to an earlier session; /sailsup never carries over, so the captain must run it again"
    return 1
  }
  if [ -n "$worker" ] && ! grep -q "^worker=$worker " "$record" 2>/dev/null; then
    echo "approval record '$record' does not cover task $worker"
    return 1
  fi
  return 0
}

# fm_sailsup_parent_approval_check <home> <parent-approval-id>: 0 when this
# secondmate home may act on its parent's approval (see Delegation above).
# Prints the parent home on success and the reason on refusal.
fm_sailsup_parent_approval_check() {  # <home> <approval-id>
  local home=$1 approval=$2 mate record now mtime max
  case "$approval" in
    ''|*[!A-Za-z0-9._-]*) echo "'$approval' is not a /sailsup approval id"; return 1 ;;
  esac
  mate=$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)
  [ -n "$mate" ] || { echo "this home is not a seeded secondmate home, so it has no parent approval to act on"; return 1; }
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" \
    || { echo "this secondmate home's parent binding is unreadable"; return 1; }
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -n "$FM_SECONDMATE_PARENT_HOME" ] \
    || { echo "this secondmate runs on a remote route and cannot read its parent's approval record"; return 1; }
  record="$FM_SECONDMATE_PARENT_HOME/state/sailsup/$approval.approval"
  [ -f "$record" ] && [ ! -L "$record" ] \
    || { echo "the parent home has no /sailsup approval '$approval'"; return 1; }
  grep -q "^forwarded=$mate " "$record" 2>/dev/null \
    || { echo "the parent's approval '$approval' was not forwarded to secondmate $mate"; return 1; }
  max=${FM_SAILSUP_DELEGATION_MAX_AGE:-$FM_SAILSUP_DELEGATION_MAX_AGE_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_SAILSUP_DELEGATION_MAX_AGE_DEFAULT ;; esac
  now=$(date +%s)
  mtime=$(stat -f %m "$record" 2>/dev/null || stat -c %Y "$record" 2>/dev/null || echo 0)
  [ $((now - mtime)) -le "$max" ] \
    || { echo "the parent's approval '$approval' is older than ${max}s; the captain must run /sailsup again"; return 1; }
  printf '%s\n' "$FM_SECONDMATE_PARENT_HOME"
}
