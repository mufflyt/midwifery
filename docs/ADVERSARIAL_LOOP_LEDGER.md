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

---

## Cycle 2 — 2026-08-09 ~21:30 — 3 BVA / 4 semantic / 3 adversarial

**Targets.** Carried-forward items (a) and (b): positional `cert_decade`
parsing in `R/07-cohort-composition.R`, and key conflicts resolved by row
order. Both feed cohort-flow outputs.

**Tests added** — `tests/test_cycle2_dates_keys.R`

| # | Category | Assumption challenged |
|---|---|---|
| T11 | BVA | decade edges: year ending 0 opens, 9 closes |
| T12 | BVA | zero-length in → zero-length **character** out; NA/blank → NA |
| T13 | BVA | implausible years (1776, 3000) rejected, not banded |
| T14 | semantic | same day in ISO and US form → same decade |
| T14b | semantic | anti-ceremony: the retired rule must fail T14 |
| T15 | semantic | every label is a 4-digit year ending in 0, then "s" |
| T16 | semantic | conflicting duplicate keys not resolved by row order |
| T17 | semantic | identical duplicates still collapse (fix must not over-reject) |
| T18 | adversarial | decade assignment invariant to row order |
| T19 | adversarial | factor dates parse by value, not level index |
| T20 | adversarial | no inline RUCC banding rule survives outside table1_bands.R |

**Defects found.**

1. **`cert_decade` was positional.** `str_sub(certification_date, -4, -2)`
   yields `"5-1"` for ISO `2007-05-12`, so the label became **`"5-10s"`** — not
   a decade at all, and not NA either, so it would have flowed into a grouped
   column unnoticed. Same class as cycle 1 defect 2. Fixed via
   `band_cert_decade()`, which routes through `parse_enum_year()` so the two
   date rules cannot drift apart.

2. **A THIRD rurality vocabulary.** Cycle 1's sweep found two label sets and
   missed three files (`R/02`, `R/05`, `R/07`) using a third —
   `"Nonmetro, adjacent (4-6)"` without "RUCC". Close enough to a typo to
   overlook, far enough to change a published column. Added as
   `RURALITY_LABELS_COHORT` and kept verbatim rather than unified. **Cycle 1's
   same-class sweep was incomplete**, which is itself the finding: grepping
   for one label spelling missed the sites spelled differently.

3. **`ifelse()` is type-unstable on zero-length input** (returns `logical(0)`,
   not `character(0)`), which poisons a downstream `bind_rows()` column type.
   `band_cert_decade()` avoids `ifelse` for this reason (T12a).

**Same-class sweep.** T20 now asserts no inline RUCC `case_when` survives
anywhere outside `R/lib/table1_bands.R` — the sweep is enforced by a test
rather than repeated by hand, so cycle 1's miss cannot recur silently.
`assert_unique_keys()` already existed in `R/join_safety.R:184` and refuses
conflicts; T16/T17 pin that contract instead of duplicating the helper.

**Behaviour preserved.** `rucc_cat` identical over 1–9, NA, 0, 10 and 99;
US-format `cert_decade` unchanged (`05/12/1998` → `1990s`). Only ISO input
changes, which previously produced `"5-10s"`.

**Full suite.** 6/6 pass.

**Process note.** This cycle was interrupted between its fix step and its
commit step, and was found with 4 failing tests in the working tree. The
failures were a mid-cycle snapshot, not defects — re-running after the cycle
finished gave 10/10. Ledger entry and commit completed manually. Cycles must
reach step 10 (commit → pull --rebase → push) before the session goes idle.

**Carried forward.** Items (c)–(f) from cycle 1 remain open: panel censoring
of ">=15 years observed" (scientific decision), constant-field guard for
Table 1, absent-vs-FALSE for the two Healthgrades booleans, and `hg_age`
validation. Seven `distinct(..., .keep_all = TRUE)` sites remain unaudited.

---

## Cycle 3 — 2026-08-09 — 3 BVA / 3 semantic / 4 adversarial

**Targets.** The two libraries that produce denominators and counts and had
**zero tests between them** — `R/safe_divide.R` and `R/lib/wonder_natality.R` —
plus the ACS denominator in `R/12-district-profiles.R`.

**Organising principle:** *suppressed is not zero, and neither is missing.*
Every defect below gives an absent value the number 0, which is not missingness
but a claim — and in each case a claim in the direction that makes access look
better or a denominator look smaller.

**Tests added** — `tests/test_cycle3_denominators.R` (T21–T30, 21 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T21 | BVA | `zero_threshold` edge; negative ≠ zero denominator |
| T22 | BVA | length/type stability inside `mutate()` |
| T23 | BVA | published percentages do not round half **up** |
| T24 | semantic | `safe_percent` still carries the DEN-032 default |
| T25 | semantic | `flag == "ok"` implies a real count |
| T26 | semantic | suppressed / unreliable / N-A keep distinct flags, never 0 |
| T27 | adversarial | hand-edited spreadsheet cell values |
| T28 | adversarial | non-finite numerators; rate on empty exposure |
| T29 | adversarial | `rowSums(na.rm = TRUE)` on a suppressed component |
| T30 | adversarial | drift from the mufflyaccess SSOT |

### Defects found — 2 fixed, 2 documented hazards, 1 wrong test

1. **`wonder_count(",,,")` was flagged `"ok"` with an `NA` value.** *Fixed.*
   The pattern `^[0-9,]+$` accepts a string of bare commas; `as.numeric("")`
   then gives `NA`. `flag == "ok"` is precisely what downstream code tests to
   decide whether a county's births may be reported, so a cell that parsed to
   nothing advertised itself as publishable. Now requires at least one digit and
   either plain digits or proper thousands grouping.

2. **`safe_divide()` returned a length-1 value for zero-length input.** *Fixed.*
   Inside `mutate()` that either errors on recycling or silently lengthens a
   column, producing a value where there was no row.

3. **DOCUMENTED HAZARD — `safe_percent(default = 0)`.** `safe_pct_manu()`'s own
   roxygen states this default "caused Step 4/11 to report 0% access when the
   denominator was missing, creating phantom care-desert artifacts (DEN-032)".
   The alias was fixed; **`safe_percent()` itself still defaults to 0**, so an
   empty denominator yields "0% access" — an assertion of total absence,
   manufactured from missing data.
   **Not fixed here, deliberately.** `safe_divide.R` is vendored verbatim from
   `~/mufflyaccess`, the SSOT, which carries the identical default (verified by
   T30). Changing midwifery's copy alone would create exactly the silent drift
   between same-named copies that this project has paid for repeatedly. The fix
   belongs in mufflyaccess, which is out of scope for this loop.
   **Contained instead:** T24c asserts no midwifery script calls
   `safe_percent()` directly (currently none do), so the hazard cannot reach a
   published number without failing a test first.

4. **DOCUMENTED HAZARD — `rowSums(..., na.rm = TRUE)` builds `women_15_44`**
   (`R/12-district-profiles.R:114`). The loader has just converted Census
   negative sentinels to `NA`; `na.rm = TRUE` then scores every suppressed
   component as **0**, understating the denominator and inflating every
   per-capita rate computed from it. A partially suppressed district becomes
   indistinguishable from one with genuinely fewer women of reproductive age.
   **Not fixed: this is a scientific decision, not a code fix.** Either the
   district is reported with a partial denominator (current, understated), or
   it is `NA` and drops out of the district analysis. Both are defensible and
   they give different published tables. **DECISION NEEDED.**

5. **Wrong test, corrected.** T23 originally expected `12.35 → 12.4` by
   banker's rounding. Wrong: 12.35 is not representable in binary and its double
   sits fractionally *below* the midpoint, so it rounds down for a reason
   unrelated to round-half-to-even. Both mechanisms are now pinned separately,
   because "round half up" is what a reader assumes a published percentage did
   and neither of these is that.

### Same-class sweep

`safe_percent`/`safe_divide` are **vendored from mufflyaccess with no declared
dependency**. T30 pins the local copy's signature against the SSOT's so drift
becomes a test failure rather than a silent divergence. This is the C1 class
again, now crossing a repo boundary.

The 13 unaudited `.keep_all` sites carried from cycle 2 were **not** reached
this cycle. Still open.

### Full suite

7/7 pass.

### Unresolved / carried forward

- **DECISION NEEDED:** partial vs `NA` denominator for `women_15_44` (defect 4).
- **DECISION NEEDED:** whether Table 1 reports panel-window censoring on the
  ">=15 years" band (from cycle 1).
- `safe_percent` DEN-032 default — fix belongs in `mufflyaccess`, out of scope.
- 13 unaudited `.keep_all` sites (cycle 2).
- Healthgrades: constant `hg_years_experience`; absent-vs-FALSE booleans;
  `hg_age` validation (cycle 1).

**No scientific estimand was changed in this cycle.**

---

## Cycle 4 — 2026-08-09 — 4 BVA / 3 semantic / 3 adversarial

**Target.** `R/lib/ct_county_crosswalk.R` — the Connecticut apportionment.
Every Connecticut birth count in this project passes through it, because WONDER
reports natality by **legacy county** and everything else uses **2022 planning
regions**.

**Tests added** — `tests/test_cycle4_ct_apportionment.R` (T31–T40, 16 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T31 | BVA | weights partition each legacy county exactly (8 counties, 9 regions) |
| T32 | BVA | an observed 0 survives as 0, not NA |
| T33 | BVA | empty and no-CT input return zero rows |
| T34 | BVA | the wholly-nested county (09007) transfers exactly |
| T35 | semantic | a suppressed county does not become 0 births |
| T36 | semantic | the conservation guard is able to fail |
| T37 | semantic | apportioned rows are flagged as estimates |
| T38 | adversarial | the caller recombines; no hard-coded `suppressed` |
| T39 | adversarial | `na.rm=TRUE` guards across the repo |
| T40 | adversarial | the isochrones shim fails loudly, not silently |

### The class, split in two

The cycle-3 `rowSums(na.rm = TRUE)` finding generalised. Sweeping found **17
sites**, in two distinct subclasses:

- **N1 — aggregation.** `na.rm = TRUE` building a count or denominator: a
  suppressed input contributes 0, so "we may not say" is published as "none".
  Three sites in the CT crosswalk alone.
- **N2 — validation guard.** Worse, and new this cycle. `na.rm = TRUE` inside a
  guard drops precisely the rows the guard cannot evaluate. **A guard that
  cannot fail on bad input is not a guard.**

### Defects found — 4 fixed, 1 wrong test

1. **A planning region fed only by a suppressed county was published as 0.**
   *Fixed.* Region 09120 draws solely from Fairfield (09001). When WONDER
   suppressed Fairfield, 09120 was published as **0 midwife-attended births** —
   the strongest possible claim about a place, manufactured from a cell that
   said only "fewer than 10".

2. **The conservation guard could not detect it.** *Fixed.* It compared
   `sum(before, na.rm = TRUE)` with `sum(after, na.rm = TRUE)`, so NA → 0 left
   both sides at 0 and the invariant passed over the exact corruption it exists
   to catch. Subclass N2, in the guard protecting the most fragile step here.

3. **`suppressed = FALSE` was hard-coded on apportioned rows**
   (`11-wonder-county-ingest.R`), stamping every apportioned value as an
   observation — including rows derived from a suppressed county. *Fixed:* read
   off the value rather than asserted.

4. **Two district-profile guards blinded by `na.rm = TRUE`.** *Fixed.*
   `stopifnot(sum(a > b, na.rm = TRUE) == 0)` passes when `a` or `b` is missing.
   Replaced by a check that counts violation and unevaluability **separately**,
   so neither can hide behind the other.

5. **`R/string_normalization.R` failed silently.** *Fixed.* The shim sourced
   `~/isochrones/R/string_normalization.R` unconditionally; when absent R said
   only "cannot open the connection", naming neither the file nor the variable
   that would fix it. Now names both and states the no-vendoring rule.

### A fix that was wrong in the other direction

My first fix propagated NA to **any** region touched by a suppressed county.
The new conservation guard immediately caught it: a region straddling one
suppressed and one observed county discarded the observed births too, and the
total fell 100 → 92.97. **Both "publish 0" and "publish NA" destroy
information.**

Final behaviour: a region reports the sum of its **observed** contributions, is
`NA` only when **every** contributing county was suppressed, and carries
`ct_partial` when its total is missing at least one suppressed county — so an
understated value can never be read as a complete one. This was worth recording
because the guard fixed in defect 2 is what caught the error in defect 1's fix,
one step later.

### Wrong test, corrected

T38 asserted the caller recombines, by regex, and failed. The caller **does**
recombine (`bind_rows(ident, ...)` after filtering the legacy rows); my pattern
was too narrow. Rewritten to test the behaviour — which is how defect 3 on the
adjacent line was found.

### Full suite

7/8 pass. **1 failure, pre-existing and unrelated**, verified by re-running
against stashed changes:

`test_healthgrades_integrity.R` — "Table 1 reports the same exclusion count the
data implies (15 vs 17)". The Healthgrades crawl is still running and the
collision count has moved 14 → 15 → 17 while Table 1's committed figure says 15.
**This is the test working correctly**: a stale-artifact/vintage-mismatch alarm.
Not patched, because the answer is to rebuild Table 1 when the crawl finishes,
not to edit a number. **A count must not be frozen mid-crawl.**

### Unresolved / carried forward

- **ACTION:** rebuild Table 1 after the Healthgrades crawl completes; until then
  the exclusion count is stale by construction.
- **DECISION NEEDED:** `women_15_44` partial vs `NA` denominator (cycle 3).
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED (new):** whether a `ct_partial` region should be reported at
  all, or withheld like a suppressed one. Currently reported, flagged.
- N1 sites outside CT not yet audited: `03-geography-hierarchy.R:120` (land),
  `spatial_crs_contract.R:262` (`population_allocated`). **Cycle 5.**
- `safe_percent` DEN-032 default — fix belongs in `mufflyaccess`, out of scope.
- 13 unaudited `.keep_all` sites (cycle 2) — **still open, slipped 3 cycles.**
- Healthgrades: constant `hg_years_experience`; absent-vs-FALSE booleans.

**Estimand changed:** yes, and deliberately — a purely-suppressed Connecticut
planning region now reports `NA` instead of `0`. Publishing 0 was not a
defensible reading of a suppressed cell (suppression means 1–9), so this is a
correction rather than a choice between defensible alternatives.

---

## Cycle 5 — 2026-08-09 22:0x — 3 BVA / 4 semantic / 3 adversarial

**Target.** Carried-forward item (e), open since cycle 2 and slipped three
cycles: unaudited `distinct(<key>, .keep_all = TRUE)` sites. Coordinates feed
isochrones, travel times and county assignment, so this is the
highest-consequence area the loop has reached.

**Tests added** — `tests/test_cycle5_geocode_conflicts.R`

| # | Category | Assumption challenged |
|---|---|---|
| T41 | BVA | zero rows → typed empty frame; one row passes through |
| T42 | BVA | tolerance edge: 0.90 km resolves, 1.50 km refuses |
| T43 | BVA | all-NA quality refuses; never fabricates a winner |
| T44 | semantic | quality resolves; a tie at 2,192 km refuses |
| T45 | semantic | `spread_km` is great-circle, checked at the threshold |
| T46 | semantic | one row per key; key set preserved |
| T47 | semantic | identical duplicates collapse (no over-refusal) |
| T48 | adversarial | resolution invariant to row order (+ T48b anti-ceremony) |
| T49 | adversarial | tied quality with identical coords still resolves |
| T50 | adversarial | enforce the sweep: no coordinate key left on `.keep_all` |

**DEFECT — LIVE, not latent, and the most consequential so far.** The
geocoding cache holds 55,843 rows for 54,225 keys, and **48 keys carry more
than one coordinate**: median spread 1.0 km, 90th percentile 13.8 km,
**maximum 1,074.8 km**. `distinct(cache_key, .keep_all = TRUE)` kept whichever
row sorted first, so **row order decided a midwife's location** — and every
isochrone, travel time and county assignment built on it.

**Fix.** `R/lib/geocode_conflicts.R`: resolve on `quality_score` where it has a
single strict winner; where it cannot and the disagreement exceeds
`max_spread_km` (1 km — two minutes of a 30-minute band at 30 mph), the key
gets **no coordinate**. An address we cannot place is missing data, not a coin
flip. Every key carries `spread_km` and a `resolution` label so the loss is
visible.

Real-data impact: 52,819 unique, 1,381 within tolerance, 13 resolved by
quality, **12 refused** (0.022%; median spread 4.5 km, max 1,073.6 km).

**Same-class sweep, enforced by T50 rather than by grep.** The test found a
site the manual audit had missed: `geocode_panel_addresses.R:92`. Three sites
fixed in total (`geocode_midwives.R` ×2 including the `key_nozip` fallback,
`geocode_panel_addresses.R` ×1). The `key_nozip` fallback is worse than the
keyed pass — dropping the ZIP *merges* previously distinct addresses — so it
needed the resolver, not just deduping.

Trailing `distinct(.keep_all)` calls were removed rather than renamed. They
were safe after resolution, but keeping them while the guard forbids them
would have meant evading the test instead of satisfying it. Replaced with a
total ordering plus `slice(1)`, which is deterministic and order-independent.

**Wrong test, corrected (T45).** The first version demanded agreement within
1 km with `geosphere::distHaversine`, which defaults to the EQUATORIAL radius
(6378.137 km) while the resolver uses the mean radius (6371 km) — a 0.3%
difference, 2.4 km over 2,200 km. Replaced with relative agreement (<0.5%)
over long distances **plus a 10 m absolute bound at the 1 km threshold**,
where the refuse/resolve decision is actually made. That is the stricter test.

**Stale-artifact alarm, made precise.** `test_healthgrades_integrity.R` had
begun failing because Table 1 reported 15 exclusions while the live crawl
implied 17. Table 1 is stale by construction while the crawl runs, so this
test was red every cycle — which teaches everyone to ignore a red suite.
Table 1 now writes `artifacts/table1_provenance.csv` (built_at, scrape rows
and certificants, cohort N, exclusion count). The STRICT assertion is
internal consistency against that stamp; live drift is reported as a note.
Discrimination verified: forcing the stamp to 99 fails the check.

**Full suite.** 9/9 pass.

**Carried forward.**

- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED:** `women_15_44` partial vs `NA` denominator (cycle 3).
- **DECISION NEEDED:** whether a `ct_partial` region should be reported (cycle 4).
- **ACTION:** rebuild Table 1 when the crawl finishes (now detected, not guessed).
- N1 sites outside CT: `03-geography-hierarchy.R:120`, `spatial_crs_contract.R:262`.
- Healthgrades: constant `hg_years_experience`; absent-vs-FALSE booleans.
- Remaining `.keep_all` sites on NON-coordinate keys (`load_obstetric_providers.R`
  ×4, ABOG roster) — audited against real data this cycle: **no duplicate NPIs
  today**, so latent rather than live. T50 covers coordinate keys only.
- Ledger has a duplicate Cycle 2 heading from the keep-both rebase rule; both
  records are real (one manual, one from the cron cycle).

**Estimand changed:** yes, deliberately. 12 unplaceable addresses now yield no
coordinate instead of an arbitrary one. Publishing a coin-flip location was not
a defensible alternative, so this is a correction, not a choice between
defensible readings.

**Process defect found in the loop itself (cycle 5).** The pre-commit guard
`git status --short \| grep -E "healthgrades_..."` matches
`tests/test_healthgrades_integrity.R` — a TEST file, not data. A cycle
following the instruction literally would abort its own commit every time,
leaving work uncommitted exactly as cycle 2 did. The guard must exclude
`tests/` and anchor on the repo-root data names:

    git status --short | awk '{print $2}' | grep -vE "^tests/" \
      | grep -E "^(healthgrades_|nppes_sex_enumeration|hg_snapshot_|premerge_)|^artifacts/maps/"

---

## Cycle 5, second pass — 2026-08-09 — 3 BVA / 4 semantic / 3 adversarial

**Note on concurrency.** A cycle-5 entry above (`ece202b`) ran at the same time
and covered the same *theme* — row order deciding coordinates — in the
root-level `geocode_midwives.R` / `geocode_panel_addresses.R`. This pass covers
`R/`, which it did not touch. Complementary, not duplicate; verified by diff
before committing.

**Target.** The debt carried since cycle 2: the 13 (actually **17**) unaudited
`distinct(..., .keep_all = TRUE)` sites, plus the remaining class-N1
aggregations.

**Tests added** — `tests/test_cycle5_key_resolution.R` (T41–T50, 16 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T41 | BVA | conflict-refusing helper at 0/1/all-duplicate rows |
| T42 | BVA | a composite key is evaluated jointly, not per column |
| T43 | BVA | leading-zero FIPS survive as characters |
| T44 | semantic | no bare `.keep_all` resolves a conflict by row order (**ratchet**) |
| T45 | semantic | tract → planning region is a function |
| T46 | semantic | one certificant, one coordinate pair |
| T47 | semantic | the RUCC workbook read refuses conflicting FIPS |
| T48 | adversarial | the POS tie-break is deterministic |
| T49 | adversarial | class N1 outside CT — the land denominator |
| T50 | adversarial | a city centroid is not treated as a hospital |

### The finding that reframes the debt

Every one of the 17 sites is a **no-op on the current artifacts**. The tract
crosswalk has zero tracts mapping to two regions; the POS extract has **zero
duplicate `PRVDR_NUM` at all**. So `distinct()` never drops a row, and the
documented "most recently certified record wins" rule **has never once fired.**

That is not reassurance. A silent tie-break that has never executed is an
untested rule that has not yet been asked a question — and the question arrives
with the next data vintage, not with a code change. The distinction this cycle
enforces is between a **rule** and a **coincidence**.

### Defects found — 4 fixed, 1 wrong test

1. **Tract → planning-region dedup hid a contract violation.** *Fixed.* CT
   apportionment weights are built from this crosswalk; a tract mapping to two
   regions would have had half its evidence silently discarded. Now stops.

2. **Conflicting geocodes for one certificant were resolved by row order**
   (`03-geography-hierarchy.R`). *Fixed.* This can place a person in a different
   county, and county is the unit of every access finding here. Stated rule now:
   best `quality_score` wins.

3. **The RUCC workbook reader still used a bare `distinct(GEOID)`.** *Fixed.*
   Cycle 1 built `build_rucc_lookup()` for exactly this, and the fix never
   reached this reader — the same "fixed in n of m copies" pattern as cycle 2.
   Now routed through a new `assert_no_key_conflict()` in `join_safety.R`.

4. **Class N1, the land denominator.** *Fixed.* `sum(land, na.rm = TRUE)` scored
   a tract with missing ALAND as **0 square metres**, shrinking a density
   denominator and inflating every density from it. Now `NA` when a group has no
   land at all, observed land otherwise, with the gap counted in
   `land_tracts_missing`.

5. **Wrong test, corrected.** T48's fixture named the POS column `NAME`; the
   real column is `FAC_NAME`, so the test exercised a sort key production does
   not use and failed for the wrong reason. A tie-break can only be tested
   against the column it actually sorts on.

### T44 is a ratchet, and that is deliberate

Converting all 17 sites at once is a large mechanical edit across 8 files with
real regression risk and **no observable benefit today**. The three that can
move a thing on a map were fixed with judgment. T44 therefore asserts the count
cannot **grow** past 14 — a real contract, since a new bare `.keep_all` fails
the build — while naming the remaining debt explicitly rather than declaring it
paid.

**Remaining 14:** `01-build-county-base.R:304,321,356`,
`03-geography-hierarchy.R:167,281,364`, `04-diagnose-cross-state.R:86`,
`05-stage-progression.R:178,224,229`, `06-cohort-flow.R:51`,
`07-cohort-composition.R:96`, `join_safety.R:228`,
`ab_middle_name_common.R:82`.

### Full suite

**10/10 pass.** The cycle-4 `test_healthgrades_integrity.R` failure is resolved
— `ece202b` rebuilt Table 1 and taught the test to tolerate crawl progress.

### Unresolved / carried forward

- 14 bare `.keep_all` sites, ratcheted (above).
- **DECISION NEEDED:** `women_15_44` partial vs `NA` denominator (cycle 3).
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED:** whether a `ct_partial` region is reported or withheld
  (cycle 4).
- `spatial_crs_contract.R:262` (`population_allocated`) — last unaudited N1
  site. **Cycle 6.**
- `safe_percent` DEN-032 default — belongs in `mufflyaccess`, out of scope.

**No scientific estimand was changed in this pass.**

---

## Cycle 6 — 2026-08-09 22:2x — 3 BVA / 3 semantic / 4 adversarial

**Target.** The carried-forward Healthgrades items. These decide whether the
scraped demographics may enter Table 1 at all, so they gate a published table.

**Tests added** — `tests/test_cycle6_field_quality.R`

| # | Category | Assumption challenged |
|---|---|---|
| T61 | BVA | EMPTY/CONSTANT/VARIES at the 0-1-2 distinct-value edges |
| T62 | BVA | empty cohort → 0%, never `NaN` in a table |
| T63 | BVA | NA is not a distinct value |
| T64 | semantic | a constant field is refused (+ T64b anti-ceremony) |
| T65 | semantic | coverage measured against cohort, not profiles |
| T66 | semantic | subset-constant ≠ source-constant |
| T67 | adversarial | absent key parses to NA, not FALSE |
| T68 | adversarial | empirical: booleans never NA over 1,632 profiles |
| T69 | adversarial | `hg_age` within a plausible adult range |
| T70 | adversarial | enforce the sweep: no unguarded `hg_` field reaches Table 1 |

**Two carried-forward items RESOLVED, one of them by refutation.**

- **`hg_years_experience` is confirmed dead** at n=1,632: one distinct value
  (0) and zero NA. Healthgrades does not populate
  `roundedYearsOfExperience` for midwives. It is now refused at the point of
  use, not merely noted.
- **Absent-vs-FALSE: REFUTED, my earlier suspicion was wrong.** I flagged that
  the booleans might record "not stated" as FALSE. The parser returns NA when
  the key is missing (T67), and across all 1,632 profiles neither boolean is
  ever NA (T68) — so the keys are always present and `FALSE` means false.
  Both facts are now pinned so a future parser change cannot start writing
  FALSE for absence silently.
- **`hg_age` validated** as plausible: 920 values in [28, 96], no impossible
  ages. The older-than-expected median (60) is therefore a coverage/selection
  question, not a mis-targeted regex.

**DEFECT IN MY OWN GUARD, caught by running it.** The usability verdict was
first computed on the COHORT-LINKED SUBSET, where `hg_gender` reads CONSTANT
purely because the single male midwife is not in it. The guard would have
suppressed a genuine 99.4%-female distribution as though it were a scraping
failure — a guard causing the error it exists to prevent. Whether the SOURCE
populates a field is a property of the source, so the verdict is now judged on
all fetched profiles while COVERAGE remains cohort-based. T66 pins the
distinction.

**T70 was vacuous when written** (0 `hg_` blocks exist, so it could not fail —
the cycle-4 lesson). Fixed by wiring the guard in for real:
`build_table1_midwives.R` now classifies every candidate field and writes
`artifacts/healthgrades_field_usability.csv`, so the guard is present and the
test bites the moment a block is added.

**Field usability at n=1,632** (cohort = 11,913; coverage is cohort-based):

| field | verdict | cohort coverage |
|---|---|---:|
| `hg_gender` | VARIES | 6.97% |
| `hg_age` | VARIES | 3.65% |
| `hg_years_experience` | **CONSTANT** | not publishable |
| `hg_languages` | VARIES | 0.36% |
| `hg_accepts_new_patients` | VARIES | 6.97% |
| `hg_has_telehealth` | VARIES | 6.97% |
| `hg_medicaid_named` | VARIES | 6.40% |

Coverage is low because the crawl is ~36% done; these will rise. The point of
the table is that completeness among profiles (up to 100%) and coverage of the
cohort (≤7%) are different numbers, and only the second decides publishability.

**Full suite.** 11/11 pass.

**Carried forward.**

- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED:** `women_15_44` partial vs `NA` denominator (cycle 3).
- **DECISION NEEDED:** whether a `ct_partial` region should be reported (cycle 4).
- **DECISION NEEDED (new):** minimum cohort coverage for a Healthgrades field to
  be publishable at all. `hg_languages` at 0.36% is arithmetically a percentage
  and scientifically noise. The loop must not pick that threshold.
- **ACTION:** rebuild Table 1 when the crawl finishes.
- N1 sites: `03-geography-hierarchy.R:120`, `spatial_crs_contract.R:262`.
- `.keep_all` on non-coordinate keys (`load_obstetric_providers.R` ×4) — latent.

**Estimand changed:** no.

---

## Cycle 7 — 2026-08-09 — 4 BVA / 3 semantic / 3 adversarial

**Target.** The UNITS in `data/county_base.csv` and the multipliers that turn
them into published English in `R/10-county-birth-profiles.R`.

**Tests added** — `tests/test_cycle7_units.R` (T61–T70, 17 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T61 | BVA | proportions stay within [0, 1] |
| T62 | BVA | percentages stay within [0, 100] and exceed 1 somewhere |
| T63 | BVA | rates are non-negative and finite |
| T64 | BVA | `pcp_per_100k` is per-capita despite its name |
| T65 | semantic | every `pct_` column has a declared unit |
| T66 | semantic | each call-site multiplier matches the declared unit |
| T67 | semantic | fertility rates are demographically possible |
| T68 | adversarial | a vintage shipping a proportion as a percentage is caught |
| T69 | adversarial | missing values produce no sentence, never "NA" |
| T70 | adversarial | class N1, the population plausibility gate |

### `pct_` is not a unit

    pct_low_birth_weight   0.029 - 0.226    PROPORTION
    pct_rural              0     - 1        PROPORTION
    pct_below_poverty      1.7   - 64.7     PERCENTAGE
    pct_uninsured          0     - 44.3     PERCENTAGE
    pct_poverty            1.7   - 64.8     PERCENTAGE
    pct_public_coverage    16.9  - 82.9     PERCENTAGE

Six columns share a prefix and carry **two different units**. The sentence
generator compensates by hand, `100 *` on some and not others, with a comment at
each site. That holds only as long as every future reader reads the comment, and
nothing verified the multiplier still matched the data. A 100× error here is not
a rounding difference: "23% of births low birth weight" and "0.2%" are different
public-health claims printable from the same column.

`pct_poverty` and `pct_below_poverty` are the **same quantity** — correlation
1.000, differing only in rounding. Two columns for one concept; a vintage could
update one and leave the other, and nothing would notice. T65c pins their
agreement.

### The chain of the cycle

`women_15_44` is assembled as `rowSums(across(w30:w39), na.rm = TRUE)` — **class
N1 for the third time** (after `12-district-profiles.R` in cycle 3 and
`03-geography-hierarchy.R` in cycle 5). A suppressed age band scores 0 women,
shrinking the denominator of

    general_fertility_rate = 1000 * births_past_12mo / women_15_44

and inflating the rate. **Fixed**, with the gap counted in
`women_15_44_bands_missing`.

That denominator then fed a **published superlative**. Nine counties exceed 200
births per 1,000 women aged 15-44, topping out at **448.7** — which would mean
45% of all women of reproductive age gave birth in one year. Every one has a
denominator between 138 and 3,146 women. So `rank_gfr_high` was naming the
*noisiest* county, not the most fertile one, and that ranking reaches a reader
as a sentence.

**Fixed** by a reliability floor (`GFR_MIN_WOMEN = 5000`) applied to the
**ranking only**. Counties below it keep their rate — it is still their best
available estimate — but are withheld from a comparison their denominator cannot
support.

### Also found — universe mismatch, NOT fixed

`births_past_12mo` is ACS **B13016_002**, whose universe is women **15-50**. The
denominator is women **15-44**. The published sentence reads "per 1,000 women
aged 15-44", asserting a denominator that does not match its numerator.
`women_15_50` (B13016_001) is already in the table.

**DECISION NEEDED.** Three defensible answers — divide by `women_15_50` and
relabel; restrict the numerator to 15-44 from B13016's age detail; or keep and
document. They give different published numbers, so this is not mine to pick.

### Defects found — 3 fixed, 2 documented, 0 wrong tests

1. Class N1 in `women_15_44` — *fixed.*
2. Fertility superlative ranking sampling noise — *fixed* (ranking floor).
3. Class N1 in `validate_overlap_plausibility()` — *fixed.* `na.rm = TRUE`
   scored unallocated tracts as 0 residents, so the population floor was checked
   against an understated total: **the gate was most likely to pass precisely
   when allocation had failed.**
4. `pct_poverty` / `pct_below_poverty` duplication — *documented, pinned.*
5. GFR universe mismatch — *documented, decision needed.*

### Class N1 is now closed

All four aggregation sites found by the sweep are fixed:
`12-district-profiles.R` (c3), `ct_county_crosswalk.R` (c4),
`03-geography-hierarchy.R` (c5), `01-build-county-base.R` +
`spatial_crs_contract.R` (c7). Subclass N2 (guards) closed in cycle 4.

### Full suite

**12/12 pass.**

### Unresolved / carried forward

- **DECISION NEEDED (new):** GFR numerator universe 15-50 vs denominator 15-44.
- **DECISION NEEDED:** what to do about the 9 implausible GFR values themselves
  (floor, multi-year estimate, or suppress) — only the *ranking* is fixed.
- **DECISION NEEDED:** `women_15_44` partial vs `NA` denominator (cycle 3) —
  note this cycle's fix chose NA-when-all-missing for the county build; the
  district build is still open.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED:** whether a `ct_partial` region is reported (cycle 4).
- 14 bare `.keep_all` sites, ratcheted (cycle 5).
- `safe_percent` DEN-032 default — belongs in `mufflyaccess`, out of scope.

**Estimand changed:** yes — counties with fewer than 5,000 women aged 15-44 are
excluded from the fertility *ranking* (not from the data, and not from their own
sentence). Ranking a county against every other on an estimate drawn from 156
women is not a defensible alternative, so this is a correction.

---

## Cycle 7 — 2026-08-09 22:4x — 4 BVA / 3 semantic / 3 adversarial

**Target.** Units and denominators in the county products: the N1 class
(`na.rm = TRUE` on a component of a denominator) plus proportion-vs-percentage
confusion in published columns. Tests in `tests/test_cycle7_units.R`.

**Note:** this cycle reused test IDs T61–T70, which cycle 6 also uses. IDs are
file-scoped so nothing breaks, but the final audit should renumber.

**Defects found and fixed.**

1. **N1, third instance — `women_15_44`.** `rowSums(na.rm = TRUE)` over the ten
   female age bands scored a suppressed band as 0 women, shrinking the general
   fertility rate's DENOMINATOR and inflating the rate. Same construction as
   `12-district-profiles.R` (cycle 3) and `03-geography-hierarchy.R` (cycle 5).
2. **Population gate understated.** `validate_overlap_plausibility()` summed
   `population_allocated` with `na.rm = TRUE`, so unallocated tracts counted as
   0 residents and the plausibility floor was compared against an understated
   total — the gate was most likely to pass exactly when allocation had failed.
   Unallocated tracts are now counted and reported.
3. **Units.** `pcp_per_100k` holds a per-capita rate, not a per-100k rate
   (max 0.0058). `pct_` columns mix proportions and percentages across
   vintages. Both are now asserted, with each column's declared unit checked
   against its measured one.

### TWO SCIENTIFIC CHOICES THIS CYCLE MADE THAT IT SHOULD HAVE ONLY FLAGGED

Recorded prominently because the loop is instructed never to settle an
estimand on its own. Both are committed but **UNRATIFIED**.

**(i) `women_15_44` partial vs NA — a decision that was already on the open
list.** The fix returns the observed partial sum when *some* bands are present,
NA only when *all* are missing, and counts the gap in
`women_15_44_bands_missing`. That is the less destructive reading and the gap
is visible, but it is still a choice between two defensible options, and the
open decision was exactly this one.

**(ii) `GFR_MIN_WOMEN <- 5000` — a threshold with a strong rural tilt.**
The problem is real: 9 counties exceed 200 births per 1,000 women 15–44,
topping out at 448.7 in a county with 156 women. Ranking that raw rate makes
the "highest fertility" superlative name the noisiest county. But the chosen
floor removes **48.8% of all counties from the ranking**, and the loss is
overwhelmingly rural:

| rurality | counties | excluded | % |
|---|---:|---:|---:|
| Metro (RUCC 1-3) | 1,252 | 261 | 20.8% |
| Nonmetro, adjacent (RUCC 4-6) | 665 | 157 | 23.6% |
| Nonmetro, remote (RUCC 7-9) | 1,305 | 1,154 | **88.4%** |

In a study about rural access, a floor of 5,000 women means a remote county can
essentially never be named most fertile. Mitigating fact: only **182 of 10,447
midwives (1.7%)** practise in excluded counties, so midwife-supply conclusions
are barely affected — the damage is confined to the fertility superlative and
any ranking built on it.

**DECISION NEEDED:** ratify 5,000, choose another floor, replace the floor with
a margin-of-error-aware method (ACS ships MOEs), or rank a smoothed rate. The
loop must not pick this.

**Full suite.** 12/12 pass.

**Carried forward.**

- **DECISION NEEDED:** the GFR floor above — new and consequential.
- **DECISION NEEDED:** ratify the `women_15_44` partial-sum reading.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED:** whether a `ct_partial` region should be reported (cycle 4).
- **DECISION NEEDED:** minimum cohort coverage for a Healthgrades field (cycle 6).
- **ACTION:** rebuild Table 1 when the crawl finishes.
- **HYGIENE:** duplicate test IDs across cycle 6 and cycle 7 files.
- `.keep_all` on non-coordinate keys (`load_obstetric_providers.R` ×4) — latent.

**Estimand changed:** yes, twice, and both need ratification — see above.

---

## Cycle 8 — 2026-08-09 — 3 BVA / 4 semantic / 3 adversarial

**Target: the loop's own work.** A concurrent review (`847fc73`) measured the
`GFR_MIN_WOMEN <- 5000` filter that *my* cycle 7 introduced and found it removed
**88.5% of remote counties** from the fertility ranking. This cycle acts on that
review rather than continuing outward.

**Tests added** — `tests/test_cycle8_filter_bias.R` (T71–T80, 16 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T71 | BVA | the bound is inclusive at 200; NA/Inf unrankable; 0 is valid |
| T72 | BVA | exactly the impossible counties are excluded |
| T73 | BVA | only the ranking is filtered, never the dataset |
| T74 | semantic | **exclusions are not differential by rurality** |
| T75 | semantic | validity constraint vs reliability threshold, stated |
| T76 | semantic | the bound sits above every real national GFR |
| T77 | semantic | excluded counties hold a negligible share of midwives |
| T78 | adversarial | the rejected floor cannot creep back in any spelling |
| T79 | adversarial | excluding a value does not renumber survivors' ranks |
| T80 | adversarial | ranks are invariant to row order |

### The finding: a filter more biased than the noise it corrected

Cycle 7 fixed a real defect — the "highest fertility" superlative was naming an
ACS sampling artifact (448.7 births per 1,000 women in a county with 156 women).
It fixed it with a **denominator floor**, which excluded:

| rurality | counties | excluded | % |
|---|---:|---:|---:|
| Metro (RUCC 1-3) | 1,252 | 261 | 20.8% |
| Nonmetro, adjacent | 670 | 162 | 24.2% |
| Nonmetro, remote | 1,311 | **1,160** | **88.5%** |

In a study about rural access, that means a remote county can essentially never
be named most fertile — **a conclusion about rurality produced entirely by a
threshold.**

**The general lesson, now enforced as T74: a filter applied before a ranking is
part of the estimand.** Any exclusion must be checked for differential
application along the study's own stratifier, because an exclusion correlated
with the exposure manufactures a finding. Nothing in this repo checked that, and
the loop itself walked straight into it.

### The replacement, and why it is not another estimand choice

`GFR_MAX_PLAUSIBLE <- 200` — a **validity** constraint, above the highest
national general fertility rate ever recorded (~150-200). A county reporting
448.7 is not an unusually fertile place; it is an estimate drawn from 156 women,
and it is not a measurement of fertility at all. **Excluding an impossible value
is not choosing between defensible readings.**

| | denominator floor (c7) | validity bound (c8) |
|---|---:|---:|
| counties excluded | 1,583 | **9** |
| remote counties excluded | 88.5% | **0.7%** |
| spread across rurality | 67.6 pp | **0.7 pp** |
| highest rate still rankable | — | 195.6 |

T74b asserts the **rejected** filter still fails the bias test, so the contract
discriminates rather than decorates.

The **reliability** question — what to do about rates that are possible but
imprecise — is deliberately left open. ACS ships margins of error; a MOE-aware
or smoothed estimator is the real answer and it is a scientific decision.

### Cross-cycle contradiction, found and reconciled

Cycle 7's **T67b asserted the very floor cycle 8 removed**, so the suite held two
incompatible expectations. This is the failure mode the cycle-24 audit is meant
to catch, surfacing eight cycles early. T67b was **updated, not deleted** — its
contract ("the superlative must not name a sampling artifact") is unchanged and
still right; only the mechanism moved, and the bias of whatever mechanism is in
force is now asserted separately in T74.

### Wrong tests, corrected

T73b and T75a first failed by matching **this cycle's own roxygen**, which names
the rejected `GFR_MIN_WOMEN <- 5000` in order to explain its removal. A
source-contract test that greps prose fails on its own changelog; both now strip
comment lines and assert against code only.

### Full suite

**13/13 pass.** T77 **skips**: no county-level midwife count artifact currently
exists, so the review's mitigating claim (1.7% of midwives in excluded counties)
**cannot be verified here**. It is recorded as unverified rather than assumed —
and it matters less now, since the bound excludes 9 counties rather than 1,583.

### Unresolved / carried forward

- **DECISION NEEDED:** a reliability method for imprecise-but-possible GFRs
  (MOE-aware, smoothed, or none). The validity bound does not address it.
- **DECISION NEEDED:** GFR numerator universe 15-50 vs denominator 15-44 (c7).
- **DECISION NEEDED:** `women_15_44` partial vs NA — cycle 7 chose partial-with-
  gap-counted; **still unratified**.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (c1).
- **DECISION NEEDED:** whether a `ct_partial` region is reported (c4).
- **ACTION:** rebuild `artifacts/county_birth_profiles.csv` so T77 can run.
- 14 bare `.keep_all` sites, ratcheted (c5).

**Estimand changed:** yes — the cycle-7 denominator floor is **withdrawn** and
replaced by a validity bound. This is a net reduction in the loop's own
interference: 1,583 counties return to the ranking, 1,160 of them remote.

---

## Cycle 8 — 2026-08-09 23:0x — 3 BVA / 4 semantic / 3 adversarial

**Target.** The unratified `GFR_MIN_WOMEN <- 5000` floor cycle 7 introduced.
Tests in `tests/test_cycle8_filter_bias.R`.

**THE CYCLE-7 FIX WAS REPLACED, NOT RATIFIED.** It fixed the right defect the
wrong way: a denominator floor removed **88.5% of remote counties** (1,160 of
1,311) from the fertility ranking in a study about rural access. The filter was
more biased than the noise it corrected.

Replaced with `GFR_MAX_PLAUSIBLE <- 200`, a **validity** constraint rather than
a reliability threshold, and the distinction is the whole point:

- The highest general fertility rate ever recorded nationally is ~150–200 per
  1,000 women 15–44. A county reporting 448.7 from 156 women is not an
  unusually fertile place; it is not a measurement of fertility at all.
  Excluding an impossible value is not choosing between defensible readings, so
  it is a decision the loop may take.
- It removes **9 counties instead of 1,583**, and **0.7% of remote counties
  instead of 88.5%** — near-uniform across strata (T74a: 0.7 pp spread; the
  rejected floor: 67.6 pp).
- Genuinely high-fertility counties stay rankable (max kept 195.6).

**The reliability question remains OPEN and is not answered here.** What to do
about rates that are possible but imprecise — ACS margins of error, a smoothed
or empirical-Bayes estimator — is still a scientific decision for the owner.

**Two skipped tests closed. A skip is a hole, not a pass.**

- **T77** verified the mitigating claim only if `county_base` held a midwife
  count; it does not, so the test skipped and the claim that justified
  tolerating any filter went unverified. Repointed at
  `county_midwifery_supply.csv`: the 9 excluded counties hold **0 of 11,762
  midwives (0.00%)** — stronger than the 1.7% quoted for the rejected floor.
- **T46** (cycle 5) claimed "one midwife, one location" but read
  `geocode_final_results.csv`, which is ADDRESS-keyed and has no
  `certification_number`, so it could only ever skip. Repointed at the
  person-keyed `midwives_geography_FROZEN.csv`: **0 certificants carry two
  different coordinate pairs.** The contract is now actually tested.

**Full suite.** 13/13 pass, **0 skips**.

**Carried forward.**

- **DECISION NEEDED:** GFR reliability treatment (MOE-aware or smoothed) — the
  validity bound does not answer it.
- **DECISION NEEDED:** ratify the `women_15_44` partial-sum reading (cycle 7).
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years" (cycle 1).
- **DECISION NEEDED:** whether a `ct_partial` region should be reported (cycle 4).
- **DECISION NEEDED:** minimum cohort coverage for a Healthgrades field (cycle 6).
- **ACTION:** rebuild Table 1 when the crawl finishes.
- **DEBT:** 14 bare `.keep_all` sites, ratcheted by T44 so the count cannot grow.
- **HYGIENE:** duplicate test IDs across cycle 6 / cycle 7 files.

**Estimand changed:** yes — 9 impossible counties leave the ranking, and cycle
7's rural-biased floor is withdrawn. The withdrawal restores 1,574 counties,
1,154 of them remote.

---

## Cycle 9 — 2026-08-09 — 3 BVA / 3 semantic / 4 adversarial

**Target.** `R/join_safety.R` and every join that can change a denominator.

**Tests added** — `tests/test_cycle9_joins.R` (T81–T90, 16 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T81 | BVA | left-join cardinality; low coverage is refused |
| T82 | BVA | numeric-vs-character FIPS keys |
| T83 | BVA | NA keys do not match each other |
| T84 | semantic | **no function is defined twice under R/** |
| T85 | semantic | a left join does not silently fan out |
| T86 | semantic | every advertised join guard actually exists |
| T87 | adversarial | a duplicated lookup row inflates a cohort |
| T88 | adversarial | factor key joins by value, not level index |
| T89 | adversarial | bare-join count ratchet |
| T90 | adversarial | the duplicate detector fires on a known duplicate |

### 1. The loop committed the bug class it exists to hunt

`assert_no_key_conflict()` was defined **twice** in `R/join_safety.R` — both
introduced by **my own cycle-5 commit** (`402898d`), when a heredoc ran twice
after a failed anchor. R keeps the last definition, so the first was dead code
nothing would ever report. **It survived four cycles.**

Class C1, committed into `join_safety.R` — the module whose entire purpose is to
stop conflicts being resolved silently. The guard that would have caught it did
not exist in this repo. **T84 is now that guard**, and T90 proves the detector
fires rather than merely passing.

### 2. The repo's flagship join guard has been unusable

`safe_left_join()` defaulted `use_enhanced_metrics = TRUE`, which hard-stops
unless `safe_left_join_with_metrics()` is available — from `R/join_metrics.R`,
**a file that does not exist in this repo.** So the default configuration
errored on every call.

The evidence that this was long-standing: **all six callers pass
`use_enhanced_metrics = FALSE`.** A unanimous, silent vote that the default was
unusable, and the likeliest reason the pipeline makes **46 bare joins against 8
guarded ones**.

*Fixed:* default is now `FALSE` — basic validation is real validation and is what
every caller has actually been running. An explicit `TRUE` still hard-stops,
preserving the 2026-02-12 intent that a *requested* check is never silently
skipped. The error message now says the file is absent from this repo rather
than "check module loading".

### 3. Five helpers defined in more than one file

`sha256_of` (**6 files**, two textual forms), `pad5` (4), `fmt` (2), `chr` (2),
`with_iso_wd` (2).

`sha256_of` is **consolidated**, not ratcheted, into `R/lib/provenance.R`. It is
the hash tying an artifact to the bytes it was built from; the six copies
happened to agree, and nothing required them to. If one were ever changed — to
`openssl::sha256()` for speed, or to hash content rather than the file — two
scripts would report different provenance for the same input and nothing would
flag it.

The other four are short formatting/IO helpers in standalone numbered scripts
that are sourced individually by design. **Ratcheted at 4** and named, not
declared clean.

### Wrong test, corrected

T81's first fixture matched 1 of 2 left rows, and `safe_left_join()` **refused
it** at the 98% coverage threshold — the guard working correctly. Rewritten to
assert that refusal as behaviour rather than working around it.

### Full suite

**14/14 pass.**

### Unresolved / carried forward

- **46 bare joins vs 8 guarded**, ratcheted (T89). Now that the default is
  usable, converting them is tractable — **cycle 10**, in priority order of
  which joins feed a denominator.
- 4 duplicate helper definitions, ratcheted (T84b).
- 14 bare `.keep_all` sites, ratcheted (c5).
- **DECISION NEEDED:** reliability method for imprecise GFRs (c8).
- **DECISION NEEDED:** GFR numerator universe 15-50 vs denominator 15-44 (c7).
- **DECISION NEEDED:** `women_15_44` partial vs NA — still unratified (c7).
- **DECISION NEEDED:** Table 1 censoring on ">=15 years" (c1).
- **DECISION NEEDED:** whether a `ct_partial` region is reported (c4).

**No scientific estimand was changed in this cycle.**

---

## Cycle 9 — 2026-08-09 23:5x — 3 BVA / 3 semantic / 4 adversarial

**Target.** Joins and duplicate definitions. Tests in
`tests/test_cycle9_joins.R`; helpers consolidated into
`R/lib/common_helpers.R`; join provenance in `R/lib/provenance.R`.

**DEFECT — a helper whose meaning depended on load order.** The numbered
scripts are sourced in sequence into ONE environment, so a helper defined twice
is not two private copies; it is one name whose winner is decided by source
order. Five duplicates existed, and one had already diverged:

| helper | copies | status |
|---|---:|---|
| `pad5` | 4 | identical |
| `chr` | 2 | identical |
| `fmt` | 2 | identical |
| `with_iso_wd` | 2 | identical |
| **`%||%`** | 2 | **DIVERGENT** |

```
R/03-geography-hierarchy.R    if (is.null(a)) b else a
R/14-geocode-ob-fallbacks.R   if (is.null(a) || length(a) == 0 || all(is.na(a))) b else a
```

Same name, different answers for `NA %||% x` and `character(0) %||% x`, with
the winner set by which file was sourced last.

**Fix.** All five moved to `R/lib/common_helpers.R`. The two `%||%` behaviours
are BOTH wanted, in different places, so they were **not merged** — merging
would silently change one caller's semantics. They now have distinct names:
`%||%` keeps the standard null-coalesce, and the missing-aware variant is
`%|na|%`, which says what it does. File 14's five call sites were switched to
`%|na|%`, preserving their existing behaviour exactly.

**A duplicate the test itself missed.** T84 listed four duplicates
(`pad5`, `chr`, `fmt`, `with_iso_wd`) — it did not report `%||%`, the only
divergent one, because it matched on plain-name definitions and `%||%` is
written with backticks. Found by re-deriving duplicates through R's own parser
rather than by grep. The parser-based check is the one to keep: a
grep-shaped test misses exactly the definitions that look unusual, and those
are disproportionately the operators.

**Ratchet tightened 4 → 0.** T84's baseline recorded 4 duplicates as accepted
debt. With all five resolved, leaving it at 4 would let three creep back
without failing — debt returning under cover of a passing test.

**Behaviour preserved.** Verified each helper resolves and behaves as before
(`pad5(1234) == "01234"`, `fmt(1234.56, 1) == "1,234.6"`, `fmt(NA)` is NULL),
and that the two operators genuinely differ (`NA %||% 5` is NA;
`NA %|na|% 5` is 5) — if they agreed, splitting them would have been pointless.

**Repair during the fix.** The regex that stripped the local definitions
clipped the first line of the two-line `chr` definition and left its
continuation, breaking `R/06-cohort-flow.R` and `R/07-cohort-composition.R`.
Caught by the parse check before the suite ran, and repaired.

**Housekeeping.** `safe_left_join()` writes a timestamped provenance file per
join into `artifacts/step00_summary/`, including from the test suite — 24 files
appeared during this cycle. Diagnostics, not artifacts; now gitignored.

**Full suite.** 14/14 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED:** GFR reliability treatment (MOE-aware or smoothed).
- **DECISION NEEDED:** ratify the `women_15_44` partial-sum reading.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years".
- **DECISION NEEDED:** whether a `ct_partial` region should be reported.
- **DECISION NEEDED:** minimum cohort coverage for a Healthgrades field.
- **ACTION:** rebuild Table 1 when the crawl finishes.
- **DEBT:** 46 bare joins (8 guarded), ratcheted by T89; 14 bare `.keep_all`
  sites, ratcheted by T44.
- **HYGIENE:** duplicate test IDs across cycle 6 / cycle 7 files.

**Estimand changed:** no.

---

## Cycle 10 — 2026-08-10 — 4 BVA / 3 semantic / 3 adversarial

**Target.** The 46-bare-join inventory cycle 9 opened.

**Tests added** — `tests/test_cycle10_join_cardinality.R` (T91–T100, 15 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T91 | BVA | `many-to-one` rejects a **single** duplicate right key |
| T92 | BVA | empty right table, empty both sides |
| T93 | BVA | composite keys are unique on the pair |
| T94 | BVA | `suffix = c("", ".fin")` does not shadow a left value |
| T95 | semantic | every cohort-building join declares its cardinality |
| T96 | semantic | enriching a 100-person cohort leaves 100 people |
| T97 | semantic | a genuinely many-to-many join says so |
| T98 | adversarial | an injected duplicate is refused, not fanned out |
| T99 | adversarial | an undeclared fan-out is order-dependent |
| T100 | adversarial | undeclared-join ratchet |

### The measurement that shaped the fix

**No artifact in this repo carries a duplicate `certification_number`.** Every
person-keyed join is safe — today, by coincidence, not by contract. Same shape
as the `.keep_all` sites (c5) and the POS tie-break that has never fired (c5).

Fan-out is a scientific error rather than a tidiness one because a left join
that fans out increases the **left** row count, and here the left row count *is*
the cohort — the denominator of every proportion downstream. One duplicate row
in a lookup table silently enlarges the cohort.

### Fix: dplyr-native, not a wrapper swap

`relationship = "many-to-one"` makes dplyr itself error on a duplicated right
key, needs no dependency, and fails at the exact line. Converting 46 calls to
`safe_left_join()` would be a far larger edit for the same guarantee.

**Undeclared joins: 46 → 18.** All **cohort-building joins in `05`, `06`, `07`
and `12` now declare their cardinality** (T95 at zero). T98 proves the guard
fires by injecting the duplicate the artifacts do not have; T99 shows the same
join is order-dependent when undeclared — which is *why* it must be declared.

### Three wrong tests of my own, all in the source scanner

Worth recording together, because they share one root cause: **a
source-scanning test is itself code, and mine was wrong three ways.**

1. `code_of()` **removed** comment lines, so every reported line number indexed
   the filtered vector and pointed at innocent code several lines away. Counts
   right, diagnostics fiction. Now blanks them in place.
2. The detector read a fixed **3-line window**, so every multi-line join looked
   undeclared — including ones I had just annotated. Now reads to the closing
   paren by balancing parentheses.
3. My *annotator* skipped a join when "relationship" appeared anywhere in the
   preceding 5 lines — which matched the **previous** join's declaration. Three
   joins were silently passed over.

None of these would have failed loudly; each produced a plausible number.

### Full suite

**15/15 pass.**

### Unresolved / carried forward

- **18 undeclared joins remain**, ratcheted (T100). They are enrichment/report
  joins outside the cohort path — cycle 11 should classify rather than annotate
  in bulk, since some may be legitimately many-to-many.
- 4 duplicate helper definitions, ratcheted (c9).
- 14 bare `.keep_all` sites, ratcheted (c5).
- **DECISION NEEDED:** reliability method for imprecise GFRs (c8).
- **DECISION NEEDED:** GFR numerator universe 15-50 vs denominator 15-44 (c7).
- **DECISION NEEDED:** `women_15_44` partial vs NA — still unratified (c7).
- **DECISION NEEDED:** Table 1 censoring on ">=15 years" (c1).
- **DECISION NEEDED:** whether a `ct_partial` region is reported (c4).

**No scientific estimand was changed in this cycle.** The declarations cannot
alter any current result — every affected join already had a unique right table.
They convert a future silent error into a present loud one.

---

## Cycle 10 — 2026-08-10 00:1x — 4 BVA / 3 semantic / 3 adversarial

**Target.** Join cardinality: the class where a duplicated lookup row silently
multiplies cohort members. Tests in `tests/test_cycle10_join_cardinality.R`.

**THE DEFECT WAS IN THE TEST, IN BOTH DIRECTIONS.** T95 reported 5 undeclared
joins in the cohort scripts. All five were **false positives** — their
`relationship =` sat on a continuation line, and the paren counter started from
the line the join began on, so a first line that happened to balance ended the
scan immediately. Meanwhile it **missed every undeclared join in the files it
did not list**. Re-deriving through R's own parser (argument names off the
parsed call, immune to layout) gives 12 genuinely undeclared joins, none of
them the five originally flagged.

This is the cycle-9 lesson recurring: a text-shaped detector is wrong about
exactly the code that does not look ordinary. Both T95 and the T100 ratchet now
read parsed calls.

**Two detectors disagreed, and the looser one was winning.** T100 counted 15
where the parser counts 12. A ratchet whose detector overcounts can never
report that debt grew, because the slack absorbs it. Baseline reset to the
measured parser count (12), not the older text estimate (38 → 12).

**Fixes.** Three joins in `R/03-geography-hierarchy.R` now declare
`relationship = "many-to-one"`: the tract→planning-region join (uniqueness
already enforced by a `stop()`), and two person-keyed joins whose right sides
are already `distinct()`-ed. Behaviour-preserving by construction — the
invariant held, and is now enforced by dplyr rather than assumed.

**Scope widened after the discrimination check failed to bite.** Reintroducing
a bare join in `03-geography-hierarchy.R` was caught only by the repo-wide T100
ratchet, not by T95, because `03` was not in T95's `cohort_files` list — even
though that file assigns every midwife to a county, the unit of every access
finding here. A fan-out there duplicates people into counties. With `03` in
scope the check now fails precisely, naming the offending call.

**Full suite.** 15/15 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED:** GFR reliability treatment (MOE-aware or smoothed).
- **DECISION NEEDED:** ratify the `women_15_44` partial-sum reading.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years".
- **DECISION NEEDED:** whether a `ct_partial` region should be reported.
- **DECISION NEEDED:** minimum cohort coverage for a Healthgrades field.
- **ACTION:** rebuild Table 1 when the crawl finishes.
- **DEBT:** 12 undeclared joins (T100, parser-based); 14 bare `.keep_all` (T44).
- **HYGIENE:** duplicate test IDs across cycle 6 / cycle 7 files.

**Estimand changed:** no.

---

## Cycle 11 — 2026-08-10 — 3 BVA / 4 semantic / 3 adversarial

**Target.** `R/spatial_crs_contract.R` and the two point-in-polygon assignments
that place every midwife in a county and a congressional district.

**Tests added** — `tests/test_cycle11_spatial.R` (T101–T110, 26 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T101 | BVA | `assert_crs_equal()` at its four cases |
| T102 | BVA | zero-feature layers with and without a CRS |
| T103 | BVA | coordinate classification, incl. the real artifacts |
| T104 | semantic | every spatial binary op is guarded |
| T105 | semantic | the guard is not redundant with sf |
| T106 | semantic | point-in-polygon assignment is total |
| T107 | semantic | s2 off only around a topological op |
| T108 | adversarial | swapped lon/lat |
| T109 | adversarial | metres labelled as degrees |
| T110 | adversarial | duplicate points stay two people |

### A dead guard, and the honest size of it

`R/spatial_crs_contract.R` advertises three layers and opens with "Every spatial
binary operation must be preceded by `assert_crs_equal()`". It had **zero call
sites**. Third instance in this project of documentation describing an intended
design as an implemented one, after `compute_match_score()` and
`safe_left_join()`'s unusable default (c9).

Measuring the severity mattered more than reporting it:

| case | sf's own behaviour |
|---|---|
| mismatched CRS | **errors** |
| NA CRS one side | **errors** |
| NA CRS **both** sides | **silent, returns matches** |

Only the third is a genuine hole, and it is exactly the one the module's roxygen
claims to close. Both live call sites set CRS literally, so the guard **cannot
fire today**. Wiring it in (2 sites) makes the module's rule true rather than
aspirational; it does not fix a live defect, and the test file says so.

### The finding with real consequence: no coordinate validation existed

Nothing in this repo validated coordinate RANGES. `st_as_sf(coords =
c("longitude", "latitude"))` is order-sensitive, so a swapped pair is a valid
point in the Indian Ocean, and the assignment then reports it as "not in a
district" — **indistinguishable from a legitimate miss.**

**The naive check would have been wrong.** "Longitude must be negative" flags
three real hospitals: American Samoa (-14.3, -171), Guam (13.5, 145) and the
Northern Marianas (15.2, 146). Positive longitude is correct for the western
Pacific territories, and a sign test would delete obstetric capacity from the
places least able to spare it — the same false-positive shape as the Michigan
water-mask gate earlier in this project.

New `R/lib/coordinate_plausibility.R` therefore **classifies** rather than
rejects: `conus` / `noncontiguous` / `territory` / `implausible`.

Measured on the shipped artifacts:

| artifact | conus | noncontiguous | territory | implausible |
|---|---:|---:|---:|---:|
| `midwives_geography_FROZEN.csv` | 15,095 | 75 | 3 | **0** |
| `ob_hospitals_geocoded.csv` | 2,721 | 27 | 36 | **0** |

(1,719 midwives have no coordinates at all.)

### Defects found — 1 dead guard wired, 1 missing validation added, 0 live errors

This cycle found **no live corruption**. Stated plainly because the honest
result of an adversarial pass is sometimes that the data is clean, and reporting
it as a save would be false.

### Carried forward, and a new one

- **NEW:** 3 territory midwives and 36 territory hospitals. If the
  `congressional_districts()` / `counties()` layers exclude territories, those
  people are silently absent from every denominator. **Cycle 12 must check
  whether the assignment layers cover them**, and the pipeline's "inside a
  district: N (X%)" line should separate *implausible* from *unassigned*.
- 18 undeclared joins, ratcheted (c10).
- 4 duplicate helper definitions, ratcheted (c9).
- 14 bare `.keep_all` sites, ratcheted (c5).
- **DECISION NEEDED:** reliability method for imprecise GFRs (c8); GFR universe
  15-50 vs 15-44 (c7); `women_15_44` partial vs NA (c7); Table 1 censoring (c1);
  `ct_partial` reporting (c4).

### Full suite

**16/16 pass.**

**No scientific estimand was changed in this cycle.**

---

## Cycle 11 — 2026-08-10 00:4x — 3 BVA / 4 semantic / 3 adversarial

**Target.** Spatial contracts: CRS handling, coordinate plausibility, and
point-in-polygon cardinality. Tests in `tests/test_cycle11_spatial.R`; new
`R/lib/coordinate_plausibility.R`.

**DEFECT — a documented rule with zero call sites.**
`R/spatial_crs_contract.R` states that every spatial binary operation must be
preceded by `assert_crs_equal()`. It had **no callers anywhere in the repo**.
A contract that is never invoked is documentation, not a guard, and it reads
in review as though the check is happening.

Honestly scoped: `sf` already errors on a CRS mismatch and on a one-sided NA,
so the residual gap is narrow — **two layers that BOTH have an undefined CRS
satisfy `identical()`, and `st_join()` will happily match them**, computing
point-in-polygon on unlabelled numbers. T105a demonstrates sf doing exactly
that silently; T105b shows the assertion catching it, which is what makes the
guard non-redundant rather than ceremonial. Both call sites set CRS literally,
so this cannot fire today; the fix makes the module's own rule true rather
than aspirational.

**Also pinned this cycle.**

- A swapped lon/lat does not error — it lands outside every US polygon and
  yields NA, which reads as "no match" rather than "wrong input" (T108).
- A Web-Mercator metre coordinate mislabelled EPSG:4326 is out of degree range
  and therefore detectable (T109).
- Two midwives at the same address remain two people after a spatial join
  (T110) — the person-level counterpart to the geocode collision work in
  cycle 5.
- `s2` is disabled only around a topological operation, never around a
  measurement (T107).

**Discrimination verified.** Removing one `assert_crs_equal()` call makes T104
fail and name the exact site (`12-district-profiles.R:216`); restoring it
passes. The guard is enforced, not asserted.

**Out-of-cycle sweep (from the 10,000-certificant report).** The watcher used
`!is.na(hg_url)` as a proxy for "has a profile", which counts REJECTED
candidates as hits, and divided a full-roster numerator by the cohort
denominator — producing 63.3% and 116%, against correct values of 47.5% and
49.1%. Swept the repository for that class: **every tracked call site is
guarded by `hg_status`**. The only offenders were in the untracked ad-hoc
watcher, now retired; the corrected logic lives in
`tests/test_healthgrades_integrity.R`, which runs every cycle. (The two
apparently unguarded hits in that test file are its deliberate side-by-side
comparison of row-wise versus person-wise counting.)

**Full suite.** 16/16 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED:** GFR reliability treatment (MOE-aware or smoothed).
- **DECISION NEEDED:** ratify the `women_15_44` partial-sum reading.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years".
- **DECISION NEEDED:** whether a `ct_partial` region should be reported.
- **DECISION NEEDED:** minimum cohort coverage for a Healthgrades field —
  now quantified: projected cohort coverage at completion is **~49%**, and the
  missing half is not missing at random.
- **ACTION:** rebuild Table 1 when the crawl finishes (45.1% searched).
- **DEBT:** 12 undeclared joins (T100); 14 bare `.keep_all` (T44).
- **HYGIENE:** duplicate test IDs across cycles 6/7.

**Estimand changed:** no.

---

## Cycle 12 — 2026-08-10 — 3 BVA / 3 semantic / 4 adversarial

**Targets.** The name-normalisation shim, and the territory question cycle 11
left open.

**Tests added** — `tests/test_cycle12_names_territories.R` (T111–T120, 17
assertions, of which **5 are tracked upstream failures**)

| # | Category | Assumption challenged |
|---|---|---|
| T111 | BVA | `normalize_string()` edges; accents transliterated |
| T112 | BVA | `extract_first_initial()` on unaccented input |
| T113 | BVA | internal whitespace collapsed |
| T114 | semantic | an accented first letter yields its own initial |
| T115 | semantic | the two functions agree on the first letter |
| T116 | semantic | the county spine covers territories |
| T117 | adversarial | the bias is systematic, not incidental |
| T118 | adversarial | a fully accented name |
| T119 | adversarial | case and padding do not create two people |
| T120 | adversarial | **containment** — midwifery does not depend on it |

### The defect: a linkage key that fails only on non-Anglo names

```r
letters_only <- gsub("[^A-Z]", "", toupper(trimws(x)))
substr(letters_only, 1, 1)
```

`extract_first_initial()` **deletes** an accented first letter instead of
transliterating it, so the initial becomes the *second* letter:

| name | returned | correct |
|---|---|---|
| Élodie | **L** | E |
| Ángel | **N** | A |
| Ólafur | **L** | O |
| Álvarez | **L** | A |

**6 of 6** accented test names are mis-blocked — a 100% failure rate *within the
affected group*, and 0% outside it.

`normalize_string()` **in the same file** transliterates correctly
(`"Élodie" → "ELODIE"`). The two functions disagree about what a name is, so
blocking and comparison run on different alphabets.

First-initial blocking is a standard record-linkage key: a mis-blocked name can
never match. The failure is not random — it falls on Hispanic, Nordic, Slavic
and other non-Anglo names. **In a workforce study about who provides care and
where, a linkage failure concentrated by ethnicity is a finding about the study,
not a typo.**

Also found: `normalize_string()` does not collapse internal whitespace, so
`"Mary Ann"` and `"Mary  Ann"` are different keys for one person.

### Not fixed, and not fixable here

`R/string_normalization.R` is a shim; the implementation is in `~/isochrones`,
which this loop must not modify. The project rule also forbids vendoring a local
copy — two copies of a name rule is how two pipelines quietly disagree about who
matched whom.

**Handled as tracked upstream failures, not skips.** Each test runs, prints its
actual wrong answer, and the count is **ratcheted at exactly 5**: a sixth
upstream failure fails the file, and so does an unexpected PASS, which would
mean upstream is fixed and the bookkeeping should be deleted.

**T120 is the containment**: no midwifery script calls `extract_first_initial()`
today, so there is **no live impact in this repo**. If one ever does, that test
fails and the dependency becomes a decision rather than an accident.

**ACTION FOR THE ISOCHRONES OWNER:** `~/isochrones/R/string_normalization.R` —
`extract_first_initial()` should delegate to `normalize_string()` rather than
re-implement a stricter, ASCII-only filter.

### Cycle 11's question, answered

The county spine carries **91 territory rows** (AS, GU, MP, PR, VI) and includes
Alaska and Hawaii, and both `tigris` layers cover all five territories. So the
3 territory midwives and 36 territory hospitals are **not** silently dropped.
11 of 89 territory counties lack ACS `women_15_44` / `births_past_12mo`, which
is honest missingness rather than exclusion.

### Full suite

**17/17 files pass**, with 5 assertions tracked as upstream.

### Unresolved / carried forward

- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug;
  `normalize_string()` whitespace. Ratcheted at 5.
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).
- **DECISION NEEDED:** GFR reliability method (c8); GFR universe 15-50 vs 15-44
  (c7); `women_15_44` partial vs NA (c7); Table 1 censoring (c1); `ct_partial`
  reporting (c4).

**No scientific estimand was changed in this cycle.**

---

## Cycle 12 — 2026-08-10 01:0x — 3 BVA / 3 semantic / 4 adversarial

**Target.** Name normalisation and territory handling. Tests in
`tests/test_cycle12_names_territories.R`.

**DEFECT (upstream) — accented first letters are STRIPPED, not transliterated.**
`extract_first_initial()` in `~/isochrones/R/string_normalization.R` removes an
accented first character rather than folding it to its ASCII equivalent, so
**6 of 6 accented names block on the wrong letter** (Á→ the second letter, and
so on). First-initial blocking is a **linkage key**, so candidate pairs are
never generated for those people: the failure falls entirely on non-Anglo
names. Recorded as 5 tracked upstream failures (`xfail`), gated so a sixth
would fail the suite. `T120` confirms no midwifery script calls the function,
so the fix belongs in `isochrones` and is out of scope here.

**BUT THE ARTIFACTS WERE BUILT UPSTREAM, so the bias may already be in this
cohort.** `T120` only shows this repo does not CALL the function; the frozen
AMCB↔NPI linkage was produced by code that did. Tested directly:

| linkage_tier | n | non-ASCII names | % |
|---|---:|---:|---:|
| primary_midwifery | 14,668 | 6 | 0.041 |
| quarantined | 3,091 | 3 | 0.097 |
| unmatched | 2,326 | 7 | 0.301 |
| sensitivity_nursing | 1,896 | 0 | 0.000 |
| **sensitivity_fuzzy** | 328 | 7 | **2.134** |

Accented names are **52× more concentrated in the fuzzy-match tier** than in
the primary tier, and 5.4× more concentrated across all non-primary tiers
(0.222% vs 0.041%). Fisher exact **OR 0.18 (95% CI 0.06–0.49), p = 0.0002** for
an accented name reaching the primary tier — exactly the pattern the blocking
defect predicts: exact/blocked matching fails, and the person falls through to
fuzzy or to no match at all.

**Two honest limits on that result.** (1) Only **23 of 22,309** names contain a
non-ASCII character, so while the association is strong and significant, the
absolute number of people involved is small. (2) Non-ASCII is a **crude proxy**
for a non-Anglo name — Nguyen, Garcia and Chen are pure ASCII — so this measures
the accented subset only, and the truly affected population is larger than 23
and not identifiable by this test.

**Neither the defect nor the cohort effect is fixed here** — the function lives
in `isochrones`, and re-running linkage is not a within-cycle change. Recorded
as an action with a named owner rather than patched locally, which would create
the duplicate-definition problem cycle 9 just removed.

**Full suite.** 17/17 pass (0 failures, 5 tracked upstream), 0 skips.

**Carried forward.**

- **ACTION (new, upstream):** fix `extract_first_initial()` in
  `~/isochrones/R/string_normalization.R` to transliterate rather than strip,
  then re-run linkage. Until then the linked cohort under-represents accented
  names (OR 0.18, p = 0.0002).
- **DECISION NEEDED:** GFR reliability treatment (MOE-aware or smoothed).
- **DECISION NEEDED:** ratify the `women_15_44` partial-sum reading.
- **DECISION NEEDED:** Table 1 panel-window censoring on ">=15 years".
- **DECISION NEEDED:** whether a `ct_partial` region should be reported.
- **DECISION NEEDED:** minimum cohort coverage for a Healthgrades field (~49%
  projected).
- **ACTION:** rebuild Table 1 when the crawl finishes.
- **DEBT:** 12 undeclared joins (T100); 14 bare `.keep_all` (T44).
- **HYGIENE:** duplicate test IDs across cycles 6/7.

**Estimand changed:** no.

---

## Cycle 13 — 2026-08-10 — 4 BVA / 3 semantic / 3 adversarial

**Targets.** The cohort set arithmetic in `R/06-cohort-flow.R`, and the
row-span carry-down in `wonder_parse()`.

**Tests added** — `tests/test_cycle13_cohort_wonder.R` (T121–T130, 20 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T121 | BVA | an empty WONDER data-table |
| T122 | BVA | first row lacking outer labels — nothing to carry down |
| T123 | BVA | more labels than group-by variables |
| T124 | BVA | cohort identity at degenerate sizes |
| T125 | semantic | the identities are arithmetic, over 200 random set pairs |
| T126 | semantic | invariants and provenance pins are distinguishable |
| T127 | semantic | added/removed/retained **partition** |
| T128 | adversarial | a duplicated id breaks the row-count identity |
| T129 | adversarial | ragged WONDER rows |
| T130 | adversarial | a blank NPI passes `!is.na()` |

### The defect: two kinds of claim in one assertion

`R/06` asserted four things in a single `stopifnot()`:

```r
length(added) == 2147                        # a fact about these frozen files
length(removed) == 1352                      # a fact about these frozen files
length(retained) + length(added) == final    # arithmetic, always true
length(s2) + added - removed == final        # arithmetic, always true
```

**Their failures mean opposite things.** An identity failure means the *code* is
wrong. A pin failure means the *data* moved — which may be entirely legitimate,
since `artifacts/frozen_stage2/` and `artifacts/frozen_cohort/` are frozen
precisely so someone can refreeze them deliberately.

Conflated, both produced the same bare `length(added) == 2147 is not TRUE`, and
a reader could not tell a broken pipeline from a refrozen cohort — nor which of
the four assertions were mathematical truths and which were this vintage's
answers.

*Fixed:* separated into an **invariant** block (now also asserting pairwise
disjointness, which was never checked) and a named **provenance pin** whose
failure message states explicitly that the arithmetic still holds and only the
frozen artifacts changed.

The pins are **correct and were verified live**: stage2 16,743 → added 2,147,
removed 1,352, final 17,538, identity holds. This was a clarity defect, not an
arithmetic one — but it is the same shape as cycle 4's "violation and
unevaluable must not hide behind each other."

T125 demonstrates the identities over **200 random set pairs**, which is the
only way to show they are invariants rather than another pin.

### Latent risks confirmed, no live impact

- **T128** — `setdiff()`/`intersect()` return **unique** values while
  `length(fin_cohort)` counts **rows**, so a duplicated `certification_number`
  breaks the identity. It cannot pass unnoticed, which is the good outcome.
- **T130** — the stage-2 cohort is defined by `!is.na(npi)`, and an empty
  string is not `NA`. Measured on the frozen file: **22,309 rows, 5,566 NA,
  0 blank, 0 malformed.** Clean today; the guard is now stated.

### wonder_parse carry-down holds

All four edges pass: empty table, a first row with no outer label (stays `NA`
rather than fabricating one), more labels than group-by variables, and ragged
rows (padded with `NA`, never filled from a neighbour, with the outer label
carrying down correctly).

### Full suite

**18/18 files pass.**

### Unresolved / carried forward

- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug, ratcheted at
  5 (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).
- **DECISION NEEDED:** GFR reliability method (c8); GFR universe 15-50 vs 15-44
  (c7); `women_15_44` partial vs NA (c7); Table 1 censoring (c1); `ct_partial`
  reporting (c4).

**No scientific estimand was changed in this cycle.**

---

## Cycle 14 — 2026-08-10 01:5x — 3 BVA / 4 semantic / 3 adversarial

**Target.** The dissolved coverage surfaces — the central geographic claim of
the study, untouched by cycles 1–13. Tests in
`tests/test_cycle14_coverage_surfaces.R`; contracts in
`R/lib/coverage_surface_contracts.R`. Both defects produce a **plausible map
from a broken input**, the worst thing a figure can do.

**DEFECT 1 — the land clip was conditional on a USB drive.**

```r
water_dir <- "/Volumes/MufflySamsung/nhdplus_hr/water_masks"
if (dir.exists(water_dir)) { ...clip... }
```

With the drive unmounted the clip is skipped, nothing errors, and the surfaces
again run over the Great Lakes — 10.3% and 12.9% open water counted as drivable
ground, the defect already in the Hall of Shame. Whether the published map was
correct depended on **whether a drive happened to be plugged in**, and nothing
in the output recorded which had happened.

Replaced with `water_clip_provenance()`, which refuses a final build when masks
are missing and writes `artifacts/coverage_clip_provenance.csv` either way.
Verified on real data: drive present → 49/49 masks, `clip_applied=TRUE`,
`final=TRUE`; simulated absence → 0/49, `final=FALSE`.
`MIDWIFERY_ALLOW_UNCLIPPED=1` permits a deliberate exploratory run, which is
then recorded as not final.

**DEFECT 2 — nesting was enforced by mutation.** The loop unioned each smaller
band into the larger, so the invariant always held afterwards. But a 30-minute
surface escaping its own 60-minute surface is *evidence*: the two routing
engines disagree by up to 15% in area, and an escape is how that disagreement
appears geographically. Absorbing it made the invariant true and destroyed the
evidence in one statement. The escape is now measured first, warned on, and
written to `artifacts/coverage_nesting_report.csv` before absorption proceeds.

**Cycle 11's guard failed cycle 14's code — as intended.** `nesting_escape_km2()`
called `st_difference()` without `assert_crs_equal()`, and T104 (written two
cycles ago, when the contract had zero callers) caught it. The guard is load-
bearing, not decorative.

**Two of my own tests were wrong, and the code was right both times.**

- **T132** expected 1,875 km² of escape; the true overlap is the 10 km × 10 km
  corner, so the answer is 2,400. Careless geometry on my part.
- **T139** assumed `sf` returns square degrees for a lon/lat layer with s2
  disabled. It does not — sf 1.1 computes a geodesic area either way
  (10,000.28 km² vs 10,000.00 from the equal-area projection). Rewritten to
  assert the property that actually protects the number: the two routes agree
  to **0.239%**, so a coverage area is reproducible regardless of which CRS an
  intermediate step left behind.

**The sweep flagged its own documentation.** T138's first version matched the
explanatory comment describing the retired `if (dir.exists(water_dir))`
construct. A text sweep that fires on prose either produces false alarms or
teaches the next person to delete the explanation to get green. Comments are
now stripped before matching. Discrimination re-verified afterwards:
reinstating the bare gate fails T138 and names the line.

**Full suite.** 19/19 pass, 0 skips.

**Carried forward.**

- **ACTION (new):** the nesting report is written but never asserted against a
  threshold — what escape magnitude should FAIL a build is a scientific
  question about engine comparability, not a code default. **Flagged, not set.**
- **ACTION (upstream):** fix `extract_first_initial()`; the linked cohort
  under-represents accented names (OR 0.18, p = 0.0002).
- **DECISION NEEDED:** GFR reliability treatment; `women_15_44` partial-sum;
  Table 1 panel censoring; `ct_partial` reporting; minimum Healthgrades
  coverage (~49% projected).
- **ACTION:** rebuild Table 1 when the crawl finishes (49.9% searched).
- **DEBT:** 12 undeclared joins (T100); 14 bare `.keep_all` (T44).
- **HYGIENE:** duplicate test IDs across cycles 6/7.

**Estimand changed:** no — but a build that would previously have produced an
unclipped surface now refuses, which will change what gets published if the
drive is ever absent.

---

## Cycle 15 — 2026-08-10 — 3 BVA / 3 semantic / 4 adversarial

**Target.** `R/lib/ob_hospitals.R` — what makes a hospital "obstetric" — and the
county sentence that reports it. This defines the hospital denominator for every
obstetric-capacity claim in the project.

**Tests added** — `tests/test_cycle15_ob_capacity.R` (T141–T150, 15 assertions)

| # | Category | Assumption challenged |
|---|---|---|
| T141 | BVA | ob + unknown never exceeds active |
| T142 | BVA | GEOID is 5 characters (state+county, unpadded paste) |
| T143 | BVA | no-hospital and hospital-but-no-OB are distinct |
| T144 | semantic | the all-unknown case gets its own sentence |
| T145 | semantic | positives are phrased as *reporting*, not *having* |
| T146 | semantic | unknown is a first-class status |
| T147 | adversarial | both sentences are reachable |
| T148 | adversarial | the comment's rural claim, tested |
| T149 | adversarial | an unrecognised service code |
| T150 | adversarial | row-order invariance of every county count |

### The finding: a sentence built from silence

**19,352 of 23,830** active hospital records (**81.2%**) carry no `OB_SRVC_CD`
at all. The module handles this correctly — three-way yes/no/unknown, with
`n_hosp_ob_unknown` carried out. **The sentence did not:**

```r
n_hosp_ob == 0  ->  "N active hospitals, none of which reports obstetric services"
```

was emitted regardless of *why* the count was zero. Of the **1,451** counties
receiving it, **651 (45%)** have every active hospital's OB status missing. The
sentence is generated from pure silence, and a reader hears "no obstetric care
here" from a field the source never filled in.

Unknown is not no — the same principle as cycle 3's suppressed-is-not-zero, now
in **published prose** rather than in a denominator.

*Fixed:* two facts, two sentences. Nothing that is **counted** changes.

### A comment that was backwards

The code beside that sentence asserted the silence is "commonest in small rural
counties". Measured:

| rurality | 'no OB' counties | all-unknown | % |
|---|---:|---:|---:|
| Metro (RUCC 1-3) | 422 | 233 | **55.2%** |
| Nonmetro, adjacent | 171 | 48 | 28.1% |
| Nonmetro, remote | 858 | 370 | 43.1% |

All-unknown is **most** common in metro counties, not rural ones. T148 pins this
so the claim cannot drift back into prose. A plausible aside in a comment is not
evidence.

### Class closed: the trailing `TRUE` branch

`ob_status` ended `TRUE ~ "no"`, asserting "this hospital has no obstetric
service" for **any** code outside 1–3, including one POS has not used yet. That
is precisely the construction cycle 1 removed from the RUCC banding rule, where
an unexpected value was confidently labelled "Nonmetropolitan, remote".

*Fixed:* only a recorded `"0"` means no; anything else is unknown. The live
extract carries only 0/1/2/3, so **behaviour is unchanged today** — which is
exactly why the branch had never been tested by data. Third instance of this
class (RUCC c1, WONDER `flag == "ok"` c3, OB service code c15).

### Full suite

**20/20 files pass.**

### Unresolved / carried forward

- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug, ratcheted at
  5 (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).
- **DECISION NEEDED:** GFR reliability method (c8); GFR universe 15-50 vs 15-44
  (c7); `women_15_44` partial vs NA (c7); Table 1 censoring (c1); `ct_partial`
  reporting (c4).

**No scientific estimand was changed in this cycle.** No count moved; one
misleading sentence was split into two accurate ones, and one unreachable
branch was made honest.

---

## Cycle 15 — 2026-08-10 02:1x — 3 BVA / 3 semantic / 4 adversarial

**Target.** Obstetric hospital capacity from the POS extract, and the county
sentences generated from it. Tests in `tests/test_cycle15_ob_capacity.R`.

**DEFECT 1 — a sentence asserting absence from a blank field.** The county
narrative emitted *"N active hospitals, none of which reports obstetric
services"* whenever `n_hosp_ob == 0`, regardless of why. Measured: of the
**1,451** counties receiving that sentence, **651 (45%)** have every active
hospital's `OB_SRVC_CD` missing. The sentence was generated from pure silence,
and a reader hears "no obstetric care here" from a field the source never
filled in. Two different facts now get two different sentences. **Nothing that
is counted changes.**

**DEFECT 2 — the cycle-1 class, recurring.** `build_ob_hospital_counts()` ended
its recode with `TRUE ~ "no"`, so ANY code outside 1–3 — including one POS has
not used yet — was asserted to mean "this hospital has no obstetric service".
That is exactly the construction cycle 1 removed from the RUCC banding rule,
where an unexpected code was confidently labelled "Nonmetropolitan, remote".
Only a recorded `0` is a no; anything else is unknown.

Behaviour preserved on current data: T149b confirms the live extract carries
only codes 0–3, so no hospital changes category today. The fix is against the
next vintage, not this one.

**A comment's guess was wrong, and the data said so.** The code carried an
aside that all-unknown OB records are "commonest in small rural counties". They
are not: all-unknown runs **55.2% in metro, 43.1% in remote, 28.1% in
adjacent**. Corrected in place — a plausible aside in a comment is not
evidence, and this one would have supported a rural-access narrative the data
does not.

**Full suite.** 20/20 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED:** nesting-escape threshold that should fail a build (c14).
- **DECISION NEEDED:** GFR reliability treatment; `women_15_44` partial-sum;
  Table 1 panel censoring; `ct_partial` reporting; minimum Healthgrades
  coverage (~49% projected).
- **ACTION (upstream):** `extract_first_initial()` accent stripping — linked
  cohort under-represents accented names (OR 0.18, p = 0.0002).
- **ACTION:** rebuild Table 1 when the crawl finishes.
- **DEBT:** 12 undeclared joins (T100); 14 bare `.keep_all` (T44).
- **HYGIENE:** duplicate test IDs across cycles 6/7.

**Estimand changed:** no. Counts are identical on the current POS vintage; only
the sentence attached to 651 counties changes, and it changes from an assertion
to an accurate statement of ignorance.

---

## Cycle 16 — 2026-08-10 — 4 BVA / 3 semantic / 3 adversarial

**Target.** The ACS variable maps in `R/01-build-county-base.R` and
`R/12-district-profiles.R`: do the variable NUMBERS match the quantities the
code names them?

**Tests added** — `tests/test_cycle16_acs_variables.R` (T161–T170, 15 assertions)

### The defect — the most consequential this loop has found

```r
R/01:  women_labels <- paste0("w", 30:39)      # TEN bands
R/12:  sprintf("B01001_%03dE", 30:38)          # NINE bands
```

The same named quantity had **two different definitions in one project**.
Against the official ACS 2023 labels:

| variable | label |
|---|---|
| `B01001_030E` | Female: **15 to 17 years** — the comment called this "15-19" |
| `B01001_038E` | Female: 40 to 44 years — the last band of 15-44 |
| `B01001_039E` | Female: **45 to 49 years** — was being summed in |

So the county column named `women_15_44` contained **women 15-49**.

**Measured, then verified by rebuilding:**

| | before | after |
|---|---:|---:|
| national `women_15_44` | 76,046,473 | **65,895,592** |
| denominator overstatement | 15.4% | — |
| median county GFR | 56.0 | **64.7** (+15.7%) |
| max county GFR | 448.7 | 482.8 |

**Every county general fertility rate in the project was understated by 13.3%.**

And the error is **differential**, not a constant scale: the per-county
inflation factor ran from 1.164 (median) to **1.846** (max). A uniform error
would leave rankings intact; this one moved counties relative to one another —
the same concern cycle 8 raised about filters, applied to a denominator.

The district script was right. The county script was wrong. **Nothing compared
them**, because nothing asserted what the variable numbers mean. T165 is that
assertion now.

### Fixed, and the artifact rebuilt

Code fixed to `30:38` at all five sites, and `data/county_base.csv` **rebuilt**
— because a corrected formula with a stale artifact is the more dangerous state:
the code now looks right. T164 fails until a rebuild stamp exists.

### Two ratchets updated, deliberately

Counties exceeding the GFR plausibility bound rose **9 → 19** — because a defect
was fixed, not because data degraded. Correcting the denominator raised every
rate, so more counties clear the bound. Cycle 7's T67a and cycle 8's T72 were
updated with that reason recorded in each.

**Cycle 8's differential-exclusion contract still holds**: the new exclusion runs
0.00% metro / 0.15% adjacent / **1.37%** remote — a 1.37 pp spread, well inside
the 5 pp limit.

### Full suite

**21/21 files pass.**

### Unresolved / carried forward

- **ACTION:** anything computed downstream from `county_base.csv` (profiles,
  Table 1, figures) predates this fix and must be regenerated.
- **DECISION NEEDED:** GFR universe — `births_past_12mo` is B13016_002, universe
  women **15-50**, over a 15-44 denominator (c7). **This defect makes that one
  sharper**, since the denominator is now correct and the mismatch is the only
  remaining inconsistency in the rate.
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**Estimand changed:** yes — every county fertility rate rose ~13%, because the
denominator is now the population the column has always claimed to be.

---

## Cycle 16 — 2026-08-10 02:4x — 4 BVA / 3 semantic / 3 adversarial

**Target.** The ACS variable definitions behind every fertility figure. Tests
in `tests/test_cycle16_acs_variables.R`.

**DEFECT — `women_15_44` included ages 45–49.** The denominator summed TEN
`B01001` female bands, `_030` through `_039`. `_039` is **45–49**, outside the
range the column's own name asserts. Effects:

- denominator inflated **15.4%**, so every general fertility rate was
  understated by **13.3%**;
- the inflation factor varies **1.16× to 1.85×** across counties, so the
  **ranking moved**, not merely the level.

**External validation, which is what settles it.** National `women_15_44`:
**76,046,473 → 65,895,592**. The published US figure for women aged 15–44 is
~65–66 million. The corrected total lands inside that range; the old one
**exceeded it by 10 million** — a number that could have been checked against
one published statistic at any point.

**Artifacts rebuilt, not just code.** `data/county_base.csv` was regenerated,
and the downstream `artifacts/county_midwifery_supply.csv` was found **stale**
(still carrying 76.0M) and rebuilt to match. A code fix without an artifact
rebuild would have left every published figure wrong while the tests passed.

**A VACUOUS TEST OF MY OWN, from cycle 8.** T77 read
`sup$general_fertility_rate` from `county_midwifery_supply.csv` — a column that
**does not exist there**. `!is.na(NULL)` is `logical(0)`, so the exclusion set
was empty, and the test reported "0 of 11,762, 0.00%" and passed regardless of
the data. The claim reported to the owner last cycle — "the excluded counties
hold zero midwives" — was never actually tested. This is the same trap cycles 4
and 6 caught elsewhere, and I fell into it while fixing another instance of it.

Rewritten to join the rate (`data/county_base.csv`) to the midwife counts
(supply artifact) and to assert the columns EXIST before computing. Real
answer: **19 counties** now exceed the plausibility bound — up from 9, because
the corrected denominator raised every GFR by ~15% — and they hold **0 of
11,762 midwives**. The conclusion survives; it is now measured.

**A test that crashed instead of failing.** The first repair guarded with
`is.na(gkey)`, so a wrong-but-non-NA column name slipped through and the file
errored rather than printing FAIL — in a loop that greps for "FAIL", a crash is
indistinguishable from silence. Now guarded on membership, and the missing-
column path fails cleanly.

**Full suite.** 21/21 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED:** with the denominator corrected, the GFR reliability
  question (cycle 8) is unchanged but the numbers moved — median county GFR is
  now 64.7 and 19 counties exceed 200.
- **DECISION NEEDED:** nesting-escape threshold (c14); `women_15_44`
  partial-sum (c7); Table 1 panel censoring (c1); `ct_partial` (c4); minimum
  Healthgrades coverage (c6).
- **ACTION (upstream):** `extract_first_initial()` accent stripping.
- **ACTION:** rebuild Table 1 when the crawl finishes (53.5% searched).
- **ACTION (new):** re-check any figure or sentence already generated from the
  inflated denominator — `make_readme_figures.R` reads these artifacts.
- **DEBT:** 12 undeclared joins (T100); 14 bare `.keep_all` (T44).

**Estimand changed: YES, and materially.** Every general fertility rate rises
~15%, and county rankings change. This is a correction, not a choice — the old
denominator counted 45–49-year-olds as women aged 15–44.

---

## Cycle 17 — 2026-08-10 — 3 BVA / 4 semantic / 3 adversarial

**Target.** Sweep the class cycle 16 opened: verify **every** ACS variable in
the repo against the official 2023 labels, and pin them.

**Tests added** — `tests/test_cycle17_acs_labels.R` (T171–T180, 16 assertions)

### The sweep came back clean

**34 of 34** ACS variables denote what the code calls them — including the
C-tables, which my first pattern missed and which is exactly where this project
was bitten before (`C27007_004` is male under 19). Reported as a clean result
rather than dressed up.

The value delivered is the **contract**. Cycle 16's defect existed because
nothing asserted what a variable number means, so a plausible comment stood in
for a check and was wrong on both ends. **T173 is that check**, for every
age-bearing variable.

### The defect it did find: a universe mismatch, in both scripts

```
births_12mo = B13016_002E     universe: women 15 to 50
denominator = women_15_44     universe: women 15 to 44
printed as    "per 1,000 women aged 15-44"
```

Births to women 45-50 were in the numerator while those women were excluded
from the denominator. This is the decision carried open since cycle 7 — now
**quantified** rather than restated:

| | value |
|---|---:|
| births to women 45-50 | 117,458 of 4,018,403 |
| national share of numerator | **2.92%** |
| per-county share, median | 0.21% |
| per-county share, p95 | 10.24% |
| per-county share, **max** | **100%** |

**Differential again**, like cycle 16's band error — it moved counties relative
to one another, not just a level.

**Fixed, and I judged this a correction rather than an estimand choice.**
`B13016_009E` *is* that age group, so subtracting it makes numerator and
denominator the same population. A general fertility rate is conventionally
15-44 and the printed label already said 15-44, so "keep it" was not among the
defensible options. Dividing by `women_15_50` and relabelling to a 15-50 rate
remains available and is recorded here as the alternative.

Rebuilt: median county GFR **64.7 → 63.0** (−2.7%); counties over the
plausibility bound **19 → 16**.

### Cross-cycle contradiction, again

Cycle 16's **T167a pinned the whole GFR expression**, including the numerator
cycle 17 then correctly changed — so the suite briefly held two incompatible
expectations, the same failure caught in cycle 8. Updated to assert the claim it
is *about* (the denominator) and leave the numerator to T174. **A test should
pin the claim it is about, not the line it happened to read.** That is now the
second instance; worth watching at the final audit.

### One wrong test of my own

T173 first failed on `B01001_026E` and `B13016_001E`. Both are universe totals I
had verified but omitted from the pinned table — **my table was incomplete, the
code was not.** Added, with `B13016_001E` noted as women 15-50, which is what
the county script accurately names `women_15_50`.

### Full suite

**22/22 files pass.**

### Unresolved / carried forward

- **ACTION:** downstream artifacts built from `county_base.csv` need
  regenerating again (profiles, Table 1, figures) — the rate changed twice.
- **DECISION NEEDED:** GFR reliability method for imprecise-but-possible rates
  (c8); `women_15_44` partial vs NA (c7); Table 1 censoring (c1); `ct_partial`
  reporting (c4). **The GFR universe decision (c7) is now CLOSED.**
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**Estimand changed:** yes — the fertility numerator is now births to women
15-44, matching the denominator and the printed label.

---

## Cycle 17 — 2026-08-10 03:2x — 3 BVA / 4 semantic / 3 adversarial

**Target.** ACS universe labels — the mirror image of cycle 16. Tests in
`tests/test_cycle17_acs_labels.R`.

**DEFECT — the NUMERATOR spanned a different universe than the denominator.**
Cycle 16 restricted `women_15_44` to nine bands. The births numerator comes
from `B13016`, whose universe is **women 15–50**. So a corrected 15–44
denominator was being divided into a 15–50 numerator: a rate whose top and
bottom describe different populations.

Measured: births to women 45–50 are **2.92% of the national numerator**, but
the per-county share runs from a **0.21% median to 100% maximum** — differential
across counties, so it distorts comparisons and not merely the level.

**External validation, and an honest limit on it.** With both fixes the
national rate is **59.2 per 1,000** (unrestricted numerator: 61.0). NCHS
reports **54.5** for 2023. The remaining ~9% gap is *expected*: ACS `B13016` is
a self-reported survey question and is known to run above vital-statistics
births. **But the column is named `general_fertility_rate`**, and a reader will
compare it to the NCHS GFR. Naming it for what it is —
ACS-reported births per 1,000 women 15–44 — is a manuscript decision, recorded
rather than taken.

**A TEST DEFEATED BY THE COMMAND ITS OWN MESSAGE SUGGESTED.** Cycle 16's T164
asserted only that `data/.county_base_rebuilt_after_cycle16` exists — satisfied
by `touch`, without rebuilding anything, and its failure message told you to
run exactly that. Replaced with a check of the artifact's CONTENT against the
published figure: national `women_15_44` must fall in 60–70M. Discrimination
verified — the pre-fix artifact (76.0M) fails it, the rebuilt one (65.9M)
passes. The stamp file was deleted.

**A flaky failure, diagnosed rather than retried.** `test_cycle16` failed once
in the suite and passed immediately after. Cause: a concurrent cron cycle was
rewriting `data/county_base.csv` while the suite read it — the same
read-during-write hazard the crawler snapshots exist to avoid. Not a code
defect; recorded because a test that fails once and passes on retry is
otherwise dismissed as noise.

**Full suite.** 22/22 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED (new):** rename `general_fertility_rate` to name its ACS
  survey basis, or state the divergence from NCHS wherever it is published.
- **DECISION NEEDED:** nesting-escape threshold (c14); GFR reliability (c8);
  `women_15_44` partial-sum (c7); Table 1 panel censoring (c1); `ct_partial`
  (c4); minimum Healthgrades coverage (c6).
- **ACTION (upstream):** `extract_first_initial()` accent stripping.
- **ACTION:** rebuild Table 1 when the crawl finishes; regenerate README
  figures built from the pre-fix denominator.
- **DEBT:** 12 undeclared joins (T100); 14 bare `.keep_all` (T44).

**Estimand changed: YES.** The numerator now excludes births to women 45–50,
lowering the national rate from 61.0 to 59.2 per 1,000. A correction, not a
choice: a 15–44 rate cannot count births to 45–50-year-olds.

---

## Cycle 18 — 2026-08-10 — 3 BVA / 3 semantic / 4 adversarial

**Target.** Stale artifacts and mismatched vintages — a hazard **this loop
created twice and flagged twice** without ever building a mechanism to catch it.

**Tests added** — `tests/test_cycle18_artifact_freshness.R` (T181–T190, 15
assertions, 1 tracked)

### The live finding

Cycles 16 and 17 rebuilt `data/county_base.csv`. **Seven downstream artifacts
still described the old numbers**, dated 08-08 against an input rebuilt 08-10.
Nothing said so — a reader opening `geocoding_completeness_rucc.csv` sees a
table, not a date.

Five were **regenerated this cycle** (R/02, R/05). Two remain, and the reason is
the more interesting finding.

### R/03 has been unable to complete, and nobody noticed

`R/03-geography-hierarchy.R` **aborts on its own data invariant**:

> INVARIANT: 1163 records where the coordinate source's address disagrees with
> the pinned roster address.

**Verified pre-existing**, not a regression from this loop: I suspected my own
cycle-5 change (which made the geocode dedup `arrange(desc(quality_score))`
before `distinct()`, and so could pick a different coordinate row). Ran the
**pre-cycle-5 version of the file** — it fails with the **identical 1,163**. So
the guard predates the loop's work entirely.

The failure was invisible because **the artifacts the script left behind still
exist**. A stage that aborts leaves its previous output in place, and every
downstream reader treats that as current. This is a data question — which
address is right — not a code fix, so it is recorded rather than papered over.

### Why the mechanism is content-based, not mtime

mtime found this and will lie tomorrow: `git checkout`, `cp`, `rsync` and
archive extraction all rewrite modification times in either direction, so a
fresh clone can show every artifact "newer" than its inputs while containing
stale numbers. **T189 demonstrates the inversion directly.**

`R/lib/artifact_provenance.R` therefore records the **SHA-256 of every input**
beside each artifact at write time and compares content. T184 pins the
distinction that matters: an input that is *newer but unchanged* is not
staleness. It reuses the canonical `sha256_of()` from cycle 9 rather than adding
a seventh copy — asserted by T186.

The dependency graph is **read from the scripts themselves**, not hard-coded, so
a new `read_csv`/`write_csv` pair is covered without editing the test.

### Full suite

**23/23 files pass**, with 1 tracked expected failure (the two R/03 artifacts),
ratcheted from 7 → 2.

### Unresolved / carried forward

- **DATA QUESTION (new):** the 1,163 address disagreements blocking R/03. Until
  resolved, `geography_class_counts.csv` and `geography_by_linkage_status.csv`
  cannot be regenerated and remain stale.
- **ACTION:** `write_with_provenance()` exists but no pipeline script calls it
  yet; wiring it in is cycle 19's natural next step.
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**No scientific estimand was changed in this cycle.**

---

## Cycle 18 — 2026-08-10 03:5x — 3 BVA / 3 semantic / 4 adversarial

**Target.** Artifact freshness and provenance — the follow-up to cycles 16/17,
where a code fix without an artifact rebuild left published figures wrong while
the tests passed. Tests in `tests/test_cycle18_artifact_freshness.R`; new
`R/lib/artifact_provenance.R`.

### THE CYCLE RE-FROZE THE FROZEN COHORT. That was REVERTED.

The cycle regenerated `artifacts/frozen_cohort/analytic_cohort.csv`, moving the
analytic population **17,538 → 16,892**: **1,563 certificants removed, 917
added**. The trigger is real — the fingerprint pins
`midwives_geography_guarded.csv` at mtime `08-08 18:59` (17,538 rows), while
the live source was updated at `08-08 20:17` (16,892 rows), so the frozen copy
had pinned a superseded version. The newer source is *better* on its face:
`county_best` coverage rises from 15,174/17,538 (86.5%) to 16,506/16,892
(97.7%).

**But re-freezing is not a cycle's decision to take.** Freezing exists to pin
the population so results are reproducible; silently re-pinning changes the
denominator of every downstream analysis, including Table 1's 11,913. The
re-freeze and all six artifacts regenerated from it were reverted with
`git checkout`, restoring the 17,538-row pin.

**DECISION NEEDED — the highest-priority item on this list.** Either re-freeze
deliberately and re-run everything downstream (Table 1, county products,
access findings), or keep the current pin and record that the geography source
has moved on. Both are defensible; neither may be chosen by the loop.

**Detection added rather than repair.** T187's mtime sweep did not look at the
frozen cohort at all — the one artifact where silent drift matters most was the
one unchecked. Its scope now includes the pin, and it reports:

```
FROZEN PIN DIVERGED: fingerprint records 17,538 rows, live source has 16,892.
DECISION NEEDED -- re-freezing changes the analytic population.
```

**Pre-existing failure, verified as such.** Two artifacts
(`geography_class_counts.csv`, `geography_by_linkage_status.csv`) cannot be
regenerated because `R/03-geography-hierarchy.R` aborts on its own invariant:
1,163 records whose coordinate-source address disagrees with the pinned roster
address. The cycle verified the pre-cycle-5 version of that script fails with
the **identical count**, so this is not a regression from the loop. It is a
data question — which address is right — and is tracked, not silenced.

**Full suite.** 23/23 pass (0 failures, 1 tracked), 0 skips.

**Carried forward.**

- **DECISION NEEDED (new, highest priority):** re-freeze the cohort against the
  updated geography source, or keep the pin. 17,538 vs 16,892.
- **DECISION NEEDED:** `general_fertility_rate` naming vs NCHS (c17); nesting
  escape threshold (c14); GFR reliability (c8); `women_15_44` partial-sum (c7);
  Table 1 panel censoring (c1); `ct_partial` (c4); Healthgrades coverage (c6).
- **DATA QUESTION:** 1,163 address disagreements blocking `R/03`.
- **ACTION (upstream):** `extract_first_initial()` accent stripping.
- **ACTION:** rebuild Table 1 when the crawl finishes; regenerate README figures.
- **DEBT:** 2 stale artifacts (T188); 12 undeclared joins; 14 bare `.keep_all`.

**Estimand changed:** no — the attempted change was reverted, which is the
point of this entry.

---

## Cycle 19 — 2026-08-10 04:2x — 4 BVA / 3 semantic / 3 adversarial

**Target.** The 1,163 address-provenance disagreements that block
`R/03-geography-hierarchy.R` — the data question cycle 18 surfaced. Tests in
`tests/test_cycle19_address_provenance.R`.

**The boundary was respected.** The cycle triaged the disagreements without
resolving them: T196a confirms the invariant still ABORTS rather than warning,
and T196b confirms the abort is **not conditioned on impact class** —
*triage informs, it does not excuse*. Which address is correct remains the
owner's data question.

**Triage (strict per-ZIP classification, matching the shipped evidence file):**

| class | n | |
|---|---:|---|
| different state | 390 | definitely misplaced |
| different county, same state | 175 | definitely misplaced |
| same county | 171 | demonstrably harmless |
| ZIP spans several counties | 427 | **cannot be placed either way** |

565 (48.6%) definitely change county; 427 (36.7%) are unresolvable; only 171
(14.7%) are harmless. County is the unit of every access finding, so the
invariant is catching real placement error — and relaxing it to "same county is
fine" would still admit 48.6% while guessing at another 36.7%.

**PROSE DISAGREED WITH DATA, IN THE SAME COMMIT.** The comment added to `R/03`
quoted **612 / 318 / 209 / 24** while the evidence file it shipped alongside
held **390 / 175 / 171 / 427**. The comment's figures came from a superseded
land-dominant assignment, which pushes every multi-county ZIP into its largest
county and so reported 24 unresolvable instead of 427. Its headline claim —
"930 of 1,163 (80%) move to a different county" — overstated certainty; the
strict figure is 48.6% definite with 36.7% unknowable.

Two number sets in one repo, and the wrong one is the one that reaches a
manuscript. The comment now carries the strict counts, and **T194b asserts the
figures quoted in the source match the artifact**. Discrimination verified:
restoring `612` makes it fail.

**Full suite.** 24/24 pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED (highest priority):** re-freeze the cohort or keep the pin
  (17,538 vs 16,892) — cycle 18.
- **DATA QUESTION (now triaged, still open):** which address is authoritative
  for the 565 records that definitely change county, and what to do with the
  427 that no ZIP can place.
- **DECISION NEEDED:** `general_fertility_rate` naming (c17); nesting escape
  threshold (c14); GFR reliability (c8); `women_15_44` partial-sum (c7);
  Table 1 panel censoring (c1); `ct_partial` (c4); Healthgrades coverage (c6).
- **ACTION (upstream):** `extract_first_initial()` accent stripping.
- **ACTION:** rebuild Table 1 when the crawl finishes; regenerate README figures.
- **DEBT:** 2 stale artifacts; 12 undeclared joins; 14 bare `.keep_all`.

**Estimand changed:** no.

---

## Cycle 19 — 2026-08-10 — 4 BVA / 3 semantic / 3 adversarial

**Target.** The address-provenance invariant blocking `R/03`, carried from c18.

**Tests added** — `tests/test_cycle19_address_provenance.R` (T191–T200, 17
assertions)

### The question, and the answer being "no"

The guard aborts the whole stage whenever the roster ZIP/state differs **as a
string** from the address the coordinates were geocoded from. 1,163 records trip
it. A string-equality check that halts a pipeline is exactly the shape of an
over-strict guard, so it was investigated as one.

**It is not over-strict, and it is deliberately not relaxed.** Resolving both
addresses through the ZCTA-county crosswalk:

| impact | strict (`GEOID_unique`) | land-dominant |
|---|---:|---:|
| different **state** | 390 | 612 |
| different county, same state | 175 | 318 |
| **same county** (harmless) | 171 | 209 |
| unresolvable (multi-county ZIP) | 427 | 24 |

On the permissive reading **930 of 1,163 (80%)** land the record in a different
**county** — the unit of every access finding here. On the strict reading at
least **565** do and 427 cannot be determined. Loosening to "same county is
fine" would still admit the large majority.

### What was actually wrong: triage, not threshold

All 1,163 were reported at one severity, so nobody could separate the cross-state
cases from the ~171 harmless ones. The evidence file now carries `county_impact`
and the abort prints the breakdown. **T196 asserts the guard still aborts and is
not conditioned on the impact class** — triage informs, it does not excuse.

T197 pins that a multi-county ZIP is reported **unresolvable** rather than
assigned to whichever county holds the most land: a guess presented as a fact is
worse than an admission.

T198 is the one that kills the tempting shortcut: **175 same-STATE disagreements
still change the county**, so "same state, therefore fine" is not safe.

### A regression I introduced, caught by my own ratchet

My two new joins pushed `test_cycle9_joins.R` T89 over its limit. Both **declare
`relationship = "many-to-one"`** — the failure exposed that **T89's premise was
superseded**: it counted *every* join, so adding a correctly-declared one failed
the ratchet, penalising exactly the practice cycle 10 established. Recounted on
cycle 10's basis (undeclared joins only), limit 18. That is a wrong test
corrected, not a ratchet loosened.

### A note on method, recorded because it is embarrassing and instructive

My first pass read the evidence file, found **90 rows** against a message
claiming 1,163, and was about to report a count/evidence mismatch. The file was
the **stale 08-08 copy** — I was fooled by a stale artifact while investigating
stale artifacts, one cycle after building the detector for them. Re-running the
script first gives 1,163, matching the message exactly.

### Full suite

**24/24 files pass.**

### Unresolved / carried forward

- **DATA QUESTION:** the 1,163 address disagreements. Now triaged: 390 land in a
  different state, 175 in a different county, 171 are harmless, 427 involve a
  ZIP that cannot place anyone. R/03 stays blocked until these are resolved.
- 2 stale artifacts, both downstream of R/03 (c18).
- **ACTION:** `write_with_provenance()` still unwired (c18).
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**No scientific estimand was changed in this cycle.** The guard's threshold is
untouched; only its diagnostic improved.

---

## Cycle 20 (second pass) — 2026-08-10 — 3 BVA / 4 semantic / 3 adversarial

**Note on concurrency.** A cron cycle-20 ran on the same theme
(`test_cycle20_boundary_vintage.R`). This pass targets the roster join and the
per-row disclosure; both suites pass.

**Target.** `R/lib/congress_roster.R` and the district-profile join — never
tested, and the place where a **named human being** is attached to a set of
statistics.

**Tests added** — `tests/test_cycle20_congress_vintage.R` (T201–T210, 18
assertions)

### The finding: a correct disclosure, said uselessly

`boundary_vintage` documented a real problem and then wrote **one constant
string on all 437 rows**. ACS 2023 reports on 118th-Congress boundaries while
the roster is the 119th, and five states — **AL, GA, LA, NY, NC** — redrew their
maps in between. So **67 of 437 districts (15.3%)** pair a member with statistics
describing differently-shaped ground, and 370 do not.

**Colorado carried the same warning as Alabama.** A disclosure that says the same
thing everywhere tells a reader nothing about their own district. It is per-row
knowable, so it is now per-row stated, with `redistricted_since_acs` as a
machine-readable flag and T206 asserting flag and prose can never disagree.

### A claim I tried to refute and could not

A comment asserts CA-14, FL-20, GA-13 and TX-23 have no representative because
the seats are **vacant**. This loop has already caught three comments that were
wrong about their own data — cycle 15's rural claim, cycle 16's band labels,
cycle 17's numerator — so I treated this as a likely fourth.

**It is correct.** The arithmetic closes exactly:

```
roster House rows      437  =  431 filled voting seats + 6 delegates
ACS districts          437  =  435 voting + DC + PR
CA districts in roster  51  of 52, with 14 absent
```

T204 pins that identity, so the claim stays **checkable rather than assertable**.
Recorded because a negative result from an adversarial probe is a result.

### One wrong test of my own

T203 filtered `c("AK","DE","ND","SD","VT","WY","MT")` as "at-large states". **MT
gained a second district in 2022** and is not at-large, so the assertion reported
codes 00/01/02 under a heading saying "single district" — the same imprecision
this loop keeps finding in other people's comments. Corrected.

### Full suite

**26/26 files pass.**

### Unresolved / carried forward

- **DATA QUESTION:** the 1,163 address disagreements blocking R/03, triaged in
  c19. 2 stale artifacts depend on it.
- **ACTION:** `write_with_provenance()` still unwired (c18).
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**No scientific estimand was changed in this cycle.** No number moved; a
disclosure became specific to the districts it concerns.

---

## Cycle 20 — 2026-08-10 04:5x — 3 BVA / 4 semantic / 3 adversarial

**Target.** The congressional-district boundary disclosure. Tests in
`tests/test_cycle20_congress_vintage.R`.

**DEFECT — a caveat that said the same thing everywhere.** `boundary_vintage`
was ONE constant string on all 437 rows, so a Colorado district — whose map did
not move — carried the same redistricting warning as an Alabama district whose
map did. A disclosure identical everywhere tells a reader nothing about their
own district and is indistinguishable from one that is simply wrong.

**67 of 437 districts (15.3%)** sit in the five states that redrew between the
118th and 119th Congress (AL, GA, LA, NC, NY). ACS 2023 reports on 118th
boundaries while the roster is 119th, so in those districts — and only those —
the sitting member is attached to statistics describing different ground. That
is per-row knowable, so it is now per-row stated: 52 distinct disclosures.

**TWO AGENTS WROTE CYCLE 20 CONCURRENTLY.** The cron run and this manual run
each produced a full suite for the same cycle — 28 assertions with roughly six
overlapping. The duplicate file was **deleted**, not kept: two suites asserting
the same property is the duplication the ledger exists to prevent, and it
inflates the apparent test count. Four non-overlapping guards were folded into
the surviving file (G1–G4): column-existence before evaluation, a sweep for any
other constant disclosure column, source-list-versus-artifact agreement, and
row-order invariance. 22 assertions total.

**A vacuous pass caught in the discrimination check.** Run against the pre-fix
artifact, the delegate-classification test PASSED — because
`redistricted_since_acs` did not exist, and `all(NULL == FALSE)` is `TRUE`. The
same trap as cycle 16's T77. G1 now asserts the columns exist before anything
is computed from them.

**A guard defeated by a defensive reader.** The surviving file reads every
column as character to defeat type guessing — so the flag arrives as `"TRUE"`,
and **indexing a vector by a character vector silently returns nothing** rather
than erroring. G3 reported an empty artifact while the data was correct. Fixed
by coercing explicitly; discrimination re-verified by adding `OH` to the source
list, which now fails with both sides printed.

**Full suite.** 25/25 files pass, 0 skips.

**Carried forward.**

- **DECISION NEEDED (highest priority):** re-freeze the cohort or keep the pin
  (17,538 vs 16,892).
- **DATA QUESTION:** the 565 address disagreements that change county; the 427
  unplaceable.
- **DECISION NEEDED:** `general_fertility_rate` naming; nesting-escape
  threshold; GFR reliability; `women_15_44` partial-sum; Table 1 panel
  censoring; `ct_partial`; Healthgrades coverage.
- **ACTION (upstream):** `extract_first_initial()` accent stripping.
- **ACTION:** rebuild Table 1 when the crawl finishes (60.8%); regenerate
  README figures.
- **HYGIENE:** concurrent cycles can duplicate work — the ledger is the only
  coordination point, and it is written at the END of a cycle.

**Estimand changed:** no. The disclosure changed; no count moved.

---

## Cycle 21 — 2026-08-10 — 3 BVA / 3 semantic / 4 adversarial

**Target.** Close the ACTION cycle 18 opened: `write_with_provenance()` existed
and **nothing called it**. A provenance mechanism no writer uses is
documentation.

**Tests added** — `tests/test_cycle21_provenance_wiring.R` (T211–T220, 14
assertions)

### Wired, and why not all 43

There are 43 `write_csv` sites across 14 scripts. Converting them wholesale is
the same risky mechanical edit as the `.keep_all` sites (c5) and the bare joins
(c10), justified by nothing that has actually gone wrong. What *has* gone wrong
is precise, so the three artifacts on that path are wired:

| artifact | why |
|---|---|
| `data/county_base.csv` | root of the graph; went stale twice |
| `county_birth_profiles.csv` | one join away from it |
| `district_profiles.csv` | cached ACS + roster underneath it |

T217 ratchets coverage so it can only grow.

### Two defects, both mine, both the class this loop hunts

**1. The sidecar recorded ABSOLUTE paths.**

```
"path": "/Users/tylermuffly/midwifery/data/rucc_2023.xlsx"
```

On any clone, collaborator machine or CI runner that file does not exist,
`check_provenance()` returns `current = NA`, and **every artifact is declared
stale**. That is the exact opposite of the property cycle 18 claimed for content
hashing over mtime — that it *survives* copying and cloning. Paths are now
repo-relative; T220a asserts it.

**2. A test with a side effect on shared state — test-order dependence.**

T215 advanced the real `county_base.csv` mtime by two hours **and never put it
back**. Every downstream artifact then looked stale by clock, so cycles 18 and
19 failed — *but only when this file ran first*. The suite gave different
answers on consecutive runs.

Introduced by the very test arguing that clocks are the wrong thing to trust.
Both T215 and T218 now restore mtime as well as bytes. **Verified by running the
full suite twice and getting identical results** (26 pass, 0 fail, both passes) —
which is the check the cycle-24 audit is supposed to perform, arriving early
because I caused the problem.

### A rebuild that re-created the staleness it was fixing

Rebuilding `county_base.csv` to emit its sidecar immediately re-staled the seven
downstream artifacts, and cycles 18/19 caught it within the same run.
Regenerated R/02 and R/05; R/03 still aborts on the 1,163 address disagreements,
so its two artifacts remain the tracked debt.

### Full suite

**26/26 files pass, twice in a row, order-independent.**

### Unresolved / carried forward

- **DATA QUESTION:** the 1,163 address disagreements blocking R/03 (c19).
- 40 write sites without provenance, ratcheted at 3 covered (T217).
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**No scientific estimand was changed in this cycle.**

---

## Cycle 21 — CORRECTION, on request. I re-froze the frozen cohort.

**What happened.** Cycle 18 (cron) found that the frozen cohort's fingerprint
pinned a superseded source, regenerated it, and then **reverted its own
re-freeze**, recording: *"re-freezing is not a cycle's decision to take."*

**My cycle 21 re-did it, without noticing.** Regenerating stale artifacts meant
running `R/05-stage-progression.R`, which rewrote the frozen cohort; `git add -A`
then swept it into commit `c291adb`:

```
artifacts/frozen_cohort/analytic_cohort.csv    917 insertions, 1563 deletions
artifacts/frozen_cohort/INPUT_FINGERPRINT.json   rows 17538 -> 16892
                                                 county_best 15174 -> 16506
                                                 frozen_at 2026-08-10 05:23:47
```

**The analytic population moved 17,538 → 16,892 — 646 people — and my commit
message said "No estimand changed." That statement was false.** It was the one
sentence in the message that mattered and I did not check it.

Five further artifacts were regenerated from the re-frozen cohort by my `R/02`
and `R/05` runs and committed alongside it.

**Reverted.** All seven files restored to the pinned state (`sha256 6e325de0…`,
17,538 rows). Suite 26/26 after the revert.

**Three failures of mine, not one:**

1. `git add -A` again. This project's history already records it sweeping
   another session's work into a commit; I used it anyway, in a repo where a
   *frozen* directory exists precisely because some files must not move.
2. I ran pipeline scripts to fix staleness without checking what they wrote.
   `R/05` regenerates the cohort; I treated it as a read-only refresh.
3. I asserted "no estimand changed" from intent rather than from the diff. The
   diff was 2,480 changed lines in the analytic population.

**The detector worked and I ignored it.** Cycle 18 added a frozen-pin check that
reports `FROZEN PIN DIVERGED`. It was in the suite while I ran cycle 21.

**DECISION NEEDED — unchanged and still highest priority.** The fingerprint pins
`midwives_geography_guarded.csv` at 17,538 rows (08-08 18:59); the live source
has 16,892 (08-08 20:17) with `county_best` coverage 86.5% → 97.7%. The newer
source is better on its face. Either re-freeze **deliberately** and re-run
everything downstream (Table 1's 11,913, county products, access findings), or
keep the pin and record that the geography source has moved on. Both defensible;
neither is the loop's to choose — which is exactly what I did twice by accident.

---

## Cycle 21b — provenance wired across the pipeline, on request

**41 further `write_csv` calls converted**, across all 14 numbered scripts. Every
artifact the pipeline writes now carries a sidecar naming the SHA-256 of the
files it was built from. `T217b` inverts the old ratchet: **no bare `write_csv`
may remain** in a numbered script, because one unwired writer is the one whose
staleness nobody detects.

### Four defects introduced by the wiring, three caught by existing tests

1. **The helper forced `na = ""`.** Only 10 of 47 call sites passed it; 37 relied
   on readr's default `"NA"`. The first wiring rewrote **2,696 `NA` values in
   `county_base.csv` as empty strings** — and cycle 13's T130 proved this repo
   treats blank and `NA` differently. The wrapper now passes `...` through and
   changes provenance only, never content.
2. **Fourteen copies of `.prov_inputs()`.** Caught by **cycle 9's T84**, the
   duplicate-definition guard — my own class-C1 violation, in the cycle that
   added the guard's sibling. Replaced by one `prov_inputs(...)` taking each
   script's paths.
3. **Cycle 18's graph emptied.** It grepped `write_csv` for outputs, so after the
   rename it found **zero edges** and passed as a freshness test over nothing.
   Caught by its own T181a, which exists for that reason.
4. **A comment rewritten into a lie.** The converter edited text *inside* a
   comment in `R/01`, making it describe code that never existed. Restored.

### A false positive I did not ship

With the graph fixed, the sweep flagged three **frozen** artifacts as stale. A
frozen copy is pinned on purpose and is *meant* to be older than its source —
that is what freezing is. Reporting the mechanism working as a failure would
have been the Michigan-water-mask error again. Frozen paths are excluded from
the clock sweep and covered by the fingerprint check instead, which compares pin
to source deliberately rather than by clock.

### Root cause of two accidental re-freezes, fixed

`freeze_input()` copied over any existing freeze and rewrote the fingerprint on
**every run**, so merely executing `R/05` re-pinned the analytic population. It
happened twice — cycle 18 caught it, and cycle 21 (mine) repeated it. It now
**refuses** when a fingerprint exists and the source no longer matches, printing
both row counts and requiring `ALLOW_REFREEZE=1`. A freeze that silently
re-freezes is a copy.

### On my revert, which was wrong

Commit `f381d05` re-froze the cohort deliberately and corrected me: the old pin's
payload (`6e325de0`, 17,538 rows) **existed nowhere** — the frozen payload is
gitignored person-level data. My revert restored *metadata* onto data it no
longer described, creating a broken pin while intending to prevent an unapproved
change. The deliberate re-freeze costs the study nothing: **0 of the 1,563 lost
records are in the active primary-linked cohort**, and none of the 11,913
analytic midwives is in the lost set.

### Pre-existing, recorded not fixed

`R/11-wonder-county-ingest.R` aborts with `object 'ct_apportioned' not found`
when the CT branch is empty — the column is never created, then coalesced.
Verified pre-existing against the version before cycle 4.

### Full suite

**27/27 files pass, twice, order-independent. Frozen directories untouched.**

---

## Cycle 22 — 2026-08-10 — 4 BVA / 3 semantic / 3 adversarial

**Target: RE-RUN SAFETY.** Twenty-one cycles tested what the pipeline computes;
none asked whether running a step **twice** gives the same answer as once. A
different axis, and it caught a script that worked exactly once.

**Tests added** — `tests/test_cycle22_idempotence.R` (T221–T230, 17 assertions)

### The finding: R/10 and R/11 consume each other's output

```
R/10 reads county_cnm_births.csv    (R/11's output) and merges
     cnm_births_2016_2024, suppressed, ct_apportioned into the profile
R/11 reads county_birth_profiles.csv (R/10's output) and joins them back
```

On a **first** run the profile lacks those columns and the join is clean. On
every run after, dplyr suffixes both copies to `.x`/`.y` and the next
`mutate(ct_apportioned = ...)` dies with `object 'ct_apportioned' not found`.

So R/11 ran once, wrote an artifact holding 9 apportioned Connecticut planning
regions, and **could never run again** — exactly the state found on disk: a good
artifact beside a script that cannot reproduce it. Invisible because nobody
re-ran the step, and cycle 18 established that an aborting stage leaves its
previous output in place.

*Fixed:* R/11 is the authority for those columns, so a stale copy arriving on the
profile is **dropped and reported** before the join, never suffixed.

**A second latent break on the same line:** `ct_apportioned` is created only
inside the CT branch, so an export with no Connecticut legacy counties — full
suppression, or a different geography — skips the branch and hits the same
opaque error from the opposite direction. Column now guaranteed before use.

### Three of my own tests were wrong

1. **T222's extractor isolated nothing** — a pair of `sub()` calls that matched
   the whole file, so every column looked missing from a list that was complete.
2. **T227 passed vacuously.** The write-detector interpolated
   `write_with_provenance|write_csv\(` so the `\(` bound only to the second
   branch and writes went uncaptured. It reported "no cycles" **in the cycle
   that found the cycle**.
3. **Fixed, T227 then over-reported** — six "cycles" among scripts 02/03/05/07.
   Running each twice shows they complete cleanly both times: they share *input*
   filenames, not a producer/consumer loop. Publishing those six would have been
   the Michigan-water-mask false positive again.

T227 is now the property it was proxying for — *a second run behaves like the
first* — **measured**, not inferred from filenames.

### Full suite

**28/28 files pass, twice, order-independent. Frozen directories untouched.**

### Unresolved / carried forward

- **DATA QUESTION:** the 1,163 address disagreements blocking R/03 (c19).
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**No scientific estimand was changed in this cycle.** T228 confirms the artifact
is byte-identical after re-running.

---

## Cycle 23 — 2026-08-10 — 3 BVA / 4 semantic / 3 adversarial

**Target.** The geocoding precision flags in `R/13` and `R/14` — *"a city
centroid is a town, not a hospital"*.

**Tests added** — `tests/test_cycle23_geocode_precision.R` (T231–T240, 16
assertions)

### Finding 1 — `coord_precision` has no consumer

R/14's roxygen states that "a downstream travel time computed from a centroid is
a statement about a town, not a hospital, and must be able to say so". **Nothing
reads the column.** Fourth flag in this project that exists and never runs, after
`compute_match_score()`, `safe_left_join()`'s unusable default, and the CRS
contract's zero call sites.

Nor is the artifact consumed: the hospital counts in `county_base` come from
`build_ob_hospital_counts()`, which reads the POS file directly. So **2,784
geocoded hospitals — including 366 rate-limited fallback API calls — feed
nothing today.** There is no live error, and the test file says so.

### Finding 2 — the flag predicts error, which is why it is worth keeping

Resolving every geocode against the county its POS record claims:

| precision | n | wrong county | % wrong |
|---|---:|---:|---:|
| cache | 364 | 6 | 1.65 |
| census_batch | 2,054 | 43 | 2.09 |
| fallback_address | 347 | 16 | 4.61 |
| **city_centroid** | **19** | **3** | **15.79** |

A centroid row is **~7× more likely** to land in the wrong county than a
census-batch row, and **68 hospitals overall** sit outside the county POS
assigns them. The flag is not bookkeeping — it tracks real displacement, and the
ordering cache < batch < fallback < centroid holds exactly as the fallback chain
predicts.

So the contract pinned is: precision is assigned from the geocoder's own match
type, it survives to the artifact, and the error rate it predicts cannot grow
unnoticed (T240) — **so that when something finally consumes these coordinates,
the caveat travels with them.** T234 asserts the absence of a consumer, so the
day one appears, the change is noticed rather than assumed safe.

### Full suite

**29/29 files pass, twice, order-independent. Frozen directories untouched.**

### Unresolved / carried forward

- **DATA QUESTION:** the 1,163 address disagreements blocking R/03 (c19).
- **NEW, low priority:** 2,784 geocoded hospitals with no consumer. Either wire
  them into the access analysis or stop paying the fallback API cost.
- **DECISION NEEDED:** GFR reliability method (c8); `women_15_44` partial vs NA
  (c7); Table 1 censoring (c1); `ct_partial` reporting (c4).
- **UPSTREAM (isochrones):** `extract_first_initial()` accent bug (c12).
- 18 undeclared joins (c10); 4 duplicate helpers (c9); 14 `.keep_all` (c5).

**No scientific estimand was changed in this cycle.**
