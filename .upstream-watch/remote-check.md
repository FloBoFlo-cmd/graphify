# Remote tier — durable Routine prompt

This is the **source of truth** for the Tier 1 Routine. Tier 1 is the durable,
always-on early warning for the raw-git watchlist (graphify et al.): it survives
the laptop being off and delivers a real push, because a scheduled remote session
can reach public upstreams over `git ls-remote` (verified reachable) without any
local machine state.

## How to create it

Create a durable trigger (Claude Code Remote / Routines — NOT `CronCreate`, which
is session-only and expires after 7 days):

- **schedule (cron, local tz):** `17 7 * * 1`  (Mondays 07:17)
- **create_new_session_on_fire:** `true`  (fresh session each fire → completion push applies)
- **notifications:** `{ push: true }`
- **prompt:** the block below, verbatim.

## Routine prompt (paste verbatim)

> You are the upstream-watch remote tier for the repo `FloBoFlo-cmd/graphify`.
> This is a fresh session — everything you need is below.
>
> 1. Read `.upstream-watch/watchlist.json` from the `FloBoFlo-cmd/graphify` repo
>    (GitHub MCP `get_file_contents`). It is a JSON array of raw-git sources.
> 2. For each entry `{repo, ref, last_sha, pull, name}`:
>    - Run `git ls-remote https://github.com/<repo> <ref>` and take the first sha
>      as `new`. (Use plain git, NOT the GitHub MCP — upstreams like
>      `safishamsi/graphify` are outside this session's MCP repo scope, but public
>      `git ls-remote` works.)
>    - If `new == last_sha`: at parity, say nothing for this entry.
>    - If `new != last_sha`: it drifted. Get an approximate ahead count with a
>      shallow fetch + `git rev-list --count <last_sha>..<new>` if feasible, else
>      just report "new commits". Record a line: `<name> +<N>  (tap: <pull>)`.
>      Then update that entry's `last_sha` to `new` in `.upstream-watch/watchlist.json`
>      and commit it back to `FloBoFlo-cmd/graphify` on the default branch
>      (GitHub MCP `create_or_update_file`, message
>      `upstream-watch: advance <name> baseline to <new_short>`).
> 3. If ANY entry drifted, end your final message with a one-line summary like
>    `graphify +12 · <other> +3` — this becomes the completion push. If nothing
>    drifted, end with exactly `parity` and send no notification of substance.
>
> Never pull, rebase, or upgrade anything. Report only.

## Notes

- Tier 1 tracks only the raw-git watchlist. brew / `npm -g` / plugins are
  local-only and belong to the Tier 2 launchd runner (`upstream-watch.sh`).
- Overlap on graphify (both tiers watch it) is intentional: Tier 1 is the
  can't-miss-it early warning; Tier 2 adds the local install sha, package
  managers, and the rebase-integrity probe.
- `watchlist.json` in the repo is the shared config **and** Tier 1's persisted
  baseline. Tier 2 keeps its own baseline in `~/.claude/.watch/state.local.json`
  so a laptop run never clobbers the remote baseline.
