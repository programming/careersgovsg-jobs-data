-- Number of live postings for an agency at every ingested revision.
-- Usage: python3 sqlite/query.py agency_history --param agency='MAS'
SELECT observed_at, COUNT(*) AS listings
FROM job_snapshots
WHERE agency LIKE '%' || :agency || '%'
GROUP BY observed_at
ORDER BY observed_at;