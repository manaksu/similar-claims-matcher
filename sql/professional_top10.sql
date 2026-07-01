-- Professional (837P) — top 10 claims most similar to a seed claim.
-- Map placeholders/columns to the data dictionary; tune weights per deployment.
-- Pattern: seed CTE -> candidate-pool filters -> weighted score -> top N.

WITH seed AS (                          -- the claim in hand
    SELECT * FROM claims WHERE claim_id = :seed_claim
),
line_cnt AS (                           -- service-line count per claim
    SELECT claim_id, COUNT(*) AS n_lines
    FROM   claim_lines
    GROUP  BY claim_id
    -- If `claims` already stores a line count, drop this CTE and use that column.
)
SELECT c.claim_id, c.member_id, c.proc_code, c.dx1, c.npi, c.pos,
       c.dos, c.billed_amt, lc.n_lines,
         (CASE WHEN c.proc_code = s.proc_code THEN 0.30 ELSE 0 END)
       + (CASE WHEN c.dx1        = s.dx1        THEN 0.25 ELSE 0 END)
       + (CASE WHEN c.npi        = s.npi        THEN 0.20
              WHEN c.specialty   = s.specialty  THEN 0.10 ELSE 0 END)
       + (CASE WHEN c.pos        = s.pos        THEN 0.10 ELSE 0 END)
       + (0.05 * (1 - LEAST(ABS(lc.n_lines - slc.n_lines), 25) / 25.0))  -- line-count proximity
       + (0.05 * (1 - LEAST(ABS(c.dos - s.dos), 365) / 365.0))
       + (0.05 * (1 - LEAST(ABS(c.billed_amt - s.billed_amt)
                     / NULLIF(GREATEST(c.billed_amt, s.billed_amt), 0), 1)))
         AS sim_score
FROM   claims c
CROSS JOIN seed s
LEFT JOIN line_cnt lc  ON lc.claim_id  = c.claim_id
LEFT JOIN line_cnt slc ON slc.claim_id = s.claim_id
WHERE  c.claim_id <> s.claim_id
  AND  c.claim_type = s.claim_type              -- candidate pool
  AND  c.proc_code IN (/* seed procedure family */)
  AND  c.dos BETWEEN s.dos - 365 AND s.dos + 365
-- Use RANK() instead of ROW_NUMBER() to surface ties (may return >10 rows).
QUALIFY ROW_NUMBER() OVER (ORDER BY sim_score DESC, c.dos DESC) <= 10;
