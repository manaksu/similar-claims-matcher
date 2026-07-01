-- Facility inpatient (837I) — top 10 similar claims to a seed. DRG-anchored.
-- Revenue codes are a SET -> Jaccard on DISTINCT rev codes (not equality).
-- Line count = TOTAL detail lines (a separate structural signal from the rev-code set).
-- Map placeholders/columns to the data dictionary; tune weights per deployment.

WITH seed AS (
    SELECT * FROM claims WHERE claim_id = :seed_claim
),
seed_rev AS (                              -- seed's DISTINCT revenue-code set
    SELECT DISTINCT rev_code FROM claim_lines WHERE claim_id = :seed_claim
),
seed_card AS (
    SELECT COUNT(*) AS n FROM seed_rev
),
rev_overlap AS (                           -- shared DISTINCT rev codes per candidate
    SELECT l.claim_id, COUNT(DISTINCT l.rev_code) AS inter
    FROM   claim_lines l
    JOIN   seed_rev sr ON l.rev_code = sr.rev_code
    GROUP  BY l.claim_id
),
rev_card AS (                              -- each candidate's DISTINCT rev-code count
    SELECT claim_id, COUNT(DISTINCT rev_code) AS n_rev FROM claim_lines GROUP BY claim_id
),
line_cnt AS (                              -- each claim's TOTAL detail-line count
    SELECT claim_id, COUNT(*) AS n_lines FROM claim_lines GROUP BY claim_id
)
SELECT c.claim_id, c.member_id, c.drg, c.prin_dx, c.prin_pcs, c.tob, c.fac_npi,
       c.stmt_from, c.los, c.total_charge, lc.n_lines,
         (CASE WHEN c.drg      = s.drg      THEN 0.40 ELSE 0 END)
       + (0.15 * COALESCE(ro.inter
                 / NULLIF(sc.n + rc.n_rev - ro.inter, 0), 0))    -- rev-code Jaccard
       + (CASE WHEN c.prin_dx  = s.prin_dx  THEN 0.15 ELSE 0 END)
       + (CASE WHEN c.tob      = s.tob      THEN 0.10 ELSE 0 END)
       + (CASE WHEN c.prin_pcs = s.prin_pcs THEN 0.05 ELSE 0 END)  -- ICD-10-PCS
       + (CASE WHEN c.fac_npi  = s.fac_npi  THEN 0.05 ELSE 0 END)
       + (0.05 * (1 - LEAST(ABS(c.los - s.los), 30) / 30.0))       -- length-of-stay proximity
       + (0.05 * (1 - LEAST(ABS(lc.n_lines - slc.n_lines), 40) / 40.0))  -- line-count proximity
         AS sim_score
FROM   claims c
CROSS JOIN seed s
LEFT JOIN rev_overlap ro  ON ro.claim_id  = c.claim_id
LEFT JOIN rev_card    rc  ON rc.claim_id  = c.claim_id
LEFT JOIN line_cnt    lc  ON lc.claim_id  = c.claim_id
LEFT JOIN line_cnt    slc ON slc.claim_id = s.claim_id
CROSS JOIN seed_card  sc
WHERE  c.claim_id <> s.claim_id
  AND  c.tob = s.tob                        -- candidate pool: same bill type
  AND  c.stmt_from BETWEEN s.stmt_from - 365 AND s.stmt_from + 365
QUALIFY ROW_NUMBER() OVER (ORDER BY sim_score DESC, c.stmt_from DESC) <= 10;
