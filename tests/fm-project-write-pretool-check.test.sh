#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the project-write PreToolUse seatbelt.
#
# bin/fm-project-write-pretool-check.sh is the runtime backing for AGENTS.md
# hard rule 1 ("never write to a project"), which was previously enforced only
# in prose. This suite proves the decision matrix (which paths deny and which
# allow), the primary-checkout scoping that keeps the guard inert inside a
# crewmate's linked task worktree, the captain-approval escape hatch that keeps
# the documented exception reachable, the harness-output shaping, and the
# fail-open transport behavior. No harness is spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-project-write-pretool-check)

install_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-project-write-pretool-check.sh" "$dir/bin/fm-project-write-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  chmod +x "$dir/bin/fm-project-write-pretool-check.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo with AGENTS.md and
# bin/. This is what the transport's scoping treats as the real primary home.
make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-project-write-pretool-check.sh"
mkdir -p "$PRIMARY/projects/demo/src"

# Run the guard the way a harness does: a PreToolUse payload on stdin.
# Sets LAST_RC / LAST_STDOUT / LAST_STDERR. Deliberately NOT called through
# command substitution: a subshell would discard the captured streams.
LAST_RC=0
LAST_STDERR=""
LAST_STDOUT=""
run_payload() {  # <payload> [extra-args...]
  local payload=$1
  shift
  local err_file="$TMP_ROOT/stderr.$$" out_file="$TMP_ROOT/stdout.$$"
  LAST_RC=0
  printf '%s' "$payload" | (cd "$PRIMARY" && "$CHECK" "$@") \
    >"$out_file" 2>"$err_file" || LAST_RC=$?
  LAST_STDOUT=$(cat "$out_file")
  LAST_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

write_payload() {  # <file_path>
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"
}

# --- decision matrix --------------------------------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_PATHS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_PATHS+=("$3")
}

# DENY: every route that lands under this home's projects/.
matrix_case D01 deny "$PRIMARY/projects/demo/src/a.ts"
matrix_case D02 deny "projects/demo/src/a.ts"
matrix_case D03 deny "./projects/demo/src/a.ts"
matrix_case D04 deny "$PRIMARY/bin/../projects/demo/src/a.ts"
matrix_case D05 deny "projects/demo/a-file-that-does-not-exist-yet.ts"
matrix_case D06 deny "$PRIMARY/projects/demo"

# ALLOW: the home's own material and anything outside it.
matrix_case A01 allow "$PRIMARY/bin/fm-thing.sh"
matrix_case A02 allow "$PRIMARY/AGENTS.md"
matrix_case A03 allow "data/backlog.md"
matrix_case A04 allow "$TMP_ROOT/elsewhere/file.txt"
# A sibling directory whose name merely starts with "projects" is not projects/.
matrix_case A05 allow "$PRIMARY/projects-archive/a.ts"

i=0
while [ "$i" -lt "${#MATRIX_IDS[@]}" ]; do
  id=${MATRIX_IDS[$i]}
  expected=${MATRIX_EXPECTED[$i]}
  candidate=${MATRIX_PATHS[$i]}
  i=$((i + 1))
  run_payload "$(write_payload "$candidate")" --claude
  rc=$LAST_RC
  if [ "$expected" = "deny" ]; then
    [ "$rc" = "2" ] || fail "matrix $id: expected deny for '$candidate', got rc=$rc"
    assert_contains "$LAST_STDERR" '"permissionDecision":"deny"' "matrix $id: deny payload"
  else
    [ "$rc" = "0" ] || fail "matrix $id: expected allow for '$candidate', got rc=$rc (stderr: $LAST_STDERR)"
    [ -z "$LAST_STDERR" ] || fail "matrix $id: allow must be silent, got: $LAST_STDERR"
  fi
  pass "matrix $id: $expected for $candidate"
done

# --- other write-tool payload shapes ---------------------------------------

run_payload '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"projects/demo/n.ipynb"}}' --claude; rc=$LAST_RC
[ "$rc" = "2" ] || fail "notebook_path under projects/ must deny, got rc=$rc"
pass "notebook_path is classified like file_path"

run_payload '{"toolName":"Write","toolInput":{"file_path":"projects/demo/a.ts"}}' --claude; rc=$LAST_RC
[ "$rc" = "2" ] || fail "Grok toolInput shape must deny, got rc=$rc"
pass "Grok toolInput shape is classified like tool_input"

run_payload '{"tool_name":"Bash","tool_input":{"command":"ls projects"}}' --claude; rc=$LAST_RC
[ "$rc" = "0" ] || fail "a payload with no file path must allow, got rc=$rc"
pass "a payload carrying no file path allows"

# --- captain-approval escape hatch -----------------------------------------
# AGENTS.md permits a concrete captain-approved project operation performed with
# firstmate's own file tools. That exception must stay reachable, and it must
# require a deliberate act rather than happening by default.

FM_PROJECT_WRITE_APPROVED=1 run_payload "$(write_payload "projects/demo/a.ts")" --claude; rc=$LAST_RC
[ "$rc" = "0" ] || fail "FM_PROJECT_WRITE_APPROVED=1 must allow, got rc=$rc"
pass "a captain-approved project operation is allowed through"

FM_PROJECT_WRITE_APPROVED=0 run_payload "$(write_payload "projects/demo/a.ts")" --claude; rc=$LAST_RC
[ "$rc" = "2" ] || fail "FM_PROJECT_WRITE_APPROVED=0 must still deny, got rc=$rc"
pass "the escape hatch is off unless explicitly set"

# --- scoping ----------------------------------------------------------------
# A crewmate's task worktree is a linked git worktree, where git-dir and
# git-common-dir differ. Project writes are that worktree's entire purpose, so
# the guard must be inert there even though the payload looks identical.

CHILD="$TMP_ROOT/child-worktree"
fm_git_worktree "$PRIMARY" "$CHILD" fm/project-write-test-branch
: > "$CHILD/AGENTS.md"
install_scripts "$CHILD"
mkdir -p "$CHILD/projects/demo"
child_rc=0
printf '%s' "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$CHILD/projects/demo/a.ts")" \
  | (cd "$CHILD" && "$CHILD/bin/fm-project-write-pretool-check.sh" --claude) >/dev/null 2>&1 || child_rc=$?
[ "$child_rc" = "0" ] || fail "guard must be inert in a linked task worktree, got rc=$child_rc"
pass "the guard is inert inside a crewmate's linked task worktree"

# A directory that is not a firstmate checkout at all has no AGENTS.md.
NONFM="$TMP_ROOT/not-firstmate"
mkdir -p "$NONFM/bin/../projects/demo"
install_scripts "$NONFM"
git init -q "$NONFM"
nonfm_rc=0
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"projects/demo/a.ts"}}' \
  | (cd "$NONFM" && "$NONFM/bin/fm-project-write-pretool-check.sh" --claude) >/dev/null 2>&1 || nonfm_rc=$?
[ "$nonfm_rc" = "0" ] || fail "guard must be inert outside a firstmate checkout, got rc=$nonfm_rc"
pass "the guard is inert outside a firstmate checkout"

# --- a home with no projects/ directory yet ---------------------------------
# The spelled-path test must still apply: a write that would CREATE projects/ is
# exactly the case an "only guard what exists" check would miss.

EMPTY=$(make_primary_fixture "$TMP_ROOT/empty-home")
empty_rc=0
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"projects/newclone/a.ts"}}' \
  | (cd "$EMPTY" && "$EMPTY/bin/fm-project-write-pretool-check.sh" --claude) >/dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" = "2" ] || fail "a write creating projects/ must deny, got rc=$empty_rc"
pass "a home with no clones yet still refuses a write into projects/"

# The same home must not deny its own ordinary files. This is the regression for
# an empty projects-path variable expanding into a match-everything pattern.
empty_allow_rc=0
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"bin/fm-thing.sh"}}' \
  | (cd "$EMPTY" && "$EMPTY/bin/fm-project-write-pretool-check.sh" --claude) >/dev/null 2>&1 || empty_allow_rc=$?
[ "$empty_allow_rc" = "0" ] || fail "a home with no projects/ must allow its own files, got rc=$empty_allow_rc"
pass "a home with no clones yet still allows writes to its own material"

# --- harness output shaping -------------------------------------------------

run_payload "$(write_payload "projects/demo/a.ts")" --claude; rc=$LAST_RC
[ "$rc" = "2" ] || fail "--claude deny must exit 2, got rc=$rc"
[ -z "$LAST_STDOUT" ] || fail "--claude requires stdout to stay empty on deny, got: $LAST_STDOUT"
assert_contains "$LAST_STDERR" '"hookEventName":"PreToolUse"' "claude deny stderr shape"
pass "--claude: exit 2, empty stdout, Claude-shaped deny on stderr"

run_payload "$(write_payload "projects/demo/a.ts")"; rc=$LAST_RC
[ "$rc" = "2" ] || fail "default-mode deny must exit 2, got rc=$rc"
assert_contains "$LAST_STDOUT" '"decision":"deny"' "grok deny stdout shape"
pass "default mode: Grok-shaped decision object on stdout"

run_payload "$(write_payload "projects/demo/a.ts")" --cursor; rc=$LAST_RC
[ "$rc" = "0" ] || fail "--cursor deny must exit 0, got rc=$rc"
assert_contains "$LAST_STDOUT" '"permission":"deny"' "cursor deny stdout shape"
pass "--cursor: exit 0 with Cursor's own decision object, which Cursor reads"

# The deny message must name the escape hatch, or a blocked agent cannot reach
# the documented exception without guessing.
assert_contains "$LAST_STDOUT" 'FM_PROJECT_WRITE_APPROVED=1' "deny message names the approval override"
pass "the deny message names the captain-approval override"

# --- fail open --------------------------------------------------------------

run_payload ""; rc=$LAST_RC
[ "$rc" = "0" ] || fail "empty stdin must fail open, got rc=$rc"
pass "fail-open: empty stdin"

run_payload "not json at all"; rc=$LAST_RC
[ "$rc" = "0" ] || fail "unparseable stdin must fail open, got rc=$rc"
pass "fail-open: unparseable JSON on stdin"

if command -v jq >/dev/null 2>&1; then
  FAKE_PATH_DIR="$TMP_ROOT/nojq"
  mkdir -p "$FAKE_PATH_DIR"
  for tool in bash sed tr git; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$resolved" "$FAKE_PATH_DIR/$tool"
  done
  nojq_rc=0
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"projects/demo/a.ts"}}' \
    | (cd "$PRIMARY" && PATH="$FAKE_PATH_DIR" "$CHECK" --claude) >/dev/null 2>&1 || nojq_rc=$?
  [ "$nojq_rc" = "0" ] || fail "missing jq must fail open, got rc=$nojq_rc"
  pass "fail-open: missing jq on the stdin path"
else
  pass "jq not installed, skipping the missing-jq fail-open case"
fi

# --- CLI transport ----------------------------------------------------------

cli_rc=0
(cd "$PRIMARY" && "$CHECK" --path "projects/demo/a.ts" --claude) >/dev/null 2>&1 || cli_rc=$?
[ "$cli_rc" = "2" ] || fail "--path deny must exit 2, got rc=$cli_rc"
pass "CLI --path transport denies a project write"

cli_allow_rc=0
(cd "$PRIMARY" && "$CHECK" --path "bin/fm-thing.sh" --claude) >/dev/null 2>&1 || cli_allow_rc=$?
[ "$cli_allow_rc" = "0" ] || fail "--path allow must exit 0, got rc=$cli_allow_rc"
pass "CLI --path transport allows a write to the home's own material"

# --- registration -----------------------------------------------------------
# A guard nothing invokes is decoration. Prove the shipped Claude registration
# actually reaches this script, through the JSON rather than by reading bytes.

if command -v jq >/dev/null 2>&1; then
  jq -e '
    any(.hooks.PreToolUse[]?.hooks[]?.command?;
        type == "string" and contains("fm-project-write-pretool-check.sh"))
  ' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "tracked .claude/settings.json does not register the project-write guard"
  pass "the tracked Claude registration invokes the project-write guard"
else
  pass "jq not installed, skipping the registration check"
fi

printf '\nall project-write guard tests passed\n'
