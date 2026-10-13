#!/usr/bin/env python3
"""Build / update jobs.db — a SQLite warehouse of every revision of data/job-listings.json.

Data model
----------
- snapshots: one row per git revision (observed_at = git committer time, UTC).
- job_snapshots: one row per (snapshot, job) with light, trackable fields.
- job_content: heavy description text, deduplicated by content hash and versioned
  by first_seen/last_seen so re-running only stores text that actually changed.
- watchlist: your own job-search tracker (never touched by this script).

Usage
-----
  python3 sqlite/ingest.py                    # full backfill of the whole git history (first run)
  python3 sqlite/ingest.py --max-revisions 90 # lighter DB: only the last 90 revisions
  python3 sqlite/ingest.py --since 2026-09-01 # only revisions on/after a date
  # ...then, after each `git pull`, re-run the same command: it only parses new revisions.

The script is idempotent: already-ingested commits are skipped, and re-running never
duplicates rows.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent
JSON_PATH = "data/job-listings.json"
SCHEMA_PATH = HERE / "schema.sql"
DEFAULT_DB = HERE / "jobs.db"

# (json field -> sql column) for the light snapshot table
LIGHT_FIELDS = [
    ("platform", "platform"),
    ("postingNo", "posting_no"),
    ("jobId", "job_id"),
    ("jobTitle", "job_title"),
    ("agency", "agency"),
    ("agencyId", "agency_id"),
    ("startDate", "start_date"),
    ("closingDate", "closing_date"),
    ("closingDateText", "closing_date_text"),
    ("remainingDays", "remaining_days"),
    ("employmentType", "employment_type"),
    ("employmentTypeCode", "employment_type_code"),
    ("experienceRequired", "experience_required"),
    ("experienceYearsMin", "experience_years_min"),
    ("experienceYearsMax", "experience_years_max"),
    ("field", "field"),
    ("fieldCode", "field_code"),
    ("functionalArea", "functional_area"),
    ("functionalAreaCode", "functional_area_code"),
    ("industry", "industry"),
    ("educationCode", "education_code"),
    ("isNew", "is_new"),
    ("location", "location"),
    ("category", "category"),
    ("workArrangement", "work_arrangement"),
]

CONTENT_FIELDS = [
    "agencyDescription",
    "jobDescription",
    "jobResponsibilities",
    "jobRequirements",
]


def natural_key(job: dict) -> str:
    return f"{job.get('platform', '')}|{job.get('jobId', '')}|{job.get('postingNo', '')}"


def content_hash(job: dict) -> str:
    h = hashlib.sha256()
    for f in CONTENT_FIELDS:
        h.update(str(job.get(f, "")).encode("utf-8"))
        h.update(b"\x00")
    return h.hexdigest()


def to_utc_iso(value: str) -> str:
    """Normalise a git ISO8601 timestamp (possibly with offset) to UTC 'Z' form."""
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git_commits() -> list[tuple[str, str]]:
    """Return [(sha, iso_committer_time)] for every commit touching the data file, oldest first."""
    proc = subprocess.run(
        ["git", "log", "--reverse", "--format=%H%x1f%cI", "--", JSON_PATH],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    out = []
    for line in proc.stdout.splitlines():
        sha, _, ts = line.partition("\x1f")
        if sha and ts:
            out.append((sha, ts))
    return out


def read_revision(sha: str) -> list | None:
    """Return the parsed job list as present at commit `sha`, or None if absent."""
    proc = subprocess.run(
        ["git", "show", f"{sha}:{JSON_PATH}"],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout:
        return None
    return json.loads(proc.stdout)


def ingest_revision(conn: sqlite3.Connection, sha: str, observed_at: str, jobs: list) -> None:
    """Insert one snapshot + its job rows + content rows (idempotent)."""
    conn.execute(
        "INSERT OR REPLACE INTO snapshots(sha, observed_at, records) VALUES (?,?,?)",
        (sha, observed_at, len(jobs)),
    )

    snap_rows = []
    content_new = []
    for raw in jobs:
        # Revisions before 2026-05 (platform field added) were hrp-only.
        job = dict(raw)
        job.setdefault("platform", "hrp")
        key = natural_key(job)
        digest = content_hash(job)

        vals = [observed_at, key]
        for json_field, _ in LIGHT_FIELDS:
            v = job.get(json_field)
            vals.append(v)
        vals.append(digest)
        snap_rows.append(vals)

        # content upsert (dedup by hash, one row per unique text per job)
        row = conn.execute(
            "SELECT id FROM job_content WHERE natural_key=? AND content_hash=?",
            (key, digest),
        ).fetchone()
        if row:
            conn.execute("UPDATE job_content SET last_seen=? WHERE id=?", (observed_at, row[0]))
        else:
            content_new.append([key, digest, observed_at, observed_at] + [job.get(f, "") for f in CONTENT_FIELDS])

    snap_columns = ["observed_at", "natural_key"] + [c for _, c in LIGHT_FIELDS] + ["content_hash"]
    conn.executemany(
        f"INSERT OR REPLACE INTO job_snapshots ({', '.join(snap_columns)}) "
        f"VALUES ({', '.join('?' * len(snap_columns))})",
        snap_rows,
    )
    if content_new:
        conn.executemany(
            "INSERT INTO job_content"
            "(natural_key, content_hash, first_seen, last_seen, "
            "agency_description, job_description, job_responsibilities, job_requirements) "
            "VALUES (?,?,?,?,?,?,?,?)",
            content_new,
        )


def sqlite_connect(db: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=OFF")  # fast bulk load; rebuild is always possible
    conn.executescript(SCHEMA_PATH.read_text())
    snap_cols = {r["name"] for r in conn.execute("PRAGMA table_info(job_snapshots)")}
    if "content_hash" not in snap_cols:
        conn.close()
        raise SystemExit(
            f"{db} uses an older schema (job_snapshots.content_hash is missing).\n"
            "Delete it and re-run the ingester to rebuild:  "
            "rm sqlite/jobs.db* && python3 sqlite/ingest.py"
        )
    return conn


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help="sqlite database path")
    ap.add_argument("--max-revisions", type=int, default=0,
                    help="only ingest the N most recent revisions (0 = all)")
    ap.add_argument("--since", default=None, help="only revisions dated on/after YYYY-MM-DD")
    ap.add_argument("--jobs-json", type=Path, default=None,
                    help="ingest a single local file instead of git history "
                         "(observed_at = file mtime; useful for previews)")
    args = ap.parse_args()

    if args.jobs_json is not None:
        jobs = json.loads(args.jobs_json.read_text())
        mtime = datetime.fromtimestamp(args.jobs_json.stat().st_mtime, tz=timezone.utc) \
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        conn = sqlite_connect(args.db)
        t0 = time.time()
        conn.execute("BEGIN")
        ingest_revision(conn, f"local:{mtime}", mtime, jobs)
        conn.commit()
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.execute("ANALYZE")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.close()
        print(f"Imported {len(jobs)} jobs from {args.jobs_json} @ {mtime} "
              f"({time.time() - t0:.1f}s)")
        return 0

    commits = git_commits()
    print(f"{len(commits)} revisions found in git history")

    if args.since:
        since = to_utc_iso(f"{args.since}T00:00:00+00:00")
        commits = [c for c in commits if c[1] >= since]
        print(f"  after --since: {len(commits)} revisions")
    if args.max_revisions:
        commits = commits[-args.max_revisions:]
        print(f"  after --max-revisions {args.max_revisions}: {len(commits)} revisions")

    conn = sqlite_connect(args.db)
    existing = {r["sha"] for r in conn.execute("SELECT sha FROM snapshots")}
    pending = [(sha, ts) for sha, ts in commits if sha not in existing]
    print(f"  already ingested: {len(commits) - len(pending)}; to ingest: {len(pending)}")

    t0 = time.time()
    seen_at = set()
    ingested = 0
    for sha, ts in commits:
        observed_at = to_utc_iso(ts)
        if observed_at in seen_at:
            continue  # two commits with identical timestamps: keep the first
        seen_at.add(observed_at)
        if sha in existing:
            continue
        jobs = read_revision(sha)
        if jobs is None:
            continue  # revision predates the data file
        conn.execute("BEGIN")
        ingest_revision(conn, sha, observed_at, jobs)
        conn.commit()
        ingested += 1
        print(f"  [{ingested}/{len(pending)}] {observed_at}  {len(jobs)} jobs", file=sys.stderr)

    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.execute("ANALYZE")
    conn.execute("PRAGMA synchronous=NORMAL")
    n_snaps = conn.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0]
    n_rows = conn.execute("SELECT COUNT(*) FROM job_snapshots").fetchone()[0]
    n_content = conn.execute("SELECT COUNT(*) FROM job_content").fetchone()[0]
    n_current = conn.execute("SELECT COUNT(*) FROM current_jobs").fetchone()[0]
    first, last = conn.execute("SELECT MIN(observed_at), MAX(observed_at) FROM snapshots").fetchone()
    size_mb = args.db.stat().st_size / 1e6
    conn.close()

    print(f"\nDone in {time.time() - t0:.1f}s ({ingested} new revisions ingested)")
    print(f"  snapshots : {n_snaps}   ({first} → {last})")
    print(f"  job rows  : {n_rows}   (~{n_snap_jobs(n_rows, n_snaps)}/revision)")
    print(f"  content   : {n_content} unique text versions")
    print(f"  current   : {n_current} live jobs")
    print(f"  db size   : {size_mb:.1f} MB  ({args.db})")
    return 0


def n_snap_jobs(rows: int, snaps: int) -> int:
    try:
        return round(rows / max(snaps, 1))
    except ZeroDivisionError:
        return 0


if __name__ == "__main__":
    sys.exit(main())