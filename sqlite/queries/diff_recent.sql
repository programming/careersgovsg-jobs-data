-- Jobs added and removed between the two most recent ingested revisions.
WITH latest AS (SELECT MAX(observed_at) AS t FROM snapshots),
     prev   AS (SELECT MAX(observed_at) AS t FROM snapshots
                WHERE observed_at < (SELECT t FROM latest))
SELECT change, natural_key, job_title, agency, closing_date_text
FROM (
  SELECT 'new' AS change, s.natural_key, s.job_title, s.agency, s.closing_date_text
  FROM job_snapshots s
  WHERE s.observed_at = (SELECT t FROM latest)
    AND s.natural_key NOT IN (
      SELECT natural_key FROM job_snapshots WHERE observed_at = (SELECT t FROM prev))
  UNION ALL
  SELECT 'removed', s.natural_key, s.job_title, s.agency, s.closing_date_text
  FROM job_snapshots s
  WHERE s.observed_at = (SELECT t FROM prev)
    AND s.natural_key NOT IN (
      SELECT natural_key FROM job_snapshots WHERE observed_at = (SELECT t FROM latest))
)
ORDER BY change, agency, job_title;