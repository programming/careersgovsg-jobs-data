-- Live jobs with a published deadline within :days days (default 7).
SELECT
  natural_key,
  agency,
  job_title,
  employment_type,
  location,
  date(closing_date / 1000, 'unixepoch') AS closes_on,
  closing_date_text,
  remaining_days
FROM current_jobs
WHERE closing_date IS NOT NULL
  AND closing_date >= CAST(strftime('%s', 'now') AS INTEGER) * 1000
  AND closing_date <= (
        CAST(strftime('%s', 'now') AS INTEGER)
        + (CASE WHEN :days = '' THEN 7 ELSE CAST(:days AS INTEGER) END) * 86400
      ) * 1000
ORDER BY closing_date;