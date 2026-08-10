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

---

## Out-of-cycle finding — 2026-08-09, stage 2 at 1,010 profiles

Field coverage was checked at the 1,000-profile mark. Three fields reported
"100% non-missing", which for optional self-reported attributes is a warning
sign, not reassurance.

**`hg_years_experience` is constant 0 across all 1,035 rows.** It is not a
parse failure: the Healthgrades payload itself carries
`roundedYearsOfExperience: 0` for midwives, verified against a live profile.
The field is unpopulated for this provider type. It read as "100% complete"
only because zero is a value. **Unusable -- must not reach Table 1**, and a
completeness statistic that counts it as present is misleading.

**`hg_accepts_new_patients` and `hg_has_telehealth` contain no NA at all**
(1,018/17 and 903/132). Every other field has missingness, so the absence of
NA suggests "attribute not stated" is being recorded as FALSE rather than
unknown. If so, `hg_has_telehealth == FALSE` conflates "no telehealth" with
"not stated", and the 87% FALSE rate is an unknown mixture of the two.
Compare with `hg_medicaid_named`, which does carry NA (156) and is documented
as a floor, not a measure. **Needs a test that distinguishes absent from
false at the parser level before either field is reported.**

`hg_languages` is 5% populated -- it does not rescue the Language row, which
should stay "not collected".

`hg_age` is 56% of profiles, and profiles cover only part of the cohort, so
effective coverage is far below that. Median 60 (IQR 47-71, range 28-96) is
older than expected for an ACTIVE workforce; whether that reflects genuine
profile-selection bias or a mis-targeted regex should be validated against a
handful of known profiles before use.

**Carried to the next cycle:** (a) assert no field reaches Table 1 while
constant; (b) distinguish absent from false for the two boolean fields;
(c) validate `hg_age` against known profiles.

---

## Cycle 2 — 2026-08-09 — 3 BVA / 4 semantic / 3 adversarial

**Targets.** The two classes cycle 1 carried forward, plus a check on cycle 1's
own sweep.

**Tests added** — `tests/test_cycle2_dates_keys.R` (T11–T20, 12 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T11 | BVA | decade opens on a year ending 0, closes on 9 |
| T12 | BVA | zero-length and blank input neither error nor fabricate |
| T13 | BVA | implausible years rejected, not banded |
| T14 | semantic | same day in two date formats gives the same decade |
| T15 | semantic | every decade label bounds the years assigned to it |
| T16 | semantic | conflicting duplicate keys are not resolved by row order |
| T17 | semantic | identical duplicates still collapse (fix must not over-reject) |
| T18 | adversarial | decade assignment invariant to row order |
| T19 | adversarial | factor dates parse by value, not level index |
| T20 | adversarial | no inline RUCC rule survives outside the library |

### Defects found — 4

1. **Cycle 1's sweep was incomplete.** It reported the RUCC banding rule in
   three copies and fixed three. There were **six**: `02-geocoding-completeness.R`,
   `05-stage-progression.R` and `07-cohort-composition.R` each carried a fourth,
   fifth and sixth copy, in a **third label vocabulary** ("Nonmetro, adjacent
   (4-6)", dropping "RUCC") that differs from `_SHORT` by an amount that looks
   like a typo and changes a published column. All three now call
   `band_rurality(rucc_2023, RURALITY_LABELS_COHORT)`.
   *A fix applied to three of six copies is a fix applied to none.*
   T20 now enforces zero inline copies, so a seventh cannot appear quietly.

2. **`cert_decade` positional parsing** (`07-cohort-composition.R:158`) —
   carried forward from cycle 1 and now fixed. `str_sub(date, -4, -2)` encodes
   a date *format* as a character offset: `05/12/2007` → "2000s", but
   `2007-05-12` → **"5-10s"**. A garbage decade is still a string, so it groups
   and tabulates without complaint. Replaced by `band_cert_decade()`, which
   delegates to the existing `parse_enum_year()` rather than reimplementing it.

3. **`assert_unique_keys(dedupe = TRUE)` resolved conflicts by row order** —
   inside `R/join_safety.R`, a helper whose name promises the opposite. Two rows
   sharing a `certification_number` but disagreeing on `practice_state` silently
   published whichever sorted first. Identical duplicates still collapse;
   disagreeing rows now stop the run and name the key and the disagreeing
   columns.

4. **`ifelse()` is type-unstable on zero-length input** — returns `logical(0)`,
   not `character(0)`, which poisons a downstream `bind_rows()` with a wrong
   column type. Caught by T12a while writing the replacement, and avoided in
   `band_cert_decade()`.

### Same-class sweep

`distinct(..., .keep_all = TRUE)` on a conflict-bearing key: the ledger
estimated 8 sites; the actual count is **14**. The one inside `join_safety.R`
is fixed because it is the shared helper. The remaining 13 are in individual
scripts and are **not yet audited** for whether their keys can actually carry
conflicting values — several are almost certainly benign (`01-build-county-base.R`
dedupes a geometry join). **Cycle 3** must classify each site rather than
rewrite it blindly.

### Anti-ceremony check

T14b asserts the *retired* rule still fails the format test (`ISO → "5-10s"`),
so T14 is proven to discriminate rather than to pass vacuously. T11–T15 and
T18–T19 were initially written against a local replica; when production was
fixed they were repointed at `band_cert_decade()`, because a test aimed at a
retired implementation pins nothing.

### Full suite

6/6 pass — checkpoint_merge, cross_taxonomy_hierarchy, cycle2_dates_keys,
healthgrades_integrity, pip_materialization, table1_bands. All five edited
sources parse.

**Correction to the cycle-1 record:** the earlier note of a pre-existing failure
in `test_table1_bands.R` was an artifact of running a plain Rscript test file
through `testthat::test_file()`. Under its documented runner it passes. The
baseline is **zero pre-existing failures**.

### Unresolved / carried forward

- 13 unaudited `.keep_all` sites (above). **Cycle 3.**
- Healthgrades: `hg_years_experience` constant 0 must not reach Table 1;
  `hg_accepts_new_patients` / `hg_has_telehealth` conflate absent with FALSE;
  `hg_age` needs validation against known profiles. **Carried from cycle 1.**
- `left_censored` — whether Table 1 should report panel-window censoring on the
  ">=15 years" band remains a **scientific decision**, still not made.

**No scientific estimand was changed in this cycle.**
