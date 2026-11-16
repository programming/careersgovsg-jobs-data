# Restore runbook

Rebuilding this project on a fresh machine — new VPS, or after losing the old one.
Follow it top to bottom; the verify section at the end is what makes a restore
*finished* rather than merely attempted.

## What lives where

| what | where | how it comes back |
|---|---|---|
| **the record**: every revision of `data/job-listings.json` and `data/workable-job-listings.json` | this repo's git history (committed twice each weekday since 2026-02-09, plus the side channel) | `git clone` |
| **tooling**: both fetchers, the ingester, queries, schema, `scripts/sync-and-ingest.sh`, workflows, these units | this repo | `git clone` |
| **derived DB**: `sqlite/jobs.db` (~950 MB) | deliberately *not* in git (`.gitignore`) | rebuild, or `gh release download` |
| credentials (gh/SSH), Deno | the machine only | recreate by hand |
| ops notes and logs (`~/.hermes/logs/jobs-sync.log`, the Hermes skill `job-market-data-warehouse` incl. `references/board-coverage.md`) | this machine only | not in this repo — copy separately if you want them |

**Two rules that everything else follows from.** The DB is 100% derived and
disposable: never back it up, and delete it freely. The git history is the asset,
and it cannot be re-collected from the sources (the APIs serve current listings
only), so never rebuild with `--max-revisions`/`--since` — those truncate the
history that is the entire point of this dataset.

## Restore

```bash
# 1. code and history (~310 MB, ~40 s)
gh repo clone programming/careersgovsg-jobs-data ~/careersgovsg-jobs-data
cd ~/careersgovsg-jobs-data

# 2. get a database — either one works
gh release download sqlite-warehouse -p 'jobs.db*' -D sqlite   # fast path, ~980 MB
# ...or rebuild from history (full backfill; leave it running, it is idempotent)
python3 sqlite/ingest.py

# 3. Deno, needed to fetch new data (the sync script expects ~/.deno/bin/deno)
curl -fsSL https://deno.land/install.sh | sh

# 4. the daily sync, as user units (symlinked so the repo stays canonical)
mkdir -p ~/.config/systemd/user ~/.hermes/logs
ln -sf ~/careersgovsg-jobs-data/deploy/systemd/jobs-sync.service ~/.config/systemd/user/
ln -sf ~/careersgovsg-jobs-data/deploy/systemd/jobs-sync.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now jobs-sync.timer
loginctl enable-linger "$USER"      # so the timer runs without a login session

# 5. push access — the sync script pushes to origin/main every run
gh auth login                       # or put an SSH key on the account
```

Run it once by hand before trusting the timer:

```bash
systemctl --user start jobs-sync.service   # ~2-3 min
tail -20 ~/.hermes/logs/jobs-sync.log
```

## Verify — a restore is not done until these pass

```bash
systemctl --user list-timers jobs-sync.timer          # next elapse ~23:00 SGT
python3 -c "
import sqlite3; c=sqlite3.connect('sqlite/jobs.db')
print('integrity :', c.execute('pragma quick_check').fetchone()[0])
print('snapshots :', c.execute('select count(*) from snapshots').fetchone()[0])
print('anchor    :', c.execute('select max(observed_at) from snapshots').fetchone()[0])
print('live      :', dict(c.execute('select platform,count(*) from current_jobs group by platform')))
"
git log --format=%H -- data/job-listings.json | wc -l   # must equal the snapshot count
git log -1 --format=%cI -- data/job-listings.json       # must equal the anchor
```

The snapshot count must equal the number of revisions on disk, and the anchor must
equal the newest data commit — if either is off, revisions were not merged or not
ingested, and the DB is stale. Baseline for comparison (2026-11-16): 398 snapshots,
842,172 job rows, 2,068 live (1,739 hrp / 275 greenhouse / 54 workable), `watchlist`
0 rows (unused — nothing in the DB depends on it).

## Known gaps

- **A full-history rebuild from a bare clone has not been run end-to-end.** A bug
  that broke every from-scratch build (a side-channel duplicate tripping
  `UNIQUE(job_content.natural_key, content_hash)`) was fixed on 2026-11-16 and the
  fix verified on a slice — rebuild the whole history once when convenient and
  correct this line.
- **Coverage is a fixed set of boards**: the Careers@Gov feed (`hrp`), greenhouse
  `govtech`, and the Workable accounts in `WORKABLE_ACCOUNTS`. Agencies on their own
  ATS are invisible; see the Hermes skill's `references/board-coverage.md`.
- **Removal is not closure.** "Removed" means the posting left the tracked boards.
