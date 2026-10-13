-- Live listings per source platform in the latest revision.
SELECT platform, COUNT(*) AS listings
FROM current_jobs
GROUP BY platform
ORDER BY listings DESC;