# Similar Claims Matcher

Given **one seed claim**, return the **top N most similar claims** for analyst
inquiry over a claims warehouse (Teradata). Deterministic, SQL-based, explainable —
not fraud detection, dedup, or auto-adjudication.

## How it works

Two match modes, side by side:

- **Service-level match** (recommended default): similar = **same service for the
  same reason** — procedure/DRG/HCPCS + diagnosis, with a tiered diagnosis fallback
  so rare combos never come back empty. No weights, explainable in one sentence.
- **Weighted score**: hard filters define a **candidate pool**, then a weighted
  similarity score ranks within it. Use when finer ranking is needed.

Professional (837P) and Facility (837I) use different parameter sets. See
**[docs/SIMILAR_CLAIMS_MATCHING.md](docs/SIMILAR_CLAIMS_MATCHING.md)** for the full
design reference: both modes, parameter tables, weights, and Teradata specifics.

## Layout

```
docs/    Design reference (portable — reusable across projects)
sql/     Query templates
           # Mode A — service-level match (default)
           professional_service_match.sql          837P: proc + dx tiers
           facility_inpatient_service_match.sql    837I IP: DRG + dx tiers
           facility_outpatient_service_match.sql   837I OP: HCPCS + dx tiers
           # Mode B — weighted score
           professional_top10.sql                  837P
           facility_inpatient_top10.sql            837I inpatient (DRG-anchored)
           facility_outpatient_top10.sql           837I outpatient (rev-code/HCPCS)
src/      App layer (TBD — CLI / notebook / service)
```

## Per-deployment setup

1. Map every `:placeholder` and column name in `sql/` to the proprietary data dictionary.
2. Verify the Teradata blocking key against row-count / skew (`HELP STATISTICS`).
3. Tune the weights (defaults live in the design reference).
4. Decide `ROW_NUMBER` (exactly N) vs `RANK` (top-N incl. ties) and tie-break order.

## Status

Design + SQL templates scaffolded. App layer not yet chosen.
