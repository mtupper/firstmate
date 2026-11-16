# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists), an X-mode relay poll
# (state/x-watch.check.sh), a registered process-to-event source, or a wake record
# in state/.wake-queue that the post-handling acknowledgement can still consume,
# and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# A queued wake counts because the wake that retires the last source is itself
# the one still owed delivery: without it, a home whose only one-shot source has
# just fired would stand supervision down before presenting that source's notice.
# The queue empties at the handling turn's post-handling acknowledgement, so this
# need ends exactly when the wake has been presented and handled.
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# The one record-shape test for a wake-queue row that bin/fm-wake-drain.sh's
# acknowledgement consumes: five or more tab-separated fields with a numeric
# sequence. The drain and the need predicate below share it, so the need always
# ends at that acknowledgement.
# shellcheck disable=SC2016 # awk, not the shell, expands $2.
FM_WAKE_ACKABLE_RECORD_AWK='NF >= 5 && $2 ~ /^[0-9]+$/'

# fm_sup_wake_queue_ackable <queue-file>
# Exit 0 (true) exactly when the queue holds a record the acknowledgement consumes.
fm_sup_wake_queue_ackable() {
  [ -s "$1" ] || return 1
  awk -F '\t' "$FM_WAKE_ACKABLE_RECORD_AWK { found = 1; exit } END { exit !found }" "$1" 2>/dev/null
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or an acknowledgeable wake in state/.wake-queue
#   FM_SUP_NEED_DESC      human-readable reason for FM_SUP_NEEDED, for banners
#                         (empty when supervision is not needed)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue holds a record the
#                         post-handling acknowledgement can still consume
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false
  FM_SUP_NEED_DESC=

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  fm_sup_wake_queue_ackable "$state/.wake-queue" && FM_SUP_QUEUE_PENDING=true
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    FM_SUP_NEED_DESC="$FM_SUP_IN_FLIGHT task(s) in flight"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEED_DESC="$FM_SUP_SOURCES process-event source(s) registered"
  elif [ -f "$state/x-watch.check.sh" ]; then
    FM_SUP_NEED_DESC="X-mode relay polling needs supervision"
  elif [ "$FM_SUP_QUEUE_PENDING" = true ]; then
    FM_SUP_NEED_DESC="a queued wake still awaits handling and acknowledgement"
  fi
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  [ -n "$FM_SUP_NEED_DESC" ] && FM_SUP_NEEDED=true

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
