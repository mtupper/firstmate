# fm-dashboard-refresh.sh - real end-to-end transcript

Fixture home: a copy of the live firstmate home's data/, state/ and config/ in a temp dir.
Projects root: the real /Users/mtupper/dgh/firstmate/projects (read only), --project dashboard.
Real pnpm, real dashboard repo at bd02b57, real Nuxt build. Nothing written outside the temp home.

## 1. first refresh - publishes a page built from a fresh feed
$ FM_HOME=<tmp-home> FM_PROJECTS_OVERRIDE=<real projects> bin/fm-dashboard-refresh.sh --project dashboard
[standalone] index.html is self-contained (618 kB).
published <tmp-home>/data/dashboard-preview/index.html (feed generated 2026-08-24T17:46:00Z)
  -> no index.html.prev on a first publish; work root holds build/, feed.json and .lock

## 2. the dashboard's own checker validates the generated feed
$ pnpm data:check <tmp-home>/data/dashboard-build/feed.json
<...>/feed.json: valid against contract 1.0.0.
  10 projects - 6 active, 4 dormant.

## 3. a second refresh while the first still holds the lock is refused
$ bin/fm-dashboard-refresh.sh --project dashboard   # started, holds the flock
$ bin/fm-dashboard-refresh.sh --project dashboard   # concurrent attempt
fm-dashboard-refresh: another refresh is already running; let it finish
concurrent exit: 3

## 4. the run that held the lock finishes and keeps the previous page
published <tmp-home>/data/dashboard-preview/index.html (feed generated 2026-08-24T17:47:31Z, previous page kept as index.html.prev)
  -> index.html.prev is byte-for-byte the page published in step 1

## 5. a failed generation leaves the served page in place (lock was released on exit)
$ mv <tmp-home>/data/projects.md <tmp-home>/data/projects.md.away
$ bin/fm-dashboard-refresh.sh --project dashboard
fm-fleet-feed: no project registry at <tmp-home>/data/projects.md; nothing can be grounded
fm-dashboard-refresh: feed generation failed; the published page is untouched
exit: 1
  -> served index.html unchanged (same sha), no index.html.new left behind,
     page still shows its own honest "COMPILED 24 AUG 2026, 10:47"

## 6. nothing reached a repository, nothing was scheduled
$ git -C <build-checkout> status --porcelain | grep -v "^??"     # empty
$ find <build-checkout> -name feed.json                          # empty
$ git -C /Users/mtupper/dgh/firstmate/projects/dashboard status --porcelain  # empty, HEAD bd02b57
$ crontab -l | grep dashboard-refresh ; launchctl list | grep -i dashboard   # no hits
