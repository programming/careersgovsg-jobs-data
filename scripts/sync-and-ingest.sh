#!/usr/bin/env bash
#
# Sync the job-listings repo and refresh the SQLite warehouse, in one run.
#
#   1. fetch and merge both remotes (origin = fork, upstream = opengovsg)
#   2. refresh the Workable side channel from the public ATS API
#   3. ingest the new revisions into sqlite/jobs.db
#   4. push back to the fork (best effort - a push hiccup must not fail the run)
#
# Safe to run at any time and from anywhere: it is idempotent (the ingester skips
# revisions it already has) and takes a lock so an overlap cannot run two copies.
#
#   scripts/sync-and-ingest.sh
#
# Driven by ~/.config/systemd/user/jobs-sync.{service,timer}.
set -euo pipefail

REPO="${JOBS_REPO:-$HOME/careersgovsg-jobs-data}"
LOCK="${JOBS_LOCK:-$HOME/.hermes/cache/jobs-sync.lock}"
export PATH="$HOME/.deno/bin:$PATH"

cd "$REPO"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# One run at a time; skip (not queue) if another copy is still going.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another sync is already running; nothing to do"
  exit 0
fi

log "=== sync start (repo $REPO)"

# --- 1. remotes -------------------------------------------------------------
# A fetch failure is not fatal: the local history is still ingestable, and the
# next run picks the remotes up. A merge conflict IS fatal (never ingest a
# conflicted tree).
if ! git fetch --all --prune; then
  log "warning: git fetch failed; continuing with local history"
fi

for remote in origin upstream; do
  if ! git rev-parse --verify -q "$remote/main" >/dev/null; then
    continue   # remote not configured/fetched
  fi
  behind=$(git rev-list --count "HEAD..$remote/main")
  if [ "$behind" -gt 0 ]; then
    log "merging $behind commit(s) from $remote/main"
    if ! git merge --no-ff --no-edit "$remote/main" >/dev/null; then
      git merge --abort || true
      log "ERROR: merge conflict on $remote/main - resolve by hand"
      exit 1
    fi
  fi
done

# --- 2. Workable side channel ----------------------------------------------
if command -v deno >/dev/null 2>&1; then
  if deno run --allow-import --allow-net --allow-read --allow-write \
      scripts/fetch-workable.ts data/workable-job-listings.json >/dev/null; then
    if ! git diff --quiet -- data/workable-job-listings.json data/workable-job-listings.csv; then
      git add data/workable-job-listings.json data/workable-job-listings.csv
      git commit -q -m "Flat: latest workable data ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
      log "committed a Workable side-channel update"
    fi
  else
    log "warning: Workable fetch failed; keeping the committed side-channel file"
  fi
else
  log "warning: deno not found; skipping the Workable side channel"
fi

# --- 3. ingest --------------------------------------------------------------
python3 sqlite/ingest.py

# --- 4. push ----------------------------------------------------------------
if [ "$(git rev-list --count origin/main..HEAD)" -eq 0 ]; then
  log "nothing to push"
else
  for attempt in 1 2 3; do
    if git push origin HEAD:main >/dev/null 2>&1; then
      log "pushed to origin/main"
      push_ok=1
      break
    fi
    sleep $((attempt * 15))
  done
  if [ "${push_ok:-0}" != "1" ]; then
    log "warning: push to origin/main failed after 3 attempts (local commits kept)"
  fi
fi

log "=== sync done"
