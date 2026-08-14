# Geographic persistence of the located midwifery workforce, 2007–2025

Computed 2026-08-14 from `midwife_panel.csv` (NPPES annual snapshots) restricted
to the 16,892 NPIs in the frozen AMCB linkage.

This exists to answer one question that every retention-to-access argument
depends on and none of them measures: **when a midwife stays in the workforce,
does she stay in the same place?** If mobility is high, retention preserves the
workforce nationally while redistributing it, and a county-level access gain
cannot be assumed. If mobility is low, retention is geographically sticky and
the incidence of a retention effect falls roughly where the midwives already
are.

---

## What was computed

| | |
|---|---|
| Panel | 443,623 NPIs × 19 annual snapshots (2007–2025), restricted to the linked cohort |
| Providers observed | **16,891** of 16,892 linked NPIs |
| Provider-years | 200,873 |
| Median years observed per provider | **12** |
| Consecutive-year pairs | 183,949 |

**County is not recorded in the panel** — it carries practice ZIP and state
only, and this repository holds no ZIP-to-county crosswalk. County persistence
is therefore *bounded* rather than measured:

- a ZIP change may or may not cross a county line, so **ZIP persistence is a
  lower bound** on county persistence
- a state change is almost always a county change, so **state persistence is an
  upper bound**

Both are reported. Closing the bound needs a ZCTA-to-county crosswalk, which is
a small ingest and has not been done.

---

## Annual persistence

Between consecutive snapshots, among providers observed in both years:

| measure | persistence | annual move rate |
|---|---:|---:|
| same ZIP5 | **94.2%** | 5.8% |
| same state | **97.9%** | 2.1% |

**County persistence lies between 94.2% and 97.9% per year.**

By year, ZIP persistence is stable in a 92–97% band across the whole panel. The
final year is the exception at **90.7%**, which is more likely an artefact of
the 2025 snapshot's construction than a real surge in mobility, and should not
be read as a trend without checking that snapshot's provenance.

---

## Persistence over a career

Comparing each provider's **first** and **last** observed snapshot — median
span **13 years**, 15,757 providers with at least two observations:

| measure | unchanged |
|---|---:|
| same ZIP5 | **55.3%** |
| same state | **82.1%** |

So roughly **45% change ZIP** and **18% change state** over a median 13-year
observation window.

---

## Mobility does not differ meaningfully by rurality

Annual ZIP persistence, stratified by the county the provider occupies in the
frozen geography:

| stratum | providers | pairs | same ZIP5 |
|---|---:|---:|---:|
| Metro (RUCC 1–3) | 13,848 | 161,264 | **94.0%** |
| Nonmetro, adjacent (4–6) | 1,099 | 12,728 | **95.1%** |
| Nonmetro, remote (7–9) | 462 | 5,780 | **94.1%** |

First-versus-last over the full span: metro **54.5%**, nonmetro-adjacent
**61.1%**, nonmetro-remote **55.9%**.

The strata are within about one percentage point of each other annually. On
this evidence there is **no rural-specific mobility penalty**: rural midwives do
not churn faster than urban ones.

### The caveat that limits this result

**Stratification is by where a provider is now, not where she started.** The
frozen geography gives one county per provider — the current one. A midwife who
began in a remote county and moved to a metro one is counted in the *metro*
stratum, and her move is recorded as metro mobility.

That biases the comparison toward showing rural stability, and the direction of
the bias is exactly the one that matters for the policy question. **The true
rural-origin mobility rate is understated by an unknown amount.**

Fixing it requires classifying each provider by her *first observed* location,
which needs the ZIP-to-county crosswalk above. Until then, treat "no rural
mobility penalty" as **suggestive and not established**.

---

## What this means for modelling a retention intervention

**Over short horizons, retention is geographically sticky.** At 94–98% annual
county persistence, a midwife retained this year is very likely practising in
the same county next year. The geographic incidence of a one-to-three-year
retention effect falls approximately where the affected midwives already are,
and a county-level incidence model is defensible without a mobility correction.

**Over a career, it is not.** With ~45% changing ZIP over a median 13 years,
any claim that retaining midwives sustains supply *in a specific county* over a
decade needs the mobility term in it. The national count and the county
distribution decouple over time.

**The practical consequence:** a retention-to-access model built on this data
should state its time horizon explicitly and should not extrapolate a
short-horizon incidence assumption across a decade. That is a modelling
decision, and it now has an empirical number attached rather than an assumption.

---

## Reproducing

Restrict `midwife_panel.csv` to the `npi` values in
`artifacts/amcb_npi_linkage_FROZEN_*.csv`, deduplicate to one row per
provider-year, and compare `practice_zip` (first five digits) and
`practice_state` between consecutive `snapshot_year` values. Both source files
are gitignored person-level artifacts; see
[SCOPE_AND_LIMITATIONS.md](SCOPE_AND_LIMITATIONS.md).

**These figures describe the *located* workforce.** Linkage is selected on
outcome — 82.3% of ACTIVE certificants link versus 19.6% of DECEASED — so
providers who left the workforce are systematically under-represented, and
persistence among those we can see is not persistence among all certificants.
