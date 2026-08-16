# Observed birth activity — `R/15-build-birth-activity.R`

The layer that answers "did this midwife attend births", and the one place in
this pipeline where **not knowing** must stay missing rather than becoming zero.

Everything else here follows from that.

---

## Why unobserved stays missing

A midwife with no observed delivery could be either of two entirely different
people:

- one who attended no births in the analysis year, or
- one who attended births in a state-year-source where **we cannot see
  deliveries at all**

Collapsing those into "no births" makes poor data reporting look like an
inactive workforce. That is not hypothetical here: cycle 15 published **651
counties as having no obstetric care** on exactly that mistake, and cycles 3
and 4 published suppressed CDC WONDER cells as zeros. The birth-activity layer
is built to be structurally incapable of repeating it.

| state | `birth_active` | `observed_births` | meaning |
|---|---|---|---|
| `observed_birth_attendant` | `TRUE` | count | deliveries observed |
| `no_observed_births` | `FALSE` | `0` | none observed **and** ascertainment declared adequate for her state-year-source |
| `NA` | `NA` | `NA` | none observed and ascertainment **not** established |

The missing row is the point. `birth_active` is `NA`, not `FALSE`, and
`observed_births` is `NA`, not `0`, so any downstream mean, rate or count
propagates the missingness instead of silently absorbing a zero.

---

## The ascertainment table is a declaration, not an inference

`ascertainment_path` supplies one row per **state × year × source** with an
explicit `adequate_ascertainment` flag. A midwife is only ever assigned
`no_observed_births` when a human has declared that we could have seen her
births had she attended any.

This is deliberate and it is the load-bearing design decision: the pipeline
never infers adequacy from the data volume it happens to observe. A source that
covers a state badly looks, from inside the data, exactly like a state where
midwives attend few births. Only an external declaration separates them.

Consequence worth stating plainly: **if the ascertainment table is wrong, this
layer is wrong**, and no amount of internal validation will catch it. It is the
input most deserving of review.

---

## Inputs and outputs

| input | role |
|---|---|
| `roster_path` | AMCB/NPI/geography roster (frozen artifact) |
| `taf_path` | normalised TAF delivery file (optional) |
| `birth_cert_path` | normalised birth-certificate file (optional) |
| `ascertainment_path` | state × year × source adequacy declarations |
| `county_base_path` | county covariates, for the rurality validation |

At least one of TAF or birth certificates must be supplied; the function stops
rather than producing a table of missing activity for everyone.

| output | contents |
|---|---|
| `midwife_birth_activity_<year>_<ts>.csv` | one row per midwife: activity state, observed births, birth FTE |
| `midwife_birth_activity_location_<year>_<ts>.csv` | provider × location weights |
| `county_effective_midwife_supply_<year>_<ts>.csv` | county supply weighted by observed activity |
| `birth_activity_rural_validation_<year>_<ts>.csv` | activity states by rurality stratum |

All four are written through `write_with_provenance()`. They were not until
2026-08-14 — this stage was added after that wiring went in and used
`readr::write_csv()` directly, which made its outputs the only pipeline
artifacts untraceable to their inputs. `tests/ci_semantic_contracts.R` (S1) now
asserts the invariant for every numbered stage.

---

## Birth FTE

`reference_births` (default 100) is the birth volume corresponding to 1.0 birth
FTE. It is a **scaling convention, not a clinical standard** — a midwife
credited with 0.5 birth FTE attended half the reference volume, not half a job.
Any manuscript language should say so, or a reader will hear "half-time".

---

## The rurality validation

`validate_activity_by_rurality()` reports the distribution of observed,
ascertainable zero, and missing activity across metro / nonmetro-adjacent /
nonmetro-remote counties.

Read it as a **data-quality** check, not a finding. A rural excess of
missing activity means our sources see rural deliveries less well -- which is a
statement about the sources. Reporting that excess as a rural workforce
difference would repeat the absence-as-zero error through the back door.

---

## Manuscript decision

The 2026-08-16 ruling for D11 is binary reporting with unobserved activity
excluded from the denominator. That is why unobserved rows are encoded as `NA`
rather than as a publishable category.

---

## Status

The layer is **built and untested against real delivery data**. TAF and birth
certificate inputs are not present in this repository, so no run has produced a
populated activity table. Treat the code as specified-and-implemented, not as
validated.
