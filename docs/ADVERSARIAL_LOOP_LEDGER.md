# Adversarial testing loop — cumulative ledger

Cycles of 10 new tests each (rotating 4/3/3, 3/4/3, 3/3/4 across
BVA / semantic / adversarial). Later cycles must consult this ledger and
exercise a genuinely different assumption, not a variant of one already here.

Rule in force: **when a defect is found, search for the same defect class
elsewhere before considering it resolved.**

---

## Cycle 1 — 2026-08-09 21:5x — 4 BVA / 3 semantic / 3 adversarial

**Targets.** Banding and date parsing behind Table 1. Rurality is the
stratifier for the access findings; enumeration year drives two of the six
characteristic blocks. A silent misclassification here changes a published
table.

**Tests added** — `tests/test_table1_bands.R`

| # | Category | Assumption challenged |
|---|---|---|
| T1 | BVA | band edges closed on the left at 5/10/15/20 |
| T2 | BVA | one panel appearance is 1 year, not 0 (inclusive span) |
| T3 | BVA | RUCC 0/10/99/NA are unclassifiable, not "remote" |
| T4 | BVA | NA/Inf/NaN/negative/out-of-window never reach a band |
| T5 | semantic | ISO and US dates for the same day give the same year |
| T6 | semantic | every band label bounds the values assigned to it |
| T7 | semantic | bands partition the domain (no gap, no overlap) |
| T8 | adversarial | conflicting duplicate FIPS error; identical ones collapse |
| T9 | adversarial | banding invariant to row order |
| T10 | adversarial | character and factor codes band as numeric does |

**Defects found — 3 classes, all latent on current data, none previously
detectable.** Each held only because the current artifacts satisfy an
assumption the code never enforced.

1. **Out-of-range codes labelled, not rejected.** `case_when(..., TRUE ~
   "Nonmetropolitan, remote")` gives every unexpected code a confident label.
   Verified against the old implementation: `rucc = 0` → **"Metropolitan"**,
   `rucc = 10` and `99` → **"remote"**. A future RUCC vintage using a sentinel
   such as 99 for "not classified" would publish those counties as rural.

2. **Positional year parsing.** `str_sub(..., -4)` takes the last four digit
   characters, so ISO `2007-05-12` parses to **512**, fails the plausibility
   window, and becomes NA. NPPES has shipped both formats. An ISO export would
   null out enumeration year for the entire cohort while looking like ordinary
   missingness.

3. **Factor → level index.** `as.integer(factor("7"))` is **2**, not 7. A
   genuinely remote county would be published as metropolitan. readxl/readr
   return factors under some options, so this needs no upstream change to fire.

**Same-class sweep (the instruction that matters).** The RUCC rule existed in
**three** copies with the same defect:

- `build_table1_midwives.R` — fixed
- `represented_subset_access.R:97` — fixed (also its duplicate RUCC lookup)
- `characterize_isochrone_representation.R:71` — fixed

Two label vocabularies were in use ("Metropolitan" vs "Metro"), so
`band_rurality()` takes a `labels` argument; published wording is unchanged
rather than silently unified.

**Fixes.** Rules extracted to `R/lib/table1_bands.R`
(`parse_enum_year`, `band_years_since_enum`, `band_years_observed`,
`band_rurality`, `build_rucc_lookup`), which validate rather than assume.
`build_rucc_lookup()` refuses to resolve a conflicting duplicate FIPS by row
order — the old `distinct(county, .keep_all = TRUE)` let file sort order decide
whether a county was metropolitan.

**Anti-ceremony check.** New tests were run against the ORIGINAL inline
implementations to confirm they discriminate: T3, T5 and T10 all fail the old
code. A test that passes both versions proves nothing.

**Behaviour preserved.** Table 1 rebuilt: every registry row byte-identical
(only the Healthgrades ambiguity count moved, 14 → 15, from crawl progress).
Rurality labels compared across all 3,235 counties: identical.

**Full suite.** 5/5 pass — table1_bands, healthgrades_integrity,
checkpoint_merge, cross_taxonomy_hierarchy, pip_materialization.

**Unresolved / carried forward.**

- `R/07-cohort-composition.R:158` — `cert_decade` uses the same positional
  parsing (`str_sub(certification_date, -4, -2)`). Same class as defect 2, not
  yet fixed. **Cycle 2.**
- 8 further `distinct(..., .keep_all = TRUE)` sites (`geocode_midwives.R`,
  `load_obstetric_providers.R`, `represented_subset_access.R:67`) resolve key
  conflicts by row order. Same class as defect 3. **Cycle 2–3.**
- `left_censored` is computed in `build_table1_midwives.R` but never used. The
  ">=15 years" band (32.7%) is bounded by the 2007 panel start, not by
  careers. Whether Table 1 should report the censoring is a **scientific
  decision, not a code fix** — flagged, not silently chosen.

**No scientific estimand was changed in this cycle.**
