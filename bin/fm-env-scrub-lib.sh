#!/usr/bin/env bash
# Session-identity environment scrubbing at every boundary where one agent
# session's environment could otherwise become another agent's.
# This file is sourced and has no side effects on source.
#
# Why it exists: a terminal multiplexer server (tmux, herdr, zellij) keeps the
# environment of whatever process started it and gives that environment to
# every pane it later creates or restores. Firstmate starts those servers on
# demand from inside a live agent session - any Herdr endpoint read starts a
# stopped server - so the starting session's identity became every pane's
# identity: its FM_HOME and FM_STATE_OVERRIDE, Claude's CLAUDE_PROJECT_DIR
# (which Claude Code honors for hook commands) and CLAUDE_CODE_CHILD_SESSION
# (which turns transcript saving off), and its own multiplexer pane. A fresh
# spawn masked part of that with its launch prefix, but a pane restored after a
# reboot replays only the agent's resume command, so restored agents acted for
# the home that happened to start the server. docs/verification/runtime-backends.md
# "Restore identity and agent resume" holds the reproduction.
#
# Two scopes, one owner:
#   agent   The firstmate identity, routing, and internal-handoff names below
#           plus the verified per-session markers each supported harness hands
#           its children. Cleared by bin/fm-agent-env.sh at every agent launch,
#           before the launch's own explicit assignments apply, so an agent
#           never inherits another home's routing or another agent's session
#           identity from its pane shell.
#   daemon  The agent scope plus per-task pane exports (GOTMPDIR, TRACEPARENT)
#           and the launching process's own multiplexer pane identity. Cleared,
#           with the working directory moved to $HOME, whenever firstmate starts
#           a multiplexer server (fm_env_scrub_daemon_exec).
#
# Operator configuration is deliberately kept: CLAUDE_CONFIG_DIR, credentials,
# model and provider settings, PATH, and firstmate's own tuning knobs such as
# FM_FLEET_PRUNE or FM_POLL (docs/configuration.md "Environment variables").
# Operators set those in their login or launch environment - the main firstmate
# on 2026-11-11 ran with FM_FLEET_PRUNE=0 - and a pane shell does not always
# re-read that environment, so clearing a knob would silently override it.
# Add a name here only when its value names WHICH home, state directory, agent
# session, or terminal pane a process belongs to, hands one firstmate script's
# internal decision to its child, or approves one specific action.

# fm_env_scrub_matches <agent|daemon> <name>: true when <scope> clears <name>.
fm_env_scrub_matches() {
  local scope=$1 name=$2
  case "$name" in
    # Which home, state, and code a process acts for.
    FM_HOME|FM_ROOT_OVERRIDE|FM_STATE_OVERRIDE|FM_DATA_OVERRIDE|FM_PROJECTS_OVERRIDE|\
    FM_CONFIG_OVERRIDE|FM_PROC_ROOT_OVERRIDE) return 0 ;;
    # One session's or agent's own identity.
    FM_SESSION_START_STAGE_FILE|FM_PUBLIC_FOLLOWUP_PRIMARY_HOME|FM_SUPERVISION_MODEL|\
    FM_PI_HARNESS|FM_SUPERVISOR_TARGET|FM_SUPERVISOR_BACKEND|FM_CONTROL_RELAUNCH_TX) return 0 ;;
    # Internal one-hop handoffs between firstmate scripts.
    FM_BOOTSTRAP_DETECT_ONLY|FM_BOOTSTRAP_NETWORK|FM_TASKS_AXI_COMPATIBLE|FM_GUARD_READ_ONLY|\
    FM_GUARD_CONTINUE_LINE|FM_SPAWN_NO_GUARD|FM_SKIP_SECONDMATE_INHERIT|FM_CONFIG_INHERIT_LIVE) return 0 ;;
    # Approvals and guard bypasses scoped to one deliberate action or session.
    FM_PROJECT_WRITE_APPROVED|FM_ALLOW_SUBAGENT|FM_GATE_REFUSE_BYPASS) return 0 ;;
    # Claude Code 2.1.311 exports these to every child process (observed in a
    # live crewmate and in the Herdr server it started, 2026-11-11).
    CLAUDECODE|CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_EXECPATH|\
    CLAUDE_CODE_MESSAGING_SOCKET|CLAUDE_CODE_MESSAGING_TOKEN|CLAUDE_CODE_SESSION_ATTENDED|\
    CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_SSE_PORT|CLAUDE_EFFORT|CLAUDE_ENV_FILE|CLAUDE_PID|\
    CLAUDE_PROJECT_DIR) return 0 ;;
    # Verified harness markers (bin/fm-harness.sh and bin/fm-hook-host-lib.sh
    # own the evidence for each).
    PI_CODING_AGENT|GROK_AGENT|GROK_HOOK_EVENT|GROK_HOOK_NAME|GROK_SESSION_ID|\
    GROK_WORKSPACE_ROOT|CURSOR_AGENT|CURSOR_INVOKED_AS|CURSOR_PROJECT_DIR|CURSOR_VERSION|\
    MUSE_CURRENT_SESSION_LOG) return 0 ;;
  esac
  [ "$scope" = daemon ] || return 1
  case "$name" in
    GOTMPDIR|TRACEPARENT) return 0 ;;
    # The launching process's own pane in another multiplexer. A pane inherits
    # these from a server started inside that multiplexer, and backend
    # auto-detection (bin/fm-backend.sh fm_backend_detect) and the Herdr agent
    # integration both read them.
    TMUX|TMUX_PANE|ZELLIJ|ZELLIJ_SESSION_NAME|ZELLIJ_PANE_ID|\
    HERDR_ENV|HERDR_PANE_ID|HERDR_TAB_ID|HERDR_WORKSPACE_ID|HERDR_SOCKET_PATH|\
    HERDR_SESSION|HERDR_BIN_PATH|CMUX_WORKSPACE_ID|CMUX_SURFACE_ID|CMUX_TAB_ID|\
    CMUX_PANEL_ID|CMUX_SOCKET_PATH|__CFBundleIdentifier) return 0 ;;
  esac
  return 1
}

# fm_env_scrub_names <agent|daemon>: print, one per line, every exported name
# in this process's environment that <scope> clears.
fm_env_scrub_names() {
  local scope=$1 name
  case "$scope" in
    agent|daemon) ;;
    *) echo "fm_env_scrub_names: unknown scope '$scope'" >&2; return 2 ;;
  esac
  # Exported names are shell identifiers, so plain word splitting is exact, and
  # a command substitution completes before the loop reads it.
  for name in $(compgen -e); do
    if fm_env_scrub_matches "$scope" "$name"; then
      printf '%s\n' "$name"
    fi
  done
}

# fm_env_scrub_exec <agent|daemon> <env-operand...>: replace this process with
# `env -u <each cleared name> <env-operand...>`. The operands follow env(1)
# syntax, so leading NAME=VALUE assignments are applied after the scrub.
fm_env_scrub_exec() {
  local scope=$1 name
  local unset_args=()
  case "$scope" in
    agent|daemon) ;;
    *) echo "fm_env_scrub_exec: unknown scope '$scope'" >&2; return 2 ;;
  esac
  shift
  for name in $(fm_env_scrub_names "$scope"); do
    unset_args+=(-u "$name")
  done
  exec env ${unset_args[@]+"${unset_args[@]}"} "$@"
}

# fm_env_scrub_daemon_exec <command...>: start a long-lived multiplexer server
# from $HOME with the daemon scope cleared. Call it in a subshell or background
# job; it replaces the calling process.
fm_env_scrub_daemon_exec() {
  cd "${HOME:-/}" 2>/dev/null || cd / || return 1
  fm_env_scrub_exec daemon "$@"
}
