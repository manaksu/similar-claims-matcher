-- Facility outpatient (837I) — top 10 similar claims to a seed.
-- Rev-code/HCPCS-anchored (no DRG). Revenue codes are a SET -> Jaccard overlap.
-- Map placeholders/columns to the data dictionary; tune weights per deployment.

WITH seed AS (
    SELECT * FROM claims WHERE claim_id = :seed_claim
),
seed_rev AS (
    SELECT rev_code FROM claim_lines WHERE claim_id = :seed_claim
),
seed_card AS (
    SELECT COUNT(*) AS n FROM seed_rev
),
rev_overlap AS (
    SELECT l.claim_id, COUNT(*) AS inter
    FROM   claim_lines l
    JOIN   seed_rev sr ON l.rev_code = sr.rev_code
    GROUP  BY l.claim_id
),
cand_card AS (
    SELECT claim_id, COUNT(*) AS n FROM claim_lines GROUP BY claim_id
)
SELECT c.claim_id, c.member_id, c.hcpcs, c.prin_dx, c.tob, c.fac_npi,
       c.stmt_from, c.total_charge,
         (CASE WHEN c.hcpcs   = s.hcpcs   THEN 0.30 ELSE 0 END)
       + (0.25 * COALESCE(ro.inter
                 / NULLIF(sc.n + cc.n - ro.inter, 0), 0))     -- rev-code Jaccard
       + (CASE WHEN c.prin_dx = s.prin_dx THEN 0.15 ELSE 0 END)
       + (CASE WHEN c.tob     = s.tob     THEN 0.15 ELSE 0 END)
       + (CASE WHEN c.fac_npi = s.fac_npi THEN 0.05 ELSE 0 END)
       + (0.10 * (1 - LEAST(ABS(c.total_charge - s.total_charge)
                     / NULLIF(GREATEST(c.total_charge, s.total_charge), 0), 1)))
         AS sim_score
FROM   claims c
CROSS JOIN seed s
LEFT JOIN rev_overlap ro ON ro.claim_id = c.claim_id
LEFT JOIN cand_card   cc ON cc.claim_id = c.claim_id
CROSS JOIN seed_card  sc
WHERE  c.claim_id <> s.claim_id
  AND  c.tob = s.tob                        -- candidate pool
  AND  c.stmt_from BETWEEN s.stmt_from - 365 AND s.stmt_from + 365
QUALIFY ROW_NUMBER() OVER (ORDER BY sim_score DESC, c.stmt_from DESC) <= 10;
