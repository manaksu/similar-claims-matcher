-- Facility inpatient (837I) — MINIMAL service-level match. Recommended default.
-- Inpatient "service identity" = DRG (the stay's clinical grouping).
-- Tiered fallback:
--   tier 1: same DRG + same principal diagnosis
--   tier 2: same DRG + same principal-dx category (ICD-10 first 3 chars)
--   tier 3: same DRG only
-- Within a tier, prefer same facility, then most recent.

WITH seed AS (
    SELECT * FROM claims WHERE claim_id = :seed_claim
),
cand AS (
    SELECT c.*,
           CASE WHEN c.prin_dx = s.prin_dx                             THEN 1
                WHEN SUBSTR(c.prin_dx, 1, 3) = SUBSTR(s.prin_dx, 1, 3) THEN 2
                ELSE 3
           END AS match_tier,
           CASE WHEN c.fac_npi = s.fac_npi THEN 0 ELSE 1 END AS fac_pref
    FROM   claims c
    CROSS JOIN seed s
    WHERE  c.claim_id <> s.claim_id
      AND  c.tob      = s.tob                    -- same bill type
      AND  c.drg      = s.drg                    -- the service: always required
      AND  c.stmt_from BETWEEN s.stmt_from - 730 AND s.stmt_from + 730
)
SELECT claim_id, member_id, drg, prin_dx, tob, fac_npi,
       stmt_from, los, total_charge, match_tier
FROM   cand
QUALIFY ROW_NUMBER() OVER (ORDER BY match_tier, fac_pref, stmt_from DESC) <= 10;
