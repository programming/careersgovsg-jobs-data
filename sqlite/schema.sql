-- SQLite warehouse schema for careersgovsg-jobs-data
-- Created / updated by sqlite/ingest.py (do not hand-edit the data tables;
-- your own search tracking lives in `watchlist`).

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- One row per ingested git revision of data/job-listings.json.
CREATE TABLE IF NOT EXISTS snapshots (
  sha         TEXT PRIMARY KEY,   -- git commit SHA the revision came from
  observed_at TEXT NOT NULL UNIQUE, -- ingestion time (git committer time, UTC ISO8601)
  records     INTEGER NOT NULL    -- number of jobs in that revision
);

-- One row per (snapshot, job). Light, trackable fields only.
-- ==== Track revisions ============================================================
--     Every revision is one snapshot; job_snapshots is the full-picture time series.
CREATE TABLE IF NOT EXISTS job_snapshots (
  observed_at          TEXT    NOT NULL REFERENCES snapshots(observed_at),
  platform             TEXT    NOT NULL,                 -- 'hrp' | 'greenhouse' | 'workable'
  posting_no           TEXT    NOT NULL DEFAULT '',      -- hrp GUID / workable shortcode; '' for greenhouse
  job_id               TEXT    NOT NULL DEFAULT '',      -- hrp numeric id / greenhouse gh_jid / workable account
  natural_key          TEXT    NOT NULL,                 -- platform|jobId|postingNo  (stable across revisions)
  job_title            TEXT    NOT NULL,
  agency               TEXT    NOT NULL,
  agency_id            TEXT    NOT NULL DEFAULT '',
  start_date           INTEGER,                          -- epoch ms, NULL if unknown
  closing_date         INTEGER,                          -- epoch ms, NULL = no published deadline
  closing_date_text    TEXT    NOT NULL DEFAULT '',
  remaining_days       TEXT    NOT NULL DEFAULT '',      -- upstream relative text, e.g. '1 week(s) ago' = time since posting (NOT a countdown)
  employment_type      TEXT    NOT NULL DEFAULT '',
  employment_type_code TEXT    NOT NULL DEFAULT '',
  experience_required  TEXT    NOT NULL DEFAULT '',
  experience_years_min INTEGER NOT NULL DEFAULT 0,
  experience_years_max INTEGER NOT NULL DEFAULT 0,
  field                TEXT    NOT NULL DEFAULT '',
  field_code           TEXT    NOT NULL DEFAULT '',
  functional_area      TEXT    NOT NULL DEFAULT '',
  functional_area_code TEXT    NOT NULL DEFAULT '',
  industry             TEXT    NOT NULL DEFAULT '',
  education_code       TEXT    NOT NULL DEFAULT '',
  is_new               INTEGER NOT NULL DEFAULT 0,       -- 0/1
  location             TEXT    NOT NULL DEFAULT '',
  category             TEXT    NOT NULL DEFAULT '',
  work_arrangement     TEXT    NOT NULL DEFAULT '',
  content_hash         TEXT    NOT NULL DEFAULT '',   -- links to job_content (exact text at this revision)
  PRIMARY KEY (observed_at, natural_key)
);

CREATE INDEX IF NOT EXISTS idx_snap_obs_platform ON job_snapshots(observed_at, platform);
CREATE INDEX IF NOT EXISTS idx_snap_obs_agency  ON job_snapshots(observed_at, agency);
CREATE INDEX IF NOT EXISTS idx_snap_obs_field   ON job_snapshots(observed_at, field);
CREATE INDEX IF NOT EXISTS idx_snap_closing     ON job_snapshots(closing_date);
CREATE INDEX IF NOT EXISTS idx_snap_key_time    ON job_snapshots(natural_key, observed_at);
CREATE INDEX IF NOT EXISTS idx_snap_content     ON job_snapshots(natural_key, content_hash);

-- Heavy text content (descriptions etc.), deduplicated by content hash.
-- Each job_snapshots row stores the content_hash live at that revision; join on
-- (natural_key, content_hash) to recover the exact text. first_seen/last_seen are
-- informational: a hash can reappear later (revert), so do not treat that interval
-- as contiguous. Text is stored once per unique hash.
CREATE TABLE IF NOT EXISTS job_content (
  id                   INTEGER PRIMARY KEY,
  natural_key          TEXT    NOT NULL,
  content_hash         TEXT    NOT NULL,
  first_seen           TEXT    NOT NULL,   -- observed_at it first appeared
  last_seen            TEXT    NOT NULL,   -- observed_at it was last current
  agency_description   TEXT    NOT NULL DEFAULT '',
  job_description      TEXT    NOT NULL DEFAULT '',
  job_responsibilities TEXT    NOT NULL DEFAULT '',
  job_requirements     TEXT    NOT NULL DEFAULT '',
  UNIQUE (natural_key, content_hash)
);
CREATE INDEX IF NOT EXISTS idx_content_key ON job_content(natural_key);

-- Your own shortlist / application tracking (only table you should edit).
CREATE TABLE IF NOT EXISTS watchlist (
  natural_key TEXT PRIMARY KEY,             -- copy from current_jobs.natural_key
  status      TEXT    NOT NULL DEFAULT 'watching',  -- watching|applied|interviewing|offer|rejected|closed
  notes       TEXT    NOT NULL DEFAULT '',
  added_on    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- The most recent snapshot joined with the content in effect at that time.
CREATE VIEW IF NOT EXISTS current_jobs AS
SELECT
  s.platform, s.posting_no, s.job_id, s.natural_key,
  s.job_title, s.agency, s.agency_id,
  s.start_date, s.closing_date, s.closing_date_text, s.remaining_days,
  s.employment_type, s.employment_type_code,
  s.experience_required, s.experience_years_min, s.experience_years_max,
  s.field, s.field_code, s.functional_area, s.functional_area_code,
  s.industry, s.education_code, s.is_new, s.location, s.category, s.work_arrangement,
  s.content_hash,
  c.agency_description, c.job_description, c.job_responsibilities, c.job_requirements
FROM job_snapshots s
JOIN (SELECT MAX(observed_at) AS t FROM snapshots) m ON m.t = s.observed_at
JOIN job_content c ON c.natural_key = s.natural_key
  AND c.content_hash = s.content_hash;