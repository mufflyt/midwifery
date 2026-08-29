# Technical Appendix: Panel-Builder Hardening and Data-Quality Findings (NPPES 2007-2026)

**Repository**: `midwifery`
**Primary script**: [`build_midwife_panel.R`](../build_midwife_panel.R)
**Permanent regression test**: [`tests/test_build_midwife_panel.R`](../tests/test_build_midwife_panel.R)
**Investigation date**: 2026-08-26 to 2026-08-27
**Status**: all findings below are verified against the actual panel and script as of this writing, not assumed.

---

## 1. Why this exists

`build_midwife_panel.R` reads one National Plan and Provider Enumeration System
(NPPES) file per year, 2007 through 2026. Those files are not one format:
CMS has changed the column set, the taxonomy-slot count, and — starting with
the December 2024 vintage — the file structure itself, at least four times
over that span. A parser tuned to the 2020 file has no guarantee of reading
the 2010 or the 2025 one correctly, and a silent misread does not look like a
crash; it looks like a slightly smaller, slightly wrong panel.

This appendix documents two things produced by the same investigation:
(1) ten adversarial edge cases built to find exactly that kind of silent
failure, all ten of which the current script handles correctly, and
(2) four data-quality facts about the real panel that the investigation
surfaced along the way and that any consumer of `midwife_panel.csv` should
know.

## 2. Edge-case hardening

Ten single-row NPPES fixtures, each isolating one hazard, were run against
`build_midwife_panel.R` via the `NPPES_HISTORY` environment variable it
already reads. All ten are now `tests/test_build_midwife_panel.R`, wired into
`ci.yml` on every push and pull request. Table:

| # | Hazard | Expected behavior | Result |
|---|---|---|---|
| 1 | Real Latin-1 bytes (e.g. `MUÑOZ`, `RENÉE`) under a plain-ASCII header | Decode correctly, not as mojibake | **Pass** |
| 2 | `entity_type_code` value carries a stray leading space (`" 1"`) | Row is still matched, not silently dropped | **Pass** |
| 3 | `Provider Middle Name` column absent entirely (an older file era) | Row resolves with an empty middle name | **Pass** |
| 4 | Only 4 taxonomy-code slots instead of the modern 15, midwife taxonomy in slot 2 | Taxonomy is found regardless of slot position | **Pass** |
| 5 | Taxonomy code given in lowercase (`367a00000x`) | Matched case-insensitively | **Pass** |
| 6 | No taxonomy columns at all — schema not recognizable | **Refuses to run** and names the reason, rather than writing an empty or wrong panel | **Pass** |
| 7 | Two files claim the same year (`...0901` and `...0115`) | The earlier-dated file wins | **Pass** |
| 8 | Legacy `snake_case_with_trailing_underscore_` column-name era | Columns still resolve | **Pass** |
| 9 | A `.lock` file naming a dead PID | Lock is recognized as stale, cleared, and the build proceeds | **Pass** |
| 10 | A `.lock` file naming a genuinely running process | **Refuses to run** and names the holding PID, rather than corrupting the panel with an interleaved write | **Pass** |

Case 6 and case 10 are the two where success means *refusing to run* — this
project's stated preference for guards that error over guards that silently
filter (see `tests/ci_leak_guard.R`'s own header for the same principle
applied to person-level data). Confirming the script actually fails loudly in
both cases, rather than merely trusting that it does, is the point of
promoting these from an ad hoc bug hunt into a permanent test.

## 3. The December 2024 file format change was validated, not assumed

Starting with the December 2024 snapshot, NPPES began publishing files in a
different structure ("reshaped" in the script's own log output) from every
prior year. `build_midwife_panel.R` gained a second parsing path to read it.
The obvious risk of a second path is that it silently produces a *different*
population than the original path would have for the same data.

It does not. The December 2024 snapshot, extracted through the new reshaped
path (`393,409` rows), was compared row-for-row against the same snapshot
already present in the production panel (built through the original path,
also `393,409` rows):

| Check | Result |
|---|---|
| Rows only in the original-path extraction | 0 |
| Rows only in the reshaped-path extraction | 0 |
| `tax_class` mismatches on shared NPIs | 0 |
| `last_name` mismatches on shared NPIs | 0 |

Corroborating evidence: the year-over-year midwife count shows no
discontinuity at the format boundary. Annualized growth declines smoothly
from 11.1% (2008) to 4.5-6% (2025-2026) across the entire 2007-2026 series;
the 2024 and 2025 reshaped-path snapshots (19,282 and 19,690 midwives) sit
exactly on that trend, not off it.

## 4. AMCB `certification_date` is not always the date of original certification

Joining the AMCB roster's ACTIVE certificants to the panel's first observed
year as a midwife (11,354 linked certificants), 104 (0.9%) show the person
already enumerated under a midwifery taxonomy in NPPES *before* their AMCB
`certification_date` — by as much as 18 years in the most extreme case.

This is not a linkage error. Of those 104, **100% remained continuously
observable as a midwife through the most recent (2026) snapshot** — the
signature of someone who has been practicing the whole time, not someone
misidentified. The far more plausible explanation is that AMCB's published
`certification_date` field is, for this subset, a **renewal or
recertification date**, not the original certification date, and the public
verification directory does not distinguish the two.

**Consequence.** Any variable derived as "years since certification" (Table 1
carries one: *Years Since AMCB Initial Certification*) is a slight
underestimate for this ~0.9% of the linked cohort. The effect is small and
one-directional (it can only understate tenure, never overstate it), but it
is a real, previously undocumented limitation of the AMCB roster as a source
for career-length, not an artifact of this project's linkage.

## 5. Surname change is common, and rises with time observed

Among the 21,106 NPIs ever enumerated under a midwifery taxonomy in the
panel, 9.5% appear under more than one surname across their observed years.
The rate is not uniform — it rises sharply with how long someone has been
observed:

| Years observed | NPIs | Changed surname at least once |
|---|---:|---:|
| 1 | 665 | 0.0% |
| 2 | 452 | 1.1% |
| 3-5 | 3,343 | 3.8% |
| 6-10 | 4,543 | 9.6% |
| 11-20 | 12,103 | 11.9% |

This is consistent with, and gives an empirical magnitude to, the rationale
already documented at the top of `build_midwife_panel.R` for carrying surname
history at all: in a cohort that is overwhelmingly women, many certified
decades ago, maiden-to-married (or post-divorce) surname changes are a
material and *increasing-with-tenure* source of name-based linkage failure
elsewhere in this pipeline (see `expand_former_name_candidates.R` and
`load_former_last_names.R`, which exist to recover exactly these cases).

## 6. The Latin-1 decoding path is a safeguard, not a fix for an observed defect

Across every one of the 20 real annual snapshots (2007-2026), **zero** midwife
rows contain a non-ASCII byte in `last_name` or `first_name`. NPPES's actual
published files are ASCII throughout this project's file history, at least
for this cohort. Case 1 above (§2) confirms the script *would* decode
Latin-1 bytes correctly if a future file contained them; it is defensive
hardening against a hazard that has not yet materialized in this data, and
should be read that way rather than as evidence the hazard has occurred.

## 7. Reproducing this

```r
# All ten hardening cases:
Rscript tests/test_build_midwife_panel.R

# The reshape-format validation (§3) and the certification-date check (§4)
# were ad hoc queries against the real panel, not committed scripts, since
# both read midwife_panel.csv directly (546 MB, gitignored, not
# regenerable from a fresh clone without the full NPPES history). The
# queries: join the AMCB roster's ACTIVE certificants to
# `SELECT npi, MIN(snapshot_year) FROM midwife_panel WHERE tax_class =
# 'midwife' GROUP BY npi`, compare `cert_year` against `first_midwife_year`,
# and inspect `last_midwife_year` for the pre-certification-appearance
# subset. Re-run against a current `midwife_panel.csv` to check whether the
# 0.9% figure has moved.
```
