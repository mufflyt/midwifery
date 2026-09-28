# Detailed Trilliant and Derived Work-Site Table

Cohort denominator: 12,171 midwives.

Counts are midwives with an observed value unless the row is explicitly a category. Percentages use the full cohort denominator. Direct directory fields are separated from derived work-site fields. Organization co-location is an address-level signal and is not evidence of employment.

| Domain | Measure | n observed | % of cohort | Summary | Source artifact | Source field(s) |
|:--|:--|--:|--:|:--|:--|:--|
| Direct Trilliant directory | Named primary practice site |  8965 |  73.7 | NA | midwife_work_sites_summary.csv | top_site_name |
| Direct Trilliant directory | Primary-site visit share | 10145 |  83.4 | median 89.9; IQR 68.7-99.6; range 19.1-100.0 | midwife_work_sites_summary.csv | top_site_visit_share |
| Direct Trilliant directory | Trilliant-reported number of practice sites | 10321 |  84.8 | median 2; IQR 1-2; range 1-8 | midwife_work_sites_summary.csv | trilliant_n_practice_sites |
| Direct Trilliant directory | Claims-associated primary organization |  9849 |  80.9 | Directory organization association; not a verified employer relationship | midwife_work_sites_summary.csv | trilliant_primary_org |
| Direct Trilliant directory | Primary site street address | 10145 |  83.4 | NA | midwife_work_sites_summary.csv | top_site_street |
| Direct Trilliant directory | Primary site city | 10145 |  83.4 | NA | midwife_work_sites_summary.csv | top_site_city |
| Direct Trilliant directory | Primary site state | 10145 |  83.4 | NA | midwife_work_sites_summary.csv | top_site_state |
| Direct Trilliant directory | Primary site ZIP | 10145 |  83.4 | NA | midwife_work_sites_summary.csv | top_site_zip |
| Direct Trilliant directory | Primary site latitude | 10138 |  83.3 | NA | midwife_work_sites_summary.csv | top_site_lat |
| Direct Trilliant directory | Primary site longitude | 10138 |  83.3 | NA | midwife_work_sites_summary.csv | top_site_lon |
| Direct Trilliant directory | Primary site county | 10145 |  83.4 | NA | midwife_work_sites_summary.csv | top_site_county_geoid |
| Direct Trilliant directory | Primary-site organization type |  2574 |  21.1 | NA | midwife_work_sites_summary.csv | top_site_org_type |
| Direct Trilliant directory | Primary-site taxonomy |  2574 |  21.1 | NA | midwife_work_sites_summary.csv | top_site_taxonomy |
| Direct Trilliant directory | Claims-directory activity flag: TRUE | 10867 |  89.3 | NA | midwife_work_sites_summary.csv | trilliant_active |
| Direct Trilliant directory | Claims-directory activity flag: FALSE |  1304 |  10.7 | NA | midwife_work_sites_summary.csv | trilliant_active |
| Derived work-site data | Number of distinct physical work sites | 12171 | 100.0 | median 2; IQR 1-2; range 0-20 | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | n_distinct_sites |
| Derived work-site data | Number of counties represented | 11933 |  98.0 | median 1; IQR 1-2; range 0-19 | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | n_distinct_counties |
| Derived work-site data | Maximum geographic distance between lower-48 sites (miles) | 11168 |  91.8 | median 0.2; IQR 0.0-20.2; range 0.0-10338.8 | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | state; lat; lon; certification_number |
| Derived work-site data | Hospital work-site indicator |  7685 |  63.1 | NA | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | any_hospital |
| Derived work-site data | Clinic/practice work-site indicator |  6023 |  49.5 | NA | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | any_clinic |
| Derived work-site data | FQHC/community-health work-site indicator |  1493 |  12.3 | NA | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | any_fqhc |
| Derived work-site data | Birth-center work-site indicator |   564 |   4.6 | NA | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | any_birth_center |
| Derived work-site data | Other-facility work-site indicator |   183 |   1.5 | Derived when the setting combination includes other facility | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | setting_combination |
| Derived work-site data | Hospital names resolved |  6312 |  51.9 | NA | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | hospital_names |
| Derived work-site data | Hospital CCNs resolved |  5049 |  41.5 | NA | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | top_site_ccn; top_site_ccn_basis |
| Derived work-site data | Strict hospital + birth-center practice |   155 |   1.3 | Both strict hospital and strict birth-center evidence present | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | blended_strict |
| Derived work-site data | Broad hospital + birth-center practice |   219 |   1.8 | Both broad hospital and broad birth-center evidence present | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | blended_broad |
| Derived work-site data | Rurality comparison: NPPES Metro (RUCC 1-3) / claims Nonmetro, adjacent (4-6) |   229 |   1.9 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: NPPES Metro (RUCC 1-3) / claims Nonmetro, remote (7-9) |    85 |   0.7 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: NPPES Nonmetro, adjacent (4-6) / claims Metro (RUCC 1-3) |   255 |   2.1 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: NPPES Nonmetro, adjacent (4-6) / claims Nonmetro, remote (7-9) |    28 |   0.2 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: NPPES Nonmetro, remote (7-9) / claims Metro (RUCC 1-3) |    81 |   0.7 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: NPPES Nonmetro, remote (7-9) / claims Nonmetro, adjacent (4-6) |    27 |   0.2 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: not comparable |  2883 |  23.7 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Rurality comparison: same band |  8583 |  70.5 | Comparison of NPPES address rurality with claims-site rurality | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | rurality_nppes_vs_claims |
| Derived work-site data | Midwives with multiple organizations at a work-site address | 10736 |  88.2 | Co-location signal; does not establish employment or affiliation | midwife_work_sites_summary.csv + midwife_work_sites_long.csv | n_orgs_at_address |
