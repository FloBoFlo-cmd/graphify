#!/usr/bin/env bash
# upstream-watch — ecosystem-wide "is anything behind upstream?" radar (report-only).
#
# Aggregates four EXISTING checkers — it invents no new version logic:
#   raw-git : git ls-remote <repo> <ref>        (curated watchlist.json)
#   brew    : brew outdated --json
#   npm     : npm outdated -g --json
#   plugins : installed_plugins.json.gitCommitSha  vs  marketplace HEAD
#
# Writes a Markdown report with ready-to-tap pull commands and fires a native
# notification when there is drift. It NEVER pulls/upgrades anything itself.
#
# Local tier of the two-tier design (see README.md). Safe to run by hand or launchd.

set -uo pipefail

# ---- config (override via env) ------------------------------------------------
WATCH_DIR="${WATCH_DIR:-${HOME}/.claude/.watch}"
WATCHLIST="${WATCHLIST:-${WATCH_DIR}/watchlist.json}"
STATE="${STATE:-${WATCH_DIR}/state.local.json}"
REPORT="${REPORT:-${WATCH_DIR}/report.md}"
PLUGINS_DIR="${PLUGINS_DIR:-${HOME}/.claude/plugins}"
INSTALLED_PLUGINS="${INSTALLED_PLUGINS:-${PLUGINS_DIR}/installed_plugins.json}"
KNOWN_MARKETPLACES="${KNOWN_MARKETPLACES:-${PLUGINS_DIR}/known_marketplaces.json}"
# Optional allow-list regex to keep brew/npm noise down (A1). Empty = report all.
# e.g. RELEVANCE='-mcp|^tsx$|^typescript$'
RELEVANCE="${RELEVANCE:-}"

mkdir -p "$WATCH_DIR"
[[ -f "$STATE" ]] || echo '{}' > "$STATE"

command -v jq >/dev/null 2>&1 || { echo "upstream-watch: jq is required" >&2; exit 2; }

DRIFT=0                     # count of drifting sources
BODY=""                     # accumulated markdown
add() { BODY+="$1"$'\n'; }  # append a report line

expand() { eval echo "$1"; }  # expand a leading ~ in config-supplied paths

# rebase_probe: returns "rebase clean: ja/nein" for an entry with .rebase_check,
# testing in a detached throwaway worktree so the live editable install is untouched.
rebase_probe() {
  local entry="$1" src onto remote branch head wt rc
  src=$(jq -r '.rebase_check.src // ""' <<<"$entry")
  onto=$(jq -r '.rebase_check.onto // ""' <<<"$entry")
  [[ -n "$src" && -n "$onto" ]] || return 0
  src=$(expand "$src")
  [[ -d "$src/.git" ]] || { echo "rebase check skipped (no repo at ${src})"; return 0; }
  remote=${onto%%/*}; branch=${onto#*/}
  git -C "$src" fetch "$remote" "$branch" --quiet 2>/dev/null || true
  head=$(git -C "$src" rev-parse HEAD 2>/dev/null) || { echo "rebase check skipped"; return 0; }
  wt=$(mktemp -d)
  if git -C "$src" worktree add --detach "$wt" "$head" --quiet 2>/dev/null; then
    if git -C "$wt" rebase "$onto" >/dev/null 2>&1; then rc="ja"; else rc="nein"; git -C "$wt" rebase --abort >/dev/null 2>&1 || true; fi
    git -C "$src" worktree remove --force "$wt" >/dev/null 2>&1 || true
    echo "rebase clean: ${rc}"
  else
    rm -rf "$wt"; echo "rebase check skipped (worktree add failed)"
  fi
}

# ---- 1. raw-git watchlist -----------------------------------------------------
add "## raw-git"
if [[ -f "$WATCHLIST" ]]; then
  # stream entries as compact JSON, one per line
  while IFS= read -r entry; do
    name=$(jq -r '.name' <<<"$entry")
    repo=$(jq -r '.repo' <<<"$entry")
    ref=$(jq -r '.ref' <<<"$entry")
    pull=$(jq -r '.pull // ""' <<<"$entry")
    seed=$(jq -r '.last_sha // ""' <<<"$entry")

    # baseline = last observed sha (state), else the acknowledged watchlist sha
    base=$(jq -r --arg n "$name" '.[$n] // ""' "$STATE")
    [[ -n "$base" ]] || base="$seed"

    new=$(git ls-remote "https://github.com/${repo}" "$ref" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z "$new" ]]; then
      add "- ⚠️ **${name}** (${repo} ${ref}): ls-remote failed (network/ref?)"
      continue
    fi

    if [[ -n "$base" && "$new" == "$base" ]]; then
      add "- ✅ **${name}** at parity (\`${new:0:7}\`)"
    else
      DRIFT=$((DRIFT+1))
      # ahead_by via gh, degrade gracefully if gh is missing/unauth
      ahead=""
      if [[ -n "$base" ]] && command -v gh >/dev/null 2>&1; then
        ahead=$(gh api "repos/${repo}/compare/${base}...${new}" --jq '.ahead_by' 2>/dev/null || true)
      fi
      countstr=${ahead:+ (+${ahead} commits)}
      add "- 🔴 **${name}**${countstr}: \`${base:0:7}\` → \`${new:0:7}\`"
      [[ -n "$pull" ]] && add "  \`\`\`sh"$'\n'"  ${pull}"$'\n'"  \`\`\`"

      # graphify-style feature-integrity check (non-destructive throwaway worktree)
      rc_msg=$(rebase_probe "$entry")
      [[ -n "$rc_msg" ]] && add "  - $rc_msg"
    fi

    # advance baseline
    tmp=$(mktemp)
    jq --arg n "$name" --arg s "$new" '.[$n]=$s' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  done < <(jq -c '.[]' "$WATCHLIST")
else
  add "_no watchlist at ${WATCHLIST}_"
fi

# ---- 2. brew ------------------------------------------------------------------
add ""; add "## brew"
if command -v brew >/dev/null 2>&1; then
  out=$(brew outdated --json 2>/dev/null || true)   # v2 shape: {formulae:[...],casks:[...]}
  n=$(jq -r '.formulae | length' <<<"$out" 2>/dev/null || echo 0)
  if [[ "$n" -gt 0 ]]; then
    while IFS= read -r line; do
      fname=$(jq -r '.name' <<<"$line")
      [[ -n "$RELEVANCE" && ! "$fname" =~ $RELEVANCE ]] && continue
      cur=$(jq -r '.installed_versions[-1] // "?"' <<<"$line")
      latest=$(jq -r '.current_version // "?"' <<<"$line")
      DRIFT=$((DRIFT+1))
      add "- 🔴 **${fname}**: ${cur} → ${latest}"
      add "  \`\`\`sh"$'\n'"  brew upgrade ${fname}"$'\n'"  \`\`\`"
    done < <(jq -c '.formulae[]' <<<"$out")
  else
    add "_none outdated_"
  fi
else
  add "_brew not installed_"
fi

# ---- 3. npm -g ----------------------------------------------------------------
add ""; add "## npm -g"
if command -v npm >/dev/null 2>&1; then
  # NOTE: `npm outdated` exits 1 when packages ARE outdated — guard it.
  out=$(npm outdated -g --json 2>/dev/null || true)
  [[ -n "$out" && "$out" != "{}" ]] || out="{}"
  keys=$(jq -r 'keys[]?' <<<"$out")
  if [[ -n "$keys" ]]; then
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      [[ -n "$RELEVANCE" && ! "$pkg" =~ $RELEVANCE ]] && continue
      cur=$(jq -r --arg p "$pkg" '.[$p].current // "?"' <<<"$out")
      latest=$(jq -r --arg p "$pkg" '.[$p].latest // "?"' <<<"$out")
      [[ "$cur" == "$latest" ]] && continue
      DRIFT=$((DRIFT+1))
      add "- 🔴 **${pkg}**: ${cur} → ${latest}"
      add "  \`\`\`sh"$'\n'"  npm i -g ${pkg}@latest"$'\n'"  \`\`\`"
    done <<<"$keys"
  else
    add "_none outdated_"
  fi
else
  add "_npm not installed_"
fi

# ---- 4. plugins ---------------------------------------------------------------
# Least-verified block: installed_plugins.json / known_marketplaces.json schemas
# were not inspectable at authoring time. Field paths below are best-effort and
# defensively guarded; if a marketplace branch is unknown we fall back to HEAD.
add ""; add "## plugins"
if [[ -f "$INSTALLED_PLUGINS" ]]; then
  # marketplace name -> git url ; and -> branch (may be null)
  mp_url() { jq -r --arg m "$1" '(.[$m].url // .[$m].repository // .[$m].source.url // "")' "$KNOWN_MARKETPLACES" 2>/dev/null; }
  mp_branch() { jq -r --arg m "$1" '(.[$m].branch // .[$m].ref // "HEAD")' "$KNOWN_MARKETPLACES" 2>/dev/null; }
  any=0
  # each installed plugin: try to read its pinned sha and owning marketplace
  while IFS= read -r p; do
    pname=$(jq -r '.name // .key // "?"' <<<"$p")
    psha=$(jq -r '.gitCommitSha // .commit // ""' <<<"$p")
    market=$(jq -r '.marketplace // .marketplaceName // ""' <<<"$p")
    [[ -z "$psha" || -z "$market" ]] && continue
    url=$(mp_url "$market"); [[ -z "$url" ]] && continue
    branch=$(mp_branch "$market")
    head=$(git ls-remote "$url" "$branch" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -z "$head" ]] && head=$(git ls-remote "$url" HEAD 2>/dev/null | awk 'NR==1{print $1}')
    [[ -z "$head" ]] && continue
    any=1
    if [[ "$head" == "$psha" ]]; then
      add "- ✅ **${pname}** at parity (\`${psha:0:7}\`)"
    else
      DRIFT=$((DRIFT+1))
      add "- 🔴 **${pname}** (${market}): \`${psha:0:7}\` → \`${head:0:7}\`"
      add "  Update via \`/plugin\` or refresh the \`${market}\` marketplace."
    fi
  done < <(jq -c '(.plugins // .installed // . ) | if type=="array" then .[] else to_entries[] | (.value + {name:.key}) end' "$INSTALLED_PLUGINS" 2>/dev/null)
  [[ "$any" -eq 0 ]] && add "_no comparable plugins (schema mismatch? inspect ${INSTALLED_PLUGINS})_"
else
  add "_no installed_plugins.json at ${INSTALLED_PLUGINS}_"
fi

# ---- write report + notify ----------------------------------------------------
{
  echo "# upstream-watch report"
  echo
  echo "_generated: $(date '+%Y-%m-%d %H:%M') — drift sources: ${DRIFT}_"
  echo
  echo "$BODY"
} > "$REPORT"

if [[ "$DRIFT" -gt 0 ]]; then
  summary="upstream-watch: ${DRIFT} source(s) behind — see report.md"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "upstream-watch" -message "$summary" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${summary}\" with title \"upstream-watch\"" >/dev/null 2>&1 || true
  fi
fi

echo "drift sources: ${DRIFT}  ->  ${REPORT}"
# exit 1 iff drift, 0 otherwise (info lives in the report/notification, not the code)
[[ "$DRIFT" -gt 0 ]] && exit 1 || exit 0
