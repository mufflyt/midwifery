# Technical Appendix: DAC and Open Payments Against NPPES's Self-Reported Address

**Repository**: `midwifery`
**Primary scripts**: [`extract_dac_midwives.R`](../extract_dac_midwives.R), [`match_open_payments_general_payments.py`](../match_open_payments_general_payments.py), [`compare_dac_openpayments_to_nppes_address.R`](../compare_dac_openpayments_to_nppes_address.R), [`make_address_agreement_figure.R`](../make_address_agreement_figure.R), [`make_address_agreement_additional_figures.R`](../make_address_agreement_additional_figures.R)
**Related**: [`TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`](TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md) (the question this was raised to help answer — can an NPPES-measured move be independently confirmed), [`OPEN_PAYMENTS_LINKAGE_COMPARISON.md`](OPEN_PAYMENTS_LINKAGE_COMPARISON.md) (two prior, disagreeing Open Payments employer-linkage builds — a different question from this one)
**Investigation date**: 2026-10-20 to 2026-10-22
**Status**: measurement complete. Every comparison in this appendix is year-matched; a DAC-vs-Open-Payments comparison was built, found to be impossible to year-match, and removed — see §4.

---

## 1. Why this exists

NPPES's self-reported practice address is the backbone of every geography
result in this repository, including the year-by-year migration measurement
in `TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`. That appendix found two
anomalous mobility spikes correlated with NPPES file-format changes and
explicitly asked for a source NPPES doesn't control to check against. This
appendix is that check, run for real against two sources already present in
this project: CMS Doctors & Clinicians (DAC, PECOS-derived) and CMS Open
Payments (Sunshine Act general payments).

Two questions, both answerable without comparing across mismatched years:

1. **Does DAC agree with NPPES, for the same provider, in the same year?**
2. **Does Open Payments agree with NPPES, for the same provider, in the same
   year — and does Open Payments agree with *itself* across different
   program years for the same person?**

A third, originally-planned question — do DAC and Open Payments agree with
*each other* — turned out not to be answerable this way at all. See §4.

## 2. What was pulled, and what it's dated to

- **DAC**: `data/CMS_DAC_NationalDownloadableFile.csv`, one vintage, dated
  2026-06. `extract_dac_midwives.R` filters to `pri_spec`/`sec_spec_all` LIKE
  `%MIDWIFE%` and collapses to one row per NPI: **5,680 distinct midwife
  NPIs**, each with `practice_address`, `practice_city`, `practice_state`,
  `practice_zip` — a full street address, independently sourced through
  Medicare enrollment (PECOS), not NPPES self-report.
- **Open Payments**: `match_open_payments_general_payments.py`, re-run this
  session for **program years 2022, 2023 and 2024** (previously this project
  had only pulled 2024). Each year is looked up live from CMS's own
  metastore catalog (`openpaymentsdata.cms.gov`) rather than a hardcoded
  download URL — the publication-date segment of the URL
  (`PGYR2024_P06302026_06032026`) is not predictable release to release, the
  same failure mode `archive_revalidation_reassignment.R` hit this month
  against a different CMS catalog. One row per matched midwife-year:
  `recipient_address`, `recipient_city`, `recipient_state`,
  `recipient_zip`. **A real bug was caught and fixed while doing this**: the
  script already parsed `Recipient_Primary_Business_Street_Address_Line1`
  from the raw file but silently dropped it before writing the output —
  street-level Open Payments comparison was impossible before this session
  for exactly that reason, not because the field doesn't exist.
  - Coverage: **3,342 / 3,556 / 4,042** of the 12,171-cohort midwives appear
    in Open Payments at all, for 2022 / 2023 / 2024 respectively — appearing
    requires having received a reportable industry payment that year, so
    this is a real but partial subset, not a universal check.
  - **Open Payments is one row per payment *transaction*, not one row per
    recipient-year**: ~37% of matched midwives in the 2022 file (and
    similar shares in 2023/2024) have more than one reported address in the
    same program year — multiple employers or practice sites paying out
    that year. Picking a single representative address per NPI-year
    therefore needs a stated rule, not an arbitrary row. This repo's safe
    rule is: the `(state, city, zip, street)` combination reported on the
    **most transactions** that year, ties broken alphabetically for
    determinism (`collapse_to_modal_address()` in
    `compare_dac_openpayments_to_nppes_address.R`). The repo's live
    `distinct(.keep_all = TRUE)` drift ratchet
    (`tests/test_cycle40_keepall_sweep_scope.R`, T40-5) is what caught the
    original arbitrary-row version of this script and forced this fix.
- **NPPES**: `midwife_panel.csv`, the same annual-snapshot panel the
  migration appendix uses. Each comparison below pulls the NPPES snapshot
  for **the same year the other source is dated to** — DAC (2026) against
  NPPES's 2026 snapshot, Open Payments 2022/2023/2024 against NPPES's
  2022/2023/2024 snapshots respectively. Comparing against *today's* address
  instead would conflate genuine disagreement with any move that happened
  in between.

## 3. Results

All agreement percentages are computed only over pairs where **both** sides
have a non-blank value at that geographic level (`comparable_n`); see
`artifacts/dac_openpayments_vs_nppes_address_agreement.csv` for the full
table with `comparable_n`/`agree_n` alongside every percentage. Both tables
below are year-matched — see §4 for the comparison that isn't, and why it's
not here.

![Two ways to check a midwife's address, and how often they agree](figures/dac_openpayments_vs_nppes_agreement.png)

### 3a. Each source vs. NPPES, same year (n = 5,576 DAC; 3,210–4,020/year Open Payments)

| Level | DAC (2026) | Open Payments 2022 | 2023 | 2024 |
|---|---:|---:|---:|---:|
| State | 89.8% | 95.3% | 95.2% | 96.1% |
| City | 55.6% | 84.1% | 82.9% | 83.9% |
| ZIP5 | 47.1% | 81.3% | 77.9% | 79.2% |
| Street | 32.8% | 78.8% | 74.6% | 75.5% |

### 3b. Open Payments against itself, different program years, same person (n = 2,175–2,500)

| Level | 2022 vs 2023 | 2022 vs 2024 | 2023 vs 2024 |
|---|---:|---:|---:|
| State | 95.0% | 92.1% | 93.8% |
| City | 80.2% | 74.1% | 78.7% |
| ZIP5 | 74.9% | 67.9% | 73.4% |
| Street | 70.9% | 62.1% | 68.6% |

## 4. Why there is no DAC-vs-Open-Payments comparison

An earlier version of this appendix included a third comparison, DAC
directly against Open Payments, plus a three-way NPPES/DAC/Open-Payments
concordance figure built on top of it. Both are removed as of 2026-10-22.

The reason: DAC has exactly **one** public vintage. Checked directly against
CMS's own metastore API (`data.cms.gov/provider-data/api/1/metastore/schemas/dataset/items/mj5m-pzi6`)
— it returns a single `distribution`, no history. Wayback Machine has only
captured the dataset's JS-rendered landing page, not the underlying
700+MB CSV. There is no public way to fetch "DAC as it stood in 2022" (or
2023, or 2024) the way Open Payments publishes one archived file per program
year. Any DAC-vs-Open-Payments comparison is therefore always DAC's single
2026 vintage against an Open Payments year 2–4 years earlier — a real,
unclosable gap, not a year-matched comparison, no matter how clearly the
gap is labeled.

"Every analysis needs to be year matched" is a hard rule in this project.
A labeled mismatch is still a mismatch, so both the pairwise
DAC-vs-Open-Payments numbers and the three-way concordance figure built on
them were removed rather than kept with a caveat. (A personal 2021 DAC
snapshot exists in the repo owner's iCloud Drive, which would narrow the
gap to one year for the 2022 Open Payments pull only — not pursued, since
it still wouldn't be a true match, and would leave 2023/2024 with no DAC
comparison at all.)

What the removed comparison had shown, for the record (see git history for
the exact figures if needed): DAC agreed with Open Payments *less* than DAC
agreed with NPPES directly, despite Open Payments agreeing with NPPES far
more than DAC did — the kind of asymmetry you'd expect if Open Payments'
agreement with NPPES weren't fully independent confirmation. That finding no
longer stands as evidence here, for the year-matching reason above, but it's
consistent with — and motivated a closer look at — the weaker, still
year-matched version of the same asymmetry in §5.

## 5. What this does and does not establish

- **DAC agrees with NPPES noticeably less than Open Payments does, and both
  comparisons are year-matched.** DAC vs. NPPES (2026 vs. 2026) is 55.6% at
  the city level; Open Payments vs. NPPES (same year, each of 2022/2023/2024)
  is 82.9–84.1%. DAC is a genuinely independent source (PECOS-derived, not
  NPPES self-report); Open Payments is suspected of partial NPPES-sourcing
  for its recipient address field (CMS documentation not yet checked to
  confirm the mechanism). This asymmetry is consistent with that suspicion,
  though it's a weaker signal than the removed DAC-vs-Open-Payments /
  three-way comparison would have given — that one is gone for the
  year-matching reason in §4, not because it was uninformative.
- **It gives a real, measured, year-matched answer to "how much do
  independent address sources disagree," at four geographic grains** —
  useful context for interpreting any NPPES-based result, including the
  migration appendix's anomalous-year spikes: NPPES addresses disagree with
  a genuinely separate system (DAC) on *city* about as often as they agree,
  even outside any anomalous year.
- **It does not resolve the migration appendix's open question.** Neither
  source is multi-year with full address granularity for the same calendar
  years NPPES's anomalous transitions fall in (2017→2018, 2023→2024) — Open
  Payments only goes back to 2013 in principle, but this project has only
  pulled 2022–2024 so far, and DAC has exactly one vintage, not a historical
  archive (§4). Closing that gap would mean pulling Open Payments 2017 and
  2018 specifically (the metastore catalog lookup this session built makes
  that a one-line change:
  `OPEN_PAYMENTS_YEAR=2017 python3 match_open_payments_general_payments.py`)
  and re-running `compare_dac_openpayments_to_nppes_address.R`.
- **The Open-Payments-vs-itself check (§3b) is the one genuinely
  same-source longitudinal address signal this project now has**, independent
  of NPPES. Its year-over-year disagreement (city: 20–26%) is higher than
  the within-year Open-Payments-vs-NPPES disagreement (city: 16–17%), which
  is the expected direction if some of it is real movement rather than pure
  source noise — but the two are not cleanly separable from this comparison
  alone.

## 6. Three more views

[`make_address_agreement_additional_figures.R`](../make_address_agreement_additional_figures.R)
re-plots the table in §3 from three different angles — no new numbers of its
own.

![Every source pair, every geographic level, one view](figures/address_agreement_heatmap.png)

- **Heatmap** (`docs/figures/address_agreement_heatmap.png`): every
  source-pair/level cell in §3 in one grid. Fastest way to see that the
  DAC row runs noticeably warmer (lower agreement) than every Open Payments
  row.

![Agreement falls apart at finer geography](figures/address_agreement_cascade.png)

- **Cascade** (`docs/figures/address_agreement_cascade.png`): the same data
  as connected lines, State through Street. Both comparison families
  degrade with geographic grain at roughly the same rate; the DAC line just
  starts lower and ends lower.

![No headline number rests on a tiny sample](figures/address_agreement_power.png)

- **Power check** (`docs/figures/address_agreement_power.png`): agreement
  percent against how many comparable records it's based on (1,500–5,500
  per row). Confirms the low DAC numbers aren't a small-sample artifact —
  they sit on comparable or larger n than the high Open-Payments-vs-NPPES
  numbers next to them.

## 7. Reproducing

```sh
# DAC (one vintage; set DAC_FILE if the national file lives somewhere else)
Rscript extract_dac_midwives.R

# Open Payments, one program year per run -- repeat for whichever years matter
OPEN_PAYMENTS_YEAR=2022 python3 match_open_payments_general_payments.py
OPEN_PAYMENTS_YEAR=2023 python3 match_open_payments_general_payments.py
OPEN_PAYMENTS_YEAR=2024 python3 match_open_payments_general_payments.py

# Comparison + figure (auto-discovers whichever Open Payments years exist in artifacts/)
Rscript compare_dac_openpayments_to_nppes_address.R
Rscript make_address_agreement_figure.R

# Three more views (heatmap, cascade, power check)
Rscript make_address_agreement_additional_figures.R
```

Requires `midwife_panel.csv` (NPPES annual snapshots, gitignored,
person-level, ~455 MB) and a network connection for the DAC national file and
each Open Payments program-year pull (tens of millions of rows streamed and
filtered; each year takes several minutes).
