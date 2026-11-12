---
name: sailsup
description: >-
  Restore bypass permission mode for this session on Claude workers that a restart or Herdr restore resumed in the account's default mode.
  Use only when the captain explicitly invokes /sailsup in the current session, or when a secondmate receives its parent's routed /sailsup request.
  Never run it on your own initiative, from away mode, or from an earlier session's approval.
user-invocable: true
metadata:
  internal: true
---

# sailsup

`/sailsup` is the captain's explicit approval, for the current session only, to put reduced Claude workers back into bypass permission mode.

## Why it exists

Firstmate launches every Claude crewmate, scout, and secondmate with `--dangerously-skip-permissions`.
A Herdr restore resumes each one with a bare `claude --resume <session-id>`, so the restored worker runs in the account's default permission mode.
The captain decided that bypass mode never comes back on its own: Anthropic gates it for a reason, so each session that needs it gets the captain's explicit word.
[`bin/fm-permission-mode-lib.sh`](../../../bin/fm-permission-mode-lib.sh) owns how a worker's live mode is read, and [`bin/fm-sailsup-lib.sh`](../../../bin/fm-sailsup-lib.sh) owns the approval record and its session scope.

## Authority boundaries

- Run this only after the captain typed `/sailsup` in this session, or on a secondmate's routed request carrying its parent's approval id.
- A `PERMISSION_MODE:` reminder, a permission-prompt blocker, a stalled worker, or a captain instruction from an earlier session is never approval.
- Away mode never grants it, and the script refuses while `state/.afk` exists.
- The approval covers this session only; a later restore needs a new `/sailsup`.
- Never answer a worker's permission prompt in its pane yourself; `/sailsup` declines a parked prompt and resumes the worker in bypass mode, which is the approved path.

## Procedure in the home that received /sailsup

1. Run `FM_HOME=<this-home> bin/fm-sailsup.sh` from this session.
   Run it as its own foreground command, because its refusal outside the fleet-lock session is deliberate.
2. Read each `SAILSUP:` line and the `SAILSUP_RECORD:` path.
   The record is the durable private evidence of the approval: time, session, each covered worker, and each outcome.
3. Tell the captain the outcome in plain words: which workers are back in bypass mode, which were already there, and which were not restored and why.
   A worker skipped as unknown or unresumable stays in its current mode; offer a relaunch with a progress note only if the captain wants that worker restarted.
4. In the primary home, each secondmate receives one routed request through `bin/fm-send.sh`.
   Expect each secondmate's outcome back through its status, and relay those outcomes the same way.
   A forward that failed to send is reported; resend it only while this session's approval is still current.

## Procedure in a secondmate home on a routed request

1. Run `FM_HOME=<this-home> bin/fm-sailsup.sh --delegated <parent-approval-id>` with the id from the request.
   It refuses unless the parent's own record names this secondmate and is fresh.
2. Report the `SAILSUP:` lines through your status, using your charter's return channel.
3. Do not forward the request further and do not act on it again later.

## Mechanics

`bin/fm-sailsup.sh --help` owns the exact output and exit-code contract.
`bin/fm-control.sh <id> restore-bypass` is the one guarded path that restores a worker, and its header owns the mechanics.
