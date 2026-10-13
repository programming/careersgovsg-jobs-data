-- Full revision history of one posting (how its trackable fields changed).
-- Usage: python3 sqlite/query.py lifecycle --param natural_key='hrp|17643792|...'
SELECT
  observed_at,
  platform,
  job_title,
  agency,
  closing_date_text,
  remaining_days AS posted_ago,  -- upstream relative text (time since posting), not a countdown
  is_new,
  employment_type
FROM job_snapshots
WHERE natural_key = :natural_key
ORDER BY observed_at;