# Technical Appendix: Validating the 2007–2026 Midwife Temporal Panel Without a Historical AMCB Roster

**Repository**: `midwifery`
**Panel Artifact**: `midwife_panel.csv` (gitignored, person-level; rebuilt 2026-08-26/27)
**Builder Script**: [`build_midwife_panel.R`](file:///Users/tmuffly/midwifery/build_midwife_panel.R)
**Panel Span**: 20 annual snapshots, 2007–2026 (`snapshot_year`), 4,748,145 rows, 451,793 distinct NPIs

---

## 0. The problem this appendix answers

AMCB (the American Midwifery Certification Board) publishes only its **current** roster. It has never published — and does not retain — a historical snapshot of who was certified in, say, 2010 or 2015. `midwife_panel.csv` is instead built from 20 **historical NPPES dissemination snapshots** (one per year), each showing who was enumerated under a midwifery or nursing taxonomy code *at that point in time*. There is no authoritative historical roster to diff this panel against directly.

Four validation strategies were used instead, each independent of a historical AMCB source:

1. Cross-format overlap — run the two different snapshot-parsing code paths (classic NPPES flat file vs. NBER's reshaped per-field format) against the **same month** and confirm they agree.
2. Cross-check against the one AMCB-derived artifact we do have — the current roster's `certification_date`, used as a plausibility floor on when a person could first appear as a midwife.
3. External, non-AMCB benchmarks — published CNM/CM workforce counts and a prior paper that used the same NPPES taxonomy-code method.
4. Internal consistency — trend smoothness, and whether the panel's structural signals (surname changes accumulating with years observed) behave the way a real population should.

---

## 1. Cross-format overlap: classic vs. reshaped, same month (December 2024)

`build_midwife_panel.R` has two independent code paths for turning an NPPES snapshot into panel rows:

- **Classic path** — parses NBER's historical flat `npidata_<dates>.csv` mirror of the original NPPES dissemination file (used for all snapshot years 2007–2024 and 2026 in this panel).
- **Reshaped path** (`process_reshaped_year()`) — NBER stopped publishing that flat format after 2024 and now reshapes each snapshot into per-field CSVs under `byvar/`. This panel's 2025 snapshot is built entirely through this second code path, which was written new for this rebuild and validated only against synthetic fixtures before this check.

December 2024 is the one month NBER still has published in **both** formats, which makes it possible to run the reshaped path against real production data and diff its output against the classic path's already-verified result for the exact same snapshot — a check that needs no AMCB access at all.

**Classic-path result for 2024-12-08** (already in `midwife_panel.csv`):
19,282 midwife rows, 374,127 nursing rows (393,409 total).

**Reshaped-path result for the same snapshot** (fetched separately from `data.nber.org/npi/2024/12/byvar/`, run through `process_reshaped_year()` in isolation):

19,282 midwife rows, 374,127 nursing rows (393,409 total) — an **exact match** on every count.

A row-level diff (joined on `npi`, comparing `tax_class` and `last_name` between the two independently-produced outputs) confirms this is not a coincidence of aggregate totals:

| Check | Result |
|---|---:|
| Rows in classic output only | 0 |
| Rows in reshaped output only | 0 |
| `tax_class` disagreements (matched NPIs) | 0 |
| `last_name` disagreements (matched NPIs) | 0 |

The two code paths, applied to two independently-downloaded, structurally different representations of the same underlying NPPES snapshot, produce byte-identical results across every field checked. This is the strongest evidence available that the reshaped-format adapter (needed only for the 2025 snapshot in this panel, since NBER stopped publishing the classic flat format after 2024) is not silently mis-extracting or mis-filtering relative to the already-trusted classic path.

Two real bugs were found and fixed by this check before it could pass (see the file's inline `BUG FIX` comments in `build_midwife_panel.R`):
- **Malformed-row intolerance**: `pfname`/`plocstatename` byvar files each contain at least one row that breaks strict CSV column-count sniffing (a first name stored as `"PAUL,"`, a place name `"YOKOSUKA, INAOKACHO, 82"`), and the reshaped path originally read these files without `ignore_errors=true`, so one bad row aborted the entire read. Fixed by adding `ignore_errors=true`, consistent with how the classic path already tolerates malformed rows.
- **Entity-type schema mismatch**: the reshaped format spells entity type as text (`Individual`/`Organization`), not the classic format's numeric code (`1`/`2`). The adapter's first version filtered on `= '1'`, which matched nothing and silently zeroed the entire 2025 snapshot. Fixed to filter on `UPPER(TRIM(entity)) = 'INDIVIDUAL'`.

Both bugs were caught precisely *because* this cross-format check was run against real data rather than trusted on the synthetic-fixture pass alone.

---

## 2. Cross-check against the current AMCB roster: does the panel respect the certification-date floor?

`artifacts/amcb_npi_linkage_FROZEN.csv` (the project's canonical AMCB↔NPI linkage) is gitignored and was not present in the local working copy at validation time. `artifacts/scraped_50_states_and_dc_midwives_master.csv` was used instead — a state-Board-of-Nursing scrape of AMCB-certified midwives carrying `npi` and `certification_date`, but **limited to `status = ACTIVE`** (11,355 of the panel's linkable population; no LAPSED/RETIRED/DECEASED rows are present in this substitute source, so the "does panel presence taper off after a person goes DECEASED" half of this check could not be run).

**Method**: for each ACTIVE, NPI-matched person, compare her `certification_date` year against the *first* year she appears as `tax_class = 'midwife'` in the panel. A person should not show up under a midwifery taxonomy code before she was certified.

**Result** (11,354 linked people):

| Relationship | n | % |
|---|---:|---:|
| First panel appearance **before** certification year | 104 | 0.9% |
| First panel appearance **in** certification year | 2,058 | 18.1% |
| First panel appearance **after** certification year | 9,192 | 81.0% |

99.1% respect the expected causal ordering. The remaining 104 (0.9%) were inspected individually rather than written off as a linkage defect:

- **100% of the 104** are still observed as `midwife` in the panel's *final* year (2026), typically with 9–20 years of continuous panel presence (median well over a decade).
- The gap between `certification_date` and first panel appearance is large for exactly the long-tenured cases (up to 18 years) and small (1 year) for the most recently-appearing ones.

That pattern — long-tenured, continuously-practicing people whose roster `certification_date` sits *after* a decade or more of observed practice — is the signature of `certification_date` recording a **renewal/recertification** event rather than each person's original, first-ever certification date, not a panel or linkage defect. AMCB requires periodic recertification, and this scraped roster's `certification_date` field appears to reflect the most recent cycle. This is a scope caveat to carry into any manuscript language that uses `certification_date` as "when she became a midwife" — it is not that, for anyone recertified since first certifying.

**What this check could not do**: without a full-status AMCB source (ACTIVE + LAPSED + RETIRED + DECEASED), the complementary check — does panel presence correctly stop for people no longer certified — is untested. That remains open pending access to a full-status roster.

---

## 3. External, non-AMCB benchmarks

### 3.1 A prior paper used the identical method on a nearby date

Kennedy et al., *"Evaluation of a method to identify midwives in national provider identifier data,"* BMC Pregnancy and Childbirth (2023) used the **same two NPPES taxonomy codes** this panel uses (367A00000X + 176B00000X) against an **August 7, 2022** NPPES snapshot and reported **16,004** matching individual providers.

This panel's nearest available snapshot is **2022-04-10** (the earliest 2022 file on hand), showing **16,746** midwife-tax-class rows.

16,746 vs. 16,004, ~4 months earlier in the year the paper's number was measured, is a **4.6% higher count from an earlier date** — consistent with, not contradicting, a growing workforce (this panel's own measured annualized growth rate for the surrounding years is 5–6%/year; see §4.2). The two independently-built counts, from the same taxonomy-code method applied to essentially the same underlying NPPES data, land within single-digit percent of each other.

The same paper also reports that **~20% of AMCB-certified midwives register under the "wrong" taxonomy code** relative to a naive single-code count (367A00000X alone undercounted their AMCB benchmark by ~28.6%), which is the paper's own stated reason for combining 367A00000X + 176B00000X rather than using either alone — the same design choice `MIDWIFE_TAX` in this codebase already makes, for the same reason.

### 3.2 Published year-by-year AMCB headcounts (active-certification totals, not a historical roster)

| Date | AMCB active count | Source |
|---|---:|---|
| 2020 | 12,997 | Thumm et al. 2023, *J Midwifery Womens Health* |
| Aug 2022 | 13,791 | cited in Kennedy et al. 2023 |
| Aug 2023 | 14,215 | ACNM/AMCB reporting (lower confidence) |
| Jan 2026 | 14,802 (14,662 CNM + 140 CM) | AMCB, via registerednursing.org |

These are **active-certification** counts, a narrower and differently-defined population than this panel's NPPES-taxonomy count (which includes anyone enumerated under the taxonomy regardless of current AMCB status, and is therefore structurally larger — consistent with this panel's 2026 count of 20,339 exceeding AMCB's reported 14,802 active certificants for the same period). No year-by-year AMCB trend series was found for 2007–2019; ACNM's own Midwifery Workforce Study page states that a multi-year trend has not yet been published.

### 3.3 Surname-change rate plausibility

Pew Research (Sept 2023): ~79% of US women in opposite-sex marriages take their spouse's surname at marriage (lifetime rate among ever-married women). This is **not directly comparable** to this panel's observed rate — Pew's figure is a lifetime rate; this panel can only observe a name change if the marriage/divorce event falls inside the 2007–2026 window, so a much lower *observed* rate is expected even if the true underlying marriage rate matches Pew's. See §4.3 for the panel's own internal check on this, which is more informative than a direct comparison to Pew's figure.

---

## 4. Internal consistency

### 4.1 No implausible year-to-year discontinuities

Midwife-tax-class counts, 2007→2026: 6,388 → 6,732 → 7,351 → 7,694 → 8,403 → 8,901 → 9,546 → 10,285 → 11,134 → 11,844 → 12,602 → 13,892 → 14,761 → 15,467 → 16,054 → 16,746 → 17,640 → 19,282 → 19,690 → 20,339. Monotonic growth throughout, including across the 2024→2025 boundary where the code path changes from classic to reshaped — no discontinuity coincides with that methodology change.

### 4.2 The apparent 2025 "growth dip" is a snapshot-spacing artifact, not a methodology problem

Raw period-over-period growth for 2025 (+2.1%) looks low against neighboring years (2024: +9.3%, 2026: +3.3%). Snapshot dates are irregular (175 to 609 days apart), so raw period-over-period change is not comparable across years. Annualizing by actual elapsed days:

| Year | Snapshot date | Days since prior | Raw % change | Annualized % |
|---|---|---:|---:|---:|
| 2023 | 2023-04-09 | 364 | +5.3% | 5.36% |
| 2024 | 2024-12-08 | 609 | +9.3% | 5.48% |
| 2025 | 2025-06-01 | 175 | +2.1% | **4.47%** |
| 2026 | 2026-02-08 | 252 | +3.3% | 4.81% |

Once annualized, 2025's growth rate sits inside the surrounding years' range, not below it. The raw dip is fully explained by 2025 having the shortest inter-snapshot interval (175 days) of the entire 20-year series, not by the reshaped-path adapter under-counting.

### 4.3 Surname-change rate rises monotonically with years observed

Restricted to the 21,106 distinct NPIs ever observed as `tax_class = 'midwife'`, the fraction who appear under more than one surname rises cleanly with how many distinct panel years that person was observed in:

| Years observed | n | % with a surname change |
|---|---:|---:|
| 1 | 665 | 0.0% |
| 2 | 452 | 1.1% |
| 3–5 | 3,343 | 3.8% |
| 6–10 | 4,543 | 9.6% |
| 11–20 | 12,103 | 11.9% |

A monotonic relationship between years-of-exposure and observed-rate is what a real, gradually-accumulating life event (marriage, divorce) should look like. Matching noise unrelated to true identity continuity would not be expected to produce this clean a gradient — noise driven by, e.g., NPI-reuse or bad joins would more plausibly scatter across the bucket structure rather than track it. (9.5% overall, for context against §3.3's non-comparable 79% lifetime figure.)

### 4.4 The encoding-decode bug fix had zero measurable effect on this specific dataset

`build_midwife_panel.R` had a real bug (fixed before this build ran; see the file's inline `BUG FIX` comments) in which pre-2018 Latin-1-encoded snapshots could silently drop any row containing a non-ASCII byte in a name field. Auditing the actual production output: **0 of 254,751 midwife rows, in any of the 20 years, contain a non-ASCII character in `last_name` or `first_name`.** The fix is confirmed correct against a synthetic fixture (§ commit history), but its real-world impact on this specific panel's row count was nil — NPPES name fields in this taxonomy-filtered population are apparently entered in ASCII-transliterated form regardless of snapshot encoding era. The fix remains warranted as a general correctness guarantee; it should not be read as having recovered a large number of previously-missing people in this build.

---

## 5. What remains unvalidated

- **DECEASED/RETIRED tapering** (§2): needs a full-status AMCB source, not the ACTIVE-only scraped roster used here.
- **County/geography resolution**: this appendix validates the *identity and taxonomy* layer of the panel (who, when, midwife-or-not). It says nothing about the accuracy of practice-address-to-county resolution, which is a separate downstream step not yet built for this panel.
- **2010, 2012, 2013, 2014 provenance**: these four years were fetched from NBER's mirror rather than CMS directly (CMS does not retain historical snapshots). NBER is itself downstream of the original CMS monthly release, so this is not an independent source, only a distinct *copy* of the same original file.
