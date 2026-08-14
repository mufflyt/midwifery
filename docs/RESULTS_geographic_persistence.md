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

**County is now measured, not bounded.** The panel carries practice ZIP and
state only, so an earlier version of this document bounded county persistence
between ZIP (lower) and state (upper). `artifacts/zcta_county_crosswalk.csv`
closes it: 33,791 ZCTAs mapped to the county holding the largest share of their
land area, derived from `data/zcta_county_2020.txt` — the Census 2020
ZCTA-to-county relationship file **already in this repository**, feeding the
unique-ZIP county fallback in stages 02, 03, 05 and 07.

Two things about that crosswalk are worth stating:

- **30.1% of ZCTAs span more than one county.** The dominant-county rule
  resolves them, and the median dominant share is 1.000 — most ZCTAs sit wholly
  in one county — but 1,629 ZCTAs have a dominant county holding under 60% of
  their land, and those assignments are genuinely arbitrary.
- **A USPS ZIP is not a ZCTA.** PO-box and unique business ZIPs have no ZCTA at
  all. **98.2%** of provider-years matched (197,254 of 200,873); the missing
  1.8% are disproportionately administrative addresses.

Cross-checked against `~/isochrones/data/external/zcta_county_dominant_2020.csv`,
whose own derivation is unrecorded: **100.00% agreement on all 33,791 ZCTAs**.
Two independent constructions landing on identical assignments is reasonable
evidence both are right — and this one records its input's SHA-256, which the
other does not.

## Persistence

Consecutive-year pairs, providers observed in both years:

| horizon | same county | same ZIP5 | same state |
|---|---:|---:|---:|
| **year to year** | **95.9%** | 94.2% | 97.9% |
| **first vs last observation** (median 13-year span) | **67.5%** | 55.3% | 82.1% |

180,436 consecutive-year pairs across 15,605 providers. The annual county
figure falls inside the 94.2–97.9% bound the ZIP/state pair predicted, which is
a small consistency check on both.

Career-length county persistence (67.5%) is much higher than ZIP persistence
(55.3%): **a large share of ZIP moves do not cross a county line.** Anyone
using ZIP change as a mobility proxy overstates relocation by about twelve
percentage points over a career.

By year, ZIP persistence sits in a 92–97% band throughout. The final year is
the exception at **90.7%**, more likely an artefact of the 2025 snapshot's
construction than a real surge, and not to be read as a trend without checking
that snapshot's provenance.

## Rurality: the earlier finding was an artefact, and it reversed

An earlier version of this document reported no rural mobility penalty, and
flagged that the stratification used each provider's **current** county — so a
midwife who left a remote county for a metro one was counted as metro, and her
move as metro mobility. The bias ran in the direction that flattered the
conclusion.

With the crosswalk, providers can be classified by **origin**: the county of
their first observed snapshot. The result changes.

| origin | providers | annual same county | first vs last, same county |
|---|---:|---:|---:|
| Metro (RUCC 1–3) | 13,646 | 96.0% | **68.1%** |
| Nonmetro, adjacent (4–6) | 1,160 | 95.3% | **63.3%** |
| Nonmetro, remote (7–9) | 520 | 95.0% | **61.9%** |

Annually the strata remain close — a remote-origin midwife moves county about
5.0% of years against 4.0% for metro, a quarter more often but small in
absolute terms. **Over a career the gradient runs the other way
from the earlier result:** 61.9% of remote-origin midwives end in the county
they started in, against 68.1% of metro-origin ones — but see the
method comparison below: this gradient is not robust to how county is resolved.

The destination-based cut had nonmetro-adjacent as the *stickiest* stratum
(61.1% versus 54.5% metro). Origin-based, it is among the least sticky. **The
correction did not shrink the effect; it changed its sign.**

### Where movers go

Career movers, by origin and destination stratum:

| origin | → Metro | → Nonmetro adj | → Nonmetro remote |
|---|---:|---:|---:|
| Metro | 3,868 | 301 | 136 |
| Nonmetro, adjacent | 339 | 48 | 38 |
| Nonmetro, remote | 125 | 36 | 37 |

Rural-origin midwives who move go overwhelmingly to metro counties — 80% of
adjacent-origin movers and 63% of remote-origin movers. Metro-origin movers
overwhelmingly stay metro (90%).

**Net flows are nevertheless close to balanced**: 464 nonmetro-origin movers
end in metro, while 437 metro-origin movers end nonmetro. There is no large
absolute rural drain in this cohort. But the nonmetro base is small — about
1,680 providers against 13,600 metro — so the same absolute flow is a far
larger share of the rural workforce, and the *rate* of leaving is what a county
feels.

## Two methods, and neither dominates

The ZCTA crosswalk was rerun through the canonical Census geocoder: 12,722
addresses batch-geocoded against `Public_AR_Current`, joined to the 3,258
already present in `~/isochrones/data/geocoding_cache.duckdb`.

**The cache covered only 17% of the panel's distinct addresses**, which is worth
recording because it is counter-intuitive: the cohort *was* geocoded before, but
the cache holds their **current** addresses, and the panel is nineteen years of
**historical** ones. Batch match rate on the residual was 89.4%, consistent with
the 86.9% this repository documents for the Census stage.

| | ZCTA crosswalk | Census geocoded |
|---|---:|---:|
| distinct addresses resolved | **98.2%** | 91.5% |
| annual same county | 95.9% | **96.2%** |
| career same county | 67.5% | **69.1%** |
| career, metro origin | 68.1% | 69.4% |
| career, nonmetro-adjacent origin | 63.3% | 65.6% |
| career, nonmetro-remote origin | 61.9% | **66.2%** |

The headline figures agree closely — annual ~96%, career ~67–69% — which is
reassuring for both.

**The rural gradient does not agree, and the reason is selection.** Census
geocoding fails disproportionately on rural addresses (rural routes, PO boxes,
non-standard street lines):

| origin | providers, ZCTA | providers, geocoded | lost |
|---|---:|---:|---:|
| Metro | 13,648 | 13,319 | **2.4%** |
| Nonmetro, adjacent | 1,160 | 1,118 | **3.6%** |
| Nonmetro, remote | 520 | 405 | **22.1%** |

Geocoding discards **more than a fifth of remote-origin providers** against one
fortieth of metro ones. Its rural estimate is therefore computed on the subset
of rural midwives whose addresses are geocodable — skewed toward town-centre
street addresses and away from the most remote practice settings, which is
precisely the population the question is about.

So the two methods trade one bias for another. The crosswalk has near-complete
coverage and misassigns some counties; the geocoder assigns counties exactly and
loses the rural tail. Under the crosswalk the gradient is monotone and 6.2
points wide (68.1 → 63.3 → 61.9). Under the geocoder it is non-monotone and 3.2
points wide (69.4 → 65.6 / 66.2), with remote no longer the least persistent
stratum.

**A rural persistence penalty is therefore not established.** It is somewhere
between small and absent, and which you conclude depends on which missingness
you prefer. Any statement about rural mobility from this panel should be
reported both ways, or not at all.

Resolving it means geocoding the rural non-matches with a service that handles
rural routes. The repository's own cascade already has one — the ArcGIS second
stage — and it was not used here.

## What this means for modelling a retention intervention

**Over short horizons, retention is geographically sticky.** At **95.9%**
annual county persistence, a midwife retained this year is very likely practising in
the same county next year. The geographic incidence of a one-to-three-year
retention effect falls approximately where the affected midwives already are,
and a county-level incidence model is defensible without a mobility correction.

**Over a career, it is not.** With **32.5%** changing county over a median 13
years — and 38.1% of remote-origin midwives doing so —
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
