# External source availability on one machine, 2026-11-08

A point-in-time check, not a design document: every external path the code
resolves, tested against the Samsung volume and the vault as they stand on the
machine this was run from. README.md says what each source *is* and
docs/DATA_VAULT.md says where it *belongs*; neither says which ones are
actually in reach right now, and six are not.

Run from a clean worktree at `6c5fa1b` (main). Paths are relative to
`/Volumes/MufflySamsung`, which is what `samsung_volume_path()` globs.

## Present

| Path | Size |
|---|---|
| `DuckDB/nber_my_duckdb.duckdb` | 85 G |
| `nppes_historical_downloads/` | 255 G |
| `nppes_historical_downloads/extracted_2026/` | 12 G |
| `nppes_historical_downloads/extracted_2025/` | 10 G |
| `hpt_prices/trilliant/20260721/lake/data/main` | 74 G |
| `open_payments_data/open_payments_merged_2013_2024.duckdb` | 20 G |
| `cms_revalidation_raw/` | 19 G |
| `cms_revalidation.duckdb` | 4.4 G |
| `ppef_raw/` | 612 M |
| `state_license_bundle_2026-05-31/` | 534 M |
| `pecos_data/ppefenrol.csv` | 274 M |
| `nhdplus_hr/water_masks/` | 23 M |
| `federal_adverse_actions/` | 11 M |

## Absent

| Path | Consumer | Consequence |
|---|---|---|
| `DuckDB/medicaid_provider_enrollment_segments.duckdb` | `build_medicaid_*`, T-MSIS by-year source | the Medicaid column of Table 1 by year cannot be rebuilt |
| `DuckDB/medicaid_provider_spending_verified.duckdb` | `extract_tmsis_medicaid_spending_history.R` | the T-MSIS billing-activity source cannot be rebuilt |
| `HCRIS/hosp10/fy2023/` | `extract_hcris_affiliated_hospitals.R` | `artifacts/hcris_affiliated_hospitals_fy2023.csv` is unreproducible |
| `HRSA_HPSA_data/HPSA_CMPPC_SHP_DET_CUR_VX.shp` | `assign_hpsa_status.R` | `artifacts/hpsa_status.csv` is unreproducible |
| `facility_affiliation/doctors_and_clinicians_2026_06/Facility_Affiliation_2026-06.csv` | `extract_dac_facility_affiliations.R` | DAC facility affiliations cannot be re-extracted |
| `isochrone_archives/isochrones_archive/` | the archived-isochrone recovery arm | the 11,592-origin archive sweep cannot be re-run |

The two HRSA/HCRIS gaps are already half-known: README.md records that the
HPSA file is named `..._CUR_...` and that its download date is nowhere in the
repository. The file being gone as well closes the other half — there is now
no way to say which vintage `hpsa_status.csv` describes.

`facility_affiliation` has a near-miss worth knowing about rather than acting
on. `data/CMS_Facility_Affiliation.csv` is tracked in the repository with the
right schema (`NPI`, `Ind_PAC_ID`, `facility_type`, `Facility Affiliations
Certification Number`), and `FACILITY_AFFILIATION_FILE` would accept it. It is
a different vintage from the 2026-06 release the script names, and that script
refuses to emit counts from a mismatched release on purpose. Pointing the
variable at it to make the run proceed is the failure this repository has
already had more than once: the run succeeds and the number is from the wrong
month. Download the 2026-06 release, or set `DAC_VINTAGE` deliberately.

## The vault is not on this machine

`docs/DATA_VAULT.md` puts person-level inputs in `Dropbox/midwifery-data/`,
found by content hash. There is no Dropbox on this machine — not an empty
vault, no Dropbox at all — and `MIDWIFERY_VAULT` is unset. `vault_root()`
stops rather than guessing, which is correct.

The consequence is the one the vault was built for. Person-level inputs here
are whatever a previous run left in the working tree, and what it left is the
superseded freeze: 22,309 rows / 16,898 cohort members (`dbcc76f4`), against
main's registered 22,357 / 16,775 (`9f224007`, run
`reconcile_ab_20261022T134500_remove_fuzzy_surname_matching`). That is the
same shape as the 2026-09-13 incident in DATA_VAULT.md, which reported 11,920
midwives against a registered 12,171.

**Anything built from `artifacts/` on this machine describes the old freeze,
including the retired class-4 fuzzy-surname evidence class.** Restore the
vault before building, or re-pin from the manifest.

## One thing fixed rather than reported

`hpt_prices/trilliant/20260721/lake` did not exist when this audit started.
The 74 GB DuckLake had been unzipped one level up, at `hpt_prices/lake`, and
`hpt_prices/trilliant/20260721/` was an empty directory — so all five
Trilliant scripts here stopped at `no directory_provider parquet under …`.

Eight scripts across this repository and `~/isochrones` expect the nested
path; four isochrones scripts expect `hpt_prices/lake`. Moving the data would
have fixed one group and broken the other, so the nested path is now a
relative symlink to the real one. Both conventions resolve, nothing moved, and
the lake's own README states it opens wherever it is unzipped (relative paths,
`OVERRIDE_DATA_PATH true`), so the catalog is unaffected.

    hpt_prices/trilliant/20260721/lake -> ../../lake

This is drive state, not repository state: a fresh machine needs the same
symlink, or `TRILLIANT_LAKE` set.
