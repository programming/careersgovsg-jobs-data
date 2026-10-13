-- Latest revision: newest jobs first, then alphabetically by agency.
SELECT
  natural_key,
  platform,
  agency,
  job_title,
  employment_type,
  work_arrangement,
  location,
  closing_date_text,
  is_new
FROM current_jobs
ORDER BY is_new DESC, agency, job_title;