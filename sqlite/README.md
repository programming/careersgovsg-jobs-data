# SQLite warehouse for job-search analysis

A derived database built **from this repo's own git history** — no changes to the
fetch pipeline, no credentials, no network. Every time the GitHub Actions workflow
commits a new `data/job-listings.json` revision, `git pull` brings it down and the
ingester adds one more snapshot.

## Quick start

```bash
# first time: backfill the full history (318+ revisions) — takes a few minutes
python3 sqlite/ingest.py

# after every `git pull`: incremental update (only new revisions are parsed)
python3 sqlite/ingest.py

# example analysis
python3 sqlite/query.py latest --limit 20
python3 sqlite/query.py diff_recent            # new & removed since last run
python3 sqlite/query.py closing_soon --param days=7
python3 sqlite/query.py search --param q='data analyst'
python3 sqlite/query.py agency_history --param agency='MAS'
python3 sqlite/query.py field_trends
python3 sqlite/query.py lifecycle --param natural_key='hrp|17643792|005056a3-53e2-1fd1-adac-d57ca848f40b'
python3 sqlite/query.py content_history --param natural_key='hrp|17643792|005056a3-53e2-1fd1-adac-d57ca848f40b'
```

`sqlite/jobs.db` is created next to this README and is gitignored.

## Automated tracking (GitHub Actions)

The `Build SQLite warehouse` workflow (`.github/workflows/build-sqlite.yml`) keeps a
ready-built full-history database available without anyone running a backfill:

- `Sync upstream` (`.github/workflows/sync-upstream.yml`) merges upstream's data
  commits and dispatches a rebuild whenever it brings in something new. Upstream
  commits data twice per weekday (`10 2,7 * * 1-5` UTC plus ~30-35 min runtime), so
  the sync runs at `20 3,8 * * 1-5` with a daily `0 13 * * *` catch-up; the build
  workflow also carries a `15 4,9 * * 1-5` safety net.
- restores the previous DB from the `sqlite-warehouse` release and adds only the new
  revisions (full rebuild if the restored file is from an older schema),
- uploads the refreshed `jobs.db` back to the `sqlite-warehouse` release with
  `--clobber`.

Download the latest DB and start querying:

```bash
gh release download sqlite-warehouse -p jobs.db -D sqlite
git pull                       # if you also want the scripts/queries
python3 sqlite/query.py stats
```

Validated after each build: the workflow fails loudly if `ingest.py` cannot produce
a consistent database. Nothing is committed to git — the asset lives on the release.

## Data model

```
snapshots      one row per ingested git revision
               (commit sha, observed_at = UTC commit time, records)
job_snapshots  one row per (snapshot, job) — light, trackable fields only
               (platform, ids, natural_key, title, agency, dates, experience,
                field, industry, location, work arrangement, content_hash, ...)
job_content    heavy description text, deduplicated by content hash
               (first_seen / last_seen are informational)
watchlist      your own tracker (watching|applied|interviewing|offer|rejected|closed)
current_jobs   VIEW: latest snapshot + the content matched by content_hash
```

Full text (`job_description`, `job_responsibilities`, `job_requirements`,
`agency_description`) lives only in `job_content`. Every `job_snapshots` row stores
the `content_hash` that was live at that revision, so joining on
`(natural_key, content_hash)` recovers the exact text for any past revision — the
history is complete, and unchanged text is stored only once. Measured sizes (Oct 2026):

| Build | Revisions | Rows | db size |
|---|---|---|---|
| Full history | 350 | 738k | ~866 MB |
| Recent 90 revisions (~2.5 mo) | 90 | 202k | ~241 MB |

Use `--max-revisions 90` for a lighter build; the full backfill is only needed if
you want to chart agency/field trends over the whole repo history.

`natural_key` = `platform|jobId|postingNo`, stable across revisions for the same
posting (e.g. `hrp|17643792|005056a3-...`). The `current_jobs` view exposes it.

## Tracking your own applications

```bash
sqlite3 sqlite/jobs.db "
INSERT INTO watchlist(natural_key, status, notes)
VALUES ('hrp|17643792|005056a3-53e2-1fd1-adac-d57ca848f40b', 'applied', 'referral from Jane, ask about matrix team');
UPDATE watchlist SET status='interviewing', notes='1st round 30 Sep' WHERE natural_key='...';
"
python3 sqlite/query.py watchlist --param status=applied
```

Copy `natural_key` from any query output. Entries survive re-ingestion forever.

## Analyses that work well on this schema

| Question | Query |
|---|---|
| What's new since the last run? | `diff_recent` |
| What closes in the next week? | `closing_soon --param days=7` |
| Find jobs matching keywords | `search --param q='...'` |
| Is my target agency hiring in waves? | `agency_history --param agency='...'` |
| Which fields are heating up? | `field_trends` |
| When did <job> open/close/changes its deadline? | `lifecycle --param natural_key='...'` |
| Did a job's description text change? | `content_history --param natural_key='...'` |
| How many listings per source? | `platform_summary` |
| How long were jobs open on average? | see below |
| Which jobs re-appeared after being removed (reposts)? | see below |

### Average days a posting stayed open (hrp, live jobs that already closed)

```sql
WITH spans AS (
  SELECT natural_key, MIN(observed_at) AS first_seen, MAX(observed_at) AS last_seen
  FROM job_snapshots GROUP BY natural_key
)
SELECT AVG(julianday(last_seen) - julianday(first_seen)) AS avg_days_visible
FROM spans;
```

### Reposts: postings that disappeared then came back

```sql
WITH ranked AS (
  SELECT natural_key, observed_at,
         LAG(observed_at) OVER (PARTITION BY natural_key ORDER BY observed_at) AS prev_obs
  FROM job_snapshots
)
SELECT DISTINCT natural_key FROM ranked WHERE prev_obs IS NOT NULL;  -- 1 row = reappeared
```

## Notes & trade-offs

- **`observed_at` is ingestion (commit) time**, i.e. the moment the pipeline ran —
  not necessarily the moment the job was posted (use `start_date` for that).
- **`closing_date` is `NULL` when the source publishes no deadline** (greenhouse,
  workable). Treat `NULL` as "no deadline", never as "closed".
- **`remaining_days` is not a closing countdown.** Upstream's `RemainingDays` field is
  a relative "time since posting" string (mostly `"1 week(s) ago"`, sometimes
  `"Today"`) — the closing countdown is the separate `closing_date_text` field. Even
  that text is frozen at snapshot time, so compute live windows from `closing_date`
  (as `closing_soon` does) rather than trusting either string for "how long left".
- **Queries that care about "now" should anchor to the latest snapshot**, not
  wall-clock time: `SELECT MAX(observed_at) FROM snapshots`. The data is a point-in-time
  copy, and `closing_soon` uses this anchor so its window matches the revision you have.
  Refresh with `ingest.py` after `git pull` to move the anchor forward.
- **`field` and `functional_area` are identical in current data** (same source
  field on hrp/workable) — trust either, they're not independent.
- Job descriptions contain **raw HTML** from greenhouse/workable sources; strip
  tags before rendering anywhere.
- Content is deduplicated per (natural_key, content_hash): identical text is stored
  once even if it appears, disappears, then reappears. Join `job_snapshots.content_hash`
  to `job_content.content_hash` to get the exact text at any revision; the
  `first_seen`/`last_seen` interval alone can overstate how long a version was live,
  because a reverted hash keeps its original `first_seen`.
- Want a smaller DB? `python3 sqlite/ingest.py --max-revisions 90` (~2.5 months of
  revisions, ~200 MB). A lighter option: `--since 2026-09-01`.

## Files

```
schema.sql   tables + current_jobs view (applied automatically by the ingester)
ingest.py    backfill/incremental loader (stdlib only, idempotent)
query.py     query runner: reads sqlite/queries/*.sql, binds --param
queries/     the analysis queries shown above
jobs.db      generated locally / published as the sqlite-warehouse release asset
```