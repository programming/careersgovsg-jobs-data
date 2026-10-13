-- Live jobs with a published deadline within :days days (default 7).
--
-- "now" is anchored to the latest ingested snapshot rather than wall-clock time,
-- so the window always matches the data revision you actually have (check its age
-- with `stats`). days_left is a calendar-day countdown derived from closing_date;
-- upstream's RemainingDays is NOT a countdown (for hrp it reads like
-- "1 week(s) ago" — time since posting), so it is surfaced as posted_ago.
WITH latest AS (SELECT MAX(observed_at) AS t FROM snapshots)
SELECT
  natural_key,
  agency,
  job_title,
  employment_type,
  location,
  date(closing_date / 1000, 'unixepoch') AS closes_on,
  CAST(julianday(date(closing_date / 1000, 'unixepoch'))
       - julianday(date((SELECT t FROM latest))) AS INTEGER) AS days_left,
  closing_date_text,
  remaining_days AS posted_ago
FROM current_jobs
WHERE closing_date IS NOT NULL
  AND closing_date >= CAST(strftime('%s', (SELECT t FROM latest)) AS INTEGER) * 1000
  AND closing_date <= (
        CAST(strftime('%s', (SELECT t FROM latest)) AS INTEGER)
        + (CASE WHEN :days = '' THEN 7 ELSE CAST(:days AS INTEGER) END) * 86400
      ) * 1000
ORDER BY closing_date;