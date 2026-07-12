# upstream-watch — ecosystem-wide upstream update radar

A **report-only** radar that answers "is anything I run behind its upstream?"
weekly, and hands you a ready-to-tap pull command when something drifted. It
never pulls or upgrades on its own.

It was born from a concrete miss: the `FloBoFlo-cmd/graphify` fork (editable
install) sat **438 commits** behind `safishamsi/graphify` with no signal. The
same blind spot exists for brew-installed MCP servers, global npm tools, and
pinned plugins. Auto-updating marketplaces don't need watching; everything
pinned-by-hand does.

## Two tiers, by where the data lives

| Tier | Runs | Covers | Why |
|---|---|---|---|
| **1 — remote Routine** | durable schedule, laptop can be off | raw-git watchlist (graphify …) | public upstreams are reachable via `git ls-remote` from anywhere; delivers a real push |
| **2 — local launchd** | weekly, when the machine is on | raw-git **+** brew **+** `npm -g` **+** plugins **+** graphify rebase-integrity | brew/npm/plugins and the local install sha are only inspectable on the machine |

Overlap on graphify is intentional: Tier 1 is the can't-miss early warning;
Tier 2 adds the full local picture.

## Files

| File | Role |
|---|---|
| `watchlist.json` | curated raw-git sources + `last_sha` baseline (shared config; Tier 1 commits baseline advances back here) |
| `upstream-watch.sh` | Tier 2 aggregator over the four native checkers |
| `com.user.upstream-watch.plist` | launchd template for the Tier 2 schedule |
| `remote-check.md` | Tier 1 Routine prompt (source of truth — create the Routine from this) |

The script also uses (read-only) `~/.claude/plugins/installed_plugins.json` and
`known_marketplaces.json`, and writes `~/.claude/.watch/state.local.json` +
`report.md`.

## Install (macOS)

```sh
# 1. Local tier: copy the runner + watchlist into the watch dir
mkdir -p ~/.claude/.watch
cp .upstream-watch/upstream-watch.sh ~/.claude/.watch/
cp .upstream-watch/watchlist.json    ~/.claude/.watch/
chmod +x ~/.claude/.watch/upstream-watch.sh

# 2. Dry run — should list any real drift and write report.md
bash ~/.claude/.watch/upstream-watch.sh
cat ~/.claude/.watch/report.md

# 3. Schedule via launchd (edit USERNAME in the plist first)
sed "s/USERNAME/$USER/g" .upstream-watch/com.user.upstream-watch.plist \
  > ~/Library/LaunchAgents/com.user.upstream-watch.plist
launchctl load ~/Library/LaunchAgents/com.user.upstream-watch.plist
launchctl start com.user.upstream-watch        # fire once to verify

# 4. Remote tier: create the durable Routine from remote-check.md
#    (schedule 17 7 * * 1, create_new_session_on_fire=true, push notifications)
```

`jq` is required (`brew install jq`). `gh` is optional — it only enriches drift
lines with an exact "+N commits" count and degrades gracefully if absent.

## Tuning

- **Noise:** set `RELEVANCE` (a regex) at the top of `upstream-watch.sh` or via
  env to limit brew/npm reporting, e.g. `RELEVANCE='-mcp|^tsx$|^typescript$'`.
  Default reports everything.
- **Adding a raw-git source:** append an entry to `watchlist.json`
  (`name`, `repo`, `ref`, `pull`; optional `rebase_check: {src, onto}` to add a
  non-destructive "does my feature still rebase?" probe).

## Behavior notes

- Drift is signalled **on change**: once a moved upstream is reported, the
  baseline advances, so an ignored drift won't re-nag on the next run. Pull to
  clear it, or it re-surfaces when upstream next moves.
- The rebase-integrity probe runs in a throwaway `git worktree` — the live
  editable checkout is never touched.
- The script writes the report and fires a native notification itself; its exit
  code is just `1` on any drift, `0` otherwise.
