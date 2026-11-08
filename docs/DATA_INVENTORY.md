# Data inventory — midwifery project

Compiled 2026-11-08 by walking the filesystem, not from documentation. Every
path below was confirmed to exist unless marked **MISSING**.

Two physical locations only:

| Root | What lives there |
|---|---|
| `/Users/tylermuffly/midwifery` | code, derived artifacts, the panel, the frozen cohort |
| `/Volumes/MufflySamsung` (1.8 TB, 618 GB free) | all raw federal source data |

`/Users/tylermuffly/isochrones` is the sibling repo that owns geocoding and
isochrone infrastructure (canonical; **not** `~/isochrones-A`).

---

## 1. The linkage spine

Everything person-level in this project keys on **two** identifiers, and you
need both:

- `certification_number` — the AMCB certification registry key. This is the
  cohort spine. The frozen analytic cohort is keyed on it.
- `npi` — assigned by the AMCB→NPPES resolution, stored in
  `artifacts/amcb_npi_linkage_FROZEN.csv`.

```
midwives.csv (AMCB roster, 22,309 certification records)
        │
        └── match_amcb_to_npi.R  ──►  artifacts/amcb_npi_linkage_FROZEN.csv
                                        22,309 rows, 16,898 carry an NPI
                                        (cohort_member == TRUE ⟺ npi non-empty)
```

NPI resolution status (`npi_match_status`), all 22,309 rows:

| status | n |
|---|---|
| matched | 14,764 |
| ambiguous_tied_names | 3,044 |
| matched_nursing_taxonomy | 2,134 |
| unmatched | 2,108 |
| candidate_class5_held_out_of_cohort | 156 |
| ambiguous_contested_npi | 95 |
| ambiguous_unruled_out_component | 8 |

**Join on `certification_number` for anything AMCB-derived; join on `npi` only
after going through the FROZEN crosswalk.** Several sources (Doximity, state
license ages, WA BON) have *no* NPI at all and must come in via
`certification_number` or `license_number`.

---

## 2. Midwife sources linked by NPI

Counts are rows / distinct NPIs. All paths relative to
`/Users/tylermuffly/midwifery`.

| Source | NPI-linked file | rows | distinct NPI | join key |
|---|---|---|---|---|
| **NPPES** (annual, 2007–2025) | `midwife_panel.csv` | 4,291,397 | — | `npi` × `snapshot_year` |
| NPPES (single snapshot subset) | `nppes_midwives.parquet` | — | — | `npi` |
| **AMCB** certification registry | `artifacts/amcb_npi_linkage_FROZEN.csv` | 22,309 | 16,898 | `certification_number` → `npi` |
| AMCB geography | `artifacts/amcb_npi_geography.csv` | 17,054 | 17,054 | `npi` |
| AMCB education / training | `artifacts/amcb_education_history.csv` | 876 | — | `npi` |
| AMCB → ACME thesis institution | `artifacts/amcb_training_institution_linked.csv` | 555 | — | `npi` |
| **State nursing boards** (50 states + DC scrape) | `artifacts/scraped_50_states_and_dc_midwives_master.csv` | 11,355 | 11,093 | `npi` |
| State boards, tier1+tier2 live APIs | `artifacts/tier1_tier2_combined_bon_validated_master.csv` | 8,092 | 7,898 | `npi` |
| **CMS Care Compare (DAC)** | `dac_midwives.csv` | 5,680 | — | `npi` |
| DAC practice locations | `artifacts/dac_cnm_locations.csv` | 9,084 | — | `NPI` |
| DAC facility affiliations | `artifacts/dac_facility_affiliations.csv` | 1,952 | 1,665 | `npi` + `cms_ccn` |
| DAC education | `artifacts/dac_cnm_education.csv` | 5,793 | — | `NPI` |
| **PECOS** org affiliations | `artifacts/midwife_pecos_organization_affiliations.csv` | 10,767 | 7,288 | `midwife_npi`, `organization_npi` |
| PECOS PAC_ID ↔ NPI crosswalk | `artifacts/pac_npi_ever.csv` | 387,768 | — | `npi` ↔ `pac_id` |
| CMS revalidation reassignment spells | `artifacts/midwife_reassignment_panel.csv` | 605,600 | 11,711 | `midwife_npi` |
| **Open Payments** general (2024) | `artifacts/cohort_midwives_open_payments_general_2024.csv` | 18,736 | 3,996 | `npi` |
| Open Payments Type-2 (orgs) | `artifacts/cohort_midwives_open_payments_type2_organizations.csv` | 41 | — | `midwife_npi` |
| Open Payments match ledger | `artifacts/open_payments_midwives_matched_vs_unmatched.csv` | 12,211 | 11,920 | `npi` (+ `open_payments_match_status`) |
| **Medicare Part B / Part D** | `artifacts/medicare_participation.csv` | 11,920 | 11,920 | `npi` |
| Medicare CPT delivery claims | `artifacts/cohort_midwives_cpt_delivery_attenders.csv` | 7,470 | 4,806 | `npi` |
| **CABC** accredited birth centers | `artifacts/cabc_matched_midwives_final.csv` | 221 | — | `npi` |
| **AABC** birth centers | `artifacts/aabc_matched_birth_center_midwives.csv` | 9 | — | `npi` |
| Hospital affiliations (multi-tier) | `artifacts/cohort_midwife_hospital_affiliations_multitier.csv` | — | — | `npi` + `cms_ccn` |
| Geography / county / RUCC / HPSA | `artifacts/midwives_geography_FROZEN.csv` | 16,898 | 16,898 | `npi` |

### Not linked by NPI (key on something else)

| Source | File | rows | key |
|---|---|---|---|
| Doximity public profiles | `artifacts/doximity_public_matched.csv` | 4,655 | `certification_number` |
| State nursing license ages (birth years) | `artifacts/state_nursing_license_ages.csv` | 1,833 | `certification_number` |
| WA nursing board licenses | `artifacts/wa_cnm_licenses.csv` | 1,483 | `license_number` |
| ACME/DNP theses (OAI-PMH harvest) | `artifacts/midwifery_theses_oai.csv` | 306 | institution + author name |
| Healthgrades profiles | `healthgrades_midwives.csv` | — | `certification_number` |
| Voter files (FL, OH) for age imputation | `artifacts/{florida,ohio}_voter_license_ages_provenance.csv` | — | license number |

### ACNM — **no data**

There is no ACNM membership file anywhere on this machine or the external
drive. Nothing in the codebase reads one. ACNM is not currently a source.

---

## 3. The one table to write the analysis against

`artifacts/cohort_midwives_tier1_tier2_bon_validated.csv` — 12,211 rows,
11,920 distinct NPI, all `status == "ACTIVE"`. It is the AMCB spine with every
downstream source already joined on as flags:

- `attribution_tier`, `attributed_hospital_name`, `cms_ccn` (hospital)
- `matched_cabc_birth_center`, `has_cabc_fbc` (birth centers)
- `cpt_delivery_claim_flag`, `has_cpt_delivery_claim` (Medicare claims)
- `has_op_profile`, `n_op_payments`, `op_total_amount`, `has_op_general`,
  `open_payments_status` (Open Payments)
- `bon_ingestion_tier`, `bon_verification_status`, `bon_recency_year` (boards)
- `final_facility_setting`, `refined_clinical_setting`, `active_attending_status`

Row count exceeds distinct NPI by 291 — dual/repeated certification records.
**Dedupe on `npi` before counting people.**

Cohort provenance: `artifacts/frozen_cohort/analytic_cohort.csv` (16,892 rows,
keyed `certification_number`) and `artifacts/frozen_cohort/INPUT_FINGERPRINT.json`.

---

## 4. Raw federal data — full paths

### NPPES — `/Volumes/MufflySamsung/nppes_historical_downloads/` (255 GB)

- 95 entries: monthly/annual dissemination zips and their extracted folders
  from Nov 2007 through Nov 2025.
- Per-year extracts used by the pipeline: `extracted_2015/` … `extracted_2026/`
- Current full file (`NPPES_2026`):
  `/Volumes/MufflySamsung/nppes_historical_downloads/extracted_2026/npidata_pfile_20050523-20260809.csv`
- Practice locations (`PL_FILE`):
  `…/extracted_2026/pl_pfile_20050523-20260809.csv`
- Endpoints (`ENDPOINT_FILE`):
  `…/extracted_2026/endpoint_pfile_20050523-20260809.csv`
- Prior vintage (`NPPES_2025`):
  `…/extracted_2025/npidata_pfile_20050523-20251109.csv`
- Code values / readme PDFs at the root of that directory.
- Local copy used by `extract_nppes_midwives.R` (hardcoded, **not** the drive):
  `/Users/tylermuffly/Documents/NPPES_Data_Dissemination_March_2024/npidata_pfile_20050523-20240310.csv`
- Deactivated NPI report:
  `/Users/tylermuffly/Documents/NPPES Deactivated NPI Report 20240408.xlsx`

Env vars: `NPPES_HISTORY`, `NPPES_2025`, `NPPES_2026`, `PL_FILE`, `ENDPOINT_FILE`.

### Open Payments — `/Volumes/MufflySamsung/open_payments_data/` (95 GB)

- Per-year directories `2013/` … `2023/`
- Merged warehouse: `open_payments_merged_2013_2024.duckdb` (21.8 GB)
- `profiles/`, `split_dbs/`, `obgyn_payments.csv`,
  `open_payments_merged_filtered_to_obgyns.csv`

### PECOS — `/Volumes/MufflySamsung/pecos_data/` (510 MB)

`ppefenrol.csv`, `ppefaddr.csv`, `ppefreassign.csv`, `ppefspec.csv`, plus the
original zips. Newer extracts in `/Volumes/MufflySamsung/ppef_raw/`:
`PPEF_Enrollment_Extract_2026.04.01.csv`, `PPEF_Enrollment_Extract_2026.07.17.csv`.
Env var: `PPEF_RAW_DIR`.

### CMS revalidation / reassignment

- Raw monthly snapshots: `/Volumes/MufflySamsung/cms_revalidation_raw/` (19 GB),
  `revalidation_reassignment_2021-12.csv` through 2025-05 (`REVAL_RAW_DIR`)
- Warehouse: `/Volumes/MufflySamsung/cms_revalidation.duckdb` (4.68 GB) (`REVAL_DB`)

### Medicare claims warehouse

- **`/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb` — 91.8 GB, 454 tables.**
  This is the real one. Resolve it with `resolve_midwifery_duckdb()` in
  `R/lib/medicare_duckdb.R`; never hardcode the path.
- ⚠️ `/Volumes/MufflySamsung/nber_my_duckdb.duckdb` is a **12 KB empty decoy**
  created by a DuckDB connect to a path that did not exist after macOS remounted
  the volume as `MufflySamsung 1`. Querying it returns zero rows and reports
  success. Do not touch it.
- `/Volumes/MufflySamsung/DuckDB/README_THIS_DB_IS_A_STALE_FORK_2026-09-04.txt`
  and the two `nber_retirement_consensus_*.duckdb` files are stale forks.
- Also there: `ahrq_3prd.duckdb`, `ahrq_3prd_national.duckdb`.

### State boards of nursing

- `/Volumes/MufflySamsung/state_license_bundle_2026-05-31/` (534 MB) —
  `bundle.tar.gz`, `bundle.sha256`, `data/state_licenses/`,
  `state_board_ingest_staging.duckdb`
- `/Volumes/MufflySamsung/state_board_registries/gold_R2/` (45 MB) —
  `all_state_board_combined.{csv,rds}`, `state_board_lifecycle_registry.{csv,rds}`,
  `state_board_longitudinal_timelines.{csv,rds}`
- `/Volumes/MufflySamsung/state_board_registries/impact_C3a_C4/` —
  `registry_C3a.rds`, `registry_C4.rds`, `registry_C5_R2.rds`,
  `registry_C0_stale.rds`, `SHA256SUMS.txt`
- `/Volumes/MufflySamsung/state_board_staging/illinois/` (92 MB)

### Federal adverse actions — `/Volumes/MufflySamsung/federal_adverse_actions/` (11 MB)

FDA debarments, OPM FEHB sanctions, ORI cases, TRICARE exclusions, DOJ physician
actions (parquet + csv.gz, Sept 2026 vintages). **Harvested, NPI-linkable, not
yet linked to the midwife cohort.** Also `/Volumes/MufflySamsung/mysterynpi/`
(`dea_fr/`, `dea_press/`, `fda_debarment/`).

### Geography and context — `/Users/tylermuffly/midwifery/data/` (773 MB)

| File | Source |
|---|---|
| `CMS_Facility_Affiliation.csv` (132 MB) | CMS Care Compare facility affiliations |
| `cms_pos_hospital.csv` (30 MB) | CMS Provider of Services |
| `chr_2025_analytic.csv` (13 MB) | County Health Rankings 2025 |
| `svi_2022_county.csv` | CDC Social Vulnerability Index |
| `rucc_2023.xlsx`, `nchs_urcodes_2013.xlsx` | rurality codes |
| `2024_Gaz_counties_national.txt`, `gaz_counties_2024.zip` | Census gazetteer |
| `zcta_county_2020.txt`, `zcta_tract_2020.txt` (24 MB) | Census crosswalks |
| `ct_tract_crosswalk_2022.csv`, `ct_legacy_to_region_weights.csv` | CT 2022 county reorg |
| `acs5_2023_county*.json` | ACS 5-year |
| `county_base.csv` + `.provenance.json` | built by `R/01-build-county-base.R` |
| `ahrf/`, `cd118/`, `cd119/`, `congress/`, `wonder/`, `revalidation/`, `cache/` | AHRF, congressional districts, CDC WONDER natality |

### Isochrones / geocoding — `/Users/tylermuffly/isochrones/`

- `data/geocoding_cache.duckdb` (15 MB) — `GEOCODING_CACHE_PATH`
- `data/address_cache.duckdb` (160 MB), `data/run_manifest.duckdb`,
  `data/event_log.duckdb`
- Env vars: `ISOCHRONES_R` → `~/isochrones/R`, `ISOCHRONES_HOME`, `ISOCHRONES_DIR`
- Polygon libraries on the drive:
  - `/Volumes/MufflySamsung/isochrone_polygons_canonical_20260508_ec2_r6i`
  - `/Volumes/MufflySamsung/isochrone_polygons_canonical_20260917_gapfill148`
  - `/Volumes/MufflySamsung/isochrone_polygons_canonical_20260927_bug021_3915`
  - plus `isochrones/`, `isochrones_runs/`, `isochrones_macrun/`,
    `isochrones_project/`, `isochrone_working_files/`, `valhalla/`, `osm/`

### MISSING inputs (artifacts exist, sources do not)

| Referenced path | Artifact it produced |
|---|---|
| `/Volumes/MufflySamsung/HRSA_HPSA_data/HPSA_CMPPC_SHP_DET_CUR_VX.shp` | `artifacts/hpsa_status.csv` |
| `/Volumes/MufflySamsung/HCRIS/hosp10/fy2023/` | `artifacts/hcris_affiliated_hospitals_fy2023.csv` |

Closest surviving HPSA data: `/Users/tylermuffly/Documents/Documents - TMuff/SDMS_AUTO_HPSA_SITE_PC.XLSX`
(different schema — site-level, not shapefile). Both artifacts are
**unreproducible** until the inputs are re-downloaded. Say so in any vignette
that uses `hpsa_status.csv`.

---

## 5. Working trees

Thirteen clones/worktrees of this repo exist. `/Users/tylermuffly/midwifery` is
the primary; the others are feature branches (`git worktree list`). Long jobs
get their own worktree branched off `origin/main` — the shared tree gets reset
mid-run by concurrent sessions.

## 6. Reproducibility

Most derived artifacts have a sibling `*.provenance.json` or `*.manifest.json`
written by `provenance_manifest.R`. Running any gate locally rewrites these
sidecars, so never `git add -A` after a test sweep.
