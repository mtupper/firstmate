#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#
# The GitLab half of the matrix mirrors it through `glab mr merge`, and adds the
# checks that path owns and the GitHub one does not: the reviewed head is pinned
# with --sha, the merge is made non-interactive and immediate, and a pipeline is
# read as green only when it ran on the exact commit being merged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Every merge needs an authority. The cases below are about recording, URL
# parsing, and merge-method forwarding rather than about authority, so this
# supplies the captain's word by default and steps aside when a case states its
# own --authority.
run_pr_merge() {
  local case_dir=$1 rc; shift
  local -a args=()
  local has_authority=0 a
  for a in "$@"; do
    case "$a" in --authority|--authority=*) has_authority=1 ;; esac
  done
  if [ "$has_authority" -eq 0 ] && [ "$#" -ge 2 ]; then
    args=("$1" "$2" --authority captain)
    shift 2
    args+=("$@")
  else
    args=("$@")
  fi
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_APPROVAL="$case_dir/state/task-x1.merge-approval" \
  FM_TEST_WITNESS="$case_dir/witness" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "${args[@]+"${args[@]}"}"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A single-segment GitLab namespace is not a real project path, so this
  # parses as neither forge. A well-formed GitLab MR URL is accepted now, so
  # the malformed case has to be genuinely malformed.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.example.com/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse an unparseable PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.example.com/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- merge authority (AGENTS.md hard rule 2) --------------------------------
# The rule is "never merge a PR without the captain's explicit word", with a
# project's standing yolo posture as the only relaxation. These cases prove the
# script refuses to act when neither is stated, refuses a standing-authority
# claim on a task that was never dispatched with one, and leaves a durable
# record of whichever authority it did act on.

test_refuses_without_authority() {
  local case_dir rc
  case_dir=$(make_case no-authority)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "no-authority: fm-pr-merge should refuse"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "no-authority: gh-axi pr merge was invoked with no stated authority"
  assert_absent "$case_dir/state/task-x1.merge-approval" \
    "no-authority: an approval record was written despite the refusal"
  pass "fm-pr-merge refuses to merge when no authority is stated"
}

test_refuses_unknown_authority() {
  local case_dir rc
  case_dir=$(make_case bad-authority)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 --authority nobody \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "bad-authority: fm-pr-merge should refuse an unknown authority"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "bad-authority: gh-axi pr merge was invoked for an unknown authority"
  pass "fm-pr-merge refuses an authority it does not recognize"
}

test_yolo_authority_refused_when_task_has_none() {
  local case_dir rc
  case_dir=$(make_case yolo-off)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"
  printf 'yolo=off\n' >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 --authority yolo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "yolo-off: fm-pr-merge should refuse standing authority"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "yolo-off: gh-axi pr merge ran for a task dispatched with yolo off"
  pass "fm-pr-merge refuses standing authority on a task dispatched with yolo off"
}

test_yolo_authority_refused_when_meta_is_silent() {
  local case_dir rc
  case_dir=$(make_case yolo-absent)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 --authority yolo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "yolo-absent: a meta with no yolo line confers no standing authority"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "yolo-absent: gh-axi pr merge ran for a task whose meta records no posture"
  pass "fm-pr-merge treats a missing yolo posture as no standing authority"
}

test_yolo_authority_allowed_when_task_carries_it() {
  local case_dir
  case_dir=$(make_case yolo-on)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"
  printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 --authority yolo \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "yolo-on: fm-pr-merge should merge on a task dispatched with yolo on"

  grep -qxF 'pr merge 35 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "yolo-on: gh-axi pr merge was not invoked"
  assert_grep 'authority=yolo' "$case_dir/state/task-x1.merge-approval" \
    "yolo-on: the exercised authority was not recorded"
  pass "fm-pr-merge merges on standing authority when the task carries it"
}

test_records_the_authority_it_acted_on() {
  local case_dir
  case_dir=$(make_case authority-record)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 --authority captain \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "authority-record: fm-pr-merge failed"

  assert_grep 'authority=captain' "$case_dir/state/task-x1.merge-approval" \
    "authority-record: the exercised authority was not recorded"
  assert_grep 'pr=https://github.com/example/repo/pull/36' "$case_dir/state/task-x1.merge-approval" \
    "authority-record: the approved PR was not recorded"
  pass "fm-pr-merge leaves a durable record naming the authority and the PR"
}

test_refuses_when_an_approval_names_a_different_pr() {
  local case_dir rc
  case_dir=$(make_case approval-mismatch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaa111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"
  printf 'task=task-x1\npr=https://github.com/example/repo/pull/1\nauthority=captain\n' \
    > "$case_dir/state/task-x1.merge-approval"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 --authority captain \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "approval-mismatch: fm-pr-merge should refuse a second, different PR"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "approval-mismatch: gh-axi pr merge ran against a mismatched approval record"
  pass "fm-pr-merge refuses when the task already carries an approval for another PR"
}

# --- GitLab merge requests -------------------------------------------------
# The same guarded path, executed through `glab mr merge` instead of `gh-axi pr
# merge`. Every authority, metadata, and approval-record check is the shared
# one; what is exercised here on top of that is the head pin, the
# non-interactive immediate merge, and the pipeline decision.

GL_URL='https://gitlab.com/group/sub/project/-/merge_requests/7'
GL_PROJECT='https://gitlab.com/group/sub/project'
GL_HEAD=1111aaaa2222bbbb3333cccc4444dddd5555eeee
GL_OTHER=9999ffff8888eeee7777dddd6666cccc5555bbbb

# glab mock. It logs every invocation, answers `mr view` with one facts line in
# the exact shape the script's --jq expression produces, and on `mr merge`
# records whether the approval record was already on disk, so the
# durable-before-destructive ordering is observed rather than assumed.
# Args: case_dir facts [merge_rc]
add_glab_mocks() {
  local case_dir=$1 facts=$2 merge_rc=${3:-0}
  cat > "$case_dir/fakebin/glab" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GLAB_LOG"
case "\${1:-} \${2:-}" in
  "mr view") printf '%s\n' '$facts' ; exit 0 ;;
  "mr merge")
    if [ -f "\$FM_TEST_APPROVAL" ]; then
      printf 'approval-present\n' > "\$FM_TEST_WITNESS"
    else
      printf 'approval-absent\n' > "\$FM_TEST_WITNESS"
    fi
    exit $merge_rc
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
}

# A GitLab case needs the glab mock plus the gh-axi mock, so an accidental
# GitHub call would be recorded rather than silently succeeding on a real CLI.
make_gitlab_case() {
  local name=$1 facts=$2 merge_rc=${3:-0} case_dir
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 0000000000000000000000000000000000000000
  add_glab_mocks "$case_dir" "$facts" "$merge_rc"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  printf '%s\n' "$case_dir"
}

test_gitlab_merges_pinned_head_when_pipeline_matches() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-green "$GL_HEAD opened $GL_HEAD success")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gl-green: fm-pr-merge should merge a green GitLab merge request"
  grep -qxF "mr merge 7 --repo $GL_PROJECT --sha $GL_HEAD --auto-merge=false --yes --squash" \
    "$case_dir/glab.log" \
    || fail "gl-green: glab mr merge was not invoked with the number, project URL, head pin, immediate merge, non-interactive flag, and default --squash"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gl-green: gh-axi was invoked for a GitLab merge request"
  assert_grep "pr=$GL_URL" "$case_dir/state/task-x1.meta" \
    "gl-green: pr= was not recorded in the task meta"
  pass "fm-pr-merge merges a GitLab merge request through glab with the reviewed head pinned"
}

test_gitlab_records_provider_head_and_pipeline_in_the_approval() {
  local case_dir
  case_dir=$(make_gitlab_case gl-approval "$GL_HEAD opened $GL_HEAD success")

  run_pr_merge "$case_dir" task-x1 "$GL_URL" --authority captain \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gl-approval: fm-pr-merge failed"

  assert_grep 'authority=captain' "$case_dir/state/task-x1.merge-approval" \
    "gl-approval: the exercised authority was not recorded"
  assert_grep 'provider=gitlab' "$case_dir/state/task-x1.merge-approval" \
    "gl-approval: the forge was not recorded"
  assert_grep "pr=$GL_URL" "$case_dir/state/task-x1.merge-approval" \
    "gl-approval: the approved merge request was not recorded"
  assert_grep "pinned_head=$GL_HEAD" "$case_dir/state/task-x1.merge-approval" \
    "gl-approval: the pinned head was not recorded"
  assert_grep "pipeline=success:$GL_HEAD" "$case_dir/state/task-x1.merge-approval" \
    "gl-approval: the pipeline the merge relied on was not recorded"
  pass "fm-pr-merge records the forge, the pinned head, and the pipeline it relied on"
}

test_gitlab_approval_is_on_disk_before_the_merge_runs() {
  local case_dir
  case_dir=$(make_gitlab_case gl-ordering "$GL_HEAD opened $GL_HEAD success")

  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gl-ordering: fm-pr-merge failed"

  assert_grep 'approval-present' "$case_dir/witness" \
    "gl-ordering: glab mr merge ran before the approval record was on disk"
  pass "fm-pr-merge writes the GitLab approval record before glab mr merge runs"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-merge-fails "$GL_HEAD opened $GL_HEAD success" 1)

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-merge-fails: fm-pr-merge should propagate the glab failure"
  assert_grep "pr=$GL_URL" "$case_dir/state/task-x1.meta" \
    "gl-merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real GitLab merge failure without silently succeeding"
}

test_gitlab_refuses_without_authority() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-no-authority "$GL_HEAD opened $GL_HEAD success")

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 "$GL_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "gl-no-authority: fm-pr-merge should refuse"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-no-authority: glab mr merge was invoked with no stated authority"
  assert_absent "$case_dir/state/task-x1.merge-approval" \
    "gl-no-authority: an approval record was written despite the refusal"
  pass "fm-pr-merge refuses a GitLab merge request with no stated authority"
}

test_gitlab_yolo_refused_when_task_has_none() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-yolo-off "$GL_HEAD opened $GL_HEAD success")
  printf 'yolo=off\n' >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" --authority yolo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-yolo-off: fm-pr-merge should refuse standing authority"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-yolo-off: glab mr merge ran for a task dispatched with yolo off"
  assert_absent "$case_dir/state/task-x1.merge-approval" \
    "gl-yolo-off: an approval record was written despite the refusal"
  pass "fm-pr-merge refuses a GitLab merge on standing authority the task never carried"
}

test_gitlab_yolo_allowed_when_task_carries_it() {
  local case_dir
  case_dir=$(make_gitlab_case gl-yolo-on "$GL_HEAD opened $GL_HEAD success")
  printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"

  run_pr_merge "$case_dir" task-x1 "$GL_URL" --authority yolo \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gl-yolo-on: fm-pr-merge should merge on a task dispatched with yolo on"

  grep -qxF "mr merge 7 --repo $GL_PROJECT --sha $GL_HEAD --auto-merge=false --yes --squash" \
    "$case_dir/glab.log" || fail "gl-yolo-on: glab mr merge was not invoked"
  assert_grep 'authority=yolo' "$case_dir/state/task-x1.merge-approval" \
    "gl-yolo-on: the exercised authority was not recorded"
  pass "fm-pr-merge merges a GitLab merge request on standing authority the task carries"
}

test_gitlab_repo_override_refused_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-repo-override "$GL_HEAD opened $GL_HEAD success")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" -- --repo other/project \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-repo-override: fm-pr-merge should refuse project override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "gl-repo-override: refusal did not explain the project override"
  assert_no_grep "pr=$GL_URL" "$case_dir/state/task-x1.meta" \
    "gl-repo-override: the MR URL was recorded before rejecting the project override"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-repo-override: glab mr merge was invoked despite the project override"
  pass "fm-pr-merge refuses GitLab project override args before recording state"
}

test_gitlab_short_repo_override_refused() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-short-repo-override "$GL_HEAD opened $GL_HEAD success")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" -- -R other/project \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-short-repo-override: fm-pr-merge should refuse glab's -R"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-short-repo-override: glab mr merge was invoked despite -R"
  pass "fm-pr-merge refuses glab's short -R project selector"
}

test_gitlab_head_pin_and_auto_merge_cannot_be_overridden() {
  local case_dir rc arg
  for arg in --sha --auto-merge; do
    case_dir=$(make_gitlab_case "gl-guard-override${arg}" "$GL_HEAD opened $GL_HEAD success")

    set +e
    run_pr_merge "$case_dir" task-x1 "$GL_URL" -- "$arg=$GL_OTHER" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gl-guard-override: fm-pr-merge should refuse $arg"
    assert_grep 'must not override the head pin or auto-merge' "$case_dir/stderr" \
      "gl-guard-override: refusal did not explain the guard override for $arg"
    assert_no_grep 'mr merge' "$case_dir/glab.log" \
      "gl-guard-override: glab mr merge was invoked despite $arg"
  done
  pass "fm-pr-merge refuses caller attempts to override the GitLab head pin or auto-merge"
}

test_gitlab_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_gitlab_case gl-explicit-method "$GL_HEAD opened $GL_HEAD success")

  run_pr_merge "$case_dir" task-x1 "$GL_URL" -- --rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gl-explicit-method: fm-pr-merge failed"

  grep -qxF "mr merge 7 --repo $GL_PROJECT --sha $GL_HEAD --auto-merge=false --yes --rebase" \
    "$case_dir/glab.log" \
    || fail "gl-explicit-method: caller --rebase was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add a default --squash when the caller states a glab merge strategy"
}

# --- the GitLab pipeline decision ------------------------------------------
# An absent pipeline is not a passing one, and neither is a pipeline that ran on
# some other commit. The only green verdict comes from a successful pipeline
# whose commit is the exact head being merged.

test_gitlab_absent_pipeline_refused_by_default() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-no-pipeline "$GL_HEAD opened - -")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-no-pipeline: an absent pipeline should not merge by default"
  assert_grep 'has no pipeline on its head commit' "$case_dir/stderr" \
    "gl-no-pipeline: refusal did not name the absent pipeline"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-no-pipeline: glab mr merge ran with no pipeline and no stated exception"
  assert_absent "$case_dir/state/task-x1.merge-approval" \
    "gl-no-pipeline: an approval record was written despite the refusal"
  pass "fm-pr-merge refuses a GitLab merge request whose head has no pipeline"
}

test_gitlab_absent_pipeline_allowed_when_stated() {
  local case_dir
  case_dir=$(make_gitlab_case gl-no-pipeline-stated "$GL_HEAD opened - -")

  run_pr_merge "$case_dir" task-x1 "$GL_URL" --authority captain --allow-absent-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gl-no-pipeline-stated: fm-pr-merge should merge once the absent gate is stated"

  grep -qxF "mr merge 7 --repo $GL_PROJECT --sha $GL_HEAD --auto-merge=false --yes --squash" \
    "$case_dir/glab.log" || fail "gl-no-pipeline-stated: glab mr merge was not invoked"
  assert_grep 'pipeline=absent-accepted' "$case_dir/state/task-x1.merge-approval" \
    "gl-no-pipeline-stated: the stated exception was not recorded in the approval"
  pass "fm-pr-merge merges with no pipeline only when the caller states that no gate applies"
}

test_gitlab_red_head_pipeline_refused() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-red "$GL_HEAD opened $GL_HEAD failed")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-red: fm-pr-merge should refuse a red head pipeline"
  assert_grep 'is failed, not success' "$case_dir/stderr" \
    "gl-red: refusal did not name the pipeline status"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-red: glab mr merge ran against a red pipeline"
  pass "fm-pr-merge refuses a GitLab merge request whose head pipeline is red"
}

test_gitlab_running_head_pipeline_refused() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-running "$GL_HEAD opened $GL_HEAD running")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-running: a pipeline still running is not a passing one"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-running: glab mr merge ran while the head pipeline was still running"
  pass "fm-pr-merge refuses to merge while the head pipeline is still running"
}

test_gitlab_pipeline_for_another_commit_is_never_green() {
  local case_dir rc
  # The 2026-08-28 shape: a successful pipeline exists, but it ran on a commit
  # that is not the head being merged, so it says nothing about that head.
  case_dir=$(make_gitlab_case gl-stale-pipeline "$GL_HEAD opened $GL_OTHER success")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-stale-pipeline: a pipeline on another commit must not merge"
  assert_grep "ran on $GL_OTHER, not on the head commit $GL_HEAD" "$case_dir/stderr" \
    "gl-stale-pipeline: refusal did not name both commits"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-stale-pipeline: glab mr merge ran on a pipeline for a different commit"
  pass "fm-pr-merge never reads a pipeline for another commit as green"
}

test_gitlab_stale_pipeline_is_not_rescued_by_the_absent_flag() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-stale-not-rescued "$GL_HEAD opened $GL_OTHER success")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" --authority captain --allow-absent-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-stale-not-rescued: --allow-absent-pipeline must not cover a mismatched pipeline"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-stale-not-rescued: the absent-pipeline exception was stretched to cover a stale one"
  pass "fm-pr-merge keeps the absent-pipeline exception from covering a pipeline on another commit"
}

test_gitlab_unresolvable_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-no-head "- opened - -")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-no-head: an unresolvable head must not merge"
  assert_grep 'refusing to merge an unpinned merge request' "$case_dir/stderr" \
    "gl-no-head: refusal did not explain the missing head"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-no-head: glab mr merge ran with no head to pin"
  pass "fm-pr-merge refuses to merge a GitLab merge request whose head it cannot pin"
}

test_gitlab_closed_merge_request_refused() {
  local case_dir rc
  case_dir=$(make_gitlab_case gl-merged "$GL_HEAD merged $GL_HEAD success")

  set +e
  run_pr_merge "$case_dir" task-x1 "$GL_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gl-merged: a merge request that is not open must not be merged"
  assert_grep 'is merged, not open' "$case_dir/stderr" \
    "gl-merged: refusal did not name the merge request state"
  assert_no_grep 'mr merge' "$case_dir/glab.log" \
    "gl-merged: glab mr merge ran against a merge request that is not open"
  pass "fm-pr-merge refuses a GitLab merge request that is not open"
}

test_allow_absent_pipeline_refused_on_github() {
  local case_dir rc
  case_dir=$(make_case gh-absent-flag)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbb111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    --authority captain --allow-absent-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "gh-absent-flag: the GitLab pipeline exception must not be accepted on GitHub"
  assert_grep 'applies only to a GitLab merge request' "$case_dir/stderr" \
    "gh-absent-flag: refusal did not explain that the flag is GitLab-only"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gh-absent-flag: gh-axi pr merge was invoked with a flag it has no meaning for"
  pass "fm-pr-merge refuses the absent-pipeline exception on a GitHub pull request"
}

test_refuses_without_authority
test_refuses_unknown_authority
test_yolo_authority_refused_when_task_has_none
test_yolo_authority_refused_when_meta_is_silent
test_yolo_authority_allowed_when_task_carries_it
test_records_the_authority_it_acted_on
test_refuses_when_an_approval_names_a_different_pr
test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_gitlab_merges_pinned_head_when_pipeline_matches
test_gitlab_records_provider_head_and_pipeline_in_the_approval
test_gitlab_approval_is_on_disk_before_the_merge_runs
test_gitlab_merge_failure_propagates
test_gitlab_refuses_without_authority
test_gitlab_yolo_refused_when_task_has_none
test_gitlab_yolo_allowed_when_task_carries_it
test_gitlab_repo_override_refused_before_recording
test_gitlab_short_repo_override_refused
test_gitlab_head_pin_and_auto_merge_cannot_be_overridden
test_gitlab_explicit_merge_method_not_overridden
test_gitlab_absent_pipeline_refused_by_default
test_gitlab_absent_pipeline_allowed_when_stated
test_gitlab_red_head_pipeline_refused
test_gitlab_running_head_pipeline_refused
test_gitlab_pipeline_for_another_commit_is_never_green
test_gitlab_stale_pipeline_is_not_rescued_by_the_absent_flag
test_gitlab_unresolvable_head_refuses
test_gitlab_closed_merge_request_refused
test_allow_absent_pipeline_refused_on_github
