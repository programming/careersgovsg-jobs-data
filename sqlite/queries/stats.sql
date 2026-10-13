-- Warehouse coverage summary.
SELECT
  (SELECT COUNT(*) FROM snapshots)          AS snapshots,
  (SELECT MIN(observed_at) FROM snapshots)  AS first_observed,
  (SELECT MAX(observed_at) FROM snapshots)  AS last_observed,
  (SELECT COUNT(*) FROM job_snapshots)      AS job_rows,
  (SELECT COUNT(*) FROM job_content)        AS content_versions,
  (SELECT COUNT(*) FROM current_jobs)       AS current_jobs;