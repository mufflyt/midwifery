# The Boards of Nursing re-harvest: what it recovered, and what no harvest can

**Date**: 2026-11-15
**Scope**: the eight state Board of Nursing snapshots consumed by
`build_state_source_audit.R`
**Prior artifacts**: the 2026-11-09 files are tracked, so git itself is the
authoritative preservation — recover any of them with
`git show 6df41c1:artifacts/live_<state>_bon_ingested_midwives_from_tracked_roster.csv`
(verified byte-identical to the working copies taken before the re-harvest,
Colorado sha256 `78a5970885abbb19...`). Local pre-overwrite copies sit in
`artifacts/archive/bon_2026-11-09/`, which is gitignored so that
person-level data is not duplicated in the repository.
**Machine-readable result**:
`artifacts/state_boards_of_nursing_reharvest_before_after.csv`

---

## 1. The defect being repaired

`build_state_source_audit.R:143` reads `live_bon_state`. Four of the eight
harvested files did not have that column, and `dplyr::bind_rows()` fills an
absent column with `NA`, so 1,411 of 2,269 verified board records entered the
state comparison with no state and silently failed to be comparable — while
the audit went on labelling the source "7 states: CO/CT/FL/IL/PA/TX/WA".

The re-harvest asked a question the earlier investigation had assumed the
answer to: **was the column missing because the harvester dropped it, or
because the source never published it?** The answer differs by state, and
that distinction is the whole result.

## 2. What the four sources actually publish

Probed live on 2026-11-15 before changing any code:

| State | Endpoint | Geographic fields the source publishes | Recoverable |
|---|---|---|---|
| Colorado | data.colorado.gov `7s5z-vewr` | `city`, **`state`**, `mailzipcode` | **yes** |
| Pennsylvania | pals.pa.gov `SearchForPersonOrFacilty` | `City`, **`State`**, `County`, `zipcode`, `AddressLine4` | **yes** |
| Texas | data.texas.gov `jnzg-cr4w` | `county_of_residence` (82% filled), `place_of_employment` (free text) | **no** |
| Washington | data.wa.gov `qxh8-f4bd` | *none* — name, credential, type, status, dates only | **no** |

Colorado and Pennsylvania were **harvester defects**: both APIs return the
licensee's state on the same row the harvester was already reading, and both
scripts discarded it. Texas and Washington are **source limitations**: no
re-harvest, re-query or re-scrape can produce a state that the publisher does
not publish.

### Why Texas's county and employer were not used as a substitute

`county_of_residence` is a Texas county name, so deriving `state = "TX"` from
it is arithmetically possible. It was rejected for two reasons. First, it
would be circular: the Texas harvester only considers cohort members NPPES
already places in Texas (§4), so a derived "TX" would agree with NPPES by
construction and measure nothing. Second, `place_of_employment` is an
*employment* address, a different concept from the residence or mailing
address every other state in this comparison reports; substituting one for
the other would make the sources non-comparable in a way no reader could see.

## 3. What the re-harvest changed

Measured by `validate_source_coverage()` against the same manifest, so the
before and after columns are the same measurement:

| State | Source publishes state | 2026-11-09 | 2026-11-15 | Recovered | Status before |
|---|---|---|---|---|---|
| Colorado | yes | 0 | **485** | +485 | `schema_invalid` |
| Pennsylvania | yes | 0 | **87** | +87 | `schema_invalid` |
| Connecticut | yes | 28 | 28 | 0 | ok |
| Delaware | yes | 0 | 0 | 0 | `present_zero_records` |
| Florida | yes | 674 | 674 | 0 | ok |
| Illinois | yes | 18 | 18 | 0 | ok |
| Texas | **no** | 0 | 0 | 0 | ok |
| Washington | **no** | 0 | 0 | 0 | ok |
| **Total** | | **720** | **1,292** | **+572** | |

Restricted to records the audit actually compares (`live_bon_match_status ==
"VERIFIED_LIVE_BON"`), the comparable sample rose from **668 to 1,240
records** and from **four states to six**.

Note the two `schema_invalid` verdicts: run against the archived 2026-11-09
files, the contract added in this branch **fails** on Colorado and
Pennsylvania. The defect is caught retroactively by the check that now
prevents it.

## 4. The circularity the re-harvest exposed, which it does not fix

Every one of the eight harvesters selects its candidate pool with
`nppes_state == "<its own state>"`. Colorado's harvester only ever examines
cohort members NPPES places in Colorado.

So "State Boards of Nursing agreement with NPPES" does **not** measure two
independent sources agreeing on a midwife's state. Within a sample selected
on NPPES state, it can only measure whether the board's own mailing address
also names that state. Agreement near 100% is close to structurally
guaranteed, and Figure 6's ranking of this pair against genuinely independent
pairs is not like-for-like.

The newly recovered data quantifies the residual:

| State | Board address = board's jurisdiction |
|---|---|
| Florida | 600 / 622 (96.5%) |
| Colorado | 455 / 485 (93.8%) |
| Illinois | 17 / 18 (94.4%) |
| Connecticut | 26 / 28 (92.9%) |
| Pennsylvania | 74 / 87 (85.1%) |

Pennsylvania is the clearest case that this field is real signal and not a
tautology: across all 500 current Nurse-Midwife licensees, only 303 (61%)
give a Pennsylvania address — 47 are New Jersey, 16 New York, 15 Maryland. A
harvester that had defaulted the column to "PA" would have fabricated 197
observations.

**This is an interpretive correction, not a data repair.** The figure and the
§4 rankings must describe this source as *address concordance within a
state-matched sample*, not as independent state agreement, and must state the
sample is six states, not seven. No re-harvest can change that; only the
labelling and the ranking can.

## 5. Florida's 191 blank states are a finding, not a gap

Of Florida's 813 verified records, 191 carry no state. They are not missing
data: the board returns an explicit message in the address field —
`"NOT PRACTICING"`, or `"No current practice location in Florida"`. Florida
is affirmatively reporting the absence of an in-state practice location.
Dropping them as `NA` discards that statement. They belong in the audit as
observed absence, in the same category as Delaware's present-and-empty file.

## 6. Contract changes made alongside

`describe_source_input()` previously required the declared state column to
exist, which would have failed Texas and Washington as `schema_invalid` for a
property of their sources rather than a defect. It now distinguishes the two:

- an **empty** `state_field` in `config/state_source_audit_sources.csv`
  declares that the source publishes no state; the schema check does not
  demand the column, and `state_observed_count` stays 0 so nothing downstream
  can read a declared absence as evidence;
- a **non-empty** `state_field` demands the column, and its absence fails a
  publication build naming the column and the producer to rerun — which is
  exactly the Colorado and Pennsylvania case.

The publication failure message now carries each row's
`validation_message` rather than only its status, so a non-interactive CI log
says which column went missing and which producer to rerun.

Tests: `tests/test_source_coverage_contracts.R` T13–T15 (30 checks, all pass).

## 7. Still outstanding

- Figure 6 and the §4 rankings must be relabelled per §4 before publication;
  they remain **RED** until then, for interpretation rather than coverage.
- Florida's 191 affirmative absences should enter the audit as observed
  absence (§5) rather than being NA-dropped.
- California has a harvester (`harvest_live_california_bon_from_tracked_roster.py`)
  but no declared manifest row and no current artifact; it is neither
  harvested nor claimed, and is listed here so it is not mistaken for an
  omission.
