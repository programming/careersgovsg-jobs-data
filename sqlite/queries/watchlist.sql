-- Your tracked applications, optionally filtered by status.
-- Usage: python3 sqlite/query.py watchlist --param status=applied
SELECT
  w.status,
  w.natural_key,
  j.agency,
  j.job_title,
  j.closing_date_text,
  w.notes,
  w.added_on
FROM watchlist w
LEFT JOIN current_jobs j ON j.natural_key = w.natural_key
WHERE (:status = '' OR w.status = :status)
ORDER BY w.status, j.closing_date;