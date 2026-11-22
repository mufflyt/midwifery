# What changed in the state-source audit's numbers, and why

Every entry is a change a reader of an earlier version would need to know
about. Changes to code that moved no published number are not listed here;
they are in the git history.

Machine-readable companion:
[`artifacts/state_source_audit_before_after.csv`](../artifacts/state_source_audit_before_after.csv),
one row per Open Payments program year with both values and a reason class.

---

## 2026-11-18 — the remaining eight sources brought under the coverage contract

**What it was.** Two of the audit's ten sources were declared: Open Payments
and the Boards of Nursing. The other eight — NPPES, DAC / Physician Compare,
PECOS revalidation, Facility Affiliation, Healthgrades, Doximity, CMS NDH and
Medicaid — were read from path literals in three producers, and their expected
windows existed only as prose in §2 of the technical appendix. The protection
was asymmetric and a reader could not tell: a missing Open Payments year
failed the build, a missing NPPES year did not.

**What it is.** All ten sources, 85 declared source-year rows in
`config/state_source_audit_sources.csv`. `build_state_source_audit.R`,
`build_state_source_pairwise_audit.R` and `build_cross_source_comparison.R`
each resolve every input through `declared_path()` and name no audited source
by a path literal.

**The part that needed a new idea, not more rows.** Open Payments keeps one
file per year, so `file.exists()` is a real test of a year. Eight of the ten
keep every year in *one* file — `midwife_panel.csv` holds 2007-2026 — and for
those, presence proves nothing: a panel that lost 2015 from inside is still a
file that exists. Declaring them row-per-year against a presence check would
have produced a contract that **cannot fail**, which is worse than none,
because it reads like protection. Panel rows are checked against the years the
file actually holds, in both directions: a declared year absent from the data
is refuted, and a year in the data that nobody declared is refused — the glob
defect with the sign flipped, the data deciding the sample.

**What moved: nothing.** All three producers were re-run and every artifact
they publish is byte-identical, which is the expected result of replacing a
path literal with a declaration of the same path. The measured windows also
agree, year for year, with what §2 of the appendix already claimed in prose —
NPPES's twenty per-year record counts reproduce the published coverage CSV
exactly — so this entry records no change to any number, only a change in what
can go wrong without anyone noticing.

**One gap is now declared rather than inferred.** Facility Affiliation
2023-2025 is `unavailable`: CMS dropped the CCN columns from the DAC file in
2023 and keeps no archived affiliation history, so no file for those years can
ever carry affiliation state. The three-year hole in Figure 2 is a gap in the
source, and a build now says so rather than a reader having to notice.

**Two sources remain weaker than the other eight**, for reasons in the sources
rather than the manifest: Healthgrades has no per-record date at all, and CMS
NDH's `meta.lastUpdated` is not extracted into this audit's state path, so both
rest on a producer's declared run rather than on the bytes. Recorded in
[`state-source-audit-source-inventory.md`](state-source-audit-source-inventory.md)
so a reader knows which years are evidenced from inside the data.

---

## 2026-11-15 — Open Payments restored from one year to five

**What it was.** The 2026-11-12 build analysed program year 2024 alone,
because it discovered its years by globbing the annual artifacts and only the
2024 file was on that machine. It reported success.

**What it is.** 2021-2025, with the window declared in
`config/state_source_audit_sources.csv` and each row's year taken from CMS's
`Program_Year` column.

**What moved.** Agreement with NPPES, against the published Section 3 table at
576b537:

| Program year | Published | Rebuilt | Movement | In the 2026-11-12 build? |
|---|---:|---:|---:|---|
| 2021 | 96.2% | 95.8% | −0.4 pt | no |
| 2022 | 96.5% | 96.5% | 0.0 pt | no |
| 2023 | 96.1% | 96.1% | 0.0 pt | no |
| 2024 | 97.5% | 96.8% | −0.7 pt | yes |
| 2025 | 96.1% | 96.6% | +0.5 pt | no |

**The finding is the size of these numbers.** Restoring four missing years
moved no annual estimate by more than 0.7 percentage points, and Open Payments
still sits in the 95-97% band it always did. The defect did not corrupt the
answer; it destroyed the evidence for it. A one-year series cannot support a
claim about change over time, however close its single value turns out to be
to the five-year one. The damage was to what could be *said*, not to what was
true — which is exactly why a build that narrows its own window silently is
dangerous even when the surviving numbers are fine.

2024 moved although its file was present throughout: the annual artifact was
regenerated from the warehouse and now takes its year from `Program_Year`
rather than from the filename.

---

## 2026-11-15 — Figure 2's trend was being computed from stale prose

`make_state_source_audit_figures.R` parses the Section 3 table out of the
technical appendix, so the appendix, not the artifact, was the de facto input
to a published figure. It was three vintages old: the figure reported **−0.228
points a year at p = 0.0014** from data that no longer existed.

Now **−0.248 at p = 0.0002**, from
`artifacts/state_source_audit_agreement.csv` via
`refresh_state_source_appendix_section3.R`, with
`tests/test_appendix_matches_artifacts.R` failing if the table and the artifact
ever diverge again.

---

## 2026-11-15 — Boards of Nursing relabelled

`substr(board, 1, 2)` gave `CO` for both colorado and connecticut, `PE` for
pennsylvania and `TE` for texas, so one run published "CO/CO/DE/FL/IL/PE;
TE/WA". Board names are not state codes. The mapping is explicit and an
unmapped board now fails loudly. The earlier "7 states: CO/CT/FL/IL/PA/TX/WA"
label described a sample this source never had.

---

## 2026-11-17 — Section 2's coverage numbers were never guarded, and had drifted

A1-A4 of `tests/test_appendix_matches_artifacts.R` pinned the Section 3
agreement table. Nothing watched Section 2, whose Open Payments row carries two
ranges in prose, and both were still pre-rebuild values.

| Claim in §2 | Was | Is | Source of truth |
|---|---|---|---|
| 2021-2025 cohort NPIs per year | 2,391-4,382 | **2,370-4,324** | `artifacts/state_source_audit_coverage.csv` |
| 2015-2020 rows per year | 1-29 | **0-29** | `artifacts/open_payments_annual_coverage_audit.csv` (2017 holds 0) |

A5c and A6 now pin both ranges to those artifacts. This is the same class of
defect as Figure 2 drawing its trend from stale prose, one section up.

---

## 2026-11-17 — Four of six figures were stale, and redrawing two of them cut text off

`eb8d693` raised `base_size` from 11 to 13 across all six audit figures but
regenerated only two of them, so four kept their 11-point rendering and the
repository stopped agreeing with the script that claims to produce it.

Redrawn at 13 without a fix, two lose text outright: the consensus title ends
`...the sources disagree abou`, and the multistate subtitle ends `43.8% were
e`. `ggsave()` draws a label wider than the canvas and returns successfully, so
nothing failed and nothing warned.

One figure had **already shipped** damaged: `state_source_agreement_by_year`'s
caption is right-aligned, so its overflow was cut from the left, and the
committed PDF begins mid-sentence at `of TECHNICAL_APPENDIX_...`.

`fit_plot_labels()` now measures every title, subtitle and caption at the size
its own completed theme will draw it — with `systemfonts`, which is what
`svglite` and `ragg` measure with at draw time — and wraps until it fits.
Titles and captions are aligned to the plot rather than the panel, so they get
the whole canvas rather than what is left beside the axis labels.

**No plotted value changed.** Every numeric token extracted from all six
rebuilt figures is identical to the committed ones, except
`state_source_agreement_by_year`, which gains the `§3` that used to be cut off
its own caption.

---

## 2026-11-17 — The Open Payments extractors were reading a different cohort arm

Both Open Payments extractors chose their cohort by matching
`amcb_npi_crosswalk_*panel*.csv` and taking the first of a **descending** sort
— the `translit` arm — while `build_table1_midwives.R`, the hospital matchers
and the licence enrichers all name `c5guard` outright. The three arms exist in
order to differ, so the denominator under every Open Payments percentage was
being selected by alphabetical order.

**No number moved**: the three arms are identical today on every column either
extractor reads. Both now call `cohort_artifact_path("crosswalk_c5guard")`.
This is recorded as a changed *method*, not a changed result — the agreement
was luck, and luck is not a contract.

---

## 2026-11-17 — Abbreviations spelled out

First-use expansions in the appendix and the vignette, a glossary at
[`state-source-audit-abbreviations.md`](state-source-audit-abbreviations.md),
and expansions in the figure captions so a plot read without the manuscript
still defines its own source names. No number changed.

One source name was wrong rather than merely abbreviated: the vignette listed
"CMS's National Downloadable Health directory" among the ten sources. That slot
is the National Directory of Healthcare Providers (NDH), and it now says so.
