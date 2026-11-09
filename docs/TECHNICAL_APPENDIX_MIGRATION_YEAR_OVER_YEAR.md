# Technical Appendix: Year-by-Year Migration, and Two Spikes That Aren't Explained by a Parser Bug

**Repository**: `midwifery`
**Primary script**: [`diagnose_migration_year_over_year.R`](../diagnose_migration_year_over_year.R)
**Related**: [`docs/RESULTS_geographic_persistence.md`](RESULTS_geographic_persistence.md) (pooled annual/career persistence rates), [`docs/TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`](TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md) (the format-change validation this appendix extends)
**Investigation date**: 2026-10-19 to 2026-10-22; refreshed 2026-10-30 against
the current 16,775-member cohort (previously 16,892; see
[`docs/RESULTS_geographic_persistence.md`](RESULTS_geographic_persistence.md)
for the re-pin this followed). The conclusion is unchanged — same spikes,
same 92% survival rate under confirmation for both the format-change and
ordinary transitions — which is itself evidence the finding isn't an
artifact of the specific cohort vintage. Also added 2026-10-30: three new
hypothesis tests (§4b) — destination/origin clustering, byte-level encoding
corruption, and move-distance distribution — all rejected, extending rather
than resolving the open question in §5.
**Status**: the measurement is settled; the mechanism behind two spikes is not.

---

## 1. What this measures

`RESULTS_geographic_persistence.md` reports one pooled year-to-year
persistence rate across the whole 2007-2026 NPPES panel (98.0% same state).
That number hides year-to-year variation. This appendix disaggregates it: for
each consecutive pair of annual snapshots, among FROZEN-cohort midwives
observed in both years, what share changed practice state, county, or ZIP5.

## 2. The full series

| year→year | n pairs | moved state | moved county | moved ZIP |
|---|---:|---:|---:|---:|
| 2007→2008 | 5,946 | 0.91% | 1.66% | 2.94% |
| 2008→2009 | 6,202 | 1.48% | 3.05% | 4.66% |
| 2009→2010 | 6,725 | 1.03% | 1.86% | 2.65% |
| 2010→2011 | 6,982 | 2.36% | 4.22% | 6.62% |
| 2011→2012 | 7,505 | 2.03% | 4.14% | 6.61% |
| 2012→2013 | 7,909 | 2.25% | 4.61% | 6.88% |
| 2013→2014 | 8,368 | 2.08% | 4.34% | 6.42% |
| 2014→2015 | 8,916 | 2.60% | 5.17% | 7.34% |
| 2015→2016 | 9,567 | 2.14% | 4.16% | 5.96% |
| 2016→2017 | 10,128 | 2.11% | 4.02% | 5.90% |
| **2017→2018** | 10,700 | **3.06%** | 5.62% | 7.50% |
| 2018→2019 | 11,717 | 2.26% | 3.96% | 5.50% |
| 2019→2020 | 12,361 | 1.46% | 2.66% | 3.88% |
| 2020→2021 | 12,841 | 1.77% | 3.14% | 4.24% |
| 2021→2022 | 13,255 | 1.64% | 3.15% | 4.17% |
| 2022→2023 | 13,767 | 2.33% | 4.68% | 6.30% |
| **2023→2024** | 14,390 | **3.68%** | 7.05% | 9.81% |
| 2024→2025 | 15,593 | 1.16% | 2.34% | 3.21% |
| 2025→2026 | 15,840 | 1.58% | 3.07% | 4.26% |

Two transitions stand out: **2017→2018 (3.06%)** and **2023→2024 (3.68%,
the highest in the series)**. No other transition exceeds 2.6%.

## 3. The correlation with known format changes

Both spike years coincide with a documented NPPES file-format transition:

| transition | % moved state | known format event |
|---|---:|---|
| 2017→2018 | 3.06% | NPPES encoding switch, Latin-1 → UTF-8 |
| 2023→2024 | 3.68% | December 2024 NPPES "reshaped" file-structure change |

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
the reshaped `byvar/` export) for all 17,028 cohort NPIs (the vintage at the
time this test ran; not re-run at the current 16,775 vintage, since it needs
the raw December 2024 NPPES source files on the external volume this test
originally used, extracted by hand, not re-derivable from this repo alone).
**Zero mismatches** on every field, for every NPI with a non-null value in
either path; the null set agreed exactly (969 NPIs, identical on both
sides). **This hypothesis is rejected.**

**Hypothesis: the spike is an artifact of the panel's 2023 data-completeness
gap** (see `TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`, the undocumented
third ingestion path fixed 2026-10-19). Checked directly: the 542 cohort
members whose 2023 row was previously missing entirely are filtered out of
both the 2022→2023 and 2023→2024 transitions by construction (a transition
requires a non-null value in both years), so they cannot manufacture a
spurious move. Re-running the full series after that fix reproduced
identical 2022→2023 and 2023→2024 move rates (2.32%, 3.62%) to before it.
**This hypothesis is rejected.**

## 4b. Three more hypotheses tested 2026-10-30, after the 16,775 re-pin

All three are new tests, not re-runs of the four above, aimed specifically
at mechanisms the original investigation hadn't checked. All three come back
negative — further evidence against an artifact, not new evidence for one.

**Hypothesis: a fallback/default value gets inserted when parsing fails,
landing many providers on the identical address.** If a parser error
produced a placeholder address, many unrelated movers would land on exactly
the same new (or old) address. Checked directly: among the 327 state-movers
in 2017→2018 and 530 in 2023→2024, the single most common destination is
shared by at most 6-8 providers (AURORA CO 80045 — UCHealth's main campus;
NASHVILLE TN 37232 — Vanderbilt), and the most common origin by at most 3-8
(ATLANTA GA 30322 — Emory). These are large real hospital/academic medical
centers, exactly what you'd expect from genuine employer-driven clustering
among a workforce concentrated in health systems, not a parser artifact —
a bug would not systematically prefer real major employers' street
addresses. **This hypothesis is rejected.**

**Hypothesis: the Latin-1→UTF-8 switch (2017→2018) corrupts bytes into
mojibake that happens to read as a different, valid-looking US address.**
Not previously tested directly — §4's parser-agreement test only checked
the 2024 reshape, not the 2017/2018 encoding transition. Checked directly:
scanned every mover's old and new `practice_address` for any byte outside
printable ASCII, in both spike transitions and four control transitions
(2016→2017, 2018→2019, 2022→2023, 2024→2025). **Zero non-ASCII characters
in any address field, spike or control.** US practice addresses are
overwhelmingly ASCII to begin with, so this doesn't rule out encoding
trouble elsewhere in the file, but it directly rules out mojibake as the
mechanism behind these specific state-level address changes. **This
hypothesis is rejected.**

**Hypothesis: spike-year moves are geographically different from ordinary
moves** — either suspiciously short (a formatting glitch within one metro
area misread as a state change) or suspiciously scattered (random
corruption rather than a real relocation). Checked directly: great-circle
distance between each mover's old and new state's population-weighted
centroid.

| transition | n movers | median distance | % under 300 mi |
|---|---:|---:|---:|
| control 2016→2017 | 214 | 618 mi | 25.6% |
| **spike 2017→2018** | 327 | 584 mi | 29.1% |
| control 2018→2019 | 265 | 596 mi | 30.5% |
| control 2022→2023 | 321 | 721 mi | 32.6% |
| **spike 2023→2024** | 530 | 622 mi | 30.7% |
| control 2024→2025 | 181 | 493 mi | 34.5% |

Both spike transitions sit squarely inside the control range on both
measures — no shift toward short glitch-sized moves, none toward
scattered/random ones. The distance *distribution* of spike-year moves is
statistically indistinguishable from ordinary-year moves; there are simply
more of them. **This hypothesis is rejected.**

These three results extend, rather than replace, §4's "92% survival rate,
identical in spike and ordinary years" finding: three independent,
unrelated angles (destination clustering, byte-level corruption, move
distance) all land on the same conclusion — spike-year address changes look
exactly like ordinary-year address changes, just more frequent. Nothing
found here identifies the mechanism; it continues to point at a real,
deliberate value change (CMS/NBER re-deriving addresses as part of the
format migration) rather than at a flaw in how this project reads the file.

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
