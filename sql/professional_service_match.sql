-- Professional (837P) — MINIMAL service-level match. Recommended default for inquiry.
-- Similar = same service (procedure) for the same reason (diagnosis).
-- Tiered fallback fills the 10 from the tightest tier down, so rare combos
-- never come back empty:
--   tier 1: same procedure + same diagnosis
--   tier 2: same procedure + same diagnosis category (ICD-10 first 3 chars)
--   tier 3: same procedure only
-- Within a tier, prefer same provider, then most recent.

WITH seed AS (
    SELECT * FROM claims WHERE claim_id = :seed_claim
),
cand AS (
    SELECT c.*,
           CASE WHEN c.dx1 = s.dx1                             THEN 1
                WHEN SUBSTR(c.dx1, 1, 3) = SUBSTR(s.dx1, 1, 3) THEN 2
                ELSE 3
           END AS match_tier,
           CASE WHEN c.npi = s.npi THEN 0 ELSE 1 END AS prov_pref
    FROM   claims c
    CROSS JOIN seed s
    WHERE  c.claim_id  <> s.claim_id
      AND  c.claim_type = s.claim_type          -- never mix 837P/837I
      AND  c.proc_code  = s.proc_code           -- the service: always required
      AND  c.dos BETWEEN s.dos - 730 AND s.dos + 730
)
SELECT claim_id, member_id, proc_code, dx1, npi, pos, dos, billed_amt, match_tier
FROM   cand
QUALIFY ROW_NUMBER() OVER (ORDER BY match_tier, prov_pref, dos DESC) <= 10;
