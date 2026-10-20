# Table 1. Characteristics of the ACTIVE certified-midwife cohort

Cohort: **12,171** midwives with AMCB status ACTIVE and a primary-tier NPI link.
Percentages are within category and use the non-missing denominator. Rows labelled not recorded, unresolved, or not applicable are shown so each block remains auditable, but they are not percentage denominators unless explicitly labelled as cohort rows.

Registry-derived rows use the full cohort. Healthgrades-derived rows use a smaller denominator of **12,171**: 0 midwives share a Healthgrades profile with another certificant and cannot be attributed one. They remain in the cohort for every registry-derived row above, and appear on their own row here so the block still sums to the cohort. ACOG district percentages likewise exclude 40 midwives with an overseas-military or US-territory address (no district exists for them); they too are shown on their own row, so every block in this table sums to 12,171.

| Characteristic | n | % |
|---|---:|---:|
| **Cohort** | | |
| ACTIVE, primary-linked midwives | 12,171 | 100.0 |
| **Certification** | | |
| Certified Nurse-Midwife | 12,052 | 99.0 |
| Certified Midwife | 119 | 1.0 |
| **Sex** | | |
| Female | 12,089 | 99.5 |
| Male | 65 | 0.5 |
| Sex not recorded in NPPES or the Trilliant directory | 17 | — |
| **Years Observed in NPPES Panel** | | |
| <5 years | 2,597 | 21.3 |
| 5-9 years | 2,885 | 23.7 |
| 10-14 years | 2,424 | 19.9 |
| >=15 years | 4,265 | 35.0 |
| **Median age of the midwife's patients** | | |
| Median (IQR), years: 32 (30-35) | — | — |
| <20 years | 37 | 0.3 |
| 20-29 years | 1,996 | 18.4 |
| 30-39 years | 7,677 | 70.6 |
| 40-49 years | 709 | 6.5 |
| 50-59 years | 268 | 2.5 |
| 60-69 years | 121 | 1.1 |
| >=70 years | 69 | 0.6 |
| NA | 1,294 | — |
| **ACOG district** | | |
| District I | 954 | 7.9 |
| District II | 988 | 8.1 |
| District III | 805 | 6.6 |
| District IV | 1,811 | 14.9 |
| District V | 1,177 | 9.7 |
| District VI | 1,274 | 10.5 |
| District VII | 675 | 5.6 |
| District VIII | 2,158 | 17.8 |
| District IX | 1,039 | 8.6 |
| District XI | 551 | 4.5 |
| District XII | 697 | 5.7 |
| State not mappable to an ACOG district | 2 | — |
| Overseas-military or US-territory address (no ACOG district) | 40 | — |
| **Rurality (RUCC 2023)** | | |
| Metropolitan (RUCC 1-3) | 10,831 | 90.4 |
| Nonmetropolitan, adjacent (RUCC 4-6) | 800 | 6.7 |
| Nonmetropolitan, remote (RUCC 7-9) | 344 | 2.9 |
| County not resolved (no RUCC code) | 196 | — |
> **Known, unresolved (2026-10-19).** A same-night rebuild of
> `build_trilliant_work_sites.R`'s outputs (`docs/table_worksite_settings.md`
> et al.) shows slightly different counts than the two blocks below — hospital
> 7,681 vs. 7,685, clinic/practice 6,017 vs. 6,023 — and a separate, larger
> three-way disagreement on the hospital+birth-center blended-practice counts
> (241/34 here vs. 156/63 on `origin/main` vs. 203/76 on a since-regenerated
> rerun) was root-caused but not fully closed: two missing source files were
> restored and regenerated, one external reference bundle (hospital CCN
> crosswalk) is still absent on this machine. None of these numbers should be
> taken as final. Full audit:
> [docs/HANDOFF_worksite_merge_conflict_audit.md](HANDOFF_worksite_merge_conflict_audit.md).

| **Any observed hospital work site** | | |
| At least one hospital work site observed | 7,685 | 64.4 |
| No hospital work site among classified sites | 4,248 | 35.6 |
| NA | 238 | — |
| **Primary claims-site setting** | | |
| Hospital | 6,527 | 64.3 |
| Clinic/practice | 2,605 | 25.7 |
| FQHC/community health | 651 | 6.4 |
| Birth center | 169 | 1.7 |
| Other facility | 151 | 1.5 |
| Unclassified | 42 | 0.4 |
| NA | 2,026 | — |
| **Language** | | |
| Not collected by NPPES, CMS DAC or the Healthgrades scrape | 12,171 | — |
| **Accepts new patients** | | |
| Healthgrades data not available | 12,171 | — |
| **Offers telehealth** | | |
| Healthgrades data not available | 12,171 | — |
