# Geographic persistence of the located midwifery workforce, 2007–2026

> **Rebuilt 2026-10-30 against the current 16,775-member cohort.** The
> previous version of this document was computed 2026-08-14 against the
> 16,892-NPI cohort and went stale through two subsequent re-pins (16,892 →
> 17,028 → 16,775, the latter from `reconcile_ab_20261022T134500_remove_fuzzy_surname_matching`)
> without ever being regenerated -- `DEBT.md` D10's own account of why, and
> [`docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`](TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md)
> is the related year-by-year diagnostic, also refreshed this pass. This
> rebuild has a checked-in script for the first time:
> [`build_results_geographic_persistence.R`](../build_results_geographic_persistence.R)
> — the previous version's "Reproducing" section gave a manual recipe, not a
> command, because none existed. **Update, same day:** the canonical "3-tier
> cascade + TIGER PIP" method (§3) was *also* re-run at this vintage --
> 15,258 distinct historical addresses geocoded live via the real
> `geocode_queue_cascade.R`, fanned out across the full panel by
> [`build_results_geographic_persistence_canonical.R`](../build_results_geographic_persistence_canonical.R)
> -- so the numbers below are no longer the faster, uncross-validated
> method alone. See §3 for the full comparison: the two methods agree to
> within 0.1 points on every headline figure, at this cohort for the first
> time.

Computed 2026-10-30 from `midwife_panel.csv` (NPPES annual snapshots, 2007–2026)
restricted to the 16,775 NPIs in the frozen AMCB linkage
(`reconcile_ab_20261022T134500_remove_fuzzy_surname_matching`).

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
| Panel | NPIs × 20 annual snapshots (2007–2026), restricted to the linked cohort |
| Providers observed | **16,775** of 16,775 linked NPIs |
| Provider-years | 215,535 |
| Median years observed per provider | **13** |
| Consecutive-year pairs | 198,760 |

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
  all. **98.2%** of provider-years matched (211,761 of 215,535); the missing
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
| **year to year** | **96.1%** | 94.5% | 98.0% |
| **first vs last observation** (median 13-year span) | **68.1%** | 56.3% | 82.5% |

195,080 consecutive-year pairs across 16,328 providers observed more than
once. The annual county figure falls inside the 94.5–98.0% bound the ZIP/state
pair predicted, which is a small consistency check on both.

Career-length county persistence (68.1%) is much higher than ZIP persistence
(56.3%): **a large share of ZIP moves do not cross a county line.** Anyone
using ZIP change as a mobility proxy overstates relocation by about twelve
percentage points over a career.

By year, ZIP persistence sits in a 92–97% band throughout -- **including the
new final transition, 2025→2026, at 95.7%.** The previous version of this
document flagged 2025 (then the final year) as a 90.7% exception, more likely
an artefact of that snapshot's construction than a real surge. With a 2026
snapshot now added, that flag resolves: 2025→2026 is unremarkable, and the one
real low point in the series is 2023→2024 at 90.2%, already fully accounted
for by the NPPES format-change spike documented in
[`docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`](TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md).
The "final year" flag was describing an incomplete-vintage artefact, not a
real trend -- exactly what it was hedged as.

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
| Metro (RUCC 1–3) | 14,021 | 96.2% | **68.6%** |
| Nonmetro, adjacent (4–6) | 1,190 | 95.6% | **64.2%** |
| Nonmetro, remote (7–9) | 544 | 95.3% | **62.8%** |

Annually the strata remain close — a remote-origin midwife moves county about
4.7% of years against 3.8% for metro, close to a quarter more often but small
in absolute terms. **Over a career the gradient runs the other way
from the earlier (destination-based) result:** 62.8% of remote-origin
midwives end in the county they started in, against 68.6% of metro-origin
ones — but see the method comparison below: this gradient's exact size (not
its direction) has not been re-verified against the canonical method at this
cohort vintage.

The destination-based cut had nonmetro-adjacent as the *stickiest* stratum
(61.1% versus 54.5% metro). Origin-based, it is among the least sticky. **The
correction did not shrink the effect; it changed its sign.**

### Where movers go

Career movers, by origin and destination stratum:

| origin | → Metro | → Nonmetro adj | → Nonmetro remote |
|---|---:|---:|---:|
| Metro | 3,882 | 302 | 137 |
| Nonmetro, adjacent | 335 | 49 | 38 |
| Nonmetro, remote | 124 | 42 | 35 |

Rural-origin midwives who move go overwhelmingly to metro counties — 79% of
adjacent-origin movers and 62% of remote-origin movers. Metro-origin movers
overwhelmingly stay metro (90%).

**Net flows are nevertheless close to balanced**: 459 nonmetro-origin movers
end in metro, while 439 metro-origin movers end nonmetro. There is no large
absolute rural drain in this cohort. But the nonmetro base is small — about
1,734 providers against 14,021 metro — so the same absolute flow is a far
larger share of the rural workforce, and the *rate* of leaving is what a county
feels.

## Three methods, and the rural penalty holds

**Re-verified at the current (16,775) cohort vintage, 2026-10-30.** Every
distinct practice address across the full 2007–2026 panel history for this
cohort — 15,258 of them — was geocoded live via `geocode_queue_cascade.R`'s
real Census → ArcGIS → TIGER point-in-polygon cascade (not reimplemented;
the actual production script), then fanned out to every provider-year
sharing that address. See
[`build_results_geographic_persistence_canonical.R`](../build_results_geographic_persistence_canonical.R)
for the fan-out and
[`artifacts/geographic_persistence_method_comparison.csv`](../artifacts/geographic_persistence_method_comparison.csv)
for the machine-readable comparison this table summarizes.

| | ZCTA crosswalk | **3-tier cascade + TIGER PIP (canonical)** |
|---|---:|---:|
| provider-years resolved | 211,761 (98.2%) | **211,751 (98.2%)** |
| annual same county | 96.10% | **96.10%** |
| career same county | 68.06% | **68.04%** |
| career — metro origin (providers) | 68.60% (14,021) | **68.59% (14,080)** |
| career — nonmetro-adjacent origin (providers) | 64.24% (1,190) | **63.74% (1,173)** |
| career — nonmetro-remote origin (providers) | 62.85% (544) | **62.55% (491)** |
| metro − remote gap | 5.75 pp | **6.04 pp** |

The cascade resolved **98.1%** of 15,258 addresses — 13,582 via Census,
1,390 via the ArcGIS fallback (8.4% ArcGIS usage, under the 35% QA
threshold), 283 non-CONUS, **3 failed outright** (one was a Liberian street
address — `TODEE JUNCTION ROAD, KAKATA, MONTSERRADO` — correctly
unresolvable by a US-only geocoder, not a bug). Tract/county enrichment
(the step the 2026-08-14 vintage below found broken) resolved
**census_tract and county_fips for 100.0%** of the 14,972 successfully
geocoded addresses.

**The two methods now agree almost exactly, at a cohort vintage neither had
been run against before this rebuild.** Annual persistence matches to two
decimal places (96.10% both). Career persistence matches within 0.02 points
(68.06% vs. 68.04%). The rurality gradient — the specific thing a 16,892-era
artefact (below) once hid entirely — comes out monotone, metro-highest,
remote-lowest, under **both** methods independently, with the gap between
them (5.75pp vs. 6.04pp) well inside the noise two different county-
resolution mechanics would be expected to produce. **Remote-origin midwives
are about six percentage points less likely to end their career in the
county where they started**, and that conclusion no longer rests on a
carried-forward cross-validation from a different, stale cohort — it is
reproduced fresh, by the actual canonical pipeline, against the cohort this
whole document otherwise describes.

### The 2026-08-14 vintage's own three-way comparison (historical)

The prior build's own three-way breakdown — included here because it is
where the ArcGIS tier's specific value was first isolated, which this
rebuild's two-method comparison above doesn't re-measure on its own (the
canonical run above always used the full Census→ArcGIS→centroid cascade
together, not a Census-only ablation):

| | ZCTA crosswalk | Census batch only | 3-tier cascade + TIGER PIP |
|---|---:|---:|---:|
| provider-years resolved | 186,670 | 186,670 | 198,567 |
| providers | 15,328 | 15,053 | 15,636 |
| annual same county | 95.9% | 96.2% | 95.9% |
| career same county | 67.5% | 69.1% | 67.3% |
| career — metro origin | 68.1% | 69.4% | 67.9% |
| career — nonmetro-adjacent | 63.3% | 65.6% | 63.2% |
| career — nonmetro-remote | 61.9% | 66.2% | 61.0% |
| remote-origin providers retained | 520 | 405 | 474 |

The middle column — a hand-rolled Census-only batch call — lost 22.1% of
remote-origin providers because the Census geocoder rejects rural routes and
PO boxes; restoring them via the ArcGIS tier is what first surfaced the
rurality gradient as real rather than flat. That finding is what the
2026-10-30 rebuild above re-confirms at the current cohort, not a new
discovery.

### A silent degradation worth recording

At the 2026-08-14 vintage, the cascade returned `county_fips` and
`census_tract` **empty for all 12,722 rows** while reporting 98.1% success.
`enrich_with_census_tracts()` needs `tracts_y2020_production.rds`, which was
a Dropbox/S3 artifact not present on that machine, and the function is
documented to warn and return its input unchanged rather than fail.

An earlier pass of that analysis joined those empty columns, silently fell
back to cache-only rows, and produced 98.8% annual and 87.7% career
persistence on a third of the data. Those numbers were wrong and are
recorded here because they looked entirely plausible. **A geocoder that
reports success and returns no geography is the failure mode this
repository's own Hall of Shame opens by naming.** Coordinates were used
instead, with the county assigned locally, at that time.

**Closed properly 2026-10-30, not re-worked around.** The missing artifact
was fetched fresh from its documented Dropbox source, its SHA-256 verified
against `config/tract_boundary_artifacts.yaml`'s own manifest
(`8aa2d622...`, matching exactly), and installed at
`~/isochrones/data/cache/tract_boundaries/tracts_y2020_production.rds` --
the real expected path, not a one-off override. The 2026-10-30 cascade run
above enriched **100.0%** of its geocoded rows with a real county and
tract, the first time this repository's own geographic-persistence pipeline
has had that file in place rather than working around its absence.

## What this means for modelling a retention intervention

**Over short horizons, retention is geographically sticky.** At **96.1%**
annual county persistence, a midwife retained this year is very likely practising in
the same county next year. The geographic incidence of a one-to-three-year
retention effect falls approximately where the affected midwives already are,
and a county-level incidence model is defensible without a mobility correction.

**Over a career, it is not.** With **31.9%** changing county over a median 13
years — and 37.2% of remote-origin midwives doing so —
any claim that retaining midwives sustains supply *in a specific county* over a
decade needs the mobility term in it. The national count and the county
distribution decouple over time.

**The practical consequence:** a retention-to-access model built on this data
should state its time horizon explicitly and should not extrapolate a
short-horizon incidence assumption across a decade. That is a modelling
decision, and it now has an empirical number attached rather than an assumption.

---

## Reproducing

```sh
# ZCTA-crosswalk method (fast, no network calls)
Rscript build_results_geographic_persistence.R

# Canonical method (3-tier cascade + TIGER PIP) -- requires the geocode
# queue to have already been built and run once (hours of live Census/
# ArcGIS calls for ~15,000 addresses); see
# build_results_geographic_persistence_canonical.R's own header for the
# exact queue-build + geocode_queue_cascade.R invocation.
Rscript build_results_geographic_persistence_canonical.R
```

Both restrict `midwife_panel.csv` to the `npi` values where
`artifacts/amcb_npi_linkage_FROZEN.csv`'s `cohort_member` is `TRUE` (no
dedup needed -- verified there is never more than one row per
`npi`/`snapshot_year`), then share one computation core
(`R/lib/geographic_persistence_stats.R`) for the annual/career/RUCC-origin/
movers math; only the county SOURCE differs. The ZCTA-crosswalk script
resolves county via the canonical `zip_county_dominant()` in
`R/lib/zip_county_crosswalk.R` (dominant-land-share mapping built fresh from
`data/zcta_county_2020.txt`, not a pre-built artifact, so it inherits that
function's own NA-key safety check). The canonical script instead reads
`artifacts/panel_geocode_results_full_history.csv` (one row per distinct
historical address, from a real `geocode_queue_cascade.R` run) and fans
each address's resolved county out across every provider-year sharing it.
Both `midwife_panel.csv` and `artifacts/amcb_npi_linkage_FROZEN.csv` are
gitignored person-level artifacts; see
[SCOPE_AND_LIMITATIONS.md](SCOPE_AND_LIMITATIONS.md).

**These figures describe the *located* workforce.** Linkage is selected on
outcome — 78.0% of ACTIVE certificants reach the primary tier versus 18.6% of
DECEASED — so
providers who left the workforce are systematically under-represented, and
persistence among those we can see is not persistence among all certificants.
