# Manuscript evidence verification report

Generated 2026-11-25 08:05 by `tools/verify_manuscript_evidence.R`.

| check | item | status | detail |
|---|---|---|---|
| C01 | CohortRoster | WARN | no provenance sidecar |
| C01 | CohortMatched | WARN | no provenance sidecar |
| C01 | CohortNursing | WARN | no provenance sidecar |
| C01 | Licensure3 | WARN | oig_table2_inaccuracy_subtypes_by_variable.csv: 14 stale provenance row(s) |
| C01 | Licensure7 | WARN | oig_table2_inaccuracy_subtypes_by_variable.csv: 14 stale provenance row(s) |
| C01 | NameAgreement | WARN | oig_table2_inaccuracy_subtypes_by_variable.csv: 14 stale provenance row(s) |
| C01 | AnyInconsistent | WARN | oig_table4_any_variable_inconsistent.csv: 14 stale provenance row(s) |
| C01 | StateAgreement | WARN | no provenance sidecar |
| C01 | PairwiseMatrix | WARN | source_pairwise_agreement_matrix.csv: 2 stale provenance row(s) |
| C01 | AgreementCI | WARN | agreement_cluster_bootstrap_ci.csv: 1 stale provenance row(s) |
| C01 | MedicaidClass | WARN | no provenance sidecar |
| C01 | MedicaidMultistate | WARN | no provenance sidecar |
| C01 | SetMembership | WARN | medicaid_set_membership_before_after.csv: 3 stale provenance row(s) |
| C01 | PersistenceDenom | WARN | persistence_denominators.csv: 1 stale provenance row(s) |
| C01 | CensoringAudit | WARN | oig_longitudinal_2021_2026_censoring_audit.csv: 14 stale provenance row(s) |
| C01 | Churn | WARN | mrost_churn_by_source.csv: 2 stale provenance row(s) |
| C01 | TierFlow | WARN | consensus_tier_persistence_2021_2025.csv: 2 stale provenance row(s) |
| C01 | OddOneOut | WARN | mrost_odd_one_out_rate.csv: 2 stale provenance row(s) |
| C01 | SourceCount | WARN | source_count_agreement_by_n_sources.csv: 1 stale provenance row(s) |
| C01 | Resolution | WARN | mrost_lead_lag.csv: 2 stale provenance row(s) |
| C01 | NpiPopulation | WARN | medicaid_npi_population_by_state.csv: 3 stale provenance row(s) |
| C01 | StateVariation | WARN | state_variation_agreement_by_source.csv: 1 stale provenance row(s) |
| C01 | Coverage | WARN | no provenance sidecar |
| C01 | Completeness | WARN | oig_table3_completeness_2019_and_2026.csv: 14 stale provenance row(s) |
| C02 | CohortRoster | PASS | unit = certification_record |
| C02 | CohortMatched | PASS | unit = unique_certification_record_link |
| C02 | CohortNursing | PASS | unit = unique_certification_record_link |
| C02 | Licensure3 | PASS | unit = resolved_record |
| C02 | Licensure7 | PASS | unit = resolved_record |
| C02 | NameAgreement | PASS | unit = resolved_record |
| C02 | AnyInconsistent | PASS | unit = provider |
| C02 | StateAgreement | PASS | unit = provider_year |
| C02 | PairwiseMatrix | PASS | unit = provider_year_or_snapshot_record |
| C02 | AgreementCI | PASS | unit = provider_year |
| C02 | MedicaidClass | PASS | unit = provider_year |
| C02 | MedicaidMultistate | PASS | unit = provider_year |
| C02 | SetMembership | PASS | unit = provider_year |
| C02 | PersistenceDenom | PASS | unit = provider_year |
| C02 | CensoringAudit | PASS | unit = clinician |
| C02 | Churn | PASS | unit = provider_year |
| C02 | TierFlow | PASS | unit = provider_year |
| C02 | OddOneOut | PASS | unit = provider_year |
| C02 | SourceCount | PASS | unit = provider_year |
| C02 | Resolution | PASS | unit = provider_year |
| C02 | NpiPopulation | PASS | unit = segment |
| C02 | StateVariation | PASS | unit = provider_year |
| C02 | Coverage | PASS | unit = source_year |
| C02 | Completeness | PASS | unit = record |
| C03 | geographic-accuracy terminology | WARN | 1 candidate line(s) at 369 |
| C04 | abstract-results shared statistics | PASS | 8 shared catalog refs (A$sources_total_n, A$nppes_license_3, A$nppes_license_7, A$any_inconsistent_2026); abstract-only:  |
| C05 | catalog key resolution | PASS | 93 keys resolve |
| C06 | figure file existence | PASS | 10 figures resolve |
| C07 | Wilson + cluster-bootstrap both present | PASS | Wilson=TRUE cluster-bootstrap=TRUE |
| C08 | provenance staleness across ledger | WARN | one or more artifacts stale |
| C09 | git conflict markers | PASS | 0 marker line(s) in qmd, 0 in manuscript/R |
| C10 | required sections | PASS | all present |
| C11 | provider-year rows carry year window | PASS | 13/13 provider-year rows declare years |
| C12 | abstract percentages | PASS | 0 percentages in abstract; all derive from `r pc(...)` catalog calls (verified by C05) |
