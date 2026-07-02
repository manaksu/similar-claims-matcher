# Similar Claims Matching — Design Reference

A reusable spec for a **"claim in hand → N most similar claims"** inquiry tool over a
claims warehouse (Teradata). Deterministic, SQL-based, explainable. Covers both
**Professional (837P / CMS-1500)** and **Facility (837I / UB-04)** claims.

> Use case: an analyst has **one seed claim** and wants the **top 10 similar claims**
> for inquiry/review. Not fraud modeling, not dedup, not auto-adjudication — just
> retrieval of comparable claims.

This document is self-contained: it includes the full SQL for every template.
Column names (`proc_code`, `dx1`, `prin_dx`, `tob`, …) and `:placeholders` are
illustrative — map them to the deployment's data dictionary.

---

## 1. Method decision — and why

**Deterministic, in-database SQL** (not ML), because:

- **Inquiry must be explainable** — the analyst has to be able to say *why* these
  claims are "similar." A readable score/`WHERE` beats a black-box distance.
- **No labeled training data needed** — ML similarity earns its keep for fraud /
  non-obvious linkage. For "claims like this one," it's overkill.
- **Push the work to the data** — Teradata is MPP. Matching in SQL means you never
  extract millions of rows to score them client-side.

**Two match modes ship side by side:**

| Mode | Templates | When to use |
|---|---|---|
| **A — Service-level match** (recommended default) | §3 | Everyday inquiry. Similar = same service for the same reason. Explainable in one sentence. |
| **B — Weighted score** | §4–5 | When finer ranking is needed (many near-identical candidates, or "similar" must weigh provider/amount/structure). |

**Routing:** the seed claim's type selects the template — 837P → professional;
837I with inpatient Type of Bill → inpatient; otherwise → outpatient.

---

## 2. Claim-family fundamentals

Professional claims key off a **single procedure + rendering provider + POS**.
Facility claims have **no single procedure spine** — they're organized around:

- **Type of Bill (TOB)** — master grouping (facility type + bill class + frequency).
- **Revenue codes** — line-level department/service; a claim is a *set* of them.
- **DRG** — dominant similarity field for **inpatient** (see the no-DRG variant, §3.3).
- **ICD-10-PCS** (inpatient) vs **HCPCS/CPT + revenue code** (outpatient).
- Admission/discharge, **length of stay**, admission type/source, discharge status, POA.
- **Facility/billing NPI + attending provider** instead of one rendering provider.

Demographics (age/sex/member attributes) are deliberately **not** match parameters —
the procedure already implies the relevant demographics.

---

## 3. Mode A — service-level match (recommended default)

Similar = **same service (procedure / DRG / HCPCS) for the same reason (diagnosis)**.
No weights, no tuning.

Exact service + dx can be *too* selective (rare combos) or leave thousands of ties
(common combos). Both are solved by a **match tier** computed in one scan:

- **tier 1** — same service + same diagnosis
- **tier 2** — same service + same diagnosis *category* (ICD-10 first 3 chars)
- **tier 3** — same service only

`ORDER BY match_tier, <preference>, date DESC` fills the top 10 from the tightest
tier down — rare combos never come back empty; common combos break ties by
preference (same provider/facility first) then recency. The service field is always
a hard requirement; only the diagnosis loosens. The returned `match_tier` column
shows the analyst *how* similar each row is.

### 3.1 Professional (837P)

```sql
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
```

### 3.2 Facility inpatient (837I) — DRG-based

```sql
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
```

### 3.3 Facility inpatient (837I) — no-DRG variant

DRG is *derived* — a grouper assigns it from principal dx + principal ICD-10-PCS +
discharge status. If the data dictionary has no DRG, match on its **inputs**,
branched the same way the grouper splits stays: **surgical** (principal PCS present)
→ service = principal PCS; **medical** (no PCS) → service = principal-dx category.
Switch to §3.2 once DRG is available.

```sql
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
      AND ( (s.prin_pcs IS NOT NULL AND c.prin_pcs = s.prin_pcs)          -- surgical
         OR (s.prin_pcs IS NULL     AND c.prin_pcs IS NULL
             AND SUBSTR(c.prin_dx, 1, 3) = SUBSTR(s.prin_dx, 1, 3)) )     -- medical
)
SELECT claim_id, member_id, prin_pcs, prin_dx, tob, fac_npi,
       stmt_from, los, total_charge, match_tier
FROM   cand
QUALIFY ROW_NUMBER() OVER (ORDER BY match_tier, fac_pref, stmt_from DESC) <= 10;
```

### 3.4 Facility outpatient (837I)

```sql
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
      AND  c.hcpcs    = s.hcpcs                  -- the service: always required
      AND  c.stmt_from BETWEEN s.stmt_from - 730 AND s.stmt_from + 730
)
SELECT claim_id, member_id, hcpcs, prin_dx, tob, fac_npi,
       stmt_from, total_charge, match_tier
FROM   cand
QUALIFY ROW_NUMBER() OVER (ORDER BY match_tier, fac_pref, stmt_from DESC) <= 10;
```

---

## 4. Mode B — weighted score: parameters

Pattern: hard filters define a **candidate pool**, then a **weighted score** ranks
within it and you keep the top N.

**Rule of thumb for placing a parameter:**
- Non-match should **exclude** the claim → it's a **hard filter**.
- Non-match should just **rank it lower** → it's a **score term**.
- (A field can be both: filter to the *family*, score the *exact* value within it.)

### Candidate-pool filters (hard `WHERE`, high selectivity)
Align these to the **Primary Index / partitioning** so the pool stays AMP-local.

| Filter | Professional | Facility |
|---|---|---|
| Blocking key (highest-cardinality) | Provider NPI *or* procedure code | Facility NPI *or* revenue code |
| Claim type / bill class | Claim type (837P) | **Type of Bill (TOB)** |
| Date window | DOS ± N days (partition-aligned) | Statement-from/thru ± N days |
| Member scope | exclude-self / same-member / population | same |

### Ranking terms (weighted score within the pool)

| Parameter | Professional | Facility — Inpatient | Facility — Outpatient |
|---|---|---|---|
| **DRG** (MS-/APR-) | — | **0.40** | — |
| Procedure (CPT/HCPCS, or ICD-10-PCS) | 0.30 | 0.05 (principal PCS) | 0.30 (HCPCS) |
| **Revenue-code set** (Jaccard) | — | 0.15 | 0.25 |
| Diagnosis (principal / set overlap) | 0.25 | 0.15 | 0.15 |
| **Type of Bill** | — | 0.10 | 0.15 |
| Provider (NPI → specialty fallback) | 0.20 | 0.05 | 0.05 |
| Place of Service | 0.10 | — | — |
| **Line count** proximity | 0.05 | 0.05 | 0.05 |
| Length of stay proximity | — | 0.05 | — |
| Temporal / billed-amount closeness | 0.10 | — | 0.05 |

Weights are starting defaults, each column sums to 1.0 — tune against real data.
If DRG is unavailable, drop the 0.40 DRG term and redistribute across principal
PCS, diagnosis, and the revenue-code Jaccard.

**Line count** = number of service/detail lines on the claim (professional service
lines; facility revenue-code lines). It captures encounter *scope/complexity* — a
3-line claim vs a 40-line claim are structurally different even when the codes match.
Scored as proximity (closer counts → higher score), capped so large gaps saturate.

**Facility structural implications:**
1. **Revenue codes are a set** → **Jaccard overlap** on DISTINCT codes from
   normalized line rows (`intersect / union`), not scalar equality. Line count uses
   *total* lines — a separate signal from the code set.
2. **Fork by TOB** — the seed's Type of Bill selects inpatient vs outpatient weights.

---

## 5. Mode B — weighted score: templates

### 5.1 Professional (837P)

```sql
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
```

### 5.2 Facility inpatient (837I)

```sql
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
```

### 5.3 Facility outpatient (837I)

```sql
WITH seed AS (
    SELECT * FROM claims WHERE claim_id = :seed_claim
),
seed_rev AS (
    SELECT DISTINCT rev_code FROM claim_lines WHERE claim_id = :seed_claim
),
seed_card AS (
    SELECT COUNT(*) AS n FROM seed_rev
),
rev_overlap AS (
    SELECT l.claim_id, COUNT(DISTINCT l.rev_code) AS inter
    FROM   claim_lines l
    JOIN   seed_rev sr ON l.rev_code = sr.rev_code
    GROUP  BY l.claim_id
),
rev_card AS (
    SELECT claim_id, COUNT(DISTINCT rev_code) AS n_rev FROM claim_lines GROUP BY claim_id
),
line_cnt AS (
    SELECT claim_id, COUNT(*) AS n_lines FROM claim_lines GROUP BY claim_id
)
SELECT c.claim_id, c.member_id, c.hcpcs, c.prin_dx, c.tob, c.fac_npi,
       c.stmt_from, c.total_charge, lc.n_lines,
         (CASE WHEN c.hcpcs   = s.hcpcs   THEN 0.30 ELSE 0 END)
       + (0.25 * COALESCE(ro.inter
                 / NULLIF(sc.n + rc.n_rev - ro.inter, 0), 0))    -- rev-code Jaccard
       + (CASE WHEN c.prin_dx = s.prin_dx THEN 0.15 ELSE 0 END)
       + (CASE WHEN c.tob     = s.tob     THEN 0.15 ELSE 0 END)
       + (CASE WHEN c.fac_npi = s.fac_npi THEN 0.05 ELSE 0 END)
       + (0.05 * (1 - LEAST(ABS(lc.n_lines - slc.n_lines), 40) / 40.0))  -- line-count proximity
       + (0.05 * (1 - LEAST(ABS(c.total_charge - s.total_charge)
                     / NULLIF(GREATEST(c.total_charge, s.total_charge), 0), 1)))
         AS sim_score
FROM   claims c
CROSS JOIN seed s
LEFT JOIN rev_overlap ro  ON ro.claim_id  = c.claim_id
LEFT JOIN rev_card    rc  ON rc.claim_id  = c.claim_id
LEFT JOIN line_cnt    lc  ON lc.claim_id  = c.claim_id
LEFT JOIN line_cnt    slc ON slc.claim_id = s.claim_id
CROSS JOIN seed_card  sc
WHERE  c.claim_id <> s.claim_id
  AND  c.tob = s.tob                        -- candidate pool
  AND  c.stmt_from BETWEEN s.stmt_from - 365 AND s.stmt_from + 365
QUALIFY ROW_NUMBER() OVER (ORDER BY sim_score DESC, c.stmt_from DESC) <= 10;
```

---

## 6. Teradata specifics

- **Blocking = the Primary Index.** Choose a high-cardinality, low-skew blocking key
  (provider NPI or procedure/revenue code) so the candidate scan is AMP-local, not a
  redistribute. Biggest performance lever — check `HELP STATISTICS` / row counts first.
- **Partition on date of service (PPI)** — almost every filter is a DOS window.
- **Fuzzy identity fields** (name/address): `SOUNDEX`, `NGram`, `EDITDISTANCE`
  (td_sysfnlib) — no external tooling needed.
- **Set overlap**: normalize/unpivot line-level codes (`TD_UNPIVOT`) so Jaccard is a
  join+count, not runtime string parsing.
- **Top-N**: `QUALIFY ROW_NUMBER() OVER (ORDER BY … DESC) <= 10`.
  Use `RANK()` if you want ties surfaced (may return 11–12 rows — often more
  defensible for inquiry). Tie-break default: date DESC (freshest first).

---

## 7. Open decisions (per deployment)

- [ ] Map every `:placeholder` / column to the proprietary data dictionary.
- [ ] Confirm whether institutional claims carry principal ICD-10-PCS (needed for
      the no-DRG inpatient variant, §3.3).
- [ ] Line-count source: computed from the line table, or a stored header column.
- [ ] Blocking key — verify cardinality/skew on the real table before locking.
- [ ] `ROW_NUMBER` (exactly 10) vs `RANK` (top-10 incl. ties).
- [ ] Tie-break order (recency default).
- [ ] Mode B caps (line count 25/40, LOS 30, date 365) — set from real distributions.

---

*Reusable across projects — copy this file in and fill the data-dictionary column
names + weights per deployment.*
