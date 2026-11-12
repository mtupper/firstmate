#!/usr/bin/env bash
# fm-permission-mode-lib.sh - the ONE owner of how firstmate reads the live
# permission mode of a Claude direct report.
#
# Why this exists. bin/fm-spawn.sh launches every Claude crewmate, scout, and
# secondmate with --dangerously-skip-permissions. A Herdr restore resumes each
# agent with a bare `claude --resume <session-id>`, so the restored agent runs in
# the account's default permission mode (Claude Code 2.1.311 showed
# "auto mode on"). The captain decided that bypass mode is never carried across
# a restore automatically: the session-start digest names every reduced worker,
# and only the captain's /sailsup restores them for that session
# (.agents/skills/sailsup/SKILL.md owns that procedure).
#
# The signal. The verdict comes from the live agent process's own arguments,
# read through bin/fm-backend.sh's fm_backend_agent_argv, never from task
# metadata: metadata records what was launched, not what a restore resumed.
# Claude Code fixes its permission mode at startup from these flags (verified
# on 2.1.311: a fresh launch with the flag and a resume with the flag both show
# "bypass permissions on"; a bare resume shows the account default).
#
#   bypass   --dangerously-skip-permissions, or --permission-mode
#            bypassPermissions, with no conflicting --permission-mode value.
#   reduced  anything else.
#   unknown  the arguments could not be read for a live agent. Unknown is never
#            reported as safe.
#
# Limits, stated so no caller reads more into a verdict than it carries:
#   - Only arguments before the first positional argument are parsed, so a
#     prompt that merely mentions a flag never counts. A value-taking option
#     this parser does not know ends the parse early, which can only turn a
#     bypass verdict into reduced, never the reverse.
#   - A captain who cycles a live agent's mode with shift+tab changes nothing
#     the arguments show.
#   - On tmux under macOS, ps joins arguments with spaces, so an option value
#     containing whitespace is split; Herdr and Linux read exact arguments.
#
# Sourcing: requires bin/fm-backend.sh already sourced; set -u safe.

# Value-taking Claude Code options (claude --help, 2.1.311), so the parser skips
# each one's value instead of reading it as the first positional argument.
FM_PERMISSION_CLAUDE_VALUE_OPTS=' --add-dir --agent --agents --allowedTools --allowed-tools --append-system-prompt --autocompact --betas --debug-file --disallowedTools --disallowed-tools --effort --environment --fallback-model --file --input-format --json-schema --max-budget-usd --mcp-config --model -n --name --output-format --permission-mode --permission-prompts --plugin-dir --plugin-url --remote-control-session-name-prefix -r --resume --session-id --setting-sources --settings --system-prompt --system-prompt-snapshot --tools '

# fm_permission_claude_argv_parse <argv...>: argv[0] first. Sets
# FM_PERMISSION_MODE (bypass|reduced) and FM_PERMISSION_SESSION (the resumed
# session id, or empty).
fm_permission_claude_argv_parse() {
  local arg opt val skip=1 dangerous=0 mode_value=
  FM_PERMISSION_MODE=reduced
  FM_PERMISSION_SESSION=
  for arg in "$@"; do
    if [ "$skip" = 1 ]; then
      skip=0
      continue
    fi
    if [ -n "${opt:-}" ]; then
      val=$arg
      case "$opt" in
        --permission-mode) mode_value=$val ;;
        -r|--resume) FM_PERMISSION_SESSION=$val ;;
      esac
      opt=
      continue
    fi
    case "$arg" in
      --) break ;;
      --dangerously-skip-permissions) dangerous=1 ;;
      --permission-mode=*) mode_value=${arg#*=} ;;
      --resume=*) FM_PERMISSION_SESSION=${arg#*=} ;;
      -*)
        case "$FM_PERMISSION_CLAUDE_VALUE_OPTS" in
          *" $arg "*) opt=$arg ;;
        esac
        ;;
      *) break ;;
    esac
  done
  if [ -n "$mode_value" ]; then
    [ "$mode_value" = bypassPermissions ] && FM_PERMISSION_MODE=bypass
  elif [ "$dangerous" = 1 ]; then
    FM_PERMISSION_MODE=bypass
  fi
  # A resume reference that is not a session id (a search term, or the value
  # parser consumed something else) names no conversation firstmate can resume.
  case "$FM_PERMISSION_SESSION" in
    ????????-????-????-????-????????????)
      case "$FM_PERMISSION_SESSION" in
        *[!0-9A-Fa-f-]*) FM_PERMISSION_SESSION= ;;
      esac
      ;;
    *) FM_PERMISSION_SESSION= ;;
  esac
  return 0
}

# fm_permission_mode_task <meta> <id>: one verdict line for a direct report:
#   bypass session=<id|none>
#   reduced session=<id|none>
#   unknown reason=<token>
#   n/a reason=<token>      (not a Claude agent, or no agent is running)
# Read-only: it reads the endpoint and process table and changes nothing.
fm_permission_mode_task() {  # <meta> <id>
  local meta=$1 id=$2 harness backend target state argv line
  local -a args
  harness=$(fm_meta_get "$meta" harness)
  case "$harness" in
    claude) ;;
    *) printf 'n/a reason=harness-%s\n' "${harness:-none}"; return 0 ;;
  esac
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    printf 'unknown reason=remote-host\n'
    return 0
  fi
  # A record with no endpoint at all names no agent firstmate could be running;
  # a present but malformed or ambiguous one is a detection failure.
  if ! grep -q '^window=' "$meta" 2>/dev/null; then
    printf 'n/a reason=no-endpoint\n'
    return 0
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    printf 'unknown reason=endpoint-invalid\n'
    return 0
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in
    tmux|herdr) ;;
    *) printf 'unknown reason=backend-%s\n' "$backend"; return 0 ;;
  esac
  # Only a positively agent-free endpoint skips the read. Herdr can report a
  # live Claude pane's agent status as unknown until its integration hook first
  # reports (seen on Herdr 0.8.2), so an inconclusive state still tries the
  # process arguments, which are the actual evidence here.
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
  case "$state" in
    dead|missing) printf 'n/a reason=no-agent\n'; return 0 ;;
  esac
  argv=$(fm_backend_agent_argv "$backend" "$target" claude 2>/dev/null) || {
    case "$state" in
      alive) printf 'unknown reason=argv-unreadable\n' ;;
      *) printf 'unknown reason=agent-%s\n' "${state:-unreadable}" ;;
    esac
    return 0
  }
  args=()
  while IFS= read -r line; do
    args+=("$line")
  done <<EOF
$argv
EOF
  [ "${#args[@]}" -gt 0 ] && [ -n "${args[0]}" ] || {
    printf 'unknown reason=argv-unreadable\n'
    return 0
  }
  fm_permission_claude_argv_parse "${args[@]}"
  printf '%s session=%s\n' "$FM_PERMISSION_MODE" "${FM_PERMISSION_SESSION:-none}"
}

# fm_permission_verdict_field <verdict-line> <key>: one key=value field.
fm_permission_verdict_field() {  # <line> <key>
  local line=$1 key=$2 word
  for word in $line; do
    case "$word" in
      "$key"=*) printf '%s' "${word#*=}"; return 0 ;;
    esac
  done
  return 1
}
