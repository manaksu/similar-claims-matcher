# Similar Claims Matching — Design Reference

A reusable spec for a **"claim in hand → N most similar claims"** inquiry tool over a
claims warehouse (Teradata). Deterministic, SQL-based, explainable. Covers both
**Professional (837P / CMS-1500)** and **Facility (837I / UB-04)** claims.

> Use case this is designed for: an analyst has **one seed claim** and wants the
> **top 10 similar claims** for inquiry/review. Not fraud modeling, not dedup, not
> auto-adjudication — just retrieval of comparable claims.

---

## 1. Method decision — and why

**Deterministic, in-database SQL** (not ML), because:

- **Inquiry must be explainable** — the analyst has to be able to say *why* these
  claims are "similar." A readable score/`WHERE` beats a black-box distance.
- **No labeled training data needed** — ML similarity earns its keep for fraud /
  non-obvious linkage. For "claims like this one," it's overkill.
- **Push the work to the data** — Teradata is MPP. Matching in SQL means you never
  extract millions of rows to score them client-side.

Pattern = **both**: hard filters define a **candidate pool**, then a **weighted
score** ranks within it and you keep the top N.

**Rule of thumb for placing a parameter:**
- Non-match should **exclude** the claim → it's a **hard filter**.
- Non-match should just **rank it lower** → it's a **score term**.
- (A field can be both: filter to the *family*, score the *exact* value within it.)

---

## 2. Parameters

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
| Procedure (CPT/HCPCS, or ICD-10-PCS) | 0.35 | 0.10 (PCS overlap) | 0.30 (HCPCS) |
| **Revenue-code set** (Jaccard) | — | 0.15 | 0.25 |
| Diagnosis (principal / set overlap) | 0.25 | 0.15 | 0.15 |
| **Type of Bill** | — | 0.10 | 0.15 |
| Provider (NPI → specialty fallback) | 0.20 | 0.05 | 0.05 |
| Place of Service | 0.10 | — | — |
| Length of stay proximity | — | 0.05 | — |
| Temporal / billed-amount closeness | 0.10 | — | 0.10 |

Weights are starting defaults — tune against real data.

---

## 3. Professional template (837P)

```sql
WITH seed AS (                          -- the claim in hand
    SELECT * FROM claims WHERE claim_id = :seed_claim
)
SELECT c.claim_id, c.member_id, c.proc_code, c.dx1, c.npi, c.pos,
       c.dos, c.billed_amt,
         (CASE WHEN c.proc_code = s.proc_code THEN 0.35 ELSE 0 END)
       + (CASE WHEN c.dx1        = s.dx1        THEN 0.25 ELSE 0 END)
       + (CASE WHEN c.npi        = s.npi        THEN 0.20
              WHEN c.specialty   = s.specialty  THEN 0.10 ELSE 0 END)
       + (CASE WHEN c.pos        = s.pos        THEN 0.10 ELSE 0 END)
       + (0.05 * (1 - LEAST(ABS(c.dos - s.dos), 365) / 365.0))
       + (0.05 * (1 - LEAST(ABS(c.billed_amt - s.billed_amt)
                     / NULLIF(GREATEST(c.billed_amt, s.billed_amt),0), 1)))
         AS sim_score
FROM   claims c
CROSS JOIN seed s
WHERE  c.claim_id <> s.claim_id
  AND  c.claim_type = s.claim_type              -- candidate pool
  AND  c.proc_code IN (/* seed procedure family */)
  AND  c.dos BETWEEN s.dos - 365 AND s.dos + 365
QUALIFY ROW_NUMBER() OVER (ORDER BY sim_score DESC) <= 10;
```

---

## 4. Facility variant (837I) — key differences

Facility claims have **no single procedure spine**. They're organized around:

- **Type of Bill (TOB)** — master grouping (facility type + bill class + frequency).
- **Revenue codes** — line-level department/service; a claim is a *set* of them.
- **DRG** — dominant similarity field for **inpatient**.
- **ICD-10-PCS** (inpatient) vs **HCPCS/CPT + revenue code** (outpatient).
- Admission/discharge, **length of stay**, admission type/source, discharge status, POA.
- **Facility/billing NPI + attending provider** instead of one rendering provider.

**Two structural implications:**
1. **Revenue codes are a set** → use **Jaccard overlap** on normalized line rows
   (`intersect_count / union_count`), not scalar equality. Same technique for
   multi-diagnosis overlap.
2. **Fork by TOB** — the seed's Type of Bill selects inpatient vs outpatient weights.
   Cleanest as two sibling queries, or one query with a `CASE`-driven weight block.

### Revenue-code Jaccard sketch
```sql
-- normalize claim -> one row per (claim_id, rev_code), then:
, seed_rev AS (SELECT rev_code FROM claim_lines WHERE claim_id = :seed_claim)
, overlap AS (
    SELECT l.claim_id,
           COUNT(*) AS inter                       -- shared rev codes
    FROM claim_lines l
    JOIN seed_rev sr ON l.rev_code = sr.rev_code
    GROUP BY l.claim_id
)
-- jaccard = inter / (seed_card + cand_card - inter)
```

---

## 5. Teradata specifics

- **Blocking = the Primary Index.** Choose a high-cardinality, low-skew blocking key
  (provider NPI or procedure/revenue code) so the candidate scan is AMP-local, not a
  redistribute. Biggest performance lever — check `HELP STATISTICS` / row counts first.
- **Partition on date of service (PPI)** — almost every filter is a DOS window.
- **Fuzzy identity fields** (name/address): `SOUNDEX`, `NGram`, `EDITDISTANCE`
  (td_sysfnlib) — no external tooling needed.
- **Set overlap**: normalize/unpivot line-level codes (`TD_UNPIVOT`) so Jaccard is a
  join+count, not runtime string parsing.
- **Top-N**: `QUALIFY ROW_NUMBER() OVER (ORDER BY sim_score DESC) <= 10`.
  Use `RANK()` if you want ties surfaced (may return 11–12 rows — often more
  defensible for inquiry). Tie-break default: `dos DESC` (freshest first).

---

## 6. Open decisions (per deployment)

- [ ] Blocking key — verify cardinality/skew on the real table before locking.
- [ ] `ROW_NUMBER` (exactly 10) vs `RANK` (top-10 incl. ties).
- [ ] Tie-break order (recency default).
- [ ] Facility: separate templates vs one unified builder branching on TOB.
- [ ] Map every `:placeholder` / column to the proprietary data dictionary.

---

*Reusable across projects — copy this file in and fill the data-dictionary column
names + weights per deployment.*
