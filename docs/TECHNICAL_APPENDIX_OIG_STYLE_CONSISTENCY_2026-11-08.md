# Technical Appendix: OIG-Style Completeness and Consistency, Six Practice-Location Sources

**Repository**: `midwifery`
**Script**: [`analysis/oig_style_source_consistency.R`](../analysis/oig_style_source_consistency.R)
**Outputs**: [`artifacts/oig_style_completeness.csv`](../artifacts/oig_style_completeness.csv), [`artifacts/oig_style_pairwise_consistency.csv`](../artifacts/oig_style_pairwise_consistency.csv), [`artifacts/oig_style_odd_one_out.csv`](../artifacts/oig_style_odd_one_out.csv), [`artifacts/oig_style_field_dictionary.csv`](../artifacts/oig_style_field_dictionary.csv) (aggregate only, each with a `.provenance.json` sidecar)
**Related**: [`TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md`](TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md) (state agreement across 10 sources, consensus tiers, lead-lag), [`TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md`](TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md)
**Model**: HHS OIG, *Improvements Are Needed To Ensure Provider Enumeration and Medicare Enrollment Data Are Accurate, Complete, and Consistent*, OEI-07-09-00440, May 2013
**Investigation date**: 2026-11-08

## 1. What this is, and what it is not

OIG compared NPPES with PECOS on three axes: accuracy (providers verified their own
records), completeness (is each required field populated) and consistency (do the two
databases say the same thing for the same NPI). This appendix repeats the two axes that
need no truth -- completeness and consistency -- for the frozen ACTIVE cohort, across six
sources instead of two. There is no accuracy arm: no source here is verified, and no
number below says which source is right.

What is new relative to the existing state-source audit:

- **ZIP5 as well as state**, for every pair of six sources, not only pairs against NPPES.
- **OIG's comparison rules**: a source listing several locations matches if *any* of
  them matches (`any_shared`); the stricter "every listed value matches" rate
  (`same_set`) is reported alongside.
- **Missingness kept out of disagreement**: a midwife absent from a source, or present
  with a blank or malformed field, is counted in its own column and never as a mismatch.
- **An error floor** for each pair (section 4).
- **Lineage flags** on every pair, and an odd-one-out variant that counts the
  PECOS/DAC lineage once.

**Frame**: 11,920 distinct NPIs in `artifacts/cohort_midwives_tier1_tier2_bon_validated.csv`
(deduplicated on `npi`). Doximity and Healthgrades are joined through
`certification_number` and the FROZEN crosswalk. This is a different, smaller frame than
the 16,775 `cohort_member` NPIs used by the state-source audit, so counts are not
interchangeable with that appendix.

**Sources and lineage**

| Source | File | Unit | Lineage note |
|---|---|---|---|
| NPPES | `amcb_npi_geography.csv` (bulk file 2025-11-09) | one practice location per NPI | self-reported |
| PECOS | `midwife_pecos_organization_affiliations.csv` (from `ppefreassign.csv`) | every reassignment affiliation | location is the receiving organization's, OIG Appendix A's mechanism |
| DAC | `dac_cnm_locations.csv` | every ranked location | built from PECOS enrollment: `shared_lineage_cms_enrollment` with PECOS |
| Open Payments | `cohort_midwives_open_payments_general_2024.csv` | every payment's recipient address | program year 2024, not 2026 |
| Doximity | `doximity_public_matched.csv` | one profile | may seed from NPPES: `possible_nppes_seeding` |
| Healthgrades | `healthgrades_midwives.csv`, `hg_status == "ok"` only | one profile, sometimes several offices | may seed from NPPES: `possible_nppes_seeding` |

**Normalization**: state through `clean_state()`; ZIP5 is the first five digits after
restoring a leading zero lost to numeric storage (PECOS carries four- and eight-digit
ZIPs; without the fix an eight-digit ZIP+4 yields the wrong ZIP5). Doximity's ZIP is the
trailing five digits of `city_zip`, as in `shape_address()`.

## 2. Completeness

A record is present when the source has any row for the NPI. Among present records, a
field is blank, populated but malformed, or usable. ">1 value" counts midwives with more
than one distinct usable value in that source.

| Source | Vintage | Field | Records present (% of 11,920) | Blank | Malformed | Usable | >1 value |
|---|---|---|---:|---:|---:|---:|---:|
| nppes | NPPES bulk file 2025-11-09 | practice_state | 11,920 (100.0%) | 8 | 22 | 11,890 | 0 |
| nppes | NPPES bulk file 2025-11-09 | practice_zip5 | 11,920 (100.0%) | 8 | 0 | 11,912 | 0 |
| pecos | PECOS organization affiliations (current artifact) | practice_state | 5,559 (46.6%) | 0 | 0 | 5,559 | 341 |
| pecos | PECOS organization affiliations (current artifact) | practice_zip5 | 5,559 (46.6%) | 0 | 0 | 5,559 | 1,633 |
| dac | DAC 2026 pull | practice_state | 4,870 (40.9%) | 0 | 0 | 4,870 | 174 |
| dac | DAC 2026 pull | practice_zip5 | 4,870 (40.9%) | 0 | 0 | 4,870 | 1,138 |
| open_payments | Open Payments program year 2024 | practice_state | 3,996 (33.5%) | 0 | 0 | 3,996 | 168 |
| open_payments | Open Payments program year 2024 | practice_zip5 | 3,996 (33.5%) | 0 | 0 | 3,996 | 1,001 |
| doximity | Doximity 2026 scrape | practice_state | 4,655 (39.1%) | 2 | 6 | 4,647 | 0 |
| doximity | Doximity 2026 scrape | practice_zip5 | 4,655 (39.1%) | 2 | 0 | 4,653 | 0 |
| healthgrades | Healthgrades 2026 scrape | practice_state | 5,995 (50.3%) | 0 | 0 | 5,995 | 624 |
| healthgrades | Healthgrades 2026 scrape | practice_zip5 | 5,995 (50.3%) | 0 | 0 | 5,995 | 3,063 |

NPPES is complete by construction: the frame was built from NPPES-linked records. The
other sources' presence rates measure coverage of this cohort, not data quality, and
OIG's completeness arm (fields missing from records that exist) is the "Blank" and
"Malformed" columns: under 0.3% for every source and field.

## 3. Pairwise consistency

"In both" is midwives with a record in both sources; "Usable in both" is the
denominator, midwives with a usable value in both; "Missing one side" is the
difference. Any match is OIG's rule. Error floor is defined in section 4. Pairs with
`possible_nppes_seeding` or `shared_lineage_cms_enrollment` are not independent
corroboration.

### Practice state

| Pair | Lineage | In both | Usable in both | Missing one side | Any match % (95% CI) | Same set % | Disagree % | Error floor % |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| nppes / pecos | separately_collected | 5,559 | 5,552 | 7 | 84.7 (83.7-85.6) | 79.5 | 15.3 | 7.7 |
| nppes / dac | separately_collected | 4,870 | 4,869 | 1 | 90.4 (89.5-91.2) | 87.7 | 9.6 | 4.8 |
| nppes / open_payments | separately_collected | 3,996 | 3,994 | 2 | 96.0 (95.4-96.6) | 91.9 | 4.0 | 2.0 |
| nppes / doximity | possible_nppes_seeding | 4,655 | 4,645 | 10 | 95.6 (95.0-96.2) | 95.6 | 4.4 | 2.2 |
| nppes / healthgrades | possible_nppes_seeding | 5,995 | 5,987 | 8 | 95.8 (95.2-96.3) | 85.6 | 4.2 | 2.1 |
| pecos / dac | shared_lineage_cms_enrollment | 2,368 | 2,368 | 0 | 82.3 (80.7-83.8) | 75.9 | 17.7 | 8.8 |
| pecos / open_payments | separately_collected | 2,012 | 2,012 | 0 | 89.0 (87.5-90.3) | 80.2 | 11.0 | 5.5 |
| pecos / doximity | separately_collected | 2,253 | 2,250 | 3 | 81.8 (80.2-83.4) | 76.4 | 18.2 | 9.1 |
| pecos / healthgrades | separately_collected | 3,566 | 3,566 | 0 | 88.8 (87.8-89.8) | 75.4 | 11.2 | 5.6 |
| dac / open_payments | separately_collected | 2,031 | 2,031 | 0 | 91.3 (90.0-92.5) | 84.9 | 8.7 | 4.3 |
| dac / doximity | separately_collected | 2,004 | 2,003 | 1 | 91.3 (90.0-92.4) | 88.6 | 8.7 | 4.3 |
| dac / healthgrades | separately_collected | 2,467 | 2,467 | 0 | 96.8 (96.0-97.4) | 85.0 | 3.2 | 1.6 |
| open_payments / doximity | separately_collected | 1,553 | 1,552 | 1 | 92.9 (91.5-94.1) | 89.0 | 7.1 | 3.5 |
| open_payments / healthgrades | separately_collected | 2,061 | 2,061 | 0 | 96.2 (95.3-97.0) | 85.0 | 3.8 | 1.9 |
| doximity / healthgrades | separately_collected | 2,543 | 2,539 | 4 | 95.7 (94.8-96.4) | 84.3 | 4.3 | 2.1 |

### Practice ZIP5

| Pair | Lineage | In both | Usable in both | Missing one side | Any match % (95% CI) | Same set % | Disagree % | Error floor % |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| nppes / pecos | separately_collected | 5,559 | 5,555 | 4 | 16.9 (16.0-18.0) | 10.3 | 83.1 | 41.5 |
| nppes / dac | separately_collected | 4,870 | 4,870 | 0 | 53.8 (52.4-55.2) | 41.0 | 46.2 | 23.1 |
| nppes / open_payments | separately_collected | 3,996 | 3,995 | 1 | 81.8 (80.6-82.9) | 58.7 | 18.2 | 9.1 |
| nppes / doximity | possible_nppes_seeding | 4,655 | 4,652 | 3 | 85.6 (84.6-86.6) | 85.6 | 14.4 | 7.2 |
| nppes / healthgrades | possible_nppes_seeding | 5,995 | 5,995 | 0 | 81.4 (80.4-82.3) | 37.0 | 18.6 | 9.3 |
| pecos / dac | shared_lineage_cms_enrollment | 2,368 | 2,368 | 0 | 17.8 (16.3-19.4) | 7.4 | 82.2 | 41.1 |
| pecos / open_payments | separately_collected | 2,012 | 2,012 | 0 | 22.1 (20.3-23.9) | 9.6 | 77.9 | 39.0 |
| pecos / doximity | separately_collected | 2,253 | 2,253 | 0 | 15.4 (14.0-17.0) | 9.7 | 84.6 | 42.3 |
| pecos / healthgrades | separately_collected | 3,566 | 3,566 | 0 | 25.1 (23.7-26.6) | 6.2 | 74.9 | 37.5 |
| dac / open_payments | separately_collected | 2,031 | 2,031 | 0 | 58.8 (56.6-60.9) | 30.3 | 41.2 | 20.6 |
| dac / doximity | separately_collected | 2,004 | 2,003 | 1 | 57.0 (54.8-59.2) | 42.2 | 43.0 | 21.5 |
| dac / healthgrades | separately_collected | 2,467 | 2,467 | 0 | 78.6 (77.0-80.2) | 24.6 | 21.4 | 10.7 |
| open_payments / doximity | separately_collected | 1,553 | 1,553 | 0 | 71.7 (69.4-73.9) | 52.2 | 28.3 | 14.2 |
| open_payments / healthgrades | separately_collected | 2,061 | 2,061 | 0 | 80.7 (79.0-82.4) | 27.9 | 19.3 | 9.7 |
| doximity / healthgrades | separately_collected | 2,543 | 2,542 | 1 | 80.5 (78.9-82.0) | 34.8 | 19.5 | 9.8 |

### Both fields (state and ZIP5 must both match)

| Pair | Lineage | In both | Usable in both | Missing one side | Any match % (95% CI) | Same set % | Disagree % | Error floor % |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| nppes / pecos | separately_collected | 5,559 | 5,552 | 7 | 16.9 (16.0-18.0) | 10.3 | 83.1 | 41.5 |
| nppes / dac | separately_collected | 4,870 | 4,869 | 1 | 53.9 (52.4-55.2) | 41.0 | 46.1 | 23.0 |
| nppes / open_payments | separately_collected | 3,996 | 3,994 | 2 | 81.8 (80.5-82.9) | 58.7 | 18.2 | 9.1 |
| nppes / doximity | possible_nppes_seeding | 4,655 | 4,645 | 10 | 85.6 (84.6-86.6) | 85.6 | 14.4 | 7.2 |
| nppes / healthgrades | possible_nppes_seeding | 5,995 | 5,987 | 8 | 81.5 (80.5-82.4) | 37.1 | 18.5 | 9.2 |
| pecos / dac | shared_lineage_cms_enrollment | 2,368 | 2,368 | 0 | 17.8 (16.3-19.4) | 7.4 | 82.2 | 41.1 |
| pecos / open_payments | separately_collected | 2,012 | 2,012 | 0 | 22.1 (20.3-23.9) | 9.6 | 77.9 | 39.0 |
| pecos / doximity | separately_collected | 2,253 | 2,250 | 3 | 15.4 (14.0-17.0) | 9.7 | 84.6 | 42.3 |
| pecos / healthgrades | separately_collected | 3,566 | 3,566 | 0 | 25.1 (23.7-26.6) | 6.2 | 74.9 | 37.5 |
| dac / open_payments | separately_collected | 2,031 | 2,031 | 0 | 58.8 (56.6-60.9) | 30.3 | 41.2 | 20.6 |
| dac / doximity | separately_collected | 2,004 | 2,003 | 1 | 57.0 (54.8-59.2) | 42.2 | 43.0 | 21.5 |
| dac / healthgrades | separately_collected | 2,467 | 2,467 | 0 | 78.6 (77.0-80.2) | 24.5 | 21.4 | 10.7 |
| open_payments / doximity | separately_collected | 1,553 | 1,552 | 1 | 71.6 (69.4-73.8) | 52.3 | 28.4 | 14.2 |
| open_payments / healthgrades | separately_collected | 2,061 | 2,061 | 0 | 80.7 (79.0-82.4) | 27.9 | 19.3 | 9.7 |
| doximity / healthgrades | separately_collected | 2,543 | 2,539 | 4 | 80.6 (79.0-82.1) | 34.9 | 19.4 | 9.7 |

**Reading it.** State agreement among separately collected pairs runs from 81.8%
(PECOS/Doximity) to 96.8% (DAC/Healthgrades). ZIP5 is a different picture: the highest
separately collected pair is NPPES/Open Payments at 81.8%, and every pair involving PECOS
sits between 15.4% and 25.1%. PECOS/DAC, the one pair that shares lineage, agrees on
ZIP5 for only 17.8%: PECOS reassignment records carry the receiving organization's
address and DAC carries practice locations, so the two files describe different
addresses even though they come from the same enrollment system. This is the
group-reassignment effect OIG blamed for its own 88.6% practice-ZIP mismatch.

Because ZIP disagreement dominates, requiring both fields to match changes little
from the ZIP5 table.

The PECOS state agreement against NPPES here (84.7%) is lower than the 87.8-88.7%
revalidation-state agreement in the state-source audit. The two use different PECOS
files: reassignment affiliations here, revalidation enrollment state there.

## 4. The error floor

If two sources disagree for a midwife, at least one of them is wrong for her. So with a
disagreement rate \(d\) among the compared midwives, the worse of the two sources is
wrong for at least \(d/2\) of them. `error_floor_pct` is that bound;
`error_floor_ci_low` takes it from the lower end of the disagreement rate's Wilson
interval. It needs no truth, but it is only a floor: it says nothing about which source
is the worse one, and two sources that agree can both be wrong. Under the any-match rule
the floor is conservative, since a partial set overlap counts as agreement.

For NPPES/PECOS the ZIP5 floor is 41.5%: whichever of the two is worse lists a wrong
practice ZIP for at least 41.5% of the 5,555 midwives both sources give a ZIP for, given
that both purport to describe the same practice. For PECOS that premise is the weak
point (section 3), so this floor is best read as "these two fields do not measure the
same thing" rather than as a data-entry error rate.

## 5. Odd one out

For midwives with three or more sources reporting, does every source agree, or is
exactly one source the lone dissenter? `attribute_odd_one_out()` needs one value per
source, so multi-location sources contribute their most frequent value (ties: DAC's
lowest `location_rank`, otherwise first listed). That is stricter than the any-match
rule in section 3. The second variant drops DAC so the CMS enrollment lineage votes
once.

| Variant | Field | Row | Label | n | Eligible | % |
|---|---|---|---|---:|---:|---:|
| all_six_sources | practice_state | structure | no_single_outlier | 345 | 7,935 | 4.3 |
| all_six_sources | practice_state | structure | odd_one_out | 1,175 | 7,935 | 14.8 |
| all_six_sources | practice_state | structure | unanimous | 6,415 | 7,935 | 80.8 |
| all_six_sources | practice_state | source_odd_one_out | pecos | 592 | 4,997 | 11.8 |
| all_six_sources | practice_state | source_odd_one_out | dac | 190 | 4,215 | 4.5 |
| all_six_sources | practice_state | source_odd_one_out | healthgrades | 133 | 5,298 | 2.5 |
| all_six_sources | practice_state | source_odd_one_out | open_payments | 73 | 3,603 | 2.0 |
| all_six_sources | practice_state | source_odd_one_out | nppes | 125 | 7,933 | 1.6 |
| all_six_sources | practice_state | source_odd_one_out | doximity | 62 | 4,070 | 1.5 |
| all_six_sources | practice_zip5 | structure | no_single_outlier | 2,814 | 7,940 | 35.4 |
| all_six_sources | practice_zip5 | structure | odd_one_out | 3,347 | 7,940 | 42.2 |
| all_six_sources | practice_zip5 | structure | unanimous | 1,779 | 7,940 | 22.4 |
| all_six_sources | practice_zip5 | source_odd_one_out | pecos | 1,957 | 4,999 | 39.1 |
| all_six_sources | practice_zip5 | source_odd_one_out | dac | 577 | 4,216 | 13.7 |
| all_six_sources | practice_zip5 | source_odd_one_out | healthgrades | 363 | 5,302 | 6.8 |
| all_six_sources | practice_zip5 | source_odd_one_out | open_payments | 172 | 3,603 | 4.8 |
| all_six_sources | practice_zip5 | source_odd_one_out | doximity | 110 | 4,075 | 2.7 |
| all_six_sources | practice_zip5 | source_odd_one_out | nppes | 168 | 7,939 | 2.1 |
| cms_enrollment_lineage_once | practice_state | structure | no_single_outlier | 195 | 6,644 | 2.9 |
| cms_enrollment_lineage_once | practice_state | structure | odd_one_out | 1,023 | 6,644 | 15.4 |
| cms_enrollment_lineage_once | practice_state | structure | unanimous | 5,426 | 6,644 | 81.7 |
| cms_enrollment_lineage_once | practice_state | source_odd_one_out | pecos | 592 | 4,752 | 12.5 |
| cms_enrollment_lineage_once | practice_state | source_odd_one_out | healthgrades | 188 | 5,007 | 3.8 |
| cms_enrollment_lineage_once | practice_state | source_odd_one_out | doximity | 77 | 3,647 | 2.1 |
| cms_enrollment_lineage_once | practice_state | source_odd_one_out | open_payments | 62 | 3,271 | 1.9 |
| cms_enrollment_lineage_once | practice_state | source_odd_one_out | nppes | 104 | 6,642 | 1.6 |
| cms_enrollment_lineage_once | practice_zip5 | structure | no_single_outlier | 1,892 | 6,648 | 28.5 |
| cms_enrollment_lineage_once | practice_zip5 | structure | odd_one_out | 3,218 | 6,648 | 48.4 |
| cms_enrollment_lineage_once | practice_zip5 | structure | unanimous | 1,538 | 6,648 | 23.1 |
| cms_enrollment_lineage_once | practice_zip5 | source_odd_one_out | pecos | 2,289 | 4,754 | 48.1 |
| cms_enrollment_lineage_once | practice_zip5 | source_odd_one_out | healthgrades | 492 | 5,010 | 9.8 |
| cms_enrollment_lineage_once | practice_zip5 | source_odd_one_out | open_payments | 185 | 3,271 | 5.7 |
| cms_enrollment_lineage_once | practice_zip5 | source_odd_one_out | doximity | 133 | 3,652 | 3.6 |
| cms_enrollment_lineage_once | practice_zip5 | source_odd_one_out | nppes | 119 | 6,647 | 1.8 |

Across all six sources, 80.8% of midwives get the same state from every reporting
source and 22.4% the same ZIP5. When exactly one source dissents, it is PECOS far more
often than any other: 11.8% of its eligible midwives for state and 39.1% for ZIP5.
NPPES is the lone dissenter least often (1.6% and 2.1%), but this is weak evidence for
NPPES: Doximity and Healthgrades may copy NPPES, so NPPES sitting in the majority can be
an echo rather than corroboration.

## 6. OIG-style results paragraph

Generated by `mysteryroster::attribute_oig_audit_prose()` for NPPES vs PECOS practice
ZIP, printed by the script:

> In 2026, NPPES and PECOS contained 11,920 and 11,920 physician records, respectively,
> within the declared study frame. Among records present in each source, practice ZIP
> codes were populated in 99.9% and 100.0%, respectively. Among 5,555 comparable
> physicians, at least one value matched in 16.9%, whereas the complete reported value
> sets agreed in 10.3%. Cross-source disagreement was not classified as verified
> inaccuracy.

Two wording problems to fix before quoting it: the function says "physician", and its
first sentence reports the frame size for both sources (11,920), not the records
present (PECOS has 5,559). Use the tables above for the counts.

## 7. Limitations

- **No truth.** Agreement and consensus are relative. A unanimous answer can be wrong
  when the sources share an upstream feed.
- **Mixed vintages.** Open Payments is program year 2024 and NPPES is the 2025-11-09 bulk file; the rest are 2026 pulls. A
  midwife who moved in 2025 disagrees between Open Payments and the others without either
  being wrong for its own date. OIG's equivalent check (January vs August 2010) is
  replaced by the lead-lag work in the state-source audit, not redone here.
- **PECOS is the organization's address.** Its ZIP disagreement is largely structural.
  A follow-up could compare PECOS practice locations from `ppefaddr.csv` once it is
  linked by individual enrollment ID.
- **Coverage selects.** Open Payments covers midwives who received industry payments;
  PECOS and DAC cover Medicare enrollees; Doximity and Healthgrades cover midwives with
  a matched profile. Each pair's agreement rate describes its own overlap, not the
  cohort.
- **Single-snapshot scrapes.** Doximity and Healthgrades cannot be re-pulled for the
  same date.

## 8. Reproducing

```bash
# from the repository root; DATA_ROOT is a checkout that has the gitignored inputs
Rscript analysis/oig_style_source_consistency.R "$DATA_ROOT" artifacts
```
