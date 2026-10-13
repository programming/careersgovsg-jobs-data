-- Keyword search across current listings (title, agency, field/industry, full text).
-- Usage: python3 sqlite/query.py search --param q='data analyst'
SELECT
  natural_key,
  platform,
  agency,
  job_title,
  location,
  employment_type,
  substr(trim(job_description), 1, 200) AS snippet
FROM current_jobs
WHERE job_title         LIKE '%' || :q || '%'
   OR agency            LIKE '%' || :q || '%'
   OR industry          LIKE '%' || :q || '%'
   OR field             LIKE '%' || :q || '%'
   OR job_description      LIKE '%' || :q || '%'
   OR job_responsibilities LIKE '%' || :q || '%'
   OR job_requirements     LIKE '%' || :q || '%'
ORDER BY agency, job_title;