#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home, plus the home-identity backstop that
# refuses an environment naming another home than the one a process runs in.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
# A process whose environment names another firstmate checkout than the one it
# runs in is out of scope too (fm_home_identity_check), so every hook that scopes
# itself here stands down instead of acting for that other home.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
  if ! fm_home_identity_check "${FM_HOME:-$root}" "$state"; then
    printf '%s\n' "$FM_HOME_IDENTITY_REASON" >&2
    return 1
  fi
}

# Return 0 when $1 is a firstmate checkout: a home, a secondmate home, or a
# task worktree of the firstmate repo itself.
fm_is_firstmate_checkout() {
  [ -f "$1/AGENTS.md" ] && [ -f "$1/bin/fm-session-start.sh" ]
}

# Print the OUTERMOST firstmate checkout that contains directory $1 (itself
# included), or nothing. Outermost, because a home's own projects/ may hold a
# clone of firstmate, and a process there still runs in the home.
fm_firstmate_checkout_of() {
  local dir found=
  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  while :; do
    fm_is_firstmate_checkout "$dir" && found=$dir
    [ "$dir" = / ] && break
    dir=$(dirname "$dir")
  done
  [ -z "$found" ] || printf '%s\n' "$found"
}

# fm_home_identity_check <home> <state>: the fail-closed backstop against an
# inherited environment. Returns 1, with FM_HOME_IDENTITY_REASON set, when this
# process runs inside one firstmate checkout (its working directory) while its
# effective home or state directory belongs to a DIFFERENT firstmate checkout.
# That is the shape a multiplexer server leaves behind when it restores an agent
# in the environment of whichever session started the server: a secondmate that
# runs in its own home but carries the main home's FM_HOME and
# FM_STATE_OVERRIDE (bin/fm-env-scrub-lib.sh owns the cause).
# Only a positive contradiction between two real checkouts refuses. A working
# directory outside every firstmate checkout, or a home or state directory that
# is not inside one (a test fixture), carries no verdict, so deliberate
# cross-home calls from scripts and isolated tests keep working.
fm_home_identity_check() {
  local home=$1 state=$2 run_root home_real home_root state_root
  FM_HOME_IDENTITY_REASON=
  run_root=$(fm_firstmate_checkout_of "$PWD")
  [ -n "$run_root" ] || return 0
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || home_real=
  if [ -n "$home_real" ] && fm_is_firstmate_checkout "$home_real" && [ "$home_real" != "$run_root" ]; then
    home_root=$(fm_firstmate_checkout_of "$home_real")
    if [ "$home_root" != "$run_root" ]; then
      FM_HOME_IDENTITY_REASON="firstmate: refusing to act for home $home_real from a process running in $run_root: this environment (FM_HOME) names another firstmate home than the one this process runs in, the shape an inherited multiplexer environment leaves after a restore. Relaunch this agent from its parent firstmate with bin/fm-control.sh <task-id> relaunch."
      return 1
    fi
  fi
  [ -d "$state" ] || return 0
  state_root=$(fm_firstmate_checkout_of "$state")
  if [ -n "$state_root" ] && [ "$state_root" != "$run_root" ]; then
    FM_HOME_IDENTITY_REASON="firstmate: refusing to act on state directory $state from a process running in $run_root: this environment (FM_STATE_OVERRIDE) names another firstmate home's state than the one this process runs in, the shape an inherited multiplexer environment leaves after a restore. Relaunch this agent from its parent firstmate with bin/fm-control.sh <task-id> relaunch."
    return 1
  fi
  return 0
}
