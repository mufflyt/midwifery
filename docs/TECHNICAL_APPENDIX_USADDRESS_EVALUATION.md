# Technical Appendix: Evaluation of `usaddress` as a Supplementary Address-Matching Pass

**Repository**: `midwifery`
**Existing hand-rolled component this was tested against**: [`R/lib/address_keys.R`](../R/lib/address_keys.R) (`norm_addr()`), consumed by [`link_practice_locations_to_org_npi.R`](../link_practice_locations_to_org_npi.R), `resolve_org_ambiguity.R`, `match_open_payments_to_facility.R`, `build_rigorous_hospital_attributions.R`
**Tool evaluated**: [`usaddress`](https://github.com/datamade/usaddress) (Python), a CRF-based US address parser
**Investigation date**: 2026-09-06
**Status**: recommended for adoption as a second-pass supplement, not a replacement. Not yet wired into any pipeline script. Every number below is read from an actual run against this project's own address data, not asserted from the tool's general reputation.

---

## 1. Why this was considered

`norm_addr()` normalizes a street address into a join key by upper-casing,
collapsing punctuation to spaces, and rewriting street-type and directional
words through a hand-built 14-entry lookup table (`STREET`→`ST`,
`AVENUE`→`AVE`, `SUITE`→`STE`, and four directionals). It is a linear
string-substitution function with no model of address grammar: it cannot
reorder tokens, and it only recognizes the street-type words someone thought
to add to the table.

`usaddress` parses a US address into labeled components (`AddressNumber`,
`StreetName`, `StreetNamePostType`, `OccupancyIdentifier`, etc.) using a
model trained on a large corpus of real addresses, rather than a fixed
substitution table. The question this evaluation answers: **does that buy
real, additional matches on this project's actual data, or is it a
plausible-sounding capability that doesn't move the number?**

## 2. Initial hypothesis, tested and rejected

The original hypothesis was that `norm_addr()`'s 14-word abbreviation table
is too small against USPS's ~200 standard street-type suffixes, and that gap
was directly costing matches. A scan of the 16,119 addresses in
`artifacts/midwife_practice_locations.csv` for suffix words absent from
`norm_addr()`'s table found 2,087 rows (12.9%) containing one.

**This hypothesis did not survive inspection of the actual matches.**
The great majority of flagged words — `PARK`, `CENTER`, `CREEK`, `MOUNTAIN`,
`HAVEN` — turned out to be parts of proper street names (`"SAM JACKSON PARK
RD"`, `"MEDICAL CENTER DR"`, `"ENGLISH CREEK AVE"`), not unhandled
terminal suffix types. A word-presence scan conflates "this word appears
somewhere in the address" with "this word is the street-type suffix
`norm_addr()` needs to rewrite," and those are not the same question. This
methodological correction is recorded here because the wrong version of this
finding would have been reported with a confident-sounding 12.9% figure.

## 3. What `usaddress` is actually good for here: grammar, not vocabulary

Direct parsing tests on real addresses from this project's data showed
`usaddress` correctly separating proper-noun street names from genuine
street types (`"3181 SW SAM JACKSON PARK RD"` → `StreetName: "SAM JACKSON
PARK"`, `StreetNamePostType: "RD"`), and — more consequentially — producing
**identical structured output from differently-ordered, differently
punctuated representations of the same address**:

- `"STE 200, 123 MAIN ST"` and `"123 Main Street, Suite 200"` parse to the
  same (`AddressNumber`, `StreetName`, `StreetNamePostType`,
  `OccupancyIdentifier`) tuple despite the unit designator appearing before
  the street address in one and after it in the other. `norm_addr()`, as a
  linear substitution function, cannot reorder tokens and would produce two
  different keys for these.

This reframed the real question: not "does `usaddress` know more
abbreviations," but "does its grammatical parsing recover matches that a
flat, order-sensitive string key misses."

## 4. Measuring the real gap, and two self-corrections along the way

**Method.** Of 9,608 distinct midwife practice locations
(`artifacts/midwife_practice_locations.csv`), 3,803 have no Type-2
organization at the same 5-digit ZIP under exact `norm_addr()` string
equality (`npi_org_all` in the Medicare DuckDB warehouse, 1,741,397
organization addresses). These 3,803 are the candidate pool: every one of
them is a location the current pipeline could not attribute to a named
organization.

**First attempt (48.6% "recovered"): rejected.** Comparing only
(`AddressNumber`, `StreetName`) — building level, no unit — found a match for
1,848 of 3,803. Inspecting the actual pairs showed most were suite-number
mismatches (`STE 1000` vs. no suite at all), and at least one was a genuine
**false positive**: `"10737 CAMINO RUIZ STE 235"` matched to
`"10737 CAMINO RUIZ #120"` — two *different* suites in the same building,
resolved to the same organization. `norm_addr()` deliberately preserves the
unit ("two suites in one building are different workplaces" — its own
docstring), so a test that drops the unit is not testing `norm_addr()`'s
actual job; it is silently substituting the different, looser
building-identity question that `norm_addr_drop_unit()` already exists to
answer for its own, separate consumer.

**Second attempt (4.0%): closer, still flawed.** Re-running with the unit
identifier included in the comparison key found 151 matches. But the
comparison key omitted `StreetNamePostType` (the actual street-type word)
entirely, meaning `"70 MAPLE STREET"` and `"70 MAPLE AVE"` counted as
agreeing — Street and Avenue are ordinarily different physical addresses,
and this key could not tell them apart.

**Third attempt, corrected: 3.1% (117 of 3,803).** The final comparison
requires `AddressNumber`, `StreetName`, and the unit identifier to agree
exactly, and `StreetNamePostType` to agree *only when both sides state one*
(a suffix stated on one side and absent on the other is not treated as a
contradiction; a suffix stated on both sides that disagrees — `ST` vs.
`AVE` — is). Every one of the 117 recovered pairs, inspected individually,
is a genuine improvement:

| Midwife address | Matched organization address | What `norm_addr()` missed |
|---|---|---|
| `1600 EUREKA RD BLDG C` | `1600 EUREKA RD` | building designator, not stripped |
| `NAVAL MEDICAL CENTER SAN DIEGO 34800 BOB WILSON DR` | `34800 BOB WILSON DR` | facility-name prefix before the real street address |
| `4705 MONTGOMERY NE` | `4705 MONTGOMERY BLVD NE` | street-type word entirely absent on one side |
| `21134 US Highway 59` | `21134 I U.S. HWY 59` | inconsistent formatting/abbreviation of "Highway" |
| `One Sun Plaza 100 Sun Ave` | `100 SUN AVE NE` | building/complex name prefix |

## 5. Decision

**Recommended: adopt `usaddress` as a second-pass supplement, not a
replacement for `norm_addr()`.** `norm_addr()` remains correct and
appropriately conservative for its actual job — exact-string, suite-aware
matching is the right default, and loosening it project-wide would
reintroduce the same-building-different-suite false-positive risk
demonstrated in §4. The verified, real contribution of `usaddress` is
narrower and specific: run it only on locations `norm_addr()` (at ZIP9,
ZIP5, and phone) fails to resolve, and accept a structured match only when
`AddressNumber`, `StreetName`, and unit identifier agree exactly with
`StreetNamePostType` treated as silent-if-absent, contradictory-if-stated.
On this project's own unmatched-location pool, that recovers 3.1% —
real, small, and honestly bounded, not the 48.6% an insufficiently-checked
first pass would have reported.

**Not yet implemented.** This evaluation produced a validated method and a
measured effect size; it did not modify `link_practice_locations_to_org_npi.R`
or `resolve_org_ambiguity.R`. Wiring it in means adding `usaddress` as a
Python dependency callable from the R pipeline (or a small standalone
Python pass reading/writing the same intermediate CSVs), and recording the
match method (`"usaddress_structured"`) alongside the existing
`telephone` / `zip9_address` / `zip5_address` key-strength labels so the
provenance of every resolved affiliation stays traceable to the evidence
that produced it — consistent with how every other match-key tier in this
pipeline is already labeled.

## 6. Disposition of the prototype

The parsing tests, the three iterations of the recovery-rate measurement,
and their outputs (`unmatched_locs.csv`, `org_addrs.csv`, the three test
scripts) were run in a scratch Python virtual environment outside this
repository. Nothing from the prototype is committed; this appendix and its
worked table in §4 are the record of the investigation. Reproducing the
3.1% figure requires re-running the method described in §4, not restoring a
saved intermediate file.
