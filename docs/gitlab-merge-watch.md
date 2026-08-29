# GitLab merge request verification

Empirical record for GitLab merge requests, alongside the existing GitHub pull request paths.
Every command is reproduced with its exact output.
The watch sections were run on 2026-07-21 against glab 1.53.0; the "Merging a merge request" section was run on 2026-08-28 against glab 1.113.0 and carries its own version block.

## Versions

Versions for the watch sections below.

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

## The evidence project

All live evidence here reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.

A non-default host appears below only as the placeholder `gitlab.example`, which resolves nowhere.
That is deliberate: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, so it is demonstrated by inspecting those rather than by reaching any private instance.

## Why the host is data rather than a constant

GitLab runs mostly on self-hosted instances, so a merge request can live under any host.
A GitLab project also sits under at least one group at no fixed depth, so no owner-and-repository pair can address one the way it can on GitHub.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
`tests/fm-pr-check-security.test.sh` asserts that neither `bin/fm-pr-lib.sh` nor `bin/fm-pr-poll.sh` contains the string `gitlab.com` at all.

## How plain glab is invoked, and why

Two things about plain `glab` were established by running it, because assuming either one would have failed silently into a permanent "not merged".

First, plain `glab` has no field selector.
`gh` reads one field with `--json state -q .state`; `glab mr view` offers only `-F, --output string  Format output as: text, json`.
Its JSON would need a JSON processor, and `jq` is not one of firstmate's common tools, so the state is read from glab's own field output instead.
Only an exact `merged` wakes firstmate, so a changed output format produces no wake rather than a false merge.

Second, `glab` cannot take a merge request URL the way `gh pr view` can.
That form shells out to git for the current repository, and the watcher runs in no repository:

```
$ cd /tmp && glab mr view https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
fatal: not a git repository (or any parent up to mount point /)
Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
git: exit status 128
```

Passing the project URL to `-R` with the merge request number works from anywhere, and resolves the instance from that URL rather than from glab's configured default:

```
$ cd /tmp && glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture
title:	Add the merged example file
state:	merged
author:	KarotKris
labels:	
assignees:	
reviewers:	
comments:	0
number:	1
url:	https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
--
This merge request is the merged half of the fixture. It is merged on purpose, so that reading its state returns merged.

$ cd /tmp && glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture | sed -n 's/^state:[[:space:]]*//p'
open
```

## End to end: arming and polling a real merge request

Three tasks were armed, two against the fixture and one against the placeholder host:

```
$ fm-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://gitlab.example/group/subgroup/project/-/merge_requests/7
armed: state/e3.check.sh
```

The stored record for each, showing the host and the full project namespace as data:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
gitlab.com
KarotKris/gitlab-merge-watch-fixture
1

$ cat state/e3.pr-poll
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
```

The provenance record for the non-default host, showing the bumped version tag:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
514b7e04f0cca3e2c913c9fd504c54dfe54c8a51a7f5ebc57279bbd4db5d4a60
1817b0f95db7148246434a4afa0b2c8e7b81fd8f74ef7d473bbd62023e47c439
70:957243
70:957244
```

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

The merged fixture merge request produces exactly one `merged` line.
The open one produces nothing, and the unreachable placeholder host produces nothing rather than a false merge.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ state/e1x.check.sh
merged
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `glab` would otherwise be indistinguishable from a merge request that is never merged.
With `glab` removed from `PATH`, the poll stays silent even for the merge request that is genuinely merged:

```
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$noglab" fm-pr-check.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
error: watching a GitLab merge request requires glab on PATH
$ echo $?
1
```

A GitHub task is unaffected by a missing `glab`:

```
$ PATH="$noglab" fm-pr-check.sh e6 https://github.com/kunchenguid/firstmate/pull/750
armed: state/e6.check.sh
```

## Upgrade path from an existing armed watch

The stored record gained the provider tag, so its version moved to `fm-pr-poll-registration-v2` and a record written by the previous release no longer parses.
The existing non-executing migration handles that: it never runs the old artifact, and rebuilds the poll from the task's recorded pull request URL.
Starting from a poll armed exactly as the previous release wrote it:

```
$ head -1 state/t1.pr-poll-registration
fm-pr-poll-registration-v1
$ fm-pr-check-migrate.sh --checks-safe
PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home
$ head -2 state/t1.pr-poll-registration
fm-pr-poll-registration-v2
t1
$ cat state/.pr-check-migration.log
task t1: migration outcome tracking started before legacy poll handling
task t1: canonical legacy poll rebuilt and armed
```

The rebuilt poll works, verified against a pull request that is genuinely merged:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
merged
```

No armed watch is lost by upgrading.

## Merging a merge request

Recorded on 2026-08-28 against glab 1.113.0 on macOS 15 (Darwin 25.6.0).

`bin/fm-pr-merge.sh` merges a GitLab merge request through the same guarded path as a GitHub pull request.
Only the execution step differs, so the facts that step depends on are pinned here.

```
$ glab --version
glab 1.113.0 (d62881304)
```

The flags the guarded path relies on all exist, and the ones it does not have are why its defaults differ from the GitHub side:

```
$ glab mr merge --help
  FLAGS
    --auto-merge               Set auto-merge. (true)
    -h --help                  Show help for this command.
    -m --message               Custom merge commit message.
    -r --rebase                Rebase the commits onto the base branch.
    -d --remove-source-branch  Remove source branch on merge.
    -R --repo                  Select another repository. You can use either OWNER/REPO or GROUP/NAMESPACE/REPO. The full URL or Git URL is also accepted.
    --sha                      Merge only if the HEAD of the source branch matches this SHA. Use to ensure that only reviewed commits are merged.
    -s --squash                Squash commits on merge.
    --squash-message           Custom squash commit message.
    -y --yes                   Skip submission confirmation prompt.
```

Four consequences follow directly from that list.
`--sha` is what pins the reviewed head, so nothing pushed between review and merge can land.
`--yes` is what keeps the path from hanging on a confirmation prompt.
`--auto-merge` defaults to true, which would queue the merge behind a pipeline instead of performing it, so the guarded path passes `--auto-merge=false` and judges the pipeline itself.
There is no `--merge` and no `--method`: a merge commit is expressed as the absence of `--squash` and `--rebase`, so `--squash=false` is how a caller asks for one.

`-R` accepts a full project URL, which carries the host, so one form addresses gitlab.com and a self-hosted instance alike and overrides any ambient glab repository setting.
The head and the head pipeline come from one read in that same form:

```
$ glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture --output json --jq '[.sha, .state, (.head_pipeline.sha // "-"), (.head_pipeline.status // "-")] | join(" ")'
33762fcf6777c8d993220d25fb541e56c48081b9 merged - -

$ glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture --output json --jq '[.sha, .state, (.head_pipeline.sha // "-"), (.head_pipeline.status // "-")] | join(" ")'
66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8 opened - -
```

`--jq` is glab's own filter, so no external JSON processor is involved.
The fixture project has no CI, and that is what an absent pipeline looks like: `head_pipeline` is null and both fields read `-`.
An absent pipeline is not a passing one, so the guarded path refuses it unless the caller passes `--allow-absent-pipeline`, which is recorded in the approval as `pipeline=absent-accepted`.
A pipeline whose `head_pipeline.sha` is not the head being merged is refused with no override, because a pipeline for another commit says nothing about this one.
The present-pipeline verdicts are exercised hermetically in `tests/fm-pr-merge.test.sh` rather than against a live project, so the classifier is enforced by CI on every run.

An extra bare argument cannot redirect the merge to another merge request, because glab bounds its own positional arguments:

```
$ glab mr merge 1 extra -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture
   ERROR
  Accepts at most 1 arg(s), received 2.
```

That check happens before any network call, so the command above is safe to rerun.
`--repo`, `-R`, `--sha`, and `--auto-merge` are still rejected in caller-supplied extra arguments, since each of those could redirect the project or defeat a guard.

## Known limits

A GitLab task records no `pr_head=` at arming time.
`gh` exposes the head commit as a selectable field that `bin/fm-pr-check.sh` already reads, while `glab` exposes it inside JSON; the merge path reads it there when it needs to pin the head, and arming has never needed it.
Both consumers already treat it as optional: `bin/fm-teardown.sh` reads the head from the forge at teardown rather than from metadata and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.

The GitHub path has no equivalent head pin.
`gh pr merge` offers `--match-head-commit`, but `gh-axi pr merge`'s documented flags are `--method`, `--merge`, `--squash`, `--rebase`, `--auto`, `--delete-branch`, `--body`, and `--subject`, and passing `--match-head-commit` to it produced neither an error nor any visible effect.
Wiring it in from here would therefore add an unverifiable no-op, which is worse than no pin at all because it reads like protection.
Adding explicit passthrough to gh-axi is the prerequisite; the pin can follow in this script once it can be observed working.
