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
