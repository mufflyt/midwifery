# Canonical source-record schema (13 fields, long format)

Every longitudinal source in this project emits its own npi/year/state file
with its own column names, its own date semantics, and its own idea of what a
row IS. The state-source audit normalizes them at consumption time; this is
the schema they are normalized INTO. `build_canonical_source_records.R`
produces `artifacts/canonical_source_records.csv` in this shape.

One row = one source's claim that a provider was associated with one state in
one period. The 13 fields:

| # | field | type | meaning |
|---|-------|------|---------|
| 1 | `amcb_id` | character | AMCB certification number, joined through the frozen linkage; empty for sources keyed only by NPI |
| 2 | `npi` | character | National Provider Identifier, 10 digits |
| 3 | `source` | character | source id, same vocabulary as `config/state_source_audit_sources.csv` |
| 4 | `source_record_id` | character | the source's own row identifier when it publishes one (PPEF `enrlmt_id`, T-MSIS segment id); empty when the source has none |
| 5 | `year` | integer | program year the claim applies to |
| 6 | `state` | character | cleaned US state/territory abbreviation (`R/lib/clean_state.R`) |
| 7 | `evidence_type` | character | `observed` (dated claim in the file), `administrative` (enrollment/registration presence, not activity), `retrospective` (linked through a later vintage — e.g. Open Payments 2013–2014 via the profile lookup), `derived` (computed, e.g. lineage-collapsed medicare_claims) |
| 8 | `snapshot_date` | character (ISO) | when the source FILE was published/taken — the vintage date; empty where the source publishes none |
| 9 | `effective_date` | character (ISO) | when the claim was true — claim month, enrollment segment start; distinct from snapshot_date, and the distinction is what separates reporting delay from retrospective dating |
| 10 | `vintage` | character | the producer-declared vintage label (e.g. `pl_pfile 2026-08-09`, `PY2021`); never a bare filename year |
| 11 | `usable_for_trend` | logical | whether this row may carry a longitudinal claim (Open Payments <PY2021 = FALSE; T-MSIS 2013–2017 left-censored = FALSE) |
| 12 | `source_hash` | character | sha256 of the raw input file, from the artifact's provenance sidecar where tracked |
| 13 | `reconstruction_version` | character | the builder's own version stamp (`canonical_v1`), so rows built under different collapse/reduction rules can never be silently pooled |

## Rules the schema enforces

- **A row names ONE state.** Multiplicity stays a separate fact of the
  source, never a row shape. Sources with genuine multi-state claims
  (T-MSIS concurrent enrollment) keep one row per state per year; the
  reduction-to-one question is the CONSUMER's, not the schema's.
- **`snapshot_date` and `effective_date` are never merged.** A file published
  in 2026 describing 2018 is retrospective evidence; conflating them is what
  turned T-MSIS into "the bad source".
- **Missing is NA, never invented.** A source that publishes no date field
  gets empty `snapshot_date`/`effective_date`, not a guess.
- **`source` vocabulary is the manifest's.** No new spellings.
