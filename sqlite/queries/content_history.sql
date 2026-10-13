-- Distinct content versions recorded for one posting, oldest first.
-- A hash can reappear later (text reverted); order here is by first appearance.
-- Usage: python3 sqlite/query.py content_history --param natural_key='hrp|17643792|...'
SELECT
  first_seen,
  last_seen,
  content_hash,
  length(job_description) AS desc_len,
  substr(job_description, 1, 120) AS desc_preview
FROM job_content
WHERE natural_key = :natural_key
ORDER BY first_seen;