-- Listings per field in the earliest vs latest ingested revision.
WITH first AS (SELECT MIN(observed_at) AS t FROM snapshots),
     last  AS (SELECT MAX(observed_at) AS t FROM snapshots),
     f AS (
       SELECT field, COUNT(*) AS n FROM job_snapshots
       WHERE observed_at = (SELECT t FROM first) AND field <> '' GROUP BY field),
     l AS (
       SELECT field, COUNT(*) AS n FROM job_snapshots
       WHERE observed_at = (SELECT t FROM last) AND field <> '' GROUP BY field),
     keys AS (SELECT field FROM f UNION SELECT field FROM l)
SELECT
  k.field,
  COALESCE(f.n, 0) AS first_count,
  COALESCE(l.n, 0) AS latest_count,
  COALESCE(l.n, 0) - COALESCE(f.n, 0) AS change
FROM keys k
LEFT JOIN f ON f.field = k.field
LEFT JOIN l ON l.field = k.field
ORDER BY latest_count DESC;