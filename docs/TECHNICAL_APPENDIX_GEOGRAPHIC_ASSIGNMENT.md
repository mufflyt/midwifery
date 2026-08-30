# Technical Appendix: Geographic Assignment, and Which Numbers Are Pinned

**Repository**: `midwifery`
**Primary scripts**: [`R/07-cohort-composition.R`](../R/07-cohort-composition.R), [`R/lib/zip_county_crosswalk.R`](../R/lib/zip_county_crosswalk.R), [`geocode_panel_addresses.R`](../geocode_panel_addresses.R)
**Catalog**: [`manuscript/R/build_stats_catalog.R`](../manuscript/R/build_stats_catalog.R)
**Investigation date**: 2026-08-29
**Status**: §2–§4 describe the implemented method. §5 documents an exposure that is currently unguarded, and is the reason this appendix exists in its present form.

---

## 1. The problem

The provider registry publishes a practice **ZIP code and state**, not a county.
Every rurality statement in this study therefore rests on a ZIP-to-county
assignment that the source data does not make, and the assignment rule is
consequential rather than clerical.

## 2. Primary assignment: dominant-county by land area

Each ZIP is mapped to the county holding the largest share of that ZCTA's land
area, across **33,791** ZCTAs, using the Census 2020 ZCTA-to-county relationship
file. Rurality is then the 2023 USDA Rural-Urban Continuum Code of that county,
banded metropolitan (1–3), nonmetropolitan adjacent (4–6), nonmetropolitan
remote (7–9).

Three properties of this rule matter and are reported rather than assumed:

- **30.1%** of ZCTAs span more than one county, so the rule is doing real work
  rather than resolving a formality.
- **1,629** ZCTAs have a dominant county holding **under 60%** of their land.
  Those assignments are arbitrary in the strict sense: a different tie-break
  would move them.
- A USPS ZIP is not a ZCTA. Post-office-box and unique-business ZIPs have no
  ZCTA at all. **98.2%** of provider-years matched; the unmatched remainder is
  disproportionately administrative addresses.

**Missing geography stays missing.** An earlier crosswalk grouped Census records
by ZIP without first excluding the 903 rows carrying no ZIP. Those rows
collapsed to a single missing key, and because a left join matches a missing key
to a missing key, every subject with no usable ZIP was assigned that row's
county — a real, remote, rural county in Alaska. Absent geography was not merely
mishandled; it was converted into a specific and plausible location that carried
a rurality classification into downstream estimates. This is now scientific law
**L3**, and its planted defect is the historical bug itself, rebuilt.

## 3. Why rurality is assigned from ZIP and not from the geocode

The composition analysis derives rurality from the practice ZIP **even though a
geocoded county exists**, and does so deliberately:

> Derived from the practice ZIP for EVERY group via the Census ZCTA-county
> crosswalk, so it is observable regardless of geocoding success. Using a
> geocoded county would condition on the outcome and make the removed group
> incomparable.
> — [`R/07-cohort-composition.R`](../R/07-cohort-composition.R)

Conditioning on geocoding success would compare groups on a variable that is
itself a function of group membership. This choice is the reason the selection
bounds had to be rebuilt: the first version of that analysis used `county_best`
— the geocoded county — and produced an interval about a population the
manuscript never reports.

## 4. Sensitivity: geocode and point-in-polygon

Addresses were independently geocoded through a three-tier cascade (Census
geocoder, then ArcGIS, then centroid fallback) and assigned to county by
point-in-polygon. The cascade resolved **98.1%** of **12,722** distinct
addresses; point-in-polygon placed **100.0%** of the resulting **66,302**
distinct points inside a county.

The two constructions have unrelated failure modes — one fails on ZCTA
mismatch, the other on address parsing — and they agree. A Census-geocoder-only
variant loses **22.1%** of addresses and flattens the rurality gradient, which
is itself informative: the flattening is a coverage artifact of the stricter
geocoder, not a finding.

## 5. Fifty-five numbers are pinned, and nothing checks them

This is the exposure, stated plainly.

The manuscript renders every quantity through a stats catalog rather than typing
it into prose, and a gate fails the build if a protected result appears as a
literal. That guarantees **prose == catalog**. It does not guarantee **catalog
== the analysis that produced it**.

Five catalog sections are entered as literals rather than read from an artifact
at render time:

| section | pinned values | what they cover |
|---|---|---|
| `panel` | 12 | snapshot count, cohort size, provider-years |
| `persist` | 9 | annual and career persistence, by county / ZIP / state |
| `rural` | 10 | the persistence-by-rurality gradient and its interval |
| `movers` | 6 | destination strata of providers who changed county |
| `geo` | 18 | every number in §2 and §4 above |

**55 values, and no test compares any of them to its source.**

The catalog documents the reason and it is a real one:

> PINNED, and flagged as such. These come from the 2007-2025 provider panel
> (~493 MB, gitignored and person-level) and from the geocoding cascade, neither
> of which can be re-derived inside a render. They are entered once, here, with
> the artifact that produced them named — not scattered through the prose, which
> is the failure this catalog exists to prevent.

That is a genuine improvement on the prior state, where the same numbers were
typed into paragraphs. It is not the end state. The failure mode it prevents —
one quantity drifting into several values — is prevented only for the
indirection between prose and catalog. Between catalog and analysis it remains
open: re-running the persistence analysis with a corrected input would produce
new numbers, and the catalog would keep the old ones silently.

This is the same shape as the defect that produced three simultaneous values for
the metropolitan share, moved one level out — from the `.qmd` into the `.R`.

**What would close it**: an aggregate artifact written by the persistence and
geocoding analyses at the time they run, carrying these values with a provenance
sidecar, and read by the catalog at render time — exactly what
`linkage_selection_bounds.csv` and `linkage_coverage_floor.csv` already do for
the numbers in this study that *are* artifact-backed. Scientific law **L12**
would then extend to cover them.

Until then, the pinned values are trustworthy exactly to the degree that the
regeneration instructions in the catalog comment are followed, which is a
process guarantee rather than a mechanical one, and this appendix records that
distinction rather than leaving a reader to infer it.

## 6. Reproducing this

```
Rscript R/07-cohort-composition.R            # ZIP-based rurality -> composition_rucc_cat.csv
Rscript tests/ci_science_laws.R              # L3: absent geography stays absent
Rscript tests/test_geography_masking_metamorphic.R   # L6: masking cannot invent geography
```

The geocoding cascade and the persistence analysis are not re-derivable inside a
render; see [`docs/RESULTS_geographic_persistence.md`](RESULTS_geographic_persistence.md)
for their regeneration.
