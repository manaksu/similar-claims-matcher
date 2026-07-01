# Similar Claims Matcher

Given **one seed claim**, return the **top N most similar claims** for analyst
inquiry over a claims warehouse (Teradata). Deterministic, SQL-based, explainable —
not fraud detection, dedup, or auto-adjudication.

## How it works

A **candidate pool** is defined by hard filters (blocking key, claim/bill type, date
window), then a **weighted similarity score** ranks claims within the pool and the top
N are returned. Professional (837P) and Facility (837I) use different parameter sets.

See **[docs/SIMILAR_CLAIMS_MATCHING.md](docs/SIMILAR_CLAIMS_MATCHING.md)** for the full
design reference: method rationale, parameter tables, weights, and Teradata specifics.

## Layout

```
docs/    Design reference (portable — reusable across projects)
sql/     Query templates
           professional_top10.sql          837P
           facility_inpatient_top10.sql    837I inpatient (DRG-anchored)
           facility_outpatient_top10.sql   837I outpatient (rev-code/HCPCS)
src/      App layer (TBD — CLI / notebook / service)
```

## Per-deployment setup

1. Map every `:placeholder` and column name in `sql/` to the proprietary data dictionary.
2. Verify the Teradata blocking key against row-count / skew (`HELP STATISTICS`).
3. Tune the weights (defaults live in the design reference).
4. Decide `ROW_NUMBER` (exactly N) vs `RANK` (top-N incl. ties) and tie-break order.

## Status

Design + SQL templates scaffolded. App layer not yet chosen.
