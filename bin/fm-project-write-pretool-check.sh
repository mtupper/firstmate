#!/usr/bin/env bash
# Stable PreToolUse transport enforcing hard rule 1: firstmate never writes to a
# project.
#
# AGENTS.md names that rule first and calls it hard, but until this guard it was
# enforced only in prose. The existing PreToolUse guards all classify a Bash
# COMMAND; none of them looks at a file path, so a primary that reached for its
# own Write or Edit tool on a file under projects/ met no refusal at all. That is
# the one hard rule an ordinary slip can break, because editing a file is the
# most natural thing an agent does.
#
# This guard classifies ONE thing: whether a tool is about to write to a path
# under this home's projects/ directory. It makes no judgment about the content,
# the tool, or whether the change is a good idea.
#
# Scope. Fires only in a real primary firstmate checkout, using the same
# git-dir == git-common-dir test as bin/fm-cd-pretool-check.sh. A crewmate or
# scout task worktree is a linked worktree where those differ, so this guard is
# inert exactly where project writes are the whole point of the work. See
# docs/cd-guard.md for the shared scoping rationale.
#
# The matcher is deliberately `.*` rather than a list of write-tool names, for
# the same reason bin/fm-subagent-pretool-check.sh uses `.*`: a name-enumerating
# matcher fails open on every tool that ships before someone updates the list.
# A payload carrying no file path is allowed here, which is the common case and
# costs one jq call.
#
# Harness reach. The tracked Claude entry is registered UNguarded, unlike the
# other Claude entries that stand down under Grok. Those defer because Grok
# covers the same event through its own .grok/hooks/ registration; no such
# registration exists for a file write, and neither does a .cursor/hooks.json
# matcher, so guarding this one would remove it from Grok and Cursor rather than
# deduplicate it. This mirrors the exception documented in docs/subagent-guard.md
# "Known residual gap", including its limitation: the tracked entry passes
# --claude, which suppresses exactly the stdout decision object Grok and Cursor
# read, so treat their coverage as incidental reach rather than as wired. Wiring
# either properly needs its write-tool matcher token verified against the real
# harness first, which is what closes this.
#
# The documented exception stays reachable. AGENTS.md lets the captain approve a
# concrete project operation that firstmate then performs with its own file
# tools. Set FM_PROJECT_WRITE_APPROVED=1 for that operation. This is a seatbelt
# against a confused agent, not a wall against a determined one - the same threat
# model bin/fm-gate-refuse-lib.sh states - so requiring a deliberate, visible act
# is the whole point: it turns an accidental project write into a chosen one.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-project-write-pretool-check.sh
#   bin/fm-project-write-pretool-check.sh --path '<file-path>'
#
# Stdin mode reads .tool_input (Claude, Codex, Cursor) or .toolInput (Grok) and
# takes file_path, notebook_path, filePath, or path. CLI mode is for adapters
# that already hold the path.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status.
#   INERT - not the real primary checkout: exit 0 with no output, exactly like
#           ALLOW. A home whose projects/ does not exist yet is NOT inert; the
#           spelled-path test still applies, because that is precisely when a
#           write would create the directory.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or an
#               unresolvable checkout.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor consumes the stdout decision object.
set -u

PATH_ARG=""
PATH_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-project-write-pretool-check.sh [--path <file>] [--claude|--cursor]

With no --path, reads a PreToolUse-style JSON payload on stdin and takes the
written path from .tool_input / .toolInput (file_path, notebook_path, filePath,
or path).
Fires only in the real primary firstmate checkout; it is a silent no-op in a
crewmate/scout task worktree and in any non-firstmate repo.
Exits 0 to allow and 2 to deny a write under this home's projects/.
Set FM_PROJECT_WRITE_APPROVED=1 to perform a captain-approved project operation.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Malformed transport and an unresolvable checkout fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      PATH_ARG=$2
      PATH_SET=1
      shift 2
      ;;
    --path=*)
      PATH_ARG=${1#--path=}
      PATH_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# The captain's own concrete approval, exercised before anything else is read.
[ "${FM_PROJECT_WRITE_APPROVED:-0}" = "0" ] || exit 0

CANDIDATES=""
if [ "$PATH_SET" -eq 1 ]; then
  CANDIDATES=$PATH_ARG
else
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CANDIDATES=$(printf '%s' "$PAYLOAD" | jq -r '
    [ (.tool_input // .toolInput // {})
      | (.file_path?, .notebook_path?, .filePath?, .path?) ]
    | map(select(type == "string" and length > 0))
    | .[]
  ' 2>/dev/null) || exit 0
fi
[ -n "$CANDIDATES" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

# Same primary-checkout scope as bin/fm-cd-pretool-check.sh: a linked worktree,
# which is the shape bin/fm-spawn.sh hands every crewmate, has a git-dir distinct
# from its git-common-dir. Any failure to confirm the checkout is inert, never a
# block, so a broken environment never denies a file write.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
PROJECTS=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}
# A home with no clones yet is not a reason to stand down. The spelled-path test
# below works on a projects/ that does not exist, which is exactly the moment a
# write would create it. Only the resolved-path test needs a real directory.
PROJECTS_PHYS=""
if [ -d "$PROJECTS" ]; then
  PROJECTS_PHYS=$(CDPATH='' cd -- "$PROJECTS" 2>/dev/null && pwd -P) || PROJECTS_PHYS=""
fi
# The spelled test compares strings, so both sides must be spelled the same way.
# On macOS /var is a symlink to /private/var, so a relative path resolved against
# a logical cwd and a projects/ path resolved with `pwd -P` describe the same
# directory in two spellings that no string test can match. Anchor both to the
# physical parent, which exists whenever the home does even when projects/ does
# not.
PROJECTS_SPELLED=$PROJECTS
PROJECTS_PARENT=${PROJECTS%/*}
PROJECTS_NAME=${PROJECTS##*/}
if [ -n "$PROJECTS_PARENT" ] && [ -d "$PROJECTS_PARENT" ]; then
  parent_phys=$(CDPATH='' cd -- "$PROJECTS_PARENT" 2>/dev/null && pwd -P) \
    && PROJECTS_SPELLED="$parent_phys/$PROJECTS_NAME"
fi
PWD_PHYS=$(pwd -P 2>/dev/null) || PWD_PHYS=$PWD

# Physical path of the deepest existing ancestor, with the not-yet-created tail
# re-appended. This resolves `..` segments and every symlink on the existing
# prefix, so a route into projects/ through a symlinked directory is seen for
# what it is rather than taken at its spelling.
resolve_physical() {  # <absolute-path>
  local p=$1 tail="" dir
  while :; do
    if [ -d "$p" ]; then
      dir=$(CDPATH='' cd -- "$p" 2>/dev/null && pwd -P) || return 1
      printf '%s%s\n' "$dir" "$tail"
      return 0
    fi
    case "$p" in
      /|"") printf '/%s\n' "${tail#/}"; return 0 ;;
    esac
    tail="/${p##*/}$tail"
    p=${p%/*}
    [ -n "$p" ] || p=/
  done
}

DENIED_PATH=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  case "$candidate" in
    /*) absolute=$candidate ;;
    # A tool that hands over a relative path means it relative to the session's
    # cwd, which for a primary is the home itself.
    *) absolute="$PWD_PHYS/$candidate" ;;
  esac
  # Two independent tests, either sufficient. The spelled path catches a
  # projects/<name> entry that is itself a symlink out to a real working clone,
  # where resolving would hide the fact that this is a project write. The
  # resolved path catches everything that reaches projects/ by another route.
  case "$absolute" in
    "$PROJECTS"/*|"$PROJECTS_SPELLED"/*) DENIED_PATH=$candidate; break ;;
  esac
  # An empty PROJECTS_PHYS must never reach the pattern below: "" + /* matches
  # every absolute path, which would deny every write in the home.
  [ -n "$PROJECTS_PHYS" ] || continue
  physical=$(resolve_physical "$absolute") || continue
  case "$physical" in
    "$PROJECTS_PHYS"/*) DENIED_PATH=$candidate; break ;;
  esac
done <<EOF
$CANDIDATES
EOF

[ -n "$DENIED_PATH" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[project-write] firstmate does not write to a project; '$DENIED_PATH' is under this home's projects/. Hand the change to a worker through bin/fm-spawn.sh, which gives it an isolated worktree. If the captain has approved this exact operation, re-run it with FM_PROJECT_WRITE_APPROVED=1."
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
