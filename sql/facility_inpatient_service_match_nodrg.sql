-- Facility inpatient (837I) — MINIMAL service-level match, NO-DRG variant.
-- Use when the data dictionary has no DRG. DRG is derived (grouper output from
-- principal dx + principal ICD-10-PCS + discharge status), so we match on its
-- inputs instead — same split the grouper itself makes:
--   * SURGICAL stay (seed has a principal PCS procedure): service = principal PCS
--   * MEDICAL stay  (no PCS procedure):                   service = principal dx
-- Tiers within the branch:
--   tier 1: same principal dx (and same PCS, for surgical)
--   tier 2: same principal-dx category (ICD-10 first 3 chars)
--   tier 3: same service only (surgical branch: same PCS, any dx)
-- Within a tier, prefer same facility, then most recent.
-- Once DRG lands in the dictionary, switch to facility_inpatient_service_match.sql.

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
      AND  c.stmt_from BETWEEN s.stmt_from - 730 AND s.stmt_from + 730
      -- service identity, branched the way the DRG grouper splits stays:
      AND ( (s.prin_pcs IS NOT NULL AND c.prin_pcs = s.prin_pcs)              -- surgical
         OR (s.prin_pcs IS NULL     AND c.prin_pcs IS NULL
             AND SUBSTR(c.prin_dx, 1, 3) = SUBSTR(s.prin_dx, 1, 3)) )         -- medical
)
SELECT claim_id, member_id, prin_pcs, prin_dx, tob, fac_npi,
       stmt_from, los, total_charge, match_tier
FROM   cand
QUALIFY ROW_NUMBER() OVER (ORDER BY match_tier, fac_pref, stmt_from DESC) <= 10;
