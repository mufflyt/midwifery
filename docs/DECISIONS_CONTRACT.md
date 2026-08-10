# Estimand and reporting decisions — contract

Nine open questions surfaced by the 21-cycle adversarial run. Each was
deliberately **not** answered by a test or a cycle: they are choices about what
the study measures and claims, and a passing suite is not authority to make
them.

Each entry states the question, the evidence as measured on current data, the
options with their consequences, a recommendation (marked as such), and a blank
ruling line. **Nothing in the code changes until a ruling is recorded here.**
Where a decision has a provisional behaviour already shipped, that is stated
explicitly so it is not mistaken for a settled choice.

Status legend: 🔴 blocks publication · 🟡 affects a published number ·
🟢 affects wording or diagnostics only

---

## D1 🟡 "Years observed in NPPES" is censored by the panel window

**Question.** Table 1 reports a `>=15 years` band holding 3,899 midwives
(32.7%). Should the censoring be disclosed, the band relabelled, or the
variable withdrawn?

**Evidence.** The NPPES snapshot panel runs **2007–2025 — 19 years**. So
`>=15 years` can only mean 15–19, and anyone enumerated before 2007 is
left-censored: the variable measures *presence in the panel*, not career
length. `build_table1_midwives.R` computes a `left_censored` flag and never
uses it. A reader comparing this to a career-duration figure would be misled.

**Options.**

| | Consequence |
|---|---|
| **A. Relabel** to `>=15 years observed (panel censored at 19)` and report the censored count | Honest, cheap, keeps the row |
| **B. Withdraw** the variable from Table 1 | Loses a real descriptor of workforce tenure |
| **C. Keep as is** | The 32.7% will be read as career length by most readers |

**Recommendation: A.** The quantity is genuine and useful; only its name
overclaims. C is not defensible now that the censoring is documented.

**Ruling:** ______________________ **Date:** __________

---

## D2 🟡 `women_15_44` when some ACS age bands are missing

**Question.** When a county has *some* of the nine female age bands suppressed,
should the denominator be the observed partial sum, or `NA`?

**Evidence.** On the current ACS vintage this is **moot but not guaranteed**:
**0 of 3,235** counties have a partial set, and 13 have every band missing
(already `NA`). A cycle-7 fix shipped the partial-sum reading with a
`women_15_44_bands_missing` counter — **provisional, unratified**.

**Options.**

| | Consequence |
|---|---|
| **A. Partial sum + counter** (shipped) | Denominator understated where bands are missing → rate overstated; visible via the counter |
| **B. `NA` whenever any band is missing** | No silently understated denominator; loses counties entirely |
| **C. Partial sum, but suppress the derived rate** when any band is missing | Keeps the count, refuses the rate |

**Recommendation: C.** A partial denominator is fine as a description and
dangerous as a divisor. Zero counties are affected today, so the cost is zero
and the rule is in place before a vintage that needs it.

**Ruling:** ______________________ **Date:** __________

---

## D3 🟡 Whether a `ct_partial` region may be reported at all

**Question.** A Connecticut planning region whose total is missing at least one
suppressed contributing county carries `ct_partial`. Should such a region be
published with its understated total, or withheld like a fully suppressed one?

**Evidence.** Current behaviour (cycle 4): a region reports the sum of its
**observed** contributions, is `NA` only when **every** contributor was
suppressed, and carries `ct_partial` otherwise. So a partial total is
published, flagged. CDC WONDER suppression means 1–9, so each missing
contributor understates by 1–9 — small individually, unbounded in aggregate.

**Options.**

| | Consequence |
|---|---|
| **A. Publish flagged** (shipped) | Understated totals reach figures; the flag protects only readers who check it |
| **B. Withhold any partial region** | No understatement; loses regions with one suppressed county out of many |
| **C. Publish with an interval** — observed to observed + 9×(suppressed contributors) | Honest bounds; more complex to render |

**Recommendation: C** for tables, **B** for any ranking or superlative. An
understated total that can win or lose a comparison is the dangerous case.

**Ruling:** ______________________ **Date:** __________

---

## D4 🔴 General fertility rate: reliability treatment

**Question.** Small-denominator counties produce imprecise rates. What, if
anything, should be done beyond the validity bound already in place?

**Evidence.** 3,221 counties carry a rate; median **63.0**, max **482.8**.
Cycle 8's validity bound (>200 per 1,000 is demographically impossible)
excludes **16** counties and is near-uniform across rurality. But precision
degrades well below that bound:

| denominator | counties | share | their median rate |
|---|---:|---:|---:|
| < 1,000 women | 451 | 14.0% | 71.9 |
| < 2,000 women | 889 | 27.6% | 69.1 |
| < 5,000 women | 1,705 | 52.9% | 67.3 |

Small-denominator counties run systematically *higher* — the signature of noise
inflating the maximum, not of genuinely higher fertility. Cycle 7's 5,000-woman
floor was withdrawn because it removed **88.4% of remote counties**.

**Options.**

| | Consequence |
|---|---|
| **A. Validity bound only** (shipped) | Noisy rates remain rankable; superlatives may still name a small county |
| **B. MOE-aware** — use the ACS margins shipped with the estimates; suppress or widen where the CV exceeds a threshold | Principled, per-county, no blanket rural exclusion; needs the MOE columns pulled |
| **C. Smoothed / empirical-Bayes rate** shrunk toward the state mean | Stabilises ranking; the published number is no longer the raw county rate |
| **D. Report rates, rank nothing** | Eliminates the problem; loses the superlative sentences |

**Recommendation: B**, with **D** for superlatives until B is in place. B adapts
to each county's actual precision instead of imposing one population cutoff,
which is exactly what made cycle 7's floor rurally biased.

**Ruling:** ______________________ **Date:** __________

---

## D5 🔴 Minimum cohort coverage for a Healthgrades field to be publishable

**Question.** At what cohort coverage does a scraped field stop being a
descriptor and start being noise?

**Evidence.** Coverage against the 11,913 ACTIVE cohort, crawl at ~65%:

| field | verdict | cohort coverage |
|---|---|---:|
| `hg_gender` | VARIES | 25.5% |
| `hg_accepts_new_patients` | VARIES | 25.5% |
| `hg_has_telehealth` | VARIES | 25.5% |
| `hg_medicaid_named` | VARIES | 23.4% |
| `hg_age` | VARIES | 13.4% |
| `hg_languages` | VARIES | **1.5%** |
| `hg_years_experience` | CONSTANT | **not publishable at any coverage** |

Projected coverage at crawl completion is **~49%**, and the missing half is
**not missing at random** — a Healthgrades profile indicates a marketing
presence, which plausibly correlates with practice setting and urbanicity.

**Options.**

| | Consequence |
|---|---|
| **A. Threshold on coverage** (e.g. ≥50%) | Simple; `hg_languages` and probably `hg_age` drop out |
| **B. Publish any VARIES field with its coverage stated** | Maximum information; invites over-reading a 1.5% field |
| **C. Publish only as a sensitivity analysis**, never in Table 1 | Safest; costs the demographic block |

**Recommendation: A at ≥50%, plus C for anything below.** Also required
regardless of threshold: state that profile presence is non-random, because
that limitation applies even at 100% coverage.

**Ruling:** ______________________ **Date:** __________

---

## D6 🟢 Nesting-escape threshold that should fail a map build

**Question.** Cycle 14 made the build measure how much of a smaller isochrone
band escapes its larger band before absorbing it, and write
`artifacts/coverage_nesting_report.csv`. **No threshold fails the build.** What
magnitude should?

**Evidence.** The escape exists because two routing engines (EC2 Valhalla and
`valhalla1.openstreetmap.de`) disagree by up to **15% in area** on shared
origins. An escape is that disagreement expressed geographically. No production
figure exists yet — the report is written but has not been reviewed.

**Options.** (A) Warn only, as shipped. (B) Fail above an absolute km² figure.
(C) Fail above a percentage of the outer band. (D) Fail if any escape exists,
and re-route the affected origins on a single engine.

**Recommendation:** review one production report first, then set **C**. Also
worth deciding separately whether mixed-engine surfaces are acceptable in a
published figure at all — that is the underlying question the escape measures.

**Ruling:** ______________________ **Date:** __________

---

## D7 🟢 `general_fertility_rate` is an ACS survey measure, not the NCHS GFR

**Question.** Should the column be renamed, or the divergence disclosed?

**Evidence.** With both cycle-16 and cycle-17 corrections applied, the national
rate is **59.2 per 1,000**. NCHS reports **54.5** for 2023. The ~9% gap is
expected — ACS `B13016` asks women whether they gave birth in the past 12
months, and self-report runs above vital-statistics birth certificates. The
number is not wrong; its **name** invites a comparison it will lose.

**Options.** (A) Rename to `acs_births_per_1000_women_15_44`. (B) Keep the name,
disclose the divergence wherever published. (C) Both.

**Recommendation: C.** The rename prevents the error; the disclosure explains
it for anyone holding the old name.

**Ruling:** ______________________ **Date:** __________

---

## D8 🔴 The 1,163 address-provenance disagreements (data question)

**Question.** `R/03-geography-hierarchy.R` aborts because the coordinate-source
address disagrees with the pinned roster address for 1,163 records. Which
address is authoritative, and what happens to those that cannot be placed?

**Evidence.** Strict per-ZIP classification, matching the shipped evidence file:

| class | n | |
|---|---:|---|
| different state | 390 | definitely misplaced |
| different county, same state | 175 | definitely misplaced |
| same county | 171 | harmless |
| ZIP spans several counties | 427 | **unplaceable either way** |

565 (48.6%) definitely change county — the unit of every access finding. Two
downstream artifacts cannot be regenerated while this aborts.

**Options.** (A) Roster address authoritative — re-geocode the 565.
(B) Coordinate-source authoritative — update the roster ZIP.
(C) Case-by-case triage on geocode quality. (D) Exclude all 1,163 and report
the exclusion.

**Recommendation:** resolve the 565 by geocode quality (**C** restricted to
them), and treat the 427 as **unplaceable** — excluded from county-level
analysis with the count reported, since no rule can place them honestly.

**Ruling:** ______________________ **Date:** __________

---

## D9 🔴 Upstream name normalisation, and whether to re-run linkage

**Question.** `extract_first_initial()` in `~/isochrones` strips an accented
first letter instead of transliterating it, and it is a **linkage blocking
key**. Fix it — then does the linkage get re-run?

**Evidence.** 6 of 6 accented names block on the wrong letter. Accented names
are 52× concentrated in the fuzzy-match tier; Fisher exact **OR 0.18 (95% CI
0.06–0.49), p = 0.0002** for reaching the primary tier. **Limits, stated
plainly:** only 23 of 22,309 names carry non-ASCII characters, and non-ASCII is
a crude proxy — Nguyen, Garcia and Chen are pure ASCII. Treat this as evidence
that the pipeline is *sensitive to name normalisation*, not as a quantified
equity finding.

**Options.** (A) Fix upstream, re-run linkage, accept a changed cohort.
(B) Fix upstream, do not re-run — document that the frozen linkage predates it.
(C) Fix and re-run only as a sensitivity analysis.

**Recommendation: A**, because the cohort is the study's denominator and a
known-biased blocking key should not define it. But note the coupling: re-running
linkage changes the 11,913, which invalidates every current figure — so it
should happen **once**, deliberately, before the manuscript's numbers are
frozen, not after.

**Ruling:** ______________________ **Date:** __________

---

## Sequencing

D9 and D8 change cohort membership and geography, so they must be settled and
executed **before** D1–D7 are applied to final numbers; otherwise every figure
is computed twice. D5 depends on the crawl finishing (~8.5 h at the time of
writing). D6 needs one production nesting report to exist.

Suggested order: **D9 → D8 → D4 → D5 → D2 → D3 → D1 → D7 → D6.**
