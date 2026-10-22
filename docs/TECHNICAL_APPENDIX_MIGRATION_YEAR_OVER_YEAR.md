# Technical Appendix: Year-by-Year Migration, and Two Spikes That Aren't Explained by a Parser Bug

**Repository**: `midwifery`
**Primary script**: [`diagnose_migration_year_over_year.R`](../diagnose_migration_year_over_year.R)
**Related**: [`docs/RESULTS_geographic_persistence.md`](RESULTS_geographic_persistence.md) (pooled annual/career persistence rates), [`docs/TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`](TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md) (the format-change validation this appendix extends)
**Investigation date**: 2026-10-19 to 2026-10-22
**Status**: the measurement is settled; the mechanism behind two spikes is not.

---

## 1. What this measures

`RESULTS_geographic_persistence.md` reports one pooled year-to-year
persistence rate across the whole 2007-2026 NPPES panel (97.9% same state).
That number hides year-to-year variation. This appendix disaggregates it: for
each consecutive pair of annual snapshots, among FROZEN-cohort midwives
observed in both years, what share changed practice state, county, or ZIP5.

## 2. The full series

| year→year | n pairs | moved state | moved county | moved ZIP |
|---|---:|---:|---:|---:|
| 2007→2008 | 6,046 | 0.93% | 1.68% | 2.94% |
| 2008→2009 | 6,306 | 1.47% | 3.02% | 4.63% |
| 2009→2010 | 6,834 | 1.01% | 1.83% | 2.60% |
| 2010→2011 | 7,096 | 2.35% | 4.20% | 6.55% |
| 2011→2012 | 7,628 | 1.99% | 4.09% | 6.54% |
| 2012→2013 | 8,036 | 2.22% | 4.56% | 6.79% |
| 2013→2014 | 8,500 | 2.07% | 4.34% | 6.39% |
| 2014→2015 | 9,052 | 2.57% | 5.10% | 7.28% |
| 2015→2016 | 9,717 | 2.11% | 4.10% | 5.88% |
| 2016→2017 | 10,287 | 2.11% | 3.98% | 5.85% |
| **2017→2018** | 10,865 | **3.03%** | 5.56% | 7.42% |
| 2018→2019 | 11,897 | 2.23% | 3.91% | 5.45% |
| 2019→2020 | 12,547 | 1.44% | 2.63% | 3.84% |
| 2020→2021 | 13,029 | 1.75% | 3.11% | 4.21% |
| 2021→2022 | 13,451 | 1.64% | 3.13% | 4.14% |
| 2022→2023 | 13,966 | 2.32% | 4.65% | 6.27% |
| **2023→2024** | 14,602 | **3.62%** | 6.98% | 9.75% |
| 2024→2025 | 15,812 | 1.16% | 2.32% | 3.20% |
| 2025→2026 | 16,066 | 1.56% | 3.04% | 4.23% |

Two transitions stand out: **2017→2018 (3.03%)** and **2023→2024 (3.62%,
the highest in the series)**. No other transition exceeds 2.6%.

## 3. The correlation with known format changes

Both spike years coincide with a documented NPPES file-format transition:

| transition | % moved state | known format event |
|---|---:|---|
| 2017→2018 | 3.03% | NPPES encoding switch, Latin-1 → UTF-8 |
| 2023→2024 | 3.62% | December 2024 NPPES "reshaped" file-structure change |

No other year in the series lands near either event. This is suggestive —
exactly the pattern you'd expect if a format change corrupted or re-derived
the address field differently — but a correlation between two data points
and two known events is not a mechanism, and it was tested rather than
assumed.

## 4. What was tested, and what it ruled out

**Hypothesis: the format change corrupts the address field, and it reverts
once the old format resumes being read correctly the next cycle.** Tested
directly: for every year, compare a midwife's practice state in year−1
against year+1; a "blip" is where those two agree but the middle year
disagrees — the signature of a one-snapshot parsing corruption. The rate is
flat and near-zero across the entire series (0.00–0.09%), including the
year centered on the December 2024 transition (0.02%, below the series
median). **This hypothesis is rejected.** The transitions themselves are
also geographically ordinary — CA↔WA, NJ↔PA, GA↔FL, DC/VA↔MD — not malformed
codes or null-to-value noise.

**Stronger version of the same hypothesis: even without reverting, a
corrupted address might not *persist* — real migration should hold, noise
shouldn't.** The blip test only catches a round trip (A,B,A); it would miss
a value that changes once and never reverts but also never stabilizes. The
repo owner asked for a stricter bar (2026-10-22): a transition only counts
as a *confirmed* move if the state was unchanged for the year immediately
before it and unchanged for the year immediately after (A,A,B,B — four
consecutive snapshots required, so 2007→2008 and 2025→2026 can't be
confirmed either way and are reported as such rather than as 0). Result,
same denominator for raw and confirmed within each row so the comparison
isn't contaminated by a population shift:

| | raw | confirmed | survives |
|---|---:|---:|---:|
| 2017→2018 and 2023→2024 | 3.17% | 2.92% | 92% |
| every other transition | 1.83% | 1.69% | 92% |

**Identical survival rate.** If the spike were disproportionately noise —
values that change once and don't hold — the format-change years should
lose a *larger* share of their raw rate under confirmation than ordinary
years do. They don't: both groups retain exactly 92% of their raw rate.
**This is further evidence against a parsing-artifact mechanism**, on top
of (not a replacement for) the round-trip test above — the elevated
2018/2024 rate is exactly as durable as normal-year migration, not a
population of changes that happen not to immediately revert but also don't
stick.

**Hypothesis: the reshaped-format parser itself reads the address fields
differently from the classic parser.** `TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`
§3 already validated the two parsers against each other for the real
December 2024 snapshot, but only for row count, `tax_class`, and
`last_name` — never the address fields this spike lives in. Extended here:
`practice_address`, `practice_state`, and `practice_zip` were extracted from
the real December 2024 snapshot both ways (the classic `npidata_pfile` and
the reshaped `byvar/` export) for all 17,028 cohort NPIs. **Zero
mismatches** on every field, for every NPI with a non-null value in either
path; the null set agreed exactly (969 NPIs, identical on both sides). **This
hypothesis is rejected.**

**Hypothesis: the spike is an artifact of the panel's 2023 data-completeness
gap** (see `TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`, the undocumented
third ingestion path fixed 2026-10-19). Checked directly: the 542 cohort
members whose 2023 row was previously missing entirely are filtered out of
both the 2022→2023 and 2023→2024 transitions by construction (a transition
requires a non-null value in both years), so they cannot manufacture a
spurious move. Re-running the full series after that fix reproduced
identical 2022→2023 and 2023→2024 move rates (2.32%, 3.62%) to before it.
**This hypothesis is rejected.**

## 5. What remains open

Both parser-level explanations are cleared. What's left is a real, measured
elevation in address change specifically in the two years NPPES also changed
its file format — without an identified mechanism connecting the two. Two
non-exclusive possibilities neither confirmed nor ruled out:

- **CMS/NBER re-derived or re-verified addresses as part of the format
  migration itself**, independent of which parser later reads the result —
  this would show up exactly as measured (a real value change, not a parsing
  error) and wouldn't be caught by a parser-agreement test, since both
  parsers would correctly read whatever CMS actually shipped that month.
- **Coincidence.** Two spikes landing on two format-change years, out of
  nineteen transitions, is suggestive but not statistically forced — the
  next-highest transition (2010→2011, 2.35%) has no known event near it
  either.

Resolving this further would need a vintage-matched comparison: the same
provider's address as reported in the format-change month versus the
immediately preceding non-transition month's *re-pull*, which NPPES does not
publish and this repo does not currently acquire.

## 6. Reproducing

```sh
Rscript diagnose_migration_year_over_year.R
```

Reads `midwife_panel.csv` (gitignored, person-level) and
`artifacts/amcb_npi_linkage_FROZEN.csv`; both must be present locally. The
parser-diff test in §4 is not part of the script — it requires the raw
December 2024 NPPES source (classic zip and the `nber_reshaped_validation_202412/`
byvar export) on the external volume, extracted by hand once, as described
in `TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`.
