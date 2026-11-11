#!/usr/bin/env bash
# Launch one firstmate-spawned agent with only its own identity.
#
# Usage: fm-agent-env.sh [NAME=VALUE...] <command> [args...]
#
# bin/fm-spawn.sh types every agent launch into a pane shell whose environment
# belongs to whoever started the multiplexer server and to the pane's history,
# not to the task. This wrapper is the first word of that launch: it clears the
# agent scope owned by bin/fm-env-scrub-lib.sh (firstmate's home, session, and
# internal-handoff variables and every verified harness session marker, never
# the operator's tuning knobs), then applies the launch's own NAME=VALUE
# assignments and replaces itself with <command>, exactly as env(1) would. So a
# secondmate's FM_HOME is the one its launch names, never one inherited from
# the pane, and a Claude agent never starts as another Claude session's child.
# It covers fresh spawns and bin/fm-control.sh relaunches alike; a pane that a
# multiplexer restores without a launch is covered by the daemon scope instead.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-scrub-lib.sh
. "$SCRIPT_DIR/fm-env-scrub-lib.sh"

case "${1:-}" in
  ''|-h|--help)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [ -n "${1:-}" ] && exit 0
    exit 2
    ;;
esac
fm_env_scrub_exec agent "$@"
