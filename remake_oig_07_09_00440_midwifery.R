#!/usr/bin/env Rscript
# =============================================================================
# Remake of HHS OIG Study OEI-07-09-00440 (May 2013) for the U.S. Midwifery
# Workforce Using DuckDB Administrative Warehouses and `mysteryroster`
# =============================================================================
# Reference Study:
#   HHS Office of Inspector General (OIG), "Improvements Needed To Ensure
#   Provider Enumeration and Medicare Enrollment Data Are Accurate, Complete,
#   and Consistent", OEI-07-09-00440, May 2013.
#
# What this script executes:
#   1. Audit Frame & Denominators (`mysteryroster::attribute_analysis_populations()`):
#      - Canonical active primary-linked AMCB midwife cohort (N = 12,170 NPIs)
#        and linkage-eligible AMCB cohort (N = 17,028) from
#        `artifacts/amcb_npi_linkage_FROZEN.csv`.
#      - Separates Coverage, Completeness (OIG Table 3), Consistency (OIG
#        Table 4: NPPES n PECOS overlap), and Accuracy (OIG Tables 1-2).
#   2. 2019 4-Table Relational PECOS vs. 2019 NPPES (`year = 2019`):
#      - Queries `main.ppef_enrol_2019`, `main.ppef_addr_2019`,
#        `main.ppef_reassign_2019`, `main.ppef_spec_2019`, and
#        `credentials.temporal_nppes_2019_fixed` in `nber_my_duckdb.duckdb`.
#      - Runs `mysteryroster::attribute_enrollment_locations()` to replicate
#        OIG Appendix A & Table 3 Footnote *** (direct individual enrollment
#        locations vs. group-reassignment locations via `enrlmt_id`).
#      - Runs `mysteryroster::attribute_record_presence()` for OIG Table 3
#        (distinguishing `field_not_in_extract`, `field_row_missing` ["Missing
#        Records"], `field_value_missing` ["Null Data Field"], and `populated`).
#      - Runs `mysteryroster::attribute_set_agreement()` and
#        `attribute_set_agreement_summary()` for OIG Table 4 (any_shared vs.
#        same_set across practice ZIP5, practice state, full name, gender,
#        specialty, plus "Any variable inconsistent").
#   3. 2026 Contemporary PECOS / DAC vs. February 2026 Full NPPES (`year = 2026`):
#      - Queries `main.NPPES_Data_Dissemination_February_2026_npidata_pfile_20050523_20260208_csv`
#        (all 10 OIG variables including mailing ZIP5, practice ZIP5, phone10,
#        gender, credential, taxonomy codes 1..15, state licenses 1..15, and
#        Last Update Date), `nppes.practice_locations_enhanced` (NPPES PL file),
#        `main.ppef_enrol_2026Q3`, and `main.doctors_and_clinicians_05_2024_DAC_NationalDownloadableFile_csv_6`
#        / `dac_midwives.csv`.
#      - Evaluates OIG Table 3 & Table 4 in 2026, plus supplemental NPPES PL
#        location recovery (`nppes_pl`) and NPPES record staleness / longitudinal
#        update-lag (`classify_record_staleness()`, `attribute_lead_lag_duration()`,
#        `attribute_catch_up_curve()`), generalizing OIG's 8-month lag test.
#   4. Remake of OIG Tables 1 & 2 (Accuracy via Primary-Source Verification):
#      - Uses `attribute_verification_codebook()`,
#        `attribute_verification_questionnaire()`, `attribute_nonresponse_audit()`,
#        `attribute_verification_status()`, `listing_validity_design()`,
#        `validity_estimates()`, and `validity_sensitivity_bounds()` against:
#        (a) 7 Live State Boards of Nursing (CO, CT, FL, IL, PA, TX, WA;
#            N = 3,855 audited midwife records), and
#        (b) Primary-source AMCB national certification board status & identity
#            (`artifacts/amcb_npi_linkage_FROZEN.csv`),
#        classifying errors into OIG Table 2's three exact subtypes:
#        `partially_incorrect`, `formerly_correct`, and `never_correct`.
#   5. Automated OIG Manuscript Narrative (`attribute_oig_audit_prose()`).
#
# Outputs (aggregate-only, provenance-stamped in `artifacts/oig_remake/`):
#   - artifacts/oig_remake/oig_table1_table2_accuracy_summary.csv
#   - artifacts/oig_remake/oig_table2_inaccuracy_subtypes_by_variable.csv
#   - artifacts/oig_remake/oig_table3_completeness_2019_and_2026.csv
#   - artifacts/oig_remake/oig_appendix_a_pecos_enrollment_location_linkage.csv
#   - artifacts/oig_remake/oig_table4_consistency_2019_and_2026.csv
#   - artifacts/oig_remake/oig_table4_any_variable_inconsistent.csv
#   - artifacts/oig_remake/oig_update_lag_and_staleness_check.csv
#   - artifacts/oig_remake/oig_audit_narrative_prose.csv
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
  library(tibble)
  library(mysteryroster)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "oig_phase2_candidate_set.R"))  # assert_one_row_per_id()
source(file.path("R", "lib", "oig_zip_normalizers.R"))  # norm_pecos_bigint_zip5(), norm_str_zip5()

#' Assert a data frame has at most one row per (key1, key2) pair; stop with a
#' clear message naming the duplicates if not. Multi-column counterpart to
#' assert_one_row_per_id() for the two call sites keyed on more than one column.
assert_one_row_per_key_pair <- function(data, key1, key2, context) {
  dup <- data[duplicated(data[c(key1, key2)]), c(key1, key2)]
  if (nrow(dup) > 0L) {
    stop(sprintf(
      "%s: expected exactly one row per (%s, %s), found %d duplicated pair(s).",
      context, key1, key2, nrow(unique(dup))
    ), call. = FALSE)
  }
  invisible(data)
}

OUT_DIR <- file.path("artifacts", "oig_remake")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

FROZEN_PATH <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
stopifnot(file.exists(FROZEN_PATH))

# -----------------------------------------------------------------------------
# Normalization helpers following OIG OEI-07-09-00440 Appendix A (p. 20)
# -----------------------------------------------------------------------------
# norm_pecos_bigint_zip5() and norm_str_zip5() live in
# R/lib/oig_zip_normalizers.R, shared with
# oig_phase2_candidate_set_and_intersection_analysis.R (tests/ci_hygiene.R's
# H4 refuses two copies of the same function name).

norm_phone10 <- function(x) {
  s <- gsub("[^0-9]", "", trimws(as.character(x)))
  s <- sub("^1([0-9]{10})$", "\\1", s)
  ifelse(!is.na(s) & nchar(s) == 10L & !grepl("^0+$", s), s, NA_character_)
}

# OIG Methodology (p. 6): "To standardize the credential variable across both
# databases, we removed punctuation (e.g., periods and commas), converted all
# text to uppercase, and removed spaces."
norm_oig_credential <- function(x) {
  s <- toupper(gsub("[^A-Za-z0-9]", "", trimws(as.character(x))))
  ifelse(!is.na(s) & nzchar(s), s, NA_character_)
}

# Map taxonomy or specialty descriptions to canonical midwifery / APRN / RN / OB classes
# plus keep raw standardized tokens so OIG specialty completeness & consistency both work.
norm_oig_specialty <- function(x, source_type = c("nppes_taxonomy", "pecos_desc")) {
  source_type <- match.arg(source_type)
  s <- toupper(trimws(as.character(x)))
  s[is.na(s) | !nzchar(s)] <- NA_character_
  if (source_type == "nppes_taxonomy") {
    dplyr::case_when(
      is.na(s) ~ NA_character_,
      s %in% c("367A00000X", "176B00000X") ~ "MIDWIFERY",
      grepl("^363L", s) ~ "NURSE_PRACTITIONER",
      grepl("^364S", s) ~ "CLINICAL_NURSE_SPECIALIST",
      grepl("^163W", s) ~ "REGISTERED_NURSE",
      grepl("^207V", s) ~ "OBSTETRICS_GYNECOLOGY",
      TRUE ~ paste0("OTHER_TAXONOMY:", s)
    )
  } else {
    dplyr::case_when(
      is.na(s) ~ NA_character_,
      grepl("MIDWIFE", s) ~ "MIDWIFERY",
      grepl("NURSE PRACTITIONER", s) ~ "NURSE_PRACTITIONER",
      grepl("CLINICAL NURSE SPECIALIST", s) ~ "CLINICAL_NURSE_SPECIALIST",
      grepl("REGISTERED NURSE", s) ~ "REGISTERED_NURSE",
      grepl("OBSTETRICS|GYNECOLOGY", s) ~ "OBSTETRICS_GYNECOLOGY",
      TRUE ~ paste0("OTHER_SPEC:", s)
    )
  }
}

norm_oig_name <- function(first, last) {
  f <- toupper(gsub("[^A-Za-z]", "", trimws(as.character(first))))
  l <- toupper(gsub("[^A-Za-z]", "", trimws(as.character(last))))
  ifelse(!is.na(f) & nzchar(f) & !is.na(l) & nzchar(l), paste0(f, "|", l), NA_character_)
}

norm_gender <- function(x) {
  s <- toupper(substr(trimws(as.character(x)), 1L, 1L))
  ifelse(s %in% c("F", "M"), s, NA_character_)
}

# =============================================================================
# 1. Load AMCB Study Cohort Spine
# =============================================================================
lnk_raw <- read_csv(FROZEN_PATH, col_types = cols(.default = "c"), progress = FALSE)
cohort_active <- canonical_active_primary(lnk_raw) %>%
  mutate(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
assert_one_row_per_id(cohort_active, "npi", "canonical_active_primary() cohort")

cohort_all_elig <- lnk_raw[linkage_eligible(lnk_raw), , drop = FALSE] %>%
  mutate(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
assert_one_row_per_id(cohort_all_elig, "npi", "linkage_eligible() cohort")

cat(sprintf("Canonical active primary-linked AMCB cohort: N = %d unique NPIs\n", nrow(cohort_active)))
cat(sprintf("All linkage-eligible AMCB cohort with NPI:   N = %d unique NPIs\n", nrow(cohort_all_elig)))

# =============================================================================
# 2. Query DuckDB (`nber_my_duckdb.duckdb`) via `open_medicare_duckdb()`
# =============================================================================
con <- open_medicare_duckdb(read_only = TRUE)
on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)

DBI::dbWriteTable(con, "tmp_cohort_active", tibble(npi = cohort_active$npi), temporary = TRUE, overwrite = TRUE)

# --- 2A. 2019 Relational PECOS tables ----------------------------------------
pecos_enrl_2019 <- DBI::dbGetQuery(con, "
  SELECT
    CAST(e.npi AS VARCHAR) AS npi,
    CAST(e.pecos_asct_cntl_id AS VARCHAR) AS pac_id,
    TRIM(e.enrlmt_id) AS enrlmt_id,
    TRIM(e.provider_type_cd) AS provider_type_cd,
    TRIM(e.provider_type_desc) AS provider_type_desc,
    TRIM(e.state_cdstr) AS enrol_state,
    TRIM(e.first_name) AS first_name,
    TRIM(e.mdl_name) AS mdl_name,
    TRIM(e.last_name) AS last_name,
    TRIM(e.gndr_sw) AS gndr_sw
  FROM main.ppef_enrol_2019 e
  INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
")

pecos_reassign_2019 <- DBI::dbGetQuery(con, "
  SELECT DISTINCT
    CAST(e.npi AS VARCHAR) AS npi,
    TRIM(r.reasgn_bnft_enrlmt_id) AS reasgn_bnft_enrlmt_id,
    TRIM(r.rcv_bnft_enrlmt_id) AS rcv_bnft_enrlmt_id
  FROM main.ppef_enrol_2019 e
  INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
  INNER JOIN main.ppef_reassign_2019 r ON TRIM(e.enrlmt_id) = TRIM(r.reasgn_bnft_enrlmt_id)
")

pecos_addr_2019 <- DBI::dbGetQuery(con, "
  SELECT
    TRIM(a.enrlmt_id) AS enrlmt_id,
    TRIM(a.city_name) AS city_name,
    a.zip_cd AS zip_cd,
    TRIM(a.state_cdstr) AS state_cdstr
  FROM main.ppef_addr_2019 a
  WHERE TRIM(a.enrlmt_id) IN (
    SELECT TRIM(e.enrlmt_id) FROM main.ppef_enrol_2019 e INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
    UNION
    SELECT TRIM(r.rcv_bnft_enrlmt_id)
    FROM main.ppef_enrol_2019 e
    INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
    INNER JOIN main.ppef_reassign_2019 r ON TRIM(e.enrlmt_id) = TRIM(r.reasgn_bnft_enrlmt_id)
  )
")

pecos_spec_2019 <- DBI::dbGetQuery(con, "
  SELECT DISTINCT
    CAST(e.npi AS VARCHAR) AS npi,
    TRIM(s.enrlmt_id) AS enrlmt_id,
    TRIM(s.provider_type_cd) AS provider_type_cd,
    TRIM(s.provider_type_desc) AS provider_type_desc
  FROM main.ppef_enrol_2019 e
  INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
  INNER JOIN main.ppef_spec_2019 s ON TRIM(e.enrlmt_id) = TRIM(s.enrlmt_id)
")

# --- 2B. 2019 NPPES (`midwife_panel.csv` snapshot_year == 2019) ----------------
nppes_2019_panel <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year == "2019") %>%
  mutate(npi = trimws(npi)) %>%
  semi_join(cohort_active, by = "npi")
assert_one_row_per_id(nppes_2019_panel, "npi", "midwife_panel.csv snapshot_year==2019")

# --- 2C. 2026 Full NPPES Dissemination + Supplemental Practice Locations ------
nppes_2026 <- DBI::dbGetQuery(con, '
  SELECT
    TRIM(n."NPI") AS npi,
    TRIM(n."Entity Type Code") AS entity_type,
    TRIM("Provider First Name") AS first_name,
    TRIM("Provider Middle Name") AS middle_name,
    TRIM("Provider Last Name (Legal Name)") AS last_name,
    TRIM("Provider Other First Name") AS other_first_name,
    TRIM("Provider Other Last Name") AS other_last_name,
    TRIM("Provider Credential Text") AS credential,
    TRIM("Provider Other Credential Text") AS other_credential,
    TRIM("Provider Sex Code") AS gender,
    TRIM("Provider Business Mailing Address State Name") AS mailing_state,
    TRIM("Provider Business Mailing Address Postal Code") AS mailing_zip,
    TRIM("Provider Business Mailing Address Telephone Number") AS mailing_phone,
    TRIM("Provider First Line Business Practice Location Address") AS practice_street,
    TRIM("Provider Business Practice Location Address City Name") AS practice_city,
    TRIM("Provider Business Practice Location Address State Name") AS practice_state,
    TRIM("Provider Business Practice Location Address Postal Code") AS practice_zip,
    TRIM("Provider Business Practice Location Address Telephone Number") AS practice_phone,
    TRIM("Provider Enumeration Date") AS enumeration_date,
    TRIM("Last Update Date") AS last_update_date,
    TRIM("NPI Deactivation Date") AS deactivation_date,
    TRIM("NPI Reactivation Date") AS reactivation_date,
    TRIM("Healthcare Provider Taxonomy Code_1") AS tax_1,
    TRIM("Healthcare Provider Taxonomy Code_2") AS tax_2,
    TRIM("Healthcare Provider Taxonomy Code_3") AS tax_3,
    TRIM("Healthcare Provider Taxonomy Code_4") AS tax_4,
    TRIM("Healthcare Provider Taxonomy Code_5") AS tax_5,
    TRIM("Provider License Number_1") AS lic_num_1,
    TRIM("Provider License Number State Code_1") AS lic_state_1,
    TRIM("Provider License Number_2") AS lic_num_2,
    TRIM("Provider License Number State Code_2") AS lic_state_2,
    TRIM("Provider License Number_3") AS lic_num_3,
    TRIM("Provider License Number State Code_3") AS lic_state_3,
    TRIM("Provider License Number_4") AS lic_num_4,
    TRIM("Provider License Number State Code_4") AS lic_state_4,
    TRIM("Provider License Number_5") AS lic_num_5,
    TRIM("Provider License Number State Code_5") AS lic_state_5
  FROM main.NPPES_Data_Dissemination_February_2026_npidata_pfile_20050523_20260208_csv n
  INNER JOIN tmp_cohort_active c ON TRIM(n."NPI") = c.npi
')

nppes_pl_2026 <- DBI::dbGetQuery(con, "
  SELECT DISTINCT
    TRIM(p.npi) AS npi,
    TRIM(p.state) AS pl_state,
    TRIM(p.zip5) AS pl_zip5
  FROM nppes.practice_locations_enhanced p
  INNER JOIN tmp_cohort_active c ON TRIM(p.npi) = c.npi
")

# --- 2D. 2026 PECOS Enrollment (`ppef_enrol_2026Q3`) + PECOS/DAC Locations ---
pecos_enrl_2026 <- DBI::dbGetQuery(con, "
  SELECT
    TRIM(e.NPI) AS npi,
    TRIM(e.PECOS_ASCT_CNTL_ID) AS pac_id,
    TRIM(e.ENRLMT_ID) AS enrlmt_id,
    TRIM(e.PROVIDER_TYPE_CD) AS provider_type_cd,
    TRIM(e.PROVIDER_TYPE_DESC) AS provider_type_desc,
    TRIM(e.STATE_CD) AS enrol_state,
    TRIM(e.FIRST_NAME) AS first_name,
    TRIM(e.MDL_NAME) AS mdl_name,
    TRIM(e.LAST_NAME) AS last_name
  FROM main.ppef_enrol_2026Q3 e
  INNER JOIN tmp_cohort_active c ON TRIM(e.NPI) = c.npi
")

dac_duck_2026 <- DBI::dbGetQuery(con, '
  SELECT
    CAST(d."NPI" AS VARCHAR) AS npi,
    TRIM(d."Ind_PAC_ID") AS pac_id,
    TRIM(d."Ind_enrl_ID") AS enrlmt_id,
    TRIM(d."Provider First Name") AS first_name,
    TRIM(d."Provider Middle Name") AS middle_name,
    TRIM(d."Provider Last Name") AS last_name,
    TRIM(d."gndr") AS gender,
    TRIM(d."Cred") AS credential,
    TRIM(d."pri_spec") AS pri_spec,
    TRIM(d."sec_spec_all") AS sec_spec_all,
    TRIM(d."City/Town") AS practice_city,
    TRIM(d."State") AS practice_state,
    TRIM(d."ZIP Code") AS practice_zip,
    CAST(d."Telephone Number" AS VARCHAR) AS practice_phone,
    TRIM(d."org_pac_id") AS org_pac_id
  FROM main.doctors_and_clinicians_05_2024_DAC_NationalDownloadableFile_csv_6 d
  INNER JOIN tmp_cohort_active c ON CAST(d."NPI" AS VARCHAR) = c.npi
')

pecos_revoked <- DBI::dbGetQuery(con, "
  SELECT DISTINCT
    TRIM(r.npi) AS npi,
    TRIM(r.enrlmt_id) AS enrlmt_id,
    TRIM(r.revocation_rsn) AS revocation_rsn,
    TRIM(r.revocation_efctv_dt) AS revocation_efctv_dt
  FROM main.cms_pecos_revoked_providers r
  INNER JOIN tmp_cohort_active c ON TRIM(r.npi) = c.npi
")

# --- 2E. Historical PECOS PPEF Enrollment (2016-2018) & All-Eligible NPPES Deactivation Status ---
pecos_ppef_16_18 <- bind_rows(lapply(2016:2018, function(yr) {
  tb_e <- sprintf("main.ppef_enrol_%d", yr)
  DBI::dbGetQuery(con, sprintf("
    SELECT DISTINCT
      CAST(e.npi AS VARCHAR) AS npi,
      %d AS year,
      TRIM(e.state_cdstr) AS state,
      '%s' AS source_table
    FROM %s e
    INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
  ", yr, tb_e, tb_e))
})) %>%
  mutate(state = clean_state(state)) %>%
  filter(!is.na(state), nzchar(state)) %>%
  distinct(npi, year, state)

DBI::dbWriteTable(con, "tmp_cohort_all_elig", tibble(npi = cohort_all_elig$npi), temporary = TRUE, overwrite = TRUE)

nppes_all_elig_2026 <- DBI::dbGetQuery(con, '
  SELECT
    TRIM(n."NPI") AS npi,
    TRIM(n."Provider Enumeration Date") AS enumeration_date,
    TRIM(n."Last Update Date") AS last_update_date,
    TRIM(n."NPI Deactivation Date") AS deactivation_date,
    TRIM(n."NPI Reactivation Date") AS reactivation_date
  FROM main.NPPES_Data_Dissemination_February_2026_npidata_pfile_20050523_20260208_csv n
  INNER JOIN tmp_cohort_all_elig c ON TRIM(n."NPI") = c.npi
')
assert_one_row_per_id(nppes_all_elig_2026, "npi", "Feb 2026 NPPES P-file, all-eligible frame")

deact_all_elig_2026 <- if (DBI::dbExistsTable(con, "nppes_deact_norm_v")) {
  d <- DBI::dbGetQuery(con, "
    SELECT DISTINCT
      CAST(d.npi AS VARCHAR) AS npi,
      CAST(d.deactivation_date AS VARCHAR) AS deact_file_date
    FROM main.nppes_deact_norm_v d
    INNER JOIN tmp_cohort_all_elig c ON CAST(d.npi AS VARCHAR) = c.npi
  ")
  assert_one_row_per_id(d, "npi", "nppes_deact_norm_v, all-eligible frame")
  d
} else {
  tibble(npi = character(), deact_file_date = character())
}

nppes_2026_gender <- nppes_2026 %>% select(npi, gender)
assert_one_row_per_id(nppes_2026_gender, "npi", "2026 NPPES gender lookup")
nppes_2019 <- nppes_2019_panel %>%
  left_join(nppes_2026_gender, by = "npi")

cat(sprintf(
  "Fetched DuckDB extracts: 2019 NPPES (%d), 2019 PECOS enrl (%d rows / %d NPIs), 2026 NPPES (%d), 2026 PECOS enrl (%d rows / %d NPIs), DAC (%d rows / %d NPIs)\n",
  nrow(nppes_2019), nrow(pecos_enrl_2019), n_distinct(pecos_enrl_2019$npi),
  nrow(nppes_2026), nrow(pecos_enrl_2026), n_distinct(pecos_enrl_2026$npi),
  nrow(dac_duck_2026), n_distinct(dac_duck_2026$npi)
))

# Also load `dac_midwives.csv` (2026 vintage) to union with DAC DuckDB rows
dac_csv_2026 <- if (file.exists("dac_midwives.csv")) {
  read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    semi_join(cohort_active, by = "npi")
} else {
  tibble()
}

# =============================================================================
# 3. Replicate OIG Appendix A & Table 3 Footnote *** (PECOS Enrollment Linkage)
#    Using `mysteryroster::attribute_enrollment_locations()`
# =============================================================================
# Build individual enrollment edges, group reassignment edges, and location rows
indiv_edges_2019 <- pecos_enrl_2019 %>%
  transmute(npi = trimws(npi), year = 2019L, enrollment_id = trimws(enrlmt_id)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(enrollment_id), nzchar(enrollment_id)) %>%
  distinct()

reassign_edges_2019 <- pecos_reassign_2019 %>%
  transmute(npi = trimws(npi), year = 2019L, enrollment_id = trimws(rcv_bnft_enrlmt_id)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(enrollment_id), nzchar(enrollment_id)) %>%
  distinct()

loc_2019 <- pecos_addr_2019 %>%
  mutate(
    year = 2019L,
    enrollment_id = trimws(enrlmt_id),
    practice_zip5 = norm_pecos_bigint_zip5(zip_cd),
    practice_state = clean_state(state_cdstr),
    practice_city = toupper(trimws(city_name))
  ) %>%
  filter(!is.na(enrollment_id), nzchar(enrollment_id)) %>%
  distinct(year, enrollment_id, practice_zip5, practice_state, practice_city) %>%
  mutate(location_id = sprintf("LOC2019_%06d", row_number()))

pecos_linkage_2019 <- attribute_enrollment_locations(
  individual_enrollments = indiv_edges_2019,
  reassignments = reassign_edges_2019,
  locations = loc_2019
)

# Summarize the OIG Appendix A / Table 3 Footnote *** finding at both the
# Enrollment-ID level and the Provider (NPI) level:
enrl_direct_summary <- indiv_edges_2019 %>%
  left_join(
    pecos_linkage_2019$links %>%
      filter(linkage_path == "direct_enrollment", location_linked) %>%
      distinct(npi = id, enrollment_id) %>%
      mutate(has_direct_loc = TRUE),
    by = c("npi", "enrollment_id")
  ) %>%
  left_join(
    pecos_reassign_2019 %>%
      inner_join(
        pecos_linkage_2019$links %>%
          filter(linkage_path == "group_reassignment", location_linked) %>%
          distinct(npi = id, rcv_bnft_enrlmt_id = enrollment_id),
        by = c("npi", "rcv_bnft_enrlmt_id")
      ) %>%
      distinct(npi, enrollment_id = reasgn_bnft_enrlmt_id) %>%
      mutate(has_reassigned_loc = TRUE),
    by = c("npi", "enrollment_id")
  ) %>%
  mutate(
    has_direct_loc = coalesce(has_direct_loc, FALSE),
    has_reassigned_loc = coalesce(has_reassigned_loc, FALSE),
    loc_resolution_class = case_when(
      has_direct_loc & has_reassigned_loc ~ "both_direct_and_group_reassignment",
      has_direct_loc & !has_reassigned_loc ~ "direct_individual_enrollment_only",
      !has_direct_loc & has_reassigned_loc ~ "group_reassignment_only_missing_direct_record",
      TRUE ~ "unmatched_no_practice_location_record"
    )
  )

npi_loc_summary_2019 <- enrl_direct_summary %>%
  group_by(npi) %>%
  summarise(
    any_direct = any(has_direct_loc),
    any_reassigned = any(has_reassigned_loc),
    .groups = "drop"
  ) %>%
  mutate(
    loc_resolution_class = case_when(
      any_direct & any_reassigned ~ "both_direct_and_group_reassignment",
      any_direct & !any_reassigned ~ "direct_individual_enrollment_only",
      !any_direct & any_reassigned ~ "group_reassignment_only_missing_direct_record",
      TRUE ~ "unmatched_no_practice_location_record"
    )
  )

appendix_a_tbl <- bind_rows(
  enrl_direct_summary %>%
    count(loc_resolution_class, name = "n_records") %>%
    mutate(
      unit = "pecos_individual_enrollment_id",
      n_total = nrow(enrl_direct_summary),
      pct_of_total = round(100 * n_records / n_total, 2),
      oig_2013_benchmark_pct = case_when(
        loc_resolution_class == "group_reassignment_only_missing_direct_record" ~ 80.07,
        loc_resolution_class == "direct_individual_enrollment_only" ~ 19.93,
        TRUE ~ NA_real_
      )
    ),
  npi_loc_summary_2019 %>%
    count(loc_resolution_class, name = "n_records") %>%
    mutate(
      unit = "pecos_enrolled_midwife_npi",
      n_total = nrow(npi_loc_summary_2019),
      pct_of_total = round(100 * n_records / n_total, 2),
      oig_2013_benchmark_pct = case_when(
        loc_resolution_class == "group_reassignment_only_missing_direct_record" ~ 80.07,
        loc_resolution_class == "direct_individual_enrollment_only" ~ 19.93,
        TRUE ~ NA_real_
      )
    )
) %>%
  mutate(
    plain_english_summary = case_when(
      loc_resolution_class %in% c("direct_individual_enrollment_only", "both_direct_and_group_reassignment") ~
        "Practice-location address directly linked to the midwife's individual Medicare enrollment record (26 of 5,897 midwives total; 0.44%).",
      loc_resolution_class == "group_reassignment_only_missing_direct_record" ~
        "No address on individual enrollment record, but practice address recovered by linking the midwife to her billing organization/group in PECOS (5,617 via group only; 5,643 of 5,897 [95.69%] total with any linked address). Organizational addresses are not independently verified as actual clinical practice sites.",
      TRUE ~
        "No practice-location address found on either the individual Medicare enrollment record or a linked billing organization (254 of 5,897 midwives; 4.31%)."
    )
  ) %>%
  select(unit, loc_resolution_class, n_records, n_total, pct_of_total, oig_2013_benchmark_pct, plain_english_summary)

cat("\n=== OIG Appendix A / Table 3 Footnote *** Remake (PECOS Practice Location Linkage) ===\n")
print(as.data.frame(appendix_a_tbl), row.names = FALSE)

# =============================================================================
# 4. Build OIG Field Dictionary & Run `attribute_analysis_populations()` and
#    `attribute_record_presence()` for 2019 and 2026 (OIG Table 3 Remake)
# =============================================================================
oig_fields <- tibble(
  attribute = c(
    "ssn_tin",
    "dob",
    "full_name",
    "gender",
    "specialty_code",
    "credential",
    "license_state",
    "phone10",
    "mailing_zip5",
    "practice_zip5_direct",
    "practice_zip5",
    "practice_state"
  ),
  definition = c(
    "Social Security Number / TIN (redacted in public CMS extracts)",
    "Date of birth (redacted in public CMS extracts)",
    "Provider legal first and last name",
    "Provider sex / gender code",
    "Provider taxonomy code (NPPES) or Medicare specialty code (PECOS)",
    "Standardized provider credential text",
    "State of professional licensure",
    "10-digit practice or business telephone number",
    "5-digit business mailing address ZIP Code",
    "5-digit practice location ZIP Code (direct individual enrollment ID only, per OIG Table 3)",
    "5-digit practice location ZIP Code (including PECOS group reassignment linkage)",
    "2-letter practice location state postal code"
  ),
  location_role = c(
    "identity", "identity", "identity", "identity", "identity", "identity",
    "identity", "practice", "mailing", "practice", "practice", "practice"
  ),
  normalizer = c(
    "redacted", "redacted", "name_upper", "gender_code", "specialty_class",
    "credential_upper_alnum", "state_code", "phone10", "zip5", "zip5", "zip5", "state_code"
  )
)

sources_vec <- c("nppes", "pecos", "dac")
oig_dictionary <- attribute_field_dictionary(
  fields = oig_fields,
  sources = sources_vec,
  lineage_groups = list(medicare_enrollment = c("pecos", "dac"))
)

# --- Construct Population Frame & Record Index across 2019 and 2026 ----------
frame_2019 <- tibble(npi = cohort_active$npi, year = 2019L)
frame_2026 <- tibble(npi = cohort_active$npi, year = 2026L)
study_frame <- bind_rows(frame_2019, frame_2026)

# Historical 2019 DAC presence from `artifacts/physician_compare_historical_midwives.csv` if available
dac_2019_npis <- character(0)
if (file.exists("artifacts/physician_compare_historical_midwives.csv")) {
  dac_hist <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE)
  dac_2019_npis <- unique(trimws(dac_hist$npi[substr(dac_hist$vintage, 1, 4) == "2019"]))
  dac_2019_npis <- intersect(dac_2019_npis, cohort_active$npi)
}

dac_2026_npis <- unique(c(trimws(dac_duck_2026$npi), trimws(dac_csv_2026$npi)))
dac_2026_npis <- intersect(dac_2026_npis[!is.na(dac_2026_npis) & nzchar(dac_2026_npis)], cohort_active$npi)

record_index <- bind_rows(
  tibble(npi = unique(nppes_2019$npi), year = 2019L, source = "nppes"),
  tibble(npi = unique(pecos_enrl_2019$npi), year = 2019L, source = "pecos"),
  if (length(dac_2019_npis) > 0) tibble(npi = dac_2019_npis, year = 2019L, source = "dac") else tibble(npi = character(0), year = integer(0), source = character(0)),
  tibble(npi = unique(nppes_2026$npi), year = 2026L, source = "nppes"),
  tibble(npi = unique(pecos_enrl_2026$npi), year = 2026L, source = "pecos"),
  tibble(npi = dac_2026_npis, year = 2026L, source = "dac")
) %>%
  distinct()

manifest <- expand_grid(
  year = c(2019L, 2026L),
  source = sources_vec
) %>%
  mutate(extract_complete = !(year == 2019L & source == "dac" & length(dac_2019_npis) == 0L))

populations <- attribute_analysis_populations(
  population = study_frame,
  record_index = record_index,
  manifest = manifest,
  pair = c("nppes", "pecos")
)

# --- Declare Explicit Field Availability per (year, source, attribute) -------
source_fields <- expand_grid(
  year = c(2019L, 2026L),
  source = sources_vec,
  attribute = oig_fields$attribute
) %>%
  mutate(
    field_available = case_when(
      attribute %in% c("ssn_tin", "dob") ~ FALSE,
      # 2019 NPPES (`midwife_panel.csv` snapshot_year == 2019 carries name, specialty, credential, practice_zip5, practice_state; gender joined from NPPES)
      year == 2019L & source == "nppes" & attribute %in% c(
        "full_name", "gender", "specialty_code", "credential",
        "practice_zip5_direct", "practice_zip5", "practice_state"
      ) ~ TRUE,
      year == 2019L & source == "nppes" ~ FALSE,
      # 2019 PECOS (`ppef_enrol_2019` + `ppef_addr_2019` + `ppef_reassign_2019` + `ppef_spec_2019`)
      year == 2019L & source == "pecos" & attribute %in% c(
        "full_name", "gender", "specialty_code",
        "practice_zip5_direct", "practice_zip5", "practice_state"
      ) ~ TRUE,
      year == 2019L & source == "pecos" ~ FALSE,
      # 2019 DAC (not used for 2019 full variable audit)
      year == 2019L & source == "dac" ~ FALSE,
      # 2026 Full NPPES (all public fields available)
      year == 2026L & source == "nppes" & attribute %in% c(
        "full_name", "gender", "specialty_code", "credential", "license_state",
        "phone10", "mailing_zip5", "practice_zip5_direct", "practice_zip5", "practice_state"
      ) ~ TRUE,
      year == 2026L & source == "nppes" ~ FALSE,
      # 2026 Raw PECOS PPEF (`ppef_enrol_2026Q3`: carries name, specialty, enrollment state)
      year == 2026L & source == "pecos" & attribute %in% c(
        "full_name", "specialty_code", "practice_state"
      ) ~ TRUE,
      year == 2026L & source == "pecos" ~ FALSE,
      # 2026 PECOS/DAC (`doctors_and_clinicians` + `dac_midwives.csv`: carries name, gender, specialty, credential, phone10, practice_zip5, practice_state)
      year == 2026L & source == "dac" & attribute %in% c(
        "full_name", "gender", "specialty_code", "credential",
        "phone10", "practice_zip5_direct", "practice_zip5", "practice_state"
      ) ~ TRUE,
      TRUE ~ FALSE
    )
  )

# --- Build Normalized Claims Table for 2019 and 2026 -------------------------
# Helper to make claim rows:
# When `present_row_exists = TRUE` for every provider in the parent table,
# an NA value becomes a row with `value = NA_character_` (`field_value_missing` = OIG "Null Data Field").
# When a relational child table has NO row for that provider, omitting the row
# causes `attribute_record_presence()` to classify it as `field_row_missing` (OIG "Missing Record")!
make_parent_field_claims <- function(df, yr, src, attr_name, val_vec) {
  tibble(
    npi = trimws(df$npi),
    year = as.integer(yr),
    source = src,
    attribute = attr_name,
    value = as.character(val_vec)
  ) %>%
    distinct()
}

# 1) 2019 NPPES claims
nppes_2019_spec_vec <- dplyr::case_when(
  tolower(trimws(nppes_2019$tax_class)) == "midwife" ~ "MIDWIFERY",
  tolower(trimws(nppes_2019$tax_class)) == "nursing" ~ "REGISTERED_NURSE",
  TRUE ~ NA_character_
)

claims_nppes_2019 <- bind_rows(
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "full_name", norm_oig_name(nppes_2019$first_name, nppes_2019$last_name)),
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "gender", norm_gender(nppes_2019$gender)),
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "specialty_code", nppes_2019_spec_vec),
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "credential", norm_oig_credential(nppes_2019$credential)),
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "practice_zip5_direct", norm_str_zip5(nppes_2019$practice_zip)),
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "practice_zip5", norm_str_zip5(nppes_2019$practice_zip)),
  make_parent_field_claims(nppes_2019, 2019L, "nppes", "practice_state", clean_state(nppes_2019$practice_state))
)

# 2) 2019 PECOS claims (Relational!)
# Notice how `practice_zip5_direct` ONLY includes rows from `pecos_linkage_2019$links`
# where `linkage_path == "direct_enrollment" & location_linked`. Providers whose
# individual `enrlmt_id` has no row in `ppef_addr_2019` have 0 rows in `claims`,
# so `attribute_record_presence()` classifies them as `field_row_missing` (OIG's "Missing Records"!).
pecos_2019_direct_zip <- pecos_linkage_2019$links %>%
  filter(linkage_path == "direct_enrollment", location_linked) %>%
  transmute(npi = id, year = 2019L, source = "pecos", attribute = "practice_zip5_direct", value = practice_zip5) %>%
  distinct()

pecos_2019_any_zip <- pecos_linkage_2019$links %>%
  filter(location_linked) %>%
  transmute(npi = id, year = 2019L, source = "pecos", attribute = "practice_zip5", value = practice_zip5) %>%
  distinct()

pecos_2019_any_state <- bind_rows(
  pecos_linkage_2019$links %>%
    filter(location_linked) %>%
    transmute(npi = id, year = 2019L, source = "pecos", attribute = "practice_state", value = practice_state),
  make_parent_field_claims(pecos_enrl_2019, 2019L, "pecos", "practice_state", clean_state(pecos_enrl_2019$enrol_state))
) %>%
  filter(!is.na(value)) %>%
  distinct()

pecos_2019_specs <- bind_rows(
  pecos_enrl_2019 %>% transmute(npi = trimws(npi), spec = norm_oig_specialty(provider_type_desc, "pecos_desc")),
  pecos_spec_2019 %>% transmute(npi = trimws(npi), spec = norm_oig_specialty(provider_type_desc, "pecos_desc"))
) %>%
  distinct()

claims_pecos_2019 <- bind_rows(
  make_parent_field_claims(pecos_enrl_2019, 2019L, "pecos", "full_name", norm_oig_name(pecos_enrl_2019$first_name, pecos_enrl_2019$last_name)),
  make_parent_field_claims(pecos_enrl_2019, 2019L, "pecos", "gender", norm_gender(pecos_enrl_2019$gndr_sw)),
  pecos_2019_specs %>% transmute(npi, year = 2019L, source = "pecos", attribute = "specialty_code", value = spec),
  pecos_2019_direct_zip,
  pecos_2019_any_zip,
  pecos_2019_any_state
) %>%
  distinct()

# 3) 2026 NPPES claims (Full 330-col file + optional PL supplement)
nppes_2026_tax <- bind_rows(
  tibble(npi = nppes_2026$npi, tax = nppes_2026$tax_1),
  tibble(npi = nppes_2026$npi, tax = nppes_2026$tax_2),
  tibble(npi = nppes_2026$npi, tax = nppes_2026$tax_3),
  tibble(npi = nppes_2026$npi, tax = nppes_2026$tax_4),
  tibble(npi = nppes_2026$npi, tax = nppes_2026$tax_5)
) %>%
  mutate(spec = norm_oig_specialty(tax, "nppes_taxonomy")) %>%
  filter(!is.na(spec)) %>%
  distinct(npi, spec)

nppes_2026_spec_claims <- tibble(npi = unique(nppes_2026$npi)) %>%
  left_join(nppes_2026_tax, by = "npi") %>%
  transmute(npi, year = 2026L, source = "nppes", attribute = "specialty_code", value = spec)

# Conditionally required license slots 1..5 in NPPES:
# If all 5 license numbers & states are blank for a provider, `n_populated == 0` -> `field_value_missing` (OIG Table 3: 9.3% conditionally required missing in NPPES)
nppes_2026_lic <- bind_rows(
  tibble(npi = nppes_2026$npi, lic_num = nppes_2026$lic_num_1, lic_st = nppes_2026$lic_state_1),
  tibble(npi = nppes_2026$npi, lic_num = nppes_2026$lic_num_2, lic_st = nppes_2026$lic_state_2),
  tibble(npi = nppes_2026$npi, lic_num = nppes_2026$lic_num_3, lic_st = nppes_2026$lic_state_3),
  tibble(npi = nppes_2026$npi, lic_num = nppes_2026$lic_num_4, lic_st = nppes_2026$lic_state_4),
  tibble(npi = nppes_2026$npi, lic_num = nppes_2026$lic_num_5, lic_st = nppes_2026$lic_state_5)
) %>%
  mutate(
    lic_st_clean = clean_state(lic_st),
    lic_num_clean = toupper(gsub("[^A-Za-z0-9]", "", trimws(lic_num))),
    valid_lic_state = ifelse(!is.na(lic_st_clean) & !is.na(lic_num_clean) & nzchar(lic_num_clean), lic_st_clean, NA_character_)
  )

nppes_2026_lic_claims <- tibble(npi = unique(nppes_2026$npi)) %>%
  left_join(
    nppes_2026_lic %>% filter(!is.na(valid_lic_state)) %>% distinct(npi, valid_lic_state),
    by = "npi"
  ) %>%
  transmute(npi, year = 2026L, source = "nppes", attribute = "license_state", value = valid_lic_state)

claims_nppes_2026 <- bind_rows(
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "full_name", norm_oig_name(nppes_2026$first_name, nppes_2026$last_name)),
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "gender", norm_gender(nppes_2026$gender)),
  nppes_2026_spec_claims,
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "credential", norm_oig_credential(nppes_2026$credential)),
  nppes_2026_lic_claims,
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "phone10", norm_phone10(nppes_2026$practice_phone)),
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "mailing_zip5", norm_str_zip5(nppes_2026$mailing_zip)),
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "practice_zip5_direct", norm_str_zip5(nppes_2026$practice_zip)),
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "practice_zip5", norm_str_zip5(nppes_2026$practice_zip)),
  make_parent_field_claims(nppes_2026, 2026L, "nppes", "practice_state", clean_state(nppes_2026$practice_state))
) %>%
  distinct()

# 4) 2026 PECOS (`ppef_enrol_2026Q3`) & 2026 DAC (`doctors_and_clinicians` + `dac_midwives.csv`)
claims_pecos_2026 <- bind_rows(
  make_parent_field_claims(pecos_enrl_2026, 2026L, "pecos", "full_name", norm_oig_name(pecos_enrl_2026$first_name, pecos_enrl_2026$last_name)),
  make_parent_field_claims(pecos_enrl_2026, 2026L, "pecos", "specialty_code", norm_oig_specialty(pecos_enrl_2026$provider_type_desc, "pecos_desc")),
  make_parent_field_claims(pecos_enrl_2026, 2026L, "pecos", "practice_state", clean_state(pecos_enrl_2026$enrol_state))
) %>%
  distinct()

dac_combined_2026 <- bind_rows(
  dac_duck_2026 %>%
    transmute(
      npi = trimws(npi),
      first_name, last_name,
      gender,
      credential,
      spec = pri_spec,
      practice_zip,
      practice_state,
      practice_phone,
      has_direct_enrl = !is.na(enrlmt_id) & nzchar(enrlmt_id) & is.na(org_pac_id)
    ),
  if (nrow(dac_csv_2026) > 0) {
    dac_csv_2026 %>%
      transmute(
        npi = trimws(npi),
        first_name, last_name,
        gender = sex,
        credential,
        spec = primary_specialty,
        practice_zip,
        practice_state,
        practice_phone = NA_character_,
        has_direct_enrl = FALSE
      )
  } else {
    tibble()
  }
) %>%
  filter(npi %in% dac_2026_npis)

# Note: In DAC, phone10 comes from the DuckDB National Downloadable File (`dac_duck_2026`).
# For NPIs only in `dac_csv_2026` where phone wasn't extracted, keep their DuckDB phone if present.
dac_phone_claims_2026 <- tibble(npi = dac_2026_npis) %>%
  left_join(
    dac_duck_2026 %>%
      transmute(npi = trimws(npi), phone = norm_phone10(practice_phone)) %>%
      filter(!is.na(phone)) %>%
      distinct(),
    by = "npi"
  ) %>%
  transmute(npi, year = 2026L, source = "dac", attribute = "phone10", value = phone)

claims_dac_2026 <- bind_rows(
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "full_name", norm_oig_name(dac_combined_2026$first_name, dac_combined_2026$last_name)),
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "gender", norm_gender(dac_combined_2026$gender)),
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "specialty_code", norm_oig_specialty(dac_combined_2026$spec, "pecos_desc")),
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "credential", norm_oig_credential(dac_combined_2026$credential)),
  dac_phone_claims_2026,
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "practice_zip5_direct", norm_str_zip5(dac_combined_2026$practice_zip)),
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "practice_zip5", norm_str_zip5(dac_combined_2026$practice_zip)),
  make_parent_field_claims(dac_combined_2026, 2026L, "dac", "practice_state", clean_state(dac_combined_2026$practice_state))
) %>%
  # Collapse duplicate NA rows when a provider has multiple site rows in DAC, at least one of which is populated
  group_by(npi, year, source, attribute) %>%
  filter(if (any(!is.na(value))) !is.na(value) else row_number() == 1L) %>%
  ungroup() %>%
  distinct()

all_claims <- bind_rows(
  claims_nppes_2019,
  claims_pecos_2019,
  claims_nppes_2026,
  claims_pecos_2026,
  claims_dac_2026
) %>%
  # Deduplicate NA vs populated per (npi, year, source, attribute)
  group_by(npi, year, source, attribute) %>%
  filter(if (any(!is.na(value))) !is.na(value) else row_number() == 1L) %>%
  ungroup()

cat("Running mysteryroster::attribute_record_presence() across all (id, year, source, attribute) cells...\n")
record_presence <- attribute_record_presence(
  coverage = populations$coverage,
  dictionary = oig_dictionary,
  source_fields = source_fields,
  claims = all_claims
)

# Summarize OIG Table 3 (Completeness in NPPES, PECOS, and DAC)
oig_table3 <- record_presence %>%
  filter(record_present) %>%
  group_by(year, source, attribute, field_available, completeness_eligible) %>%
  summarise(
    n_records_present = n(),
    n_populated = sum(field_status == "populated"),
    n_missing_records_row = sum(field_status == "field_row_missing"),
    n_null_data_field = sum(field_status == "field_value_missing"),
    n_not_in_extract = sum(field_status == "field_not_in_extract"),
    n_total_incomplete = n_missing_records_row + n_null_data_field,
    pct_incomplete_of_eligible = ifelse(
      first(completeness_eligible) & n_records_present > 0,
      round(100 * (n_missing_records_row + n_null_data_field) / n_records_present, 2),
      NA_real_
    ),
    pct_complete_of_eligible = ifelse(
      first(completeness_eligible) & n_records_present > 0,
      round(100 * n_populated / n_records_present, 2),
      NA_real_
    ),
    .groups = "drop"
  ) %>%
  arrange(year, source, attribute)

cat("\n=== OIG Table 3 Remake: Completeness in NPPES, PECOS, and DAC ===\n")
print(as.data.frame(oig_table3 %>% filter(year == 2019L, source %in% c("nppes", "pecos"))), row.names = FALSE)
print(as.data.frame(oig_table3 %>% filter(year == 2026L)), row.names = FALSE)

# =============================================================================
# 5. Remake of OIG Table 4 (Inconsistency Between NPPES and PECOS/DAC)
#    Using `mysteryroster::attribute_set_agreement()` & `attribute_set_agreement_summary()`
# =============================================================================
run_oig_table4_pair <- function(yr, src_a, src_b, attr_name, claims_df) {
  sub_a <- claims_df %>%
    filter(year == yr, source == src_a, attribute == attr_name, !is.na(value), nzchar(value)) %>%
    select(npi, year, !!attr_name := value) %>%
    distinct()
  sub_b <- claims_df %>%
    filter(year == yr, source == src_b, attribute == attr_name, !is.na(value), nzchar(value)) %>%
    select(npi, year, !!attr_name := value) %>%
    distinct()
  if (nrow(sub_a) == 0L || nrow(sub_b) == 0L) return(NULL)
  src_list <- setNames(list(sub_a, sub_b), c(src_a, src_b))
  ag <- attribute_set_agreement(src_list, attribute = attr_name)
  if (nrow(ag) == 0L) return(NULL)
  sm <- attribute_set_agreement_summary(ag) %>%
    mutate(
      attribute = attr_name,
      n_inconsistent_any_shared = n_compared - n_any_shared,
      pct_inconsistent_any_shared = round(100 * (1 - pct_any_shared), 2),
      pct_agree_any_shared = round(100 * pct_any_shared, 2),
      n_inconsistent_same_set = n_compared - n_same_set,
      pct_inconsistent_same_set = round(100 * (1 - pct_same_set), 2),
      pct_agree_same_set = round(100 * pct_same_set, 2)
    )
  list(detail = ag %>% mutate(attribute = attr_name), summary = sm)
}

# Run across all comparable attributes in:
# (A) 2019 NPPES vs. 2019 PECOS (Relational 4-table PPEF)
# (B) 2026 NPPES vs. 2026 PECOS (`ppef_enrol_2026Q3`)
# (C) 2026 NPPES vs. 2026 PECOS/DAC (`dac`)
attrs_2019_pecos <- c("practice_zip5_direct", "practice_zip5", "practice_state", "full_name", "gender", "specialty_code")
attrs_2026_pecos <- c("practice_state", "full_name", "specialty_code")
attrs_2026_dac   <- c("practice_zip5", "practice_state", "phone10", "credential", "full_name", "gender", "specialty_code")

res_2019_pecos <- lapply(attrs_2019_pecos, function(a) run_oig_table4_pair(2019L, "nppes", "pecos", a, all_claims))
res_2026_pecos <- lapply(attrs_2026_pecos, function(a) run_oig_table4_pair(2026L, "nppes", "pecos", a, all_claims))
res_2026_dac   <- lapply(attrs_2026_dac,   function(a) run_oig_table4_pair(2026L, "nppes", "dac",   a, all_claims))

# Also run 2026 NPPES + Supplemental Practice Location File (`nppes_pl_2026`) vs DAC on `practice_zip5`
nppes_2026_plus_pl_zip <- bind_rows(
  all_claims %>% filter(year == 2026L, source == "nppes", attribute == "practice_zip5", !is.na(value)) %>% select(npi, year, practice_zip5 = value),
  nppes_pl_2026 %>% transmute(npi = trimws(npi), year = 2026L, practice_zip5 = norm_str_zip5(pl_zip5)) %>% filter(!is.na(practice_zip5))
) %>%
  distinct()
dac_2026_zip_only <- all_claims %>%
  filter(year == 2026L, source == "dac", attribute == "practice_zip5", !is.na(value)) %>%
  select(npi, year, practice_zip5 = value) %>%
  distinct()

ag_pl_2026 <- attribute_set_agreement(
  list(nppes_with_pl = nppes_2026_plus_pl_zip, dac = dac_2026_zip_only),
  attribute = "practice_zip5"
)
sm_pl_2026 <- attribute_set_agreement_summary(ag_pl_2026) %>%
  mutate(
    attribute = "practice_zip5_with_nppes_pl",
    n_inconsistent_any_shared = n_compared - n_any_shared,
    pct_inconsistent_any_shared = round(100 * (1 - pct_any_shared), 2),
    pct_agree_any_shared = round(100 * pct_any_shared, 2),
    n_inconsistent_same_set = n_compared - n_same_set,
    pct_inconsistent_same_set = round(100 * (1 - pct_same_set), 2),
    pct_agree_same_set = round(100 * pct_same_set, 2)
  )

oig_table4 <- bind_rows(
  lapply(res_2019_pecos, `[[`, "summary"),
  lapply(res_2026_pecos, `[[`, "summary"),
  lapply(res_2026_dac,   `[[`, "summary"),
  sm_pl_2026
) %>%
  mutate(
    oig_2013_benchmark_inconsistent_pct = case_when(
      attribute %in% c("practice_zip5", "practice_zip5_direct", "practice_zip5_with_nppes_pl") ~ 88.6,
      attribute == "phone10" ~ 59.0,
      attribute == "mailing_zip5" ~ 50.7,
      attribute == "license_state" ~ 42.1,
      attribute == "credential" ~ 9.3,
      attribute == "full_name" ~ 5.2,
      attribute == "gender" ~ 1.2,
      TRUE ~ NA_real_
    )
  ) %>%
  select(
    year, source_a, source_b, attribute,
    n_compared,
    n_inconsistent_any_shared, pct_inconsistent_any_shared,
    n_any_shared, pct_agree_any_shared,
    n_inconsistent_same_set, pct_inconsistent_same_set,
    n_same_set, pct_agree_same_set,
    oig_2013_benchmark_inconsistent_pct
  )

cat("\n=== OIG Table 4 Remake: Inconsistency Between NPPES and PECOS/DAC ===\n")
print(as.data.frame(oig_table4), row.names = FALSE)

# Compute OIG Table 4 Composite Row: "Any variable inconsistent" per provider
compute_any_inconsistent <- function(detail_list, label, yr, src_a, src_b, exclude_attrs = "practice_zip5_direct") {
  df <- bind_rows(lapply(detail_list, `[[`, "detail")) %>%
    filter(!attribute %in% exclude_attrs)
  by_id <- df %>%
    group_by(id) %>%
    summarise(
      n_vars_evaluated = n(),
      n_vars_inconsistent_any_shared = sum(!any_shared),
      n_vars_inconsistent_same_set = sum(!same_set),
      any_var_inconsistent_oig_rule = any(!any_shared),
      any_var_inconsistent_strict_set = any(!same_set),
      .groups = "drop"
    )
  tibble(
    comparison_label = label,
    year = yr,
    source_a = src_a,
    source_b = src_b,
    n_overlap_providers = nrow(by_id),
    n_any_inconsistent_oig_rule = sum(by_id$any_var_inconsistent_oig_rule),
    pct_any_inconsistent_oig_rule = round(100 * mean(by_id$any_var_inconsistent_oig_rule), 2),
    n_any_inconsistent_strict_set = sum(by_id$any_var_inconsistent_strict_set),
    pct_any_inconsistent_strict_set = round(100 * mean(by_id$any_var_inconsistent_strict_set), 2),
    mean_inconsistent_vars_per_provider = round(mean(by_id$n_vars_inconsistent_any_shared), 2),
    oig_2013_benchmark_any_inconsistent_pct = 97.4
  )
}

oig_table4_any <- bind_rows(
  compute_any_inconsistent(
    res_2019_pecos,
    "2019 NPPES vs 2019 Relational PECOS (with group-reassignment ZIP linkage)",
    2019L, "nppes", "pecos",
    exclude_attrs = "practice_zip5_direct"
  ),
  compute_any_inconsistent(
    res_2026_dac,
    "2026 NPPES vs 2026 PECOS/DAC (practice ZIP, state, phone, credential, name, gender, specialty)",
    2026L, "nppes", "dac",
    exclude_attrs = character(0)
  )
)

cat("\n=== OIG Table 4 Composite: 'Any Variable Inconsistent' Rate ===\n")
print(as.data.frame(oig_table4_any), row.names = FALSE)

# =============================================================================
# 6. OIG Update-Lag & Staleness Check (Report p. 16 Analogue)
#    Using `classify_record_staleness()`, `record_age_band()`, and
#    `attribute_lead_lag_duration()` / `attribute_catch_up_curve()`
# =============================================================================
# OIG tested whether inconsistencies between NPPES and PECOS were explained by
# asynchronous updates over an 8-month window (finding only 1.2% explained by lag).
# We test:
#   (A) In 2026 NPPES (`Last Update Date`), what share of NPPES vs PECOS/DAC
#       practice ZIP5 inconsistencies occur in recently updated (< 1 yr) vs
#       stale (> 3 yr / > 5 yr) NPPES records (`classify_record_staleness()`)?
#   (B) Across the multi-year PECOS Revalidation (`2021-2026`) vs NPPES (`2021-2026`)
#       panel (`artifacts/pecos_revalidation_cohort_state_by_year.csv` and
#       `midwife_panel.csv`), how many base-year state disagreements resolve
#       in subsequent years (`attribute_lead_lag_duration()`)?

nppes_2026_staleness <- nppes_2026 %>%
  transmute(
    npi = trimws(npi),
    last_updated = as.Date(last_update_date, format = "%m/%d/%Y"),
    enumeration_dt = as.Date(enumeration_date, format = "%m/%d/%Y")
  ) %>%
  mutate(
    effective_date = coalesce(last_updated, enumeration_dt),
    age_years = record_age_years(effective_date, as_of = as.Date("2026-02-08")),
    age_band = as.character(record_age_band(effective_date, as_of = as.Date("2026-02-08")))
  )

zip_ag_2026_df <- res_2026_dac[[which(attrs_2026_dac == "practice_zip5")]]$detail %>%
  rename(npi = id) %>%
  left_join(nppes_2026_staleness, by = "npi")

staleness_summary <- zip_ag_2026_df %>%
  mutate(age_band = coalesce(age_band, "Unknown")) %>%
  group_by(age_band) %>%
  summarise(
    n_compared = n(),
    n_zip5_inconsistent = sum(!any_shared),
    pct_zip5_inconsistent = round(100 * mean(!any_shared), 2),
    n_zip5_agree = sum(any_shared),
    pct_zip5_agree = round(100 * mean(any_shared), 2),
    .groups = "drop"
  ) %>%
  mutate(
    analysis_type = "2026_nppes_record_age_band_vs_pecos_dac_zip5_inconsistency",
    metric_detail = age_band
  ) %>%
  select(analysis_type, metric_detail, n_compared, n_zip5_inconsistent, pct_zip5_inconsistent, n_zip5_agree, pct_zip5_agree)

# Longitudinal lead-lag duration on PECOS Revalidation vs NPPES state (2021-2026)
lag_summary_rows <- tibble()
if (file.exists("artifacts/pecos_revalidation_cohort_state_by_year.csv") && file.exists("midwife_panel.csv")) {
  pecos_rev_panel <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
    filter(!is.na(npi), !is.na(year), !is.na(state)) %>%
    distinct() %>%
    group_by(npi, year) %>%
    slice(1L) %>%
    ungroup()

  nppes_panel_21_26 <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
    filter(year >= 2021L, year <= 2026L, !is.na(npi), !is.na(state)) %>%
    distinct() %>%
    group_by(npi, year) %>%
    slice(1L) %>%
    ungroup()

  ll_dur <- attribute_lead_lag_duration(
    source_a = nppes_panel_21_26,
    source_b = pecos_rev_panel,
    attribute = "state",
    base_year = 2021L,
    source_a_label = "NPPES",
    source_b_label = "PECOS"
  )

  n_dis_2021 <- ll_dur$disc_base_n
  n_b_adopts <- ll_dur$b_adopts$n
  n_a_reverts <- ll_dur$a_reverts$n
  n_resolved <- n_b_adopts + n_a_reverts
  lag_summary_rows <- tibble(
    analysis_type = c(
      "longitudinal_2021_2026_pecos_adopts_nppes_lag",
      "longitudinal_2021_2026_nppes_adopts_pecos_lag",
      "longitudinal_2021_2026_combined_lag_resolution"
    ),
    metric_detail = c(
      sprintf("PECOS adopts 2021 NPPES state (median %s yr, IQR %s-%s yr)", ll_dur$b_adopts$median, ll_dur$b_adopts$p25, ll_dur$b_adopts$p75),
      sprintf("NPPES adopts 2021 PECOS state (median %s yr, IQR %s-%s yr)", ll_dur$a_reverts$median, ll_dur$a_reverts$p25, ll_dur$a_reverts$p75),
      ll_dur$combined_text
    ),
    n_compared = rep(n_dis_2021, 3),
    n_zip5_inconsistent = c(n_dis_2021 - n_b_adopts, n_dis_2021 - n_a_reverts, n_dis_2021 - n_resolved),
    pct_zip5_inconsistent = round(100 * c(n_dis_2021 - n_b_adopts, n_dis_2021 - n_a_reverts, n_dis_2021 - n_resolved) / n_dis_2021, 2),
    n_zip5_agree = c(n_b_adopts, n_a_reverts, n_resolved),
    pct_zip5_agree = round(100 * c(n_b_adopts, n_a_reverts, n_resolved) / n_dis_2021, 2)
  )
}

oig_lag_check_tbl <- bind_rows(staleness_summary, lag_summary_rows)
cat("\n=== OIG Update-Lag & Record Staleness Check ===\n")
print(as.data.frame(oig_lag_check_tbl), row.names = FALSE)

# =============================================================================
# 7. Remake of OIG Tables 1 & 2 (Accuracy via Primary-Source Verification)
#    Using `attribute_verification_codebook()`, `attribute_verification_questionnaire()`,
#    `attribute_nonresponse_audit()`, `attribute_verification_status()`,
#    `listing_validity_design()`, `validity_estimates()`, & `validity_sensitivity_bounds()`
# =============================================================================
# In OIG Tables 1 & 2, OIG verified provider attributes and classified errors into:
#   - `partially_incorrect` (OIG: "Partially inaccurate [e.g., typo]")
#   - `formerly_correct`    (OIG: "Correct at one time, but no longer current")
#   - `never_correct`       (OIG: "Never correct")
#
# We execute primary-source verification across two authoritative gold standards:
#   Track 1: 7 Live State Boards of Nursing (CO, CT, FL, IL, PA, TX, WA; N = 3,855
#            midwife records audited against live state licensing registries).
#   Track 2: AMCB National Certification Board (`amcb_npi_linkage_FROZEN.csv`) +
#            NPPES Deactivation / PECOS Revocation across the overlap cohort,
#            evaluating legal name accuracy (`full_name`) and active status /
#            credential currency (`credential`).

bon_files <- c(
  CO = "artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv",
  CT = "artifacts/live_connecticut_bon_ingested_midwives_from_tracked_roster.csv",
  FL = "artifacts/live_florida_bon_ingested_midwives_from_tracked_roster.csv",
  IL = "artifacts/live_illinois_bon_ingested_midwives_from_tracked_roster.csv",
  PA = "artifacts/live_pennsylvania_bon_ingested_midwives_from_tracked_roster.csv",
  TX = "artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv",
  WA = "artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv"
)

bon_all <- bind_rows(lapply(names(bon_files), function(st) {
  f <- bon_files[[st]]
  if (!file.exists(f)) return(tibble())
  df <- read_csv(f, col_types = cols(.default = "c"), progress = FALSE)
  if (nrow(df) == 0L) return(tibble())
  df %>%
    transmute(
      bon_state = st,
      npi = trimws(npi),
      nppes_state = clean_state(nppes_state),
      live_bon_match_status = trimws(live_bon_match_status),
      live_bon_status = toupper(trimws(live_bon_status)),
      live_bon_zip = if ("live_bon_zip" %in% names(df)) norm_str_zip5(df$live_bon_zip) else NA_character_
    )
})) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  semi_join(cohort_active, by = "npi")
assert_one_row_per_key_pair(bon_all, "npi", "bon_state", "state BON ingest, per clinician per state")

# Classify each State BON record into OIG's verification codebook categories:
# Correction Priority 5: An administrative non-match ("UNMATCHED") in a state
# board lookup is classified as `unable_to_verify` (unresolved administrative
# non-match) rather than `never_correct`, reserving `formerly_correct` for
# records with affirmative evidence of an expired/inactive/retired license.
bon_classified <- bon_all %>%
  mutate(
    oig_answer = case_when(
      live_bon_match_status == "VERIFIED_LIVE_BON" &
        live_bon_status %in% c("ACTIVE", "ACTIVE IN RENEWAL", "CLEAR/ACTIVE", "CURRENT") ~ "correct",
      live_bon_match_status == "VERIFIED_LIVE_BON" &
        live_bon_status %in% c(
          "EXPIRED", "EXPIRED APPLICATION", "INACTIVE", "CLEAR/INACTIVE",
          "DECEASED/", "DECEASED", "DELINQUENT/", "NULL AND VOID/",
          "RETIRED/", "VOL RELINQUISH/", "NOT RENEWED", "SUSPENSION",
          "VOLUNTEER RETIRED", "INOPERABLE"
        ) ~ "formerly_correct",
      live_bon_match_status == "NOT_CNM_QUALIFIED" ~ "partially_incorrect",
      live_bon_match_status %in% c("UNMATCHED", "AMBIGUOUS") ~ "unable_to_verify",
      TRUE ~ "unable_to_verify"
    )
  )

# Run `mysteryroster` formal verification pipeline on the State BON sample:
bon_sample_npis <- unique(bon_classified$npi)
bon_sample_frame <- tibble(
  npi = bon_sample_npis,
  year = 2026L,
  stratum = "state_bon_audited_states",
  weight = 1.0,
  eligibility_status = "eligible"
)

bon_claims_nppes <- bon_classified %>%
  transmute(
    npi,
    year = 2026L,
    source = "nppes",
    attribute = "license_state",
    value = bon_state
  ) %>%
  distinct()

bon_questionnaire <- attribute_verification_questionnaire(
  sample = bon_sample_frame,
  claims = bon_claims_nppes
)

bon_answers <- bon_questionnaire %>%
  inner_join(
    bon_classified %>%
      filter(oig_answer != "unable_to_verify") %>%
      select(id = npi, value = bon_state, oig_answer),
    by = c("id", "value")
  ) %>%
  transmute(
    question_id,
    answer = oig_answer,
    verified_at = as.Date("2026-11-01"),
    respondent_role = "state_board_registry",
    verification_method = "license_registry"
  )

bon_contacts <- tibble(
  npi = bon_sample_npis,
  year = 2026L,
  contacted_at = as.Date("2026-11-01"),
  channel = "license_registry",
  outcome = base::ifelse(
    bon_sample_npis %in% bon_classified$npi[bon_classified$oig_answer != "unable_to_verify"],
    "reached", "no_answer"
  )
)

bon_nonresponse <- attribute_nonresponse_audit(
  sample = bon_sample_frame,
  questions = bon_questionnaire,
  answers = bon_answers,
  contacts = bon_contacts
)

bon_verif_status <- attribute_verification_status(
  audit = bon_nonresponse,
  targets = tibble(source = "nppes", attribute = "license_state"),
  independent_methods = "license_registry"
)

bon_design <- listing_validity_design(bon_verif_status$validity)
bon_est_definitive <- validity_estimates(bon_design, definitive_only = TRUE)
bon_bounds <- validity_sensitivity_bounds(bon_design, denominator = "all_sampled")

# Correction Priority 1 & Priority 5:
# State BON address ZIPs (CT, FL, IL, PA; N = 756) represent licensing/mailing
# addresses on file with state nursing boards, NOT verified clinical practice
# sites. We evaluate them separately as Licensing-Address Geographic Concordance
# and only classify a mismatch as `historical_mailing_or_prior_zip_match` when
# it matches the clinician's NPPES mailing ZIP5 or a prior panel ZIP.
bon_with_zip <- bon_classified %>%
  filter(!is.na(live_bon_zip), oig_answer %in% c("correct", "formerly_correct")) %>%
  left_join(
    all_claims %>%
      filter(year == 2026L, source == "nppes", attribute == "practice_zip5", !is.na(value)) %>%
      select(npi, nppes_zip5 = value),
    by = "npi"
  ) %>%
  left_join(
    all_claims %>%
      filter(year == 2026L, source == "nppes", attribute == "mailing_zip5", !is.na(value)) %>%
      select(npi, nppes_mailing_zip5 = value),
    by = "npi"
  ) %>%
  left_join(
    # Multi-site DAC clinicians genuinely carry >1 distinct practice_zip5
    # (confirmed: 955 cohort NPIs have 2-6 distinct DAC ZIP5s). Collapsing to
    # one arbitrary row before this join silently discarded the other real
    # sites, which could make a true BON match read as a mismatch purely
    # because the "wrong" DAC site got kept. Carry every distinct ZIP5 as a
    # pipe-joined set instead, so membership (not a single arbitrary value)
    # is what compute_bon_zip_decomposition() tests against.
    all_claims %>%
      filter(year == 2026L, source == "dac", attribute == "practice_zip5", !is.na(value)) %>%
      distinct(npi, value) %>%
      group_by(npi) %>%
      summarise(dac_zip5_set = paste(sort(unique(value)), collapse = "|"), .groups = "drop"),
    by = "npi"
  ) %>%
  left_join(
    # NPPES Practice Locations (PL): the main P-file's "practice_zip5" is only
    # NPPES's single primary business location; PL carries whatever
    # additional practice sites a clinician separately registered. Already
    # treated this way for the Table 4 comparison above
    # (`nppes_2026_plus_pl_zip`, labeled "practice_zip5_with_nppes_pl",
    # reported alongside -- not merged into -- plain "practice_zip5"). Same
    # convention here: nppes_plus_pl_zip5_set is its own labeled comparison
    # arm below, not a silent replacement of the single-value nppes_zip5 one.
    nppes_pl_2026 %>%
      transmute(npi = trimws(npi), pl_zip5 = norm_str_zip5(pl_zip5)) %>%
      filter(!is.na(pl_zip5)) %>%
      distinct(npi, pl_zip5) %>%
      group_by(npi) %>%
      summarise(nppes_pl_zip5_set = paste(sort(unique(pl_zip5)), collapse = "|"), .groups = "drop"),
    by = "npi"
  ) %>%
  rowwise() %>%
  mutate(
    nppes_plus_pl_zip5_set = paste(
      sort(unique(c(
        if (!is.na(nppes_zip5)) nppes_zip5 else character(0),
        if (!is.na(nppes_pl_zip5_set)) strsplit(nppes_pl_zip5_set, "\\|")[[1]] else character(0)
      ))),
      collapse = "|"
    ),
    nppes_plus_pl_zip5_set = ifelse(nzchar(nppes_plus_pl_zip5_set), nppes_plus_pl_zip5_set, NA_character_)
    # Verified during review: 0 of 12,160 cohort NPIs with a PL record have a
    # PL ZIP5 different from their main NPPES practice ZIP5 -- PL currently
    # mirrors the primary location for every midwife here rather than adding
    # a genuinely new site. The "NPPES + PL" comparison row below is
    # therefore expected to equal the plain "NPPES" row exactly; that is a
    # finding about this cohort's PL data, not a bug in this computation.
  ) %>%
  ungroup()

compute_bon_zip_decomposition <- function(df, prac_col, pair_label) {
  # prac_col names a column holding a pipe-joined SET of practice ZIP5s (a
  # singleton for sources like NPPES that only ever report one; genuinely
  # multi-valued for DAC). Matching tests membership in the set, never an
  # arbitrary single element of it.
  any_zip_in_set <- function(set_str, target) {
    mapply(function(s, t) {
      if (is.na(s) || is.na(t)) return(NA)
      t %in% strsplit(s, "\\|")[[1]]
    }, set_str, target)
  }
  any_scf3_in_set <- function(set_str, target) {
    mapply(function(s, t) {
      if (is.na(s) || is.na(t)) return(NA)
      substr(t, 1, 3) %in% substr(strsplit(s, "\\|")[[1]], 1, 3)
    }, set_str, target)
  }
  d <- df %>%
    mutate(
      prac_z = .data[[prac_col]],
      bon_z  = live_bon_zip,
      mail_z = nppes_mailing_zip5
    ) %>%
    filter(!is.na(prac_z), !is.na(bon_z)) %>%
    mutate(
      is_exact_prac = any_zip_in_set(prac_z, bon_z),
      is_same_scf3  = any_scf3_in_set(prac_z, bon_z),
      is_mail_match = (!is.na(mail_z) & mail_z == bon_z),
      # 5 Strictly Mutually Exclusive & Collectively Exhaustive Categories:
      cat1_exact_prac_zip5 = is_exact_prac,
      cat2_diff_prac_matches_mailing_same_scf3 = (!is_exact_prac & is_mail_match & is_same_scf3),
      cat3_diff_prac_matches_mailing_diff_scf3 = (!is_exact_prac & is_mail_match & !is_same_scf3),
      cat4_same_scf3_only_no_mailing_match     = (!is_exact_prac & !is_mail_match & is_same_scf3),
      cat5_unattributed_discordance_all_diff   = (!is_exact_prac & !is_mail_match & !is_same_scf3)
    )

  n_tot <- nrow(d)
  c1 <- sum(d$cat1_exact_prac_zip5)
  c2 <- sum(d$cat2_diff_prac_matches_mailing_same_scf3)
  c3 <- sum(d$cat3_diff_prac_matches_mailing_diff_scf3)
  c4 <- sum(d$cat4_same_scf3_only_no_mailing_match)
  c5 <- sum(d$cat5_unattributed_discordance_all_diff)
  stopifnot(c1 + c2 + c3 + c4 + c5 == n_tot)

  tibble(
    comparison_pair = pair_label,
    measure_classification = "Geographic Concordance (Not Practice-Site Gold Standard)",
    n_compared = n_tot,
    # Part A: 5 Mutually Exclusive Categories (Sum = n_compared / 100.00%)
    cat1_exact_practice_zip5_n = c1,
    cat1_exact_practice_zip5_pct = round(100 * c1 / n_tot, 2),
    cat2_diff_practice_matches_mailing_same_scf3_n = c2,
    cat2_diff_practice_matches_mailing_same_scf3_pct = round(100 * c2 / n_tot, 2),
    cat3_diff_practice_matches_mailing_diff_scf3_n = c3,
    cat3_diff_practice_matches_mailing_diff_scf3_pct = round(100 * c3 / n_tot, 2),
    cat4_same_scf3_only_no_mailing_match_n = c4,
    cat4_same_scf3_only_no_mailing_match_pct = round(100 * c4 / n_tot, 2),
    cat5_unattributed_zip5_and_scf3_discordant_n = c5,
    cat5_unattributed_zip5_and_scf3_discordant_pct = round(100 * c5 / n_tot, 2),
    mutually_exclusive_sum_n = c1 + c2 + c3 + c4 + c5,
    mutually_exclusive_sum_pct = round(100 * (c1 + c2 + c3 + c4 + c5) / n_tot, 2),
    # Part B: Separate Non-Mutually-Exclusive Marginal Indicators
    marginal_overlap_any_same_scf3_diff_practice_zip5_n = c2 + c4,
    marginal_overlap_any_same_scf3_diff_practice_zip5_pct = round(100 * (c2 + c4) / n_tot, 2),
    marginal_overlap_any_matches_nppes_mailing_zip5_diff_practice_n = c2 + c3,
    marginal_overlap_any_matches_nppes_mailing_zip5_diff_practice_pct = round(100 * (c2 + c3) / n_tot, 2),
    marginal_overlap_any_practice_or_mailing_zip5_match_n = c1 + c2 + c3,
    marginal_overlap_any_practice_or_mailing_zip5_match_pct = round(100 * (c1 + c2 + c3) / n_tot, 2),
    marginal_overlap_any_same_scf3_including_exact_zip5_n = c1 + c2 + c4,
    marginal_overlap_any_same_scf3_including_exact_zip5_pct = round(100 * (c1 + c2 + c4) / n_tot, 2)
  )
}

bon_zip_concordance_tbl <- bind_rows(
  compute_bon_zip_decomposition(
    bon_with_zip, "nppes_zip5",
    "NPPES Practice ZIP5 vs. State BON Licensing/Mailing ZIP5 (CT, FL, IL, PA)"
  ),
  compute_bon_zip_decomposition(
    bon_with_zip, "dac_zip5_set",
    "PECOS/DAC Practice ZIP5 vs. State BON Licensing/Mailing ZIP5 (CT, FL, IL, PA)"
  ),
  compute_bon_zip_decomposition(
    bon_with_zip, "nppes_plus_pl_zip5_set",
    "NPPES + Practice Locations (PL) vs. State BON Licensing/Mailing ZIP5 (CT, FL, IL, PA)"
  )
)

# Evaluate Name Accuracy & Enumeration-vs-Certification Decomposition across the
# full AMCB linkage cohort (`lnk_raw`) against 2026 NPPES and 2026 PECOS:
amcb_verif_base <- lnk_raw %>%
  filter(cohort_member == "TRUE", !is.na(npi), nzchar(trimws(npi))) %>%
  mutate(
    npi = trimws(npi),
    amcb_status = toupper(trimws(status)),
    amcb_full_name = norm_oig_name(first_name, last_name)
  )
assert_one_row_per_id(amcb_verif_base, "npi", "AMCB linkage cohort (cohort_member==TRUE)")

# pecos_enrl_2026 has >1 enrollment row for 1,215 cohort NPIs (multiple
# enrollment IDs), but every such NPI's rows carry an IDENTICAL legal name
# (verified empirically: 0 of 1,215 differ) -- so any row's name is the
# right one, and arrange() + slice(1) is a genuine reduction, not a
# silently-arbitrary pick, unlike distinct(npi, .keep_all = TRUE).
pecos_enrl_2026_names <- pecos_enrl_2026 %>%
  transmute(
    npi = trimws(npi),
    pecos_legal_name = norm_oig_name(first_name, last_name),
    pecos_last = toupper(gsub("[^A-Za-z]", "", trimws(last_name))),
    pecos_first = toupper(gsub("[^A-Za-z]", "", trimws(first_name)))
  ) %>%
  arrange(npi, pecos_legal_name) %>%
  group_by(npi) %>%
  slice(1L) %>%
  ungroup()

amcb_verif <- amcb_verif_base %>%
  left_join(
    nppes_2026 %>%
      transmute(
        npi = trimws(npi),
        nppes_legal_name = norm_oig_name(first_name, last_name),
        nppes_other_name = norm_oig_name(coalesce(other_first_name, first_name), other_last_name),
        nppes_last = toupper(gsub("[^A-Za-z]", "", trimws(last_name))),
        nppes_first = toupper(gsub("[^A-Za-z]", "", trimws(first_name))),
        nppes_deact = !is.na(deactivation_date) & nzchar(deactivation_date)
      ),
    by = "npi"
  ) %>%
  left_join(pecos_enrl_2026_names, by = "npi") %>%
  mutate(
    nppes_legal_name = coalesce(nppes_legal_name, norm_oig_name(nppes_first_name, nppes_last_name)),
    nppes_last = coalesce(nppes_last, toupper(gsub("[^A-Za-z]", "", trimws(nppes_last_name)))),
    nppes_first = coalesce(nppes_first, toupper(gsub("[^A-Za-z]", "", trimws(nppes_first_name)))),
    amcb_last = toupper(gsub("[^A-Za-z]", "", trimws(last_name))),
    amcb_first = toupper(gsub("[^A-Za-z]", "", trimws(first_name))),
    # Correction Priority 5: Require historical name-change or Other-Name evidence
    # before assigning `formerly_correct`; do not assign `never_correct` without evidence.
    nppes_name_oig = case_when(
      is.na(nppes_legal_name) ~ "unable_to_verify",
      nppes_legal_name == amcb_full_name ~ "correct",
      !is.na(nppes_other_name) & nppes_other_name == amcb_full_name ~ "formerly_correct",
      nppes_name_changed_since_match == "TRUE" ~ "formerly_correct",
      nppes_last == amcb_last | nppes_first == amcb_first ~ "partially_incorrect",
      TRUE ~ "unable_to_verify"
    ),
    pecos_name_oig = case_when(
      is.na(pecos_legal_name) ~ "not_applicable",
      pecos_legal_name == amcb_full_name ~ "correct",
      nppes_name_changed_since_match == "TRUE" ~ "formerly_correct",
      pecos_last == amcb_last | pecos_first == amcb_first ~ "partially_incorrect",
      TRUE ~ "unable_to_verify"
    )
  )

# Correction Priority 6 & Priority 5 Date/Deactivation Audit:
# Join `nppes_all_elig_2026` and `deact_all_elig_2026` across ALL 16,775 NPIs in `amcb_verif`
# (not just `cohort_active`) so that confirmed NPI deactivations in `nppes_deact_norm_v`
# and the Feb 2026 NPPES P-file are accurately attributed!
amcb_verif <- amcb_verif %>%
  left_join(
    nppes_all_elig_2026 %>%
      transmute(
        npi = trimws(npi),
        pfile_enum_date = enumeration_date,
        pfile_last_update_date = last_update_date,
        pfile_deact_date = deactivation_date,
        pfile_react_date = reactivation_date
      ),
    by = "npi"
  ) %>%
  left_join(deact_all_elig_2026, by = "npi") %>%
  mutate(
    in_feb2026_pfile = !is.na(pfile_enum_date) & nzchar(pfile_enum_date),
    has_pfile_deact = !is.na(pfile_deact_date) & nzchar(pfile_deact_date) & (is.na(pfile_react_date) | !nzchar(pfile_react_date)),
    has_deact_file  = !is.na(deact_file_date) & nzchar(deact_file_date),
    confirmed_deactivated_npi = coalesce(nppes_deact, FALSE) | has_pfile_deact | has_deact_file | !in_feb2026_pfile
  )

enum_cert_decomposition_tbl <- amcb_verif %>%
  mutate(
    nppes_enumeration_state = case_when(
      confirmed_deactivated_npi ~ "Confirmed Deactivated NPI in NPPES (`nppes_deact_norm_v` / Feb 2026 P-File)",
      TRUE ~ "Open / Active NPI Enumeration in Feb 2026 NPPES"
    ),
    amcb_certification_state = case_when(
      amcb_status == "ACTIVE" ~ "Active AMCB Certification",
      amcb_status %in% c("EXPIRED", "LAPSED", "RETIRED", "EMERITUS", "INACTIVE") ~ "Expired / Lapsed / Retired AMCB Certification",
      amcb_status %in% c("REVOKED", "SUSPENDED", "SURRENDERED") ~ "Revoked / Suspended / Surrendered AMCB Certification",
      amcb_status == "DECEASED" ~ "Deceased (AMCB Registry)",
      TRUE ~ paste0("Other AMCB Status (", amcb_status, ")")
    ),
    pecos_2026_enrollment_state = ifelse(
      !is.na(pecos_legal_name),
      "Enrolled in 2026 Q3 Medicare PECOS (Active Cohort Queried)",
      "Not in Active 2026 Q3 Medicare PECOS Cohort"
    )
  ) %>%
  count(amcb_certification_state, linkage_tier, nppes_enumeration_state, pecos_2026_enrollment_state, name = "n_clinicians") %>%
  mutate(
    pct_of_linkage_cohort = round(100 * n_clinicians / sum(n_clinicians), 2),
    methodological_interpretation = case_when(
      grepl("^Active AMCB", amcb_certification_state) & grepl("^Open", nppes_enumeration_state) ~
        "Active national certification & open federal NPI enumeration",
      grepl("^Expired", amcb_certification_state) & grepl("^Open", nppes_enumeration_state) ~
        "Lapsed/expired/retired AMCB certification with open NPI enumeration (not an NPPES accuracy error; NPIs are permanent identifiers and do not auto-deactivate upon certification lapse)",
      grepl("^Deceased", amcb_certification_state) & grepl("^Confirmed Deactivated", nppes_enumeration_state) ~
        "Deceased per AMCB AND confirmed deactivated in NPPES (89 of 91 [97.8%] primary-tier and 8 of 68 sensitivity-tier deceased midwives = 97 of 159 [61.0%] total)",
      grepl("^Deceased", amcb_certification_state) & grepl("^Open", nppes_enumeration_state) & linkage_tier == "primary_midwifery" ~
        "Deceased per AMCB with open NPI in primary midwifery tier (n=2 of 91 [2.2%]; AMCB lacks exact date of death; candidate for SSA Death Master File cross-check)",
      grepl("^Deceased", amcb_certification_state) & grepl("^Open", nppes_enumeration_state) & linkage_tier == "sensitivity_nursing" ~
        "Deceased per AMCB with open NPI in nursing-only sensitivity tier (n=60 of 68; either unrecorded NPI deactivation or common-name linkage to a living RN without midwifery taxonomy)",
      grepl("^Revoked", amcb_certification_state) & grepl("^Open", nppes_enumeration_state) ~
        "Revoked/suspended/surrendered certification with open NPI enumeration (requires credential/eligibility review if billing)",
      TRUE ~ "Confirmed deactivated NPI in NPPES across active/expired/revoked certification strata"
    )
  ) %>%
  arrange(desc(n_clinicians))

summarize_oig_table2_var <- function(vec, database_label, variable_label, verification_source) {
  v <- vec[!is.na(vec) & vec != "not_applicable"]
  n_eval <- length(v)
  n_unres <- sum(v == "unable_to_verify")
  n_def <- n_eval - n_unres
  n_corr <- sum(v == "correct")
  n_part <- sum(v == "partially_incorrect")
  n_form <- sum(v == "formerly_correct")
  n_nevr <- sum(v == "never_correct")
  n_inacc <- n_part + n_form + n_nevr
  tibble(
    database = database_label,
    variable = variable_label,
    verification_gold_standard = verification_source,
    n_evaluated = n_eval,
    n_definitive = n_def,
    n_unresolved = n_unres,
    n_accurate = n_corr,
    pct_accurate_definitive = round(100 * n_corr / max(1L, n_def), 2),
    n_inaccurate_total = n_inacc,
    pct_inaccurate_definitive = round(100 * n_inacc / max(1L, n_def), 2),
    n_partially_inaccurate_typo = n_part,
    pct_of_inaccurate_partially = ifelse(n_inacc > 0, round(100 * n_part / n_inacc, 1), 0),
    n_formerly_correct_outdated = n_form,
    pct_of_inaccurate_formerly = ifelse(n_inacc > 0, round(100 * n_form / n_inacc, 1), 0),
    n_never_correct = n_nevr,
    pct_of_inaccurate_never = ifelse(n_inacc > 0, round(100 * n_nevr / n_inacc, 1), 0)
  )
}

# PECOS enrolled midwives audited against State BONs
bon_pecos_vec <- bon_classified %>%
  semi_join(pecos_enrl_2026, by = "npi") %>%
  pull(oig_answer)

bon_genuine3_nppes_vec <- bon_classified %>%
  filter(bon_state %in% GENUINE_BOARD_STATES) %>%
  pull(oig_answer)

bon_genuine3_pecos_vec <- bon_classified %>%
  filter(bon_state %in% GENUINE_BOARD_STATES) %>%
  semi_join(pecos_enrl_2026, by = "npi") %>%
  pull(oig_answer)

oig_table2_vars <- bind_rows(
  summarize_oig_table2_var(bon_genuine3_nppes_vec, "NPPES (2026)", "State Licensure Status (3 API-Verified State BONs: CO, TX, WA)", "Live State Boards of Nursing (CO, TX, WA - GENUINE_BOARD_STATES)"),
  summarize_oig_table2_var(bon_genuine3_pecos_vec, "PECOS (2026)", "State Licensure Status (3 API-Verified State BONs: CO, TX, WA)", "Live State Boards of Nursing (CO, TX, WA - GENUINE_BOARD_STATES)"),
  summarize_oig_table2_var(bon_classified$oig_answer, "NPPES (2026)", "State Licensure Status & Qualification (All 7 State BON Files; Unmatched = Unresolved)", "Live State Boards of Nursing (CO, CT, FL, IL, PA, TX, WA)"),
  summarize_oig_table2_var(bon_pecos_vec, "PECOS (2026)", "State Licensure Status & Qualification (All 7 State BON Files; Unmatched = Unresolved)", "Live State Boards of Nursing (CO, CT, FL, IL, PA, TX, WA)"),
  summarize_oig_table2_var(amcb_verif$nppes_name_oig, "NPPES (2026)", "Legal Name (First & Last Name vs AMCB National Board; Historical Evidence Required)", "AMCB National Certification Roster"),
  summarize_oig_table2_var(amcb_verif$pecos_name_oig, "PECOS (2026)", "Legal Name (First & Last Name vs AMCB National Board; Historical Evidence Required)", "AMCB National Certification Roster")
)

# Summarize OIG Table 1 (Overall Accuracy & Design-Weighted Bounds via `mysteryroster`)
# Correction Priority 3: Present 2013 OIG figures strictly as historical physician-survey
# benchmarks with an explicit study_design_comparison_note column.
oig_table1_summary <- tibble(
  audit_track = c(
    "State BON License Verification (NPPES, 7 States, Design-Weighted via mysteryroster; Unmatched = Unresolved)",
    "State BON License Verification (NPPES, 3 API-Verified States: CO, TX, WA)",
    "State BON License Verification (PECOS-Enrolled Midwives, 7 States; Unmatched = Unresolved)",
    "AMCB Primary-Source Legal Name Verification (NPPES, Canonical Linkage Cohort N=16,775)",
    "AMCB Primary-Source Legal Name Verification (PECOS-Enrolled Overlap Cohort)"
  ),
  n_providers_audited = c(
    nrow(bon_verif_status$fields),
    length(bon_genuine3_nppes_vec),
    length(bon_pecos_vec),
    nrow(amcb_verif),
    sum(amcb_verif$pecos_name_oig != "not_applicable")
  ),
  n_definitive = c(
    bon_est_definitive$n,
    sum(bon_genuine3_nppes_vec != "unable_to_verify"),
    sum(bon_pecos_vec != "unable_to_verify"),
    sum(amcb_verif$nppes_name_oig != "unable_to_verify"),
    sum(amcb_verif$pecos_name_oig != "not_applicable" & amcb_verif$pecos_name_oig != "unable_to_verify")
  ),
  pct_accurate_point = c(
    round(100 * bon_est_definitive$estimate, 2),
    round(100 * mean(bon_genuine3_nppes_vec[bon_genuine3_nppes_vec != "unable_to_verify"] == "correct"), 2),
    round(100 * mean(bon_pecos_vec[bon_pecos_vec != "unable_to_verify"] == "correct"), 2),
    round(100 * mean(amcb_verif$nppes_name_oig[amcb_verif$nppes_name_oig != "unable_to_verify"] == "correct"), 2),
    round(100 * mean(amcb_verif$pecos_name_oig[amcb_verif$pecos_name_oig != "not_applicable" & amcb_verif$pecos_name_oig != "unable_to_verify"] == "correct"), 2)
  ),
  pct_inaccurate_point = round(100 - pct_accurate_point, 2),
  ci95_accurate_low = c(
    round(100 * bon_est_definitive$ci_low, 2),
    NA_real_, NA_real_, NA_real_, NA_real_
  ),
  ci95_accurate_high = c(
    round(100 * bon_est_definitive$ci_high, 2),
    NA_real_, NA_real_, NA_real_, NA_real_
  ),
  sensitivity_bound_worst_case_accurate_pct = c(
    round(bon_bounds$pct_valid[3], 2),
    round(100 * sum(bon_genuine3_nppes_vec == "correct") / length(bon_genuine3_nppes_vec), 2),
    round(100 * sum(bon_pecos_vec == "correct") / length(bon_pecos_vec), 2),
    round(100 * sum(amcb_verif$nppes_name_oig == "correct") / nrow(amcb_verif), 2),
    round(100 * sum(amcb_verif$pecos_name_oig == "correct") / sum(amcb_verif$pecos_name_oig != "not_applicable"), 2)
  ),
  sensitivity_bound_best_case_accurate_pct = c(
    round(bon_bounds$pct_valid[2], 2),
    round(100 * sum(bon_genuine3_nppes_vec %in% c("correct", "unable_to_verify")) / length(bon_genuine3_nppes_vec), 2),
    round(100 * sum(bon_pecos_vec %in% c("correct", "unable_to_verify")) / length(bon_pecos_vec), 2),
    round(100 * sum(amcb_verif$nppes_name_oig %in% c("correct", "unable_to_verify")) / nrow(amcb_verif), 2),
    round(100 * sum(amcb_verif$pecos_name_oig %in% c("correct", "unable_to_verify")) / sum(amcb_verif$pecos_name_oig != "not_applicable"), 2)
  ),
  oig_2013_historical_physician_survey_benchmark_pct = c(48.4, 48.4, 57.9, 48.4, 57.9),
  oig_2013_overlap_universe_n = rep(987266L, 5L),
  oig_2013_survey_sampled_n = rep(170L, 5L),
  oig_2013_survey_respondent_n = rep(126L, 5L),
  oig_2013_survey_nonrespondent_n = rep(44L, 5L),
  oig_2013_survey_response_rate_pct = rep(74.1, 5L),
  oig_2013_weighted_projected_n = rep(731738L, 5L),
  study_design_comparison_note = rep(
    "Historical 2013 OIG Medicare provider survey benchmark (OEI-07-09-00440: N_overlap=987,266; n_sampled=170; n_respondents=126 [74.1% response rate]; weighted projection N=731,738); not a directly comparable national CNM administrative accuracy estimate.",
    5L
  )
)

# Dedicated 2013 OIG Historical Denominator Reconciliation Table (Issue 4)
oig_2013_denominator_reconciliation_tbl <- tibble(
  oig_2013_report_stage = c(
    "1. NPPES Individual Provider Universe (Jan 2010; Report p. 10 & Table 3)",
    "2. PECOS Individual PAC ID Universe (Aug 2010; Report p. 10 fn 57)",
    "3. PECOS Individual Health Care Practitioner Completeness Frame (Aug 2010; Report p. 12 fn 66 & Table 3)",
    "4. NPPES n PECOS Overlap Consistency & Survey Sampling Frame (Report p. 10, p. 11 & Table 4)",
    "5. Online Provider Survey Simple Random Sample (Report p. 11 & Appendix A p. 31)",
    "6. Online Provider Survey Nonrespondents (Declined, Retired, or Incomplete; Appendix A p. 31)",
    "7. Online Provider Survey Completed Respondents & Variable-Specific Accuracy Denominator (Tables 1-2 & Appendix B Table B-1)",
    "8. Unadjusted Survey-Projected Medicare Provider Population (74.1% of 987,266; Report p. 12 & Tables 1-2)",
    "9. Inaccurate Data Elements Identified Within n=126 Survey Responses — NPPES (Report p. 18)",
    "10. Inaccurate Data Elements Identified Within n=126 Survey Responses — PECOS (Report p. 19)"
  ),
  oig_2013_denominator_n = c(
    2313183L, 1211520L, 1021652L, 987266L, 170L, 44L, 126L, 731738L, 96L, 106L
  ),
  oig_2013_rate_or_composition = c(
    "90.7% complete all variables; 9.3% (214,399) null conditionally required license/SSN",
    "Includes 1,021,652 practitioners + 189,868 authorized/delegated organizational officials",
    "3.7% (37,443) incomplete required variables; practice address excluded due to group reassignment (818,015 missing individual address rows)",
    "97.4% (961,634) inconsistent on >=1 variable; 88.6% (874,401) practice ZIP inconsistent",
    "Simple random sample drawn from the 987,266 NPPES n PECOS overlap universe",
    "25.9% (44 / 170) nonresponse; not adjusted for in OIG population projections",
    "74.1% (126 / 170) response rate; all 10 accuracy variables in Appendix B Table B-1 evaluated on n=126 respondents",
    "48.4% (95% CI 39.7%-57.2%) inaccurate in NPPES; 57.9% (95% CI 49.1%-66.3%) inaccurate in PECOS",
    "51 (53%) outdated/formerly correct, 18 (19%) partially inaccurate, 27 (28%) never correct",
    "60 (57%) outdated/formerly correct, 25 (24%) partially inaccurate, 21 (20%) never correct"
  ),
  midwifery_remake_counterpart = c(
    "2026 Full NPPES Active Canonical CNM Cohort (N = 12,170; 100.0% required-field completeness)",
    "All NPI-Linked AMCB Midwifery Universe (N = 16,775 across active/expired/deceased certification strata)",
    "2019 Relational PECOS CNM Cohort (N = 5,897; 0.44% [26] direct address vs 95.69% [5,643] after group reassignment linkage)",
    "2019 NPPES n PECOS (N = 5,896; 32.16% inconsistent) & 2026 NPPES n DAC (N = 5,817; 72.89% inconsistent)",
    "7-State Live BON Administrative Audit Frame (N = 3,190 CNMs) & 3 API-Verified States (CO, TX, WA: N = 1,391)",
    "Unresolved Administrative Registry Non-Matches (N = 1,252 across 7 states; N = 165 across CO, TX, WA)",
    "Definitive Registry Matches: n = 1,938 (60.8% linkage rate across 7 states; 92.57% valid) & n = 1,226 (88.1% in CO, TX, WA; 94.05% valid)",
    "Sensitivity Bounds Across Full Audited Frame: 56.24%-95.49% (7 states) & 82.89%-94.75% (CO, TX, WA)",
    "NPPES 7-State BON Errors (n = 144): 135 (93.8%) formerly correct/expired, 9 (6.2%) partially incorrect, 0 (0.0%) never correct",
    "PECOS 7-State BON Errors (n = 51): 47 (92.2%) formerly correct/expired, 4 (7.8%) partially incorrect, 0 (0.0%) never correct"
  )
)

cat("\n=== OIG Table 1 Remake: Overall Accuracy & Sensitivity Bounds ===\n")
print(as.data.frame(oig_table1_summary), row.names = FALSE)

cat("\n=== OIG Table 2 Remake: Inaccuracy Subtypes by Variable ===\n")
print(as.data.frame(oig_table2_vars), row.names = FALSE)

cat("\n=== Priority 1 & Issue 1 Correction: State BON Licensing-Address Geographic Concordance (Mutually Exclusive + Marginal Overlap) ===\n")
print(as.data.frame(bon_zip_concordance_tbl), row.names = FALSE)

cat("\n=== Priority 6 Correction: NPI Enumeration vs AMCB Certification Currency Decomposition ===\n")
print(as.data.frame(enum_cert_decomposition_tbl), row.names = FALSE)

# =============================================================================
# 8. T-MSIS Medicaid Validation Extension (2018-2024) & Proposed Figure 6
#    - Analysis A: Three-way state concordance (NPPES, PECOS/DAC, T-MSIS)
#    - Analysis B: Medicaid enrollment and practice-location transitions
#    - Analysis C: Medicare-vs-Medicaid participation completeness
#    - Issue 3 Audit: Medicare PECOS vs. DAC Source-Vintage Decomposition (2016-2026)
# =============================================================================
tmsis_years <- 2018:2024
cohort_npis_vec <- cohort_active$npi
n_cohort_total <- length(cohort_npis_vec)

# 1. NPPES annual state claims (2018-2024) from `midwife_panel.csv`
nppes_18_24 <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(
    npi = trimws(npi),
    year = as.integer(snapshot_year),
    state = clean_state(practice_state)
  ) %>%
  filter(npi %in% cohort_npis_vec, year %in% tmsis_years, !is.na(state), nzchar(state)) %>%
  distinct(npi, year, state)

# 2. PECOS / DAC annual state claims (2018-2024):
#    Issue 3 Fix: Include 2018 relational PECOS (`pecos_ppef_16_18` from `main.ppef_enrol_2018` +
#    `main.ppef_addr_2018`), 2019 relational PECOS (`pecos_2019_st`), 2021-2024 PECOS revalidation
#    (`pecos_rev_18_24`), and 2018-2024 Physician Compare / DAC (`dac_18_24`), while tracking
#    PECOS-enrollment vs. public-DAC source availability separately by year!
pecos_rev_all_years <- if (file.exists("artifacts/pecos_revalidation_cohort_state_by_year.csv")) {
  read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
    filter(npi %in% cohort_npis_vec, !is.na(state), nzchar(state)) %>%
    distinct(npi, year, state)
} else {
  tibble(npi = character(), year = integer(), state = character())
}

pecos_rev_18_24 <- pecos_rev_all_years %>% filter(year %in% tmsis_years)

pecos_2019_st <- all_claims %>%
  filter(year == 2019L, source == "pecos", attribute == "practice_state", !is.na(value)) %>%
  transmute(npi, year = 2019L, state = value) %>%
  distinct(npi, year, state)

pecos_2018_st <- pecos_ppef_16_18 %>%
  filter(year == 2018L) %>%
  distinct(npi, year, state)

pecos_enrol_only_18_24 <- bind_rows(pecos_2018_st, pecos_2019_st, pecos_rev_18_24) %>%
  distinct(npi, year, state)

dac_all_years <- if (file.exists("artifacts/physician_compare_historical_midwives.csv")) {
  read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state)) %>%
    filter(npi %in% cohort_npis_vec, !is.na(state), nzchar(state)) %>%
    distinct(npi, year, state)
} else {
  tibble(npi = character(), year = integer(), state = character())
}

dac_18_24 <- dac_all_years %>% filter(year %in% tmsis_years)

pecos_dac_18_24 <- bind_rows(pecos_enrol_only_18_24, dac_18_24) %>%
  distinct(npi, year, state)

# Build dedicated Source-Vintage Audit Table (2016-2026) for Issue 3
pecos_enrol_16_26 <- bind_rows(
  pecos_ppef_16_18,
  pecos_2019_st,
  pecos_rev_all_years
) %>%
  distinct(npi, year, state)

dac_2026_st <- all_claims %>%
  filter(year == 2026L, source == "dac", attribute == "practice_state", !is.na(value)) %>%
  transmute(npi, year = 2026L, state = value) %>%
  distinct(npi, year, state)

dac_16_26 <- bind_rows(
  dac_all_years %>% filter(year >= 2016L, year <= 2025L),
  dac_2026_st
) %>%
  distinct(npi, year, state)

medicare_source_vintage_audit_tbl <- tibble(year = 2016:2026) %>%
  rowwise() %>%
  mutate(
    n_cohort_denominator = n_cohort_total,
    n_pecos_enrollment_extract = n_distinct(pecos_enrol_16_26$npi[pecos_enrol_16_26$year == year]),
    pct_pecos_enrollment_extract = ifelse(
      year == 2020L,
      NA_real_,
      round(100 * n_pecos_enrollment_extract / n_cohort_total, 2)
    ),
    n_dac_public_directory = n_distinct(dac_16_26$npi[dac_16_26$year == year]),
    pct_dac_public_directory = round(100 * n_dac_public_directory / n_cohort_total, 2),
    n_combined_pecos_or_dac = n_distinct(c(
      pecos_enrol_16_26$npi[pecos_enrol_16_26$year == year],
      dac_16_26$npi[dac_16_26$year == year]
    )),
    pct_combined_pecos_or_dac = round(100 * n_combined_pecos_or_dac / n_cohort_total, 2),
    pecos_extract_vintage_source = case_when(
      year %in% 2016:2019 ~ sprintf("DuckDB main.ppef_enrol_%d + main.ppef_addr_%d (4-table relational PECOS)", year, year),
      year == 2020L ~ "NOT_IN_WAREHOUSE (No 2020 PECOS PPEF/Revalidation snapshot archived; 2020 combined series is DAC-only)",
      year %in% 2021:2026 ~ "artifacts/pecos_revalidation_cohort_state_by_year.csv (PECOS Enrollment/Revalidation extract)"
    ),
    dac_extract_vintage_source = case_when(
      year %in% 2016:2025 ~ sprintf("artifacts/physician_compare_historical_midwives.csv (%d vintage releases)", year),
      year == 2026L ~ "dac_midwives.csv + DuckDB DAC National Downloadable File"
    ),
    discontinuity_diagnosis = case_when(
      year == 2018L ~ "FIXED: Prior 22.65% reflected DAC-only because main.ppef_enrol_2018 was omitted; adding main.ppef_enrol_2018 restores 46.84% combined (46.09% PECOS alone).",
      year == 2020L ~ "SOURCE-VINTAGE GAP: No 2020 PECOS enrollment extract exists in warehouse; 24.82% reflects public Physician Compare/DAC alone (which is smooth across 2018-2023: 22.74%-31.21%).",
      TRUE ~ "Complete PECOS Enrollment + Public Physician Compare/DAC coverage."
    )
  ) %>%
  ungroup()

# 3. T-MSIS Medicaid Provider Enrollment Segments (2018-2024; 2024 preliminary)
tmsis_18_24 <- read_csv("artifacts/tmsis_medicaid_enrollment_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state)) %>%
  filter(npi %in% cohort_npis_vec, year %in% tmsis_years, !is.na(state), nzchar(state)) %>%
  distinct(npi, year, state)

# Collapse state sets per (npi, year) for each source to preserve multi-state enrollments
collapse_state_set <- function(df, col_prefix) {
  df %>%
    arrange(npi, year, state) %>%
    group_by(npi, year) %>%
    summarise(
      !!paste0(col_prefix, "_set") := paste(unique(state), collapse = "|"),
      !!paste0(col_prefix, "_n_states") := n_distinct(state),
      .groups = "drop"
    )
}

grid_18_24 <- expand_grid(npi = cohort_npis_vec, year = tmsis_years) %>%
  left_join(collapse_state_set(nppes_18_24, "nppes"), by = c("npi", "year")) %>%
  left_join(collapse_state_set(pecos_dac_18_24, "pecos"), by = c("npi", "year")) %>%
  left_join(collapse_state_set(pecos_enrol_only_18_24, "pecos_enrol_only"), by = c("npi", "year")) %>%
  left_join(collapse_state_set(dac_18_24, "dac_only"), by = c("npi", "year")) %>%
  left_join(collapse_state_set(tmsis_18_24, "tmsis"), by = c("npi", "year"))

has_shared_state <- function(set1, set2) {
  mapply(function(a, b) {
    if (is.na(a) || is.na(b)) return(FALSE)
    length(intersect(strsplit(a, "\\|")[[1]], strsplit(b, "\\|")[[1]])) > 0L
  }, set1, set2, USE.NAMES = FALSE)
}

has_common_all3 <- function(set1, set2, set3) {
  mapply(function(a, b, c) {
    if (is.na(a) || is.na(b) || is.na(c)) return(FALSE)
    length(Reduce(intersect, list(
      strsplit(a, "\\|")[[1]],
      strsplit(b, "\\|")[[1]],
      strsplit(c, "\\|")[[1]]
    ))) > 0L
  }, set1, set2, set3, USE.NAMES = FALSE)
}

# Issue 2 Fix: Use neutral, mechanism-agnostic cross-source state concordance labels
# without presuming which source is lagging or clinically correct.
grid_18_24 <- grid_18_24 %>%
  mutate(
    nppes_present = !is.na(nppes_set),
    pecos_present = !is.na(pecos_set),
    pecos_enrol_present = !is.na(pecos_enrol_only_set),
    dac_only_present = !is.na(dac_only_set),
    tmsis_present = !is.na(tmsis_set),
    n_sources_present = as.integer(nppes_present) + as.integer(pecos_present) + as.integer(tmsis_present),
    ab_match = has_shared_state(nppes_set, pecos_set),
    ac_match = has_shared_state(nppes_set, tmsis_set),
    bc_match = has_shared_state(pecos_set, tmsis_set),
    abc_match = has_common_all3(nppes_set, pecos_set, tmsis_set),
    concordance_category = case_when(
      n_sources_present == 3L & abc_match ~ "All 3 Sources Present & All 3 Agree on State",
      n_sources_present == 3L & ab_match & !ac_match & !bc_match ~ "All 3 Present: NPPES & PECOS/DAC Agree, T-MSIS Differs (e.g., Cross-Border Medicaid Enrollment)",
      n_sources_present == 3L & ac_match & !ab_match & !bc_match ~ "All 3 Present: NPPES & T-MSIS Agree, PECOS/DAC State Differs (Cross-Source State Divergence)",
      n_sources_present == 3L & bc_match & !ab_match & !ac_match ~ "All 3 Present: PECOS/DAC & T-MSIS Agree, NPPES State Differs (Cross-Source State Divergence)",
      n_sources_present == 3L & (ab_match + ac_match + bc_match >= 2L) & !abc_match ~ "All 3 Present: Multi-State Pairwise Overlap Without Single Common State",
      n_sources_present == 3L ~ "All 3 Sources Present & All 3 Differ",
      n_sources_present == 2L & nppes_present & pecos_present & ab_match ~ "2 Sources Present (NPPES + PECOS/DAC, No T-MSIS): Agree",
      n_sources_present == 2L & nppes_present & pecos_present & !ab_match ~ "2 Sources Present (NPPES + PECOS/DAC, No T-MSIS): Differ",
      n_sources_present == 2L & nppes_present & tmsis_present & ac_match ~ "2 Sources Present (NPPES + T-MSIS, Missing from Medicare PECOS/DAC): Agree",
      n_sources_present == 2L & nppes_present & tmsis_present & !ac_match ~ "2 Sources Present (NPPES + T-MSIS, Missing from Medicare PECOS/DAC): Differ",
      n_sources_present == 2L & pecos_present & tmsis_present & bc_match ~ "2 Sources Present (PECOS/DAC + T-MSIS, No NPPES): Agree",
      n_sources_present == 2L & pecos_present & tmsis_present & !bc_match ~ "2 Sources Present (PECOS/DAC + T-MSIS, No NPPES): Differ",
      n_sources_present == 1L & nppes_present ~ "1 Source Only: NPPES Only",
      n_sources_present == 1L & pecos_present ~ "1 Source Only: PECOS/DAC Only",
      n_sources_present == 1L & tmsis_present ~ "1 Source Only: T-MSIS Only",
      TRUE ~ "0 Sources Observed in Year (Pre-Enumeration or Inactive Year)"
    )
  )

# Analysis A & Figure 6 Panel B: Three-way state concordance table (by year, pooled 2018-2024, and PECOS-complete years)
tmsis_three_way_by_year <- grid_18_24 %>%
  count(year, concordance_category, name = "n_clinician_years") %>%
  group_by(year) %>%
  mutate(
    pct_of_cohort = round(100 * n_clinician_years / sum(n_clinician_years), 2),
    n_all3_in_year = sum(n_clinician_years[grepl("^All 3", concordance_category)]),
    pct_of_all3_present = ifelse(
      grepl("^All 3", concordance_category) & n_all3_in_year > 0,
      round(100 * n_clinician_years / n_all3_in_year, 2),
      NA_real_
    ),
    preliminary_flag = case_when(
      year == 2020L ~ "2020 Medicare is DAC-only (no 2020 PECOS PPEF extract in warehouse)",
      year == 2024L ~ "2024 T-MSIS observations preliminary",
      TRUE ~ "Complete annual PECOS + DAC + T-MSIS window"
    )
  ) %>%
  ungroup() %>%
  mutate(year_label = as.character(year))

tmsis_three_way_pooled <- grid_18_24 %>%
  count(concordance_category, name = "n_clinician_years") %>%
  mutate(
    year = NA_integer_,
    year_label = "Pooled 2018-2024",
    pct_of_cohort = round(100 * n_clinician_years / sum(n_clinician_years), 2),
    n_all3_in_year = sum(n_clinician_years[grepl("^All 3", concordance_category)]),
    pct_of_all3_present = ifelse(
      grepl("^All 3", concordance_category) & n_all3_in_year > 0,
      round(100 * n_clinician_years / n_all3_in_year, 2),
      NA_real_
    ),
    preliminary_flag = "Includes DAC-only 2020 and preliminary 2024 T-MSIS"
  )

tmsis_three_way_pecos_complete <- grid_18_24 %>%
  filter(year != 2020L) %>%
  count(concordance_category, name = "n_clinician_years") %>%
  mutate(
    year = NA_integer_,
    year_label = "Pooled PECOS-Complete Years (2018-2019 & 2021-2024)",
    pct_of_cohort = round(100 * n_clinician_years / sum(n_clinician_years), 2),
    n_all3_in_year = sum(n_clinician_years[grepl("^All 3", concordance_category)]),
    pct_of_all3_present = ifelse(
      grepl("^All 3", concordance_category) & n_all3_in_year > 0,
      round(100 * n_clinician_years / n_all3_in_year, 2),
      NA_real_
    ),
    preliminary_flag = "Excludes DAC-only 2020; includes preliminary 2024 T-MSIS"
  )

oig_tmsis_three_way_tbl <- bind_rows(
  tmsis_three_way_by_year,
  tmsis_three_way_pooled,
  tmsis_three_way_pecos_complete
) %>%
  select(year_label, concordance_category, n_clinician_years, pct_of_cohort, pct_of_all3_present, preliminary_flag)

# Analysis C & Figure 6 Panel A: Coverage over time + Medicare-vs-Medicaid participation completeness
oig_tmsis_participation_tbl <- grid_18_24 %>%
  group_by(year) %>%
  summarise(
    n_cohort_denominator = n(),
    n_nppes_observed = sum(nppes_present),
    pct_nppes_coverage = round(100 * mean(nppes_present), 2),
    n_pecos_enrol_extract_observed = ifelse(first(year) == 2020L, NA_integer_, sum(pecos_enrol_present)),
    pct_pecos_enrol_extract_coverage = ifelse(first(year) == 2020L, NA_real_, round(100 * mean(pecos_enrol_present), 2)),
    n_dac_public_observed = sum(dac_only_present),
    pct_dac_public_coverage = round(100 * mean(dac_only_present), 2),
    n_pecos_dac_observed = sum(pecos_present),
    pct_pecos_dac_coverage = round(100 * mean(pecos_present), 2),
    n_tmsis_observed = sum(tmsis_present),
    pct_tmsis_coverage = round(100 * mean(tmsis_present), 2),
    n_all_three_sources = sum(n_sources_present == 3L),
    pct_all_three_sources = round(100 * mean(n_sources_present == 3L), 2),
    n_in_nppes_and_tmsis_missing_medicare = sum(nppes_present & tmsis_present & !pecos_present),
    pct_of_cohort_nppes_tmsis_missing_medicare = round(100 * mean(nppes_present & tmsis_present & !pecos_present), 2),
    pct_of_tmsis_missing_medicare = round(100 * sum(nppes_present & tmsis_present & !pecos_present) / max(1L, sum(tmsis_present)), 2),
    n_in_nppes_and_medicare_missing_tmsis = sum(nppes_present & pecos_present & !tmsis_present),
    pct_of_cohort_nppes_medicare_missing_tmsis = round(100 * mean(nppes_present & pecos_present & !tmsis_present), 2),
    medicare_source_vintage_note = case_when(
      first(year) %in% c(2018L, 2019L) ~ sprintf("DuckDB ppef_enrol_%d + ppef_addr_%d + Physician Compare/DAC", first(year), first(year)),
      first(year) == 2020L ~ "DAC-only observation year (no 2020 PECOS PPEF extract in warehouse; do not interpret 2020 dip as Medicare disenrollment)",
      first(year) %in% 2021L:2023L ~ "PECOS Revalidation extract + Physician Compare/DAC",
      first(year) == 2024L ~ "PECOS Revalidation extract + Physician Compare/DAC (2024 T-MSIS preliminary)"
    ),
    .groups = "drop"
  )

# Analysis B & Figure 6 Panel C: Longitudinal Medicaid enrollment & practice-location transitions
# Issue 2 Fix: Do not assert that earlier Medicaid enrollment proves NPPES lag; describe as
# pre-existing or earlier destination-state Medicaid enrollment.
oig_tmsis_transitions_tbl <- read_csv("artifacts/address_lead_lag_medicaid_nppes_moves.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(
    direction_type = trimws(direction_type),
    transition_timing_category = trimws(category),
    n_transitions = as.integer(n),
    total_matched_moves = as.integer(total_matched_moves),
    pct_of_matched_moves = as.numeric(pct_of_matched),
    scientific_interpretation = case_when(
      direction_type == "destination_arrival_timing" & grepl("^Same calendar year", category) ~
        "Coincident destination-state observation (0-yr lag; administrative corroboration of state change, not standalone proof of physical clinic relocation)",
      direction_type == "destination_arrival_timing" & grepl("^Medicaid led", category) ~
        "Pre-existing or earlier destination-state Medicaid enrollment (clinician held destination-state Medicaid enrollment 1 to >=3 yr before NPPES state change; reflects multi-state/border enrollment or credentialing prior to NPPES change, not standalone proof of NPPES update lag)",
      direction_type == "destination_arrival_timing" & grepl("^NPPES led", category) ~
        "NPPES practice-state change preceded T-MSIS Medicaid enrollment (subsequent Medicaid enrollment in destination state)",
      direction_type == "origin_departure_termination_timing" & grepl("AFTER", category) ~
        "Origin-state Medicaid enrollment remained open after NPPES state change (persistent multi-state enrollment or open administrative segment)",
      TRUE ~ "Origin-state Medicaid enrollment terminated before or during NPPES move year"
    )
  )

cat("\n=== Issue 3 Audit: Medicare Coverage Source-Vintage Decomposition (2016-2026) ===\n")
print(as.data.frame(medicare_source_vintage_audit_tbl), row.names = FALSE)

cat("\n=== Issue 4 Audit: 2013 OIG Historical Denominator Reconciliation ===\n")
print(as.data.frame(oig_2013_denominator_reconciliation_tbl), row.names = FALSE)

cat("\n=== T-MSIS Analysis A & Figure 6 Panel B: Three-Way State Concordance (Pooled 2018-2024 & PECOS-Complete Years) ===\n")
print(as.data.frame(oig_tmsis_three_way_tbl %>% filter(grepl("^Pooled", year_label))), row.names = FALSE)

cat("\n=== T-MSIS Analysis C & Figure 6 Panel A: Coverage & Medicare-vs-Medicaid Participation (2018-2024) ===\n")
print(as.data.frame(oig_tmsis_participation_tbl), row.names = FALSE)

cat("\n=== T-MSIS Analysis B & Figure 6 Panel C: Longitudinal Transitions & Enrollment Timing ===\n")
print(as.data.frame(oig_tmsis_transitions_tbl), row.names = FALSE)

# =============================================================================
# 9. Generate Automated OIG Manuscript Prose (`attribute_oig_audit_prose()`)
#    and Self-Contained Package HTML Report (`attribute_oig_audit_html()`)
#    Correction Priority 4: Pass `provider_noun = "nurse-midwife"` and
#    `verification_mode = "administrative_registry"`.
# =============================================================================
prose_2019_zip_direct <- attribute_oig_audit_prose(
  record_presence = record_presence,
  set_agreement_summary = res_2019_pecos[[which(attrs_2019_pecos == "practice_zip5_direct")]]$summary,
  year = 2019L,
  source_a = "nppes",
  source_b = "pecos",
  attribute = "practice_zip5_direct",
  attribute_label = "direct-enrollment practice location ZIP codes",
  linkage = pecos_linkage_2019$links,
  provider_noun = "nurse-midwife",
  verification_mode = "administrative_registry"
)

prose_2019_zip_reassigned <- attribute_oig_audit_prose(
  record_presence = record_presence,
  set_agreement_summary = res_2019_pecos[[which(attrs_2019_pecos == "practice_zip5")]]$summary,
  year = 2019L,
  source_a = "nppes",
  source_b = "pecos",
  attribute = "practice_zip5",
  attribute_label = "practice location ZIP codes (including group reassignments)",
  linkage = pecos_linkage_2019$links,
  provider_noun = "nurse-midwife",
  verification_mode = "administrative_registry"
)

prose_2026_zip_dac <- attribute_oig_audit_prose(
  record_presence = record_presence,
  set_agreement_summary = res_2026_dac[[which(attrs_2026_dac == "practice_zip5")]]$summary,
  year = 2026L,
  source_a = "nppes",
  source_b = "dac",
  attribute = "practice_zip5",
  attribute_label = "practice location ZIP codes",
  nonresponse = bon_nonresponse,
  provider_noun = "nurse-midwife",
  verification_mode = "administrative_registry"
)

prose_2026_phone_dac <- attribute_oig_audit_prose(
  record_presence = record_presence,
  set_agreement_summary = res_2026_dac[[which(attrs_2026_dac == "phone10")]]$summary,
  year = 2026L,
  source_a = "nppes",
  source_b = "dac",
  attribute = "phone10",
  attribute_label = "practice telephone numbers",
  provider_noun = "nurse-midwife",
  verification_mode = "administrative_registry"
)

# Also invoke the new exported `mysteryroster::attribute_oig_audit_html()` function:
pkg_html_2019 <- attribute_oig_audit_html(
  record_presence = record_presence,
  set_agreement_summary = res_2019_pecos[[which(attrs_2019_pecos == "practice_zip5")]]$summary,
  year = 2019L,
  source_a = "nppes",
  source_b = "pecos",
  attribute = "practice_zip5",
  attribute_label = "practice location ZIP codes (including group reassignments)",
  linkage = pecos_linkage_2019$links,
  provider_noun = "nurse-midwife",
  verification_mode = "administrative_registry",
  lead_lag = if (exists("ll_dur")) ll_dur else NULL,
  title = "HHS OIG OEI-07-09-00440 Remake: 2019 NPPES vs. Relational PECOS Nurse-Midwife Audit",
  file = file.path(OUT_DIR, "oig_2019_nppes_vs_pecos_mysteryroster_report.html")
)

pkg_html_2026 <- attribute_oig_audit_html(
  record_presence = record_presence,
  set_agreement_summary = res_2026_dac[[which(attrs_2026_dac == "practice_zip5")]]$summary,
  year = 2026L,
  source_a = "nppes",
  source_b = "dac",
  attribute = "practice_zip5",
  attribute_label = "practice location ZIP codes",
  nonresponse = bon_nonresponse,
  provider_noun = "nurse-midwife",
  verification_mode = "administrative_registry",
  validity_estimate = bon_est_definitive,
  validity_bounds = bon_bounds,
  lead_lag = if (exists("ll_dur")) ll_dur else NULL,
  title = "HHS OIG OEI-07-09-00440 Remake: 2026 NPPES vs. PECOS/DAC Nurse-Midwife Audit",
  file = file.path(OUT_DIR, "oig_2026_nppes_vs_dac_mysteryroster_report.html")
)

prose_tbl <- tibble(
  section = c(
    "2019_nppes_vs_pecos_direct_practice_zip5",
    "2019_nppes_vs_pecos_reassignment_linked_practice_zip5",
    "2026_nppes_vs_pecos_dac_practice_zip5_with_bon_verification",
    "2026_nppes_vs_pecos_dac_telephone_number"
  ),
  oig_manuscript_prose = c(
    prose_2019_zip_direct,
    prose_2019_zip_reassigned,
    prose_2026_zip_dac,
    prose_2026_phone_dac
  )
)

cat("\n=== Automated OIG Audit Narrative Prose (`attribute_oig_audit_prose()`) ===\n")
for (i in seq_len(nrow(prose_tbl))) {
  cat(sprintf("\n[%s]\n%s\n", prose_tbl$section[i], prose_tbl$oig_manuscript_prose[i]))
}

# =============================================================================
# 9B. Clinical Meaning & Location-Specificity Audit of 2019 PECOS Locations
#     (Priorities 1, 2, 3, 4, 5 & Rebuilt Figure 2 Evidence Funnel)
# =============================================================================
nppes_2019_st_zip <- nppes_2019 %>%
  transmute(
    npi = trimws(npi),
    nppes_state_2019 = clean_state(practice_state),
    nppes_zip5_2019 = norm_str_zip5(practice_zip)
  )
assert_one_row_per_id(nppes_2019_st_zip, "npi", "2019 NPPES state/ZIP5")

pecos_addr_raw_clean <- pecos_addr_2019 %>%
  mutate(
    addr_row_id = row_number(),
    zip5 = norm_pecos_bigint_zip5(zip_cd),
    state = clean_state(state_cdstr),
    city = toupper(trimws(city_name))
  )

enrl_dedup_2019 <- pecos_enrl_2019 %>% distinct(npi, enrlmt_id)
assert_one_row_per_key_pair(enrl_dedup_2019, "npi", "enrlmt_id", "2019 PECOS individual enrollment")
reass_dedup_2019 <- pecos_reassign_2019 %>% distinct(npi, reasgn_bnft_enrlmt_id, rcv_bnft_enrlmt_id)

direct_join_2019 <- enrl_dedup_2019 %>%
  inner_join(pecos_addr_raw_clean, by = "enrlmt_id", relationship = "many-to-many")

group_join_raw_2019 <- enrl_dedup_2019 %>%
  inner_join(reass_dedup_2019, by = c("npi", "enrlmt_id" = "reasgn_bnft_enrlmt_id"), relationship = "many-to-many") %>%
  inner_join(pecos_addr_raw_clean, by = c("rcv_bnft_enrlmt_id" = "enrlmt_id"), relationship = "many-to-many") %>%
  left_join(nppes_2019_st_zip, by = "npi")

dist_npi_zip_2019 <- group_join_raw_2019 %>%
  filter(!is.na(zip5)) %>%
  distinct(npi, zip5, state, nppes_state_2019, nppes_zip5_2019)

# Priority 1: Join-Cardinality & Duplication Audit of the 184,694 Group-Reassignment Rows
pecos_2019_cardinality_audit_tbl <- tibble(
  decomposition_step = c(
    "1. Raw relational join rows (indiv_enrlmt_id x rcv_bnft_enrlmt_id x raw ppef_addr_2019 row)",
    "2. Deduplicated across multiple individual enrlmt_ids per NPI (npi x rcv_bnft_enrlmt_id x raw ppef_addr_2019 row)",
    "3. Deduplicated street/suite rows within same billing group, city, state & ZIP5 (mysteryroster link rows: npi x indiv_enrlmt_id x rcv_bnft_enrlmt_id x city x state x zip5)",
    "4. Distinct clinician x billing organization x 5-digit ZIP5 (npi x rcv_bnft_enrlmt_id x zip5)",
    "5. Distinct clinician x city x state x 5-digit ZIP5 across all billing groups (npi x city x state x zip5)",
    "6. Distinct clinician x 5-digit ZIP5 pairs across all billing groups (npi x zip5)",
    "7. Distinct clinician x state pairs across all billing groups (npi x state)",
    "8. Distinct clinician x billing organization pairs (npi x rcv_bnft_enrlmt_id)",
    "9. Distinct midwives with >=1 group-reassigned location (npi)",
    "10. Distinct midwives with >=1 direct OR group-reassigned location (npi; Figure 2 Stage 2)",
    "11. Out-of-state share among 184,694 city/state/ZIP-deduped group rows (state != 2019 NPPES state)",
    "12. Out-of-state share among 168,917 distinct (npi, zip5) pairs (state != 2019 NPPES state)"
  ),
  n_count = c(
    nrow(group_join_raw_2019),
    nrow(distinct(group_join_raw_2019, npi, rcv_bnft_enrlmt_id, addr_row_id)),
    nrow(distinct(group_join_raw_2019, npi, enrlmt_id, rcv_bnft_enrlmt_id, city, state, zip5)),
    nrow(distinct(group_join_raw_2019, npi, rcv_bnft_enrlmt_id, zip5)),
    nrow(distinct(group_join_raw_2019, npi, city, state, zip5)),
    nrow(distinct(group_join_raw_2019, npi, zip5)),
    nrow(distinct(group_join_raw_2019, npi, state)),
    nrow(distinct(group_join_raw_2019, npi, rcv_bnft_enrlmt_id)),
    n_distinct(group_join_raw_2019$npi),
    5643L,
    sum(!is.na(group_join_raw_2019$state) & !is.na(group_join_raw_2019$nppes_state_2019) & group_join_raw_2019$state != group_join_raw_2019$nppes_state_2019),
    sum(!is.na(dist_npi_zip_2019$state) & !is.na(dist_npi_zip_2019$nppes_state_2019) & dist_npi_zip_2019$state != dist_npi_zip_2019$nppes_state_2019)
  ),
  mean_per_linked_midwife = round(n_count / 5625, 2),
  methodological_explanation = c(
    "Includes multiple suite/street rows in ppef_addr_2019 for the same group & ZIP5 (210,055 redundant suite/street rows removed in Step 3).",
    "Removes 3,136 duplicate rows caused by midwives holding >1 individual enrollment ID (I20...) linked to the same billing group.",
    "Exact 184,694 count reported by mysteryroster::attribute_enrollment_locations() after collapsing ppef_addr_2019 to unique (enrlmt_id, city, state, zip5).",
    "Collapses multiple city names within the same 5-digit ZIP5 and billing organization.",
    "Collapses overlapping clinic sites shared across >1 billing organization for the same midwife.",
    "True distinct (midwife, 5-digit ZIP5) candidate practice locations (~30.0 unique ZIP5s per group-linked midwife; median 15).",
    "Mean 1.11 states per group-linked midwife (510 midwives linked to multi-state billing groups).",
    "Mean 1.45 billing organizations (O20...) per group-linked midwife.",
    "5,625 midwives have group-reassigned locations (plus 18 with direct-only and 8 with both = 5,643 linked midwives).",
    "95.69% (5,643 / 5,897) of 2019 PECOS-enrolled midwives have >=1 associated administrative address.",
    "9.32% of raw group rows lie outside the midwife's 2019 NPPES state due to interstate billing groups.",
    "9.65% (16,148 / 168,917) of distinct (midwife, ZIP5) pairs lie outside the midwife's 2019 NPPES state."
  )
)

# Priority 2: 6-Tier Mutually Exclusive Location-Specificity Hierarchy (N = 5,897)
direct_by_npi_2019 <- direct_join_2019 %>%
  filter(!is.na(zip5)) %>%
  group_by(npi) %>%
  summarise(
    has_direct = TRUE,
    n_direct_zip5 = n_distinct(zip5),
    direct_zip5_set = paste(sort(unique(zip5)), collapse = "|"),
    direct_state_set = paste(sort(unique(state[!is.na(state)])), collapse = "|"),
    .groups = "drop"
  )

group_by_npi_2019 <- group_join_raw_2019 %>%
  filter(!is.na(zip5)) %>%
  group_by(npi) %>%
  summarise(
    has_group = TRUE,
    n_raw_group_rows = n(),
    n_billing_orgs = n_distinct(rcv_bnft_enrlmt_id),
    n_group_zip5 = n_distinct(zip5),
    n_group_states = n_distinct(state[!is.na(state)]),
    group_zip5_set = paste(sort(unique(zip5)), collapse = "|"),
    group_state_set = paste(sort(unique(state[!is.na(state)])), collapse = "|"),
    .groups = "drop"
  )

hierarchy_2019_df <- tibble(npi = unique(enrl_dedup_2019$npi)) %>%
  left_join(nppes_2019_st_zip, by = "npi") %>%
  left_join(direct_by_npi_2019, by = "npi") %>%
  left_join(group_by_npi_2019, by = "npi") %>%
  mutate(
    has_direct = coalesce(has_direct, FALSE),
    has_group = coalesce(has_group, FALSE),
    n_raw_group_rows = coalesce(n_raw_group_rows, 0L),
    n_billing_orgs = coalesce(n_billing_orgs, 0L),
    n_group_zip5 = coalesce(n_group_zip5, 0L),
    n_group_states = coalesce(n_group_states, 0L),
    specificity_tier = case_when(
      has_direct ~ "Tier 1: Direct Individual Practice Location (Attached to Individual Enrollment ID)",
      !has_direct & has_group & n_group_zip5 == 1L & n_group_states == 1L ~ "Tier 2: Unique Group-Associated Location (1 ZIP5 in 1 State via Billing Group)",
      !has_direct & has_group & n_group_zip5 >= 2L & n_group_zip5 <= 5L & n_group_states == 1L ~ "Tier 3: Small Intrastate Multi-Site Group (2-5 Unique ZIP5s in 1 State)",
      !has_direct & has_group & n_group_zip5 > 5L & n_group_states == 1L ~ "Tier 4: Large Intrastate Multi-Site Group (>5 Unique ZIP5s in 1 State)",
      !has_direct & has_group & n_group_states >= 2L ~ "Tier 5: Multi-State / Interstate Billing Group Locations (>=2 States)",
      TRUE ~ "Tier 6: No Practice Location Linked in PECOS (Neither Direct Nor Group)"
    )
  ) %>%
  rowwise() %>%
  mutate(
    eff_zip_set = ifelse(has_direct, direct_zip5_set, group_zip5_set),
    eff_state_set = ifelse(has_direct, direct_state_set, group_state_set),
    any_zip5_matches_nppes = !is.na(eff_zip_set) & !is.na(nppes_zip5_2019) & (nppes_zip5_2019 %in% strsplit(eff_zip_set, "\\|")[[1]]),
    unambiguous_single_zip5_matches_nppes = !is.na(eff_zip_set) & !is.na(nppes_zip5_2019) & all(strsplit(eff_zip_set, "\\|")[[1]] == nppes_zip5_2019),
    any_state_matches_nppes = !is.na(eff_state_set) & !is.na(nppes_state_2019) & (nppes_state_2019 %in% strsplit(eff_state_set, "\\|")[[1]])
  ) %>%
  ungroup()

pecos_2019_specificity_hierarchy_tbl <- hierarchy_2019_df %>%
  group_by(specificity_tier) %>%
  summarise(
    n_midwives = n(),
    pct_of_5897_enrolled = round(100 * n() / nrow(hierarchy_2019_df), 2),
    pct_of_5643_linked = ifelse(grepl("^Tier 6", first(specificity_tier)), NA_real_, round(100 * n() / 5643, 2)),
    median_unique_zip5_per_midwife = median(ifelse(has_direct, n_direct_zip5, n_group_zip5)),
    iqr_unique_zip5_per_midwife = paste0(
      quantile(ifelse(has_direct, n_direct_zip5, n_group_zip5), 0.25), "-",
      quantile(ifelse(has_direct, n_direct_zip5, n_group_zip5), 0.75)
    ),
    mean_raw_group_rows = round(mean(n_raw_group_rows), 1),
    n_any_state_match_nppes = sum(any_state_matches_nppes),
    pct_any_state_match_nppes = round(100 * mean(any_state_matches_nppes), 2),
    n_any_zip5_match_nppes = sum(any_zip5_matches_nppes),
    pct_any_zip5_match_nppes = round(100 * mean(any_zip5_matches_nppes), 2),
    n_unambiguous_1to1_zip5_match_nppes = sum(unambiguous_single_zip5_matches_nppes),
    pct_unambiguous_1to1_zip5_match_nppes = round(100 * mean(unambiguous_single_zip5_matches_nppes), 2),
    .groups = "drop"
  )

# Priority 3: Stratified 2019 Practice-Location Corroboration Substudy
pc_2019_sub <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(vintage %in% c("2019-06", "2019-12")) %>%
  transmute(
    npi = trimws(npi),
    pc_street = toupper(trimws(practice_address)),
    pc_state = clean_state(practice_state),
    pc_zip5 = norm_str_zip5(practice_zip),
    has_hospital_ccn = (!is.na(ccn_1) & nzchar(trimws(ccn_1)))
  ) %>%
  filter(npi %in% hierarchy_2019_df$npi, !is.na(pc_zip5)) %>%
  group_by(npi) %>%
  summarise(
    in_2019_phys_compare = TRUE,
    pc_zip5_set = paste(sort(unique(pc_zip5)), collapse = "|"),
    has_hospital_ccn = any(has_hospital_ccn),
    has_street_addr = any(!is.na(pc_street) & nzchar(pc_street)),
    .groups = "drop"
  )

# Named apart from R/lib/wilson_interval.R's wilson_ci() on purpose, same
# convention that file documents for mw_wilson()/scn_wilson(): this one is
# prop.test()-based (plain numeric pair), not the closed-form Wilson score
# formula (tibble of ci_low/ci_high) -- different return shape, not a
# duplicate to merge.
wilson_ci_proptest <- function(k, n) {
  if (n == 0L) return(c(NA_real_, NA_real_))
  ci <- suppressWarnings(prop.test(k, n, correct = FALSE)$conf.int)
  round(100 * as.numeric(ci), 2)
}

pecos_2019_location_corroboration_tbl <- hierarchy_2019_df %>%
  left_join(pc_2019_sub, by = "npi") %>%
  mutate(in_2019_phys_compare = coalesce(in_2019_phys_compare, FALSE)) %>%
  rowwise() %>%
  mutate(
    pecos_matches_pc_zip5 = in_2019_phys_compare & !is.na(eff_zip_set) &
      length(intersect(strsplit(eff_zip_set, "\\|")[[1]], strsplit(pc_zip5_set, "\\|")[[1]])) > 0L,
    nppes_matches_pc_zip5 = in_2019_phys_compare & !is.na(nppes_zip5_2019) &
      (nppes_zip5_2019 %in% strsplit(pc_zip5_set, "\\|")[[1]]),
    pinpoint_corroborated_site = (specificity_tier %in% c(
      "Tier 1: Direct Individual Practice Location (Attached to Individual Enrollment ID)",
      "Tier 2: Unique Group-Associated Location (1 ZIP5 in 1 State via Billing Group)"
    )) & (unambiguous_single_zip5_matches_nppes | pecos_matches_pc_zip5),
    all3_zip5_corroborated = pecos_matches_pc_zip5 & nppes_matches_pc_zip5
  ) %>%
  ungroup() %>%
  group_by(specificity_tier) %>%
  summarise(
    n_midwives_in_tier = n(),
    n_evaluated_in_2019_claims_directory = sum(in_2019_phys_compare),
    pct_evaluated_in_2019_claims_directory = round(100 * mean(in_2019_phys_compare), 2),
    n_pecos_zip5_corroborated_by_claims_dir = sum(pecos_matches_pc_zip5),
    pct_pecos_corroborated_among_evaluated = ifelse(sum(in_2019_phys_compare) > 0, round(100 * sum(pecos_matches_pc_zip5) / sum(in_2019_phys_compare), 2), NA_real_),
    ci95_low_corroborated_among_evaluated = wilson_ci_proptest(sum(pecos_matches_pc_zip5), sum(in_2019_phys_compare))[1],
    ci95_high_corroborated_among_evaluated = wilson_ci_proptest(sum(pecos_matches_pc_zip5), sum(in_2019_phys_compare))[2],
    n_all3_zip5_corroborated_pecos_nppes_pc = sum(all3_zip5_corroborated),
    pct_all3_corroborated_of_tier = round(100 * mean(all3_zip5_corroborated), 2),
    n_all3_corroborated_with_hospital_ccn = sum(all3_zip5_corroborated & coalesce(has_hospital_ccn, FALSE)),
    n_pinpoint_single_site_corroborated = sum(pinpoint_corroborated_site),
    pct_pinpoint_single_site_corroborated = round(100 * mean(pinpoint_corroborated_site), 2),
    sensitivity_bound_worst_case_pct = round(100 * sum(all3_zip5_corroborated) / n(), 2),
    sensitivity_bound_best_case_pct = round(100 * (sum(pecos_matches_pc_zip5) + sum(!in_2019_phys_compare & any_zip5_matches_nppes)) / n(), 2),
    .groups = "drop"
  )

# Priority 4: 2021-2026 Longitudinal State Disagreement & Right-Censoring Audit (N = 892)
base_2021_disc <- inner_join(
  nppes_panel_21_26 %>% filter(year == 2021L) %>% select(npi, nppes_2021 = state),
  pecos_rev_panel %>% filter(year == 2021L) %>% select(npi, pecos_2021 = state),
  by = "npi"
) %>%
  filter(nppes_2021 != pecos_2021)

longitudinal_2021_2026_censoring_tbl <- expand_grid(npi = base_2021_disc$npi, year = 2022:2026) %>%
  left_join(base_2021_disc, by = "npi") %>%
  left_join(nppes_panel_21_26 %>% rename(nppes_state = state), by = c("npi", "year")) %>%
  left_join(pecos_rev_panel %>% rename(pecos_state = state), by = c("npi", "year")) %>%
  group_by(npi, nppes_2021, pecos_2021) %>%
  summarise(
    pecos_adopts_nppes21 = any(!is.na(pecos_state) & pecos_state == nppes_2021),
    nppes_adopts_pecos21 = any(!is.na(nppes_state) & nppes_state == pecos_2021),
    converge_third_state = any(!is.na(nppes_state) & !is.na(pecos_state) & nppes_state == pecos_state & nppes_state != nppes_2021 & nppes_state != pecos_2021),
    observed_in_both_2026 = any(year == 2026L & !is.na(nppes_state) & !is.na(pecos_state)),
    exited_pecos_before_2026 = !any(year == 2026L & !is.na(pecos_state)),
    exited_nppes_before_2026 = !any(year == 2026L & !is.na(nppes_state)),
    .groups = "drop"
  ) %>%
  mutate(
    longitudinal_disposition = case_when(
      pecos_adopts_nppes21 & !nppes_adopts_pecos21 ~ "1. Resolved: PECOS subsequently adopted 2021 NPPES state",
      nppes_adopts_pecos21 & !pecos_adopts_nppes21 ~ "2. Resolved: NPPES subsequently adopted 2021 PECOS state",
      pecos_adopts_nppes21 & nppes_adopts_pecos21  ~ "3. Resolved: Bidirectional/swap state convergence across 2022-2026",
      converge_third_state ~ "4. Resolved: Both sources converged on a new third state in 2022-2026",
      observed_in_both_2026 ~ "5. Unresolved & Continuously Observed Through 2026 (True Persistent State Divergence)",
      exited_pecos_before_2026 | exited_nppes_before_2026 ~ "6. Unresolved & Right-Censored (Disappeared from PECOS or NPPES Before 2026)"
    )
  ) %>%
  count(longitudinal_disposition, name = "n_clinicians") %>%
  mutate(
    n_base_2021_disagreements = sum(n_clinicians),
    pct_of_all_892 = round(100 * n_clinicians / sum(n_clinicians), 2),
    pct_of_728_uncensored = ifelse(
      grepl("^6\\.", longitudinal_disposition),
      NA_real_,
      round(100 * n_clinicians / sum(n_clinicians[!grepl("^6\\.", longitudinal_disposition)]), 2)
    )
  )

# Priority 5: Temporal & Linkage-Tier Audit of the 159 Deceased-in-AMCB Clinicians
deceased_clinician_temporal_audit_tbl <- amcb_verif %>%
  filter(amcb_status == "DECEASED") %>%
  mutate(
    cert_exp_year = as.integer(sub("^.*/", "", trimws(expiration_date))),
    last_upd_year = as.integer(substr(pfile_last_update_date, 7, 10)),
    in_pecos_2026 = !is.na(pecos_legal_name),
    deceased_audit_stratum = case_when(
      confirmed_deactivated_npi & linkage_tier == "primary_midwifery" ~
        "1. Primary Midwifery Tier: Confirmed Deactivated NPI in NPPES (`nppes_deact_norm_v` / Feb 2026 P-File)",
      confirmed_deactivated_npi & linkage_tier == "sensitivity_nursing" ~
        "2. Sensitivity Nursing Tier: Confirmed Deactivated NPI in NPPES (`nppes_deact_norm_v` / Feb 2026 P-File)",
      !confirmed_deactivated_npi & linkage_tier == "primary_midwifery" ~
        "3. Primary Midwifery Tier: Open NPI in Feb 2026 NPPES (AMCB lacks exact death date; candidate for SSA Death Master File check)",
      !confirmed_deactivated_npi & linkage_tier == "sensitivity_nursing" & !is.na(cert_exp_year) & cert_exp_year <= 2019L ~
        "4. Sensitivity Nursing Tier: Open NPI in Feb 2026 NPPES & AMCB Cert Expired <=2019 (either unrecorded death or common-name RN linkage)",
      TRUE ~
        "5. Sensitivity Nursing Tier: Open NPI in Feb 2026 NPPES & AMCB Cert Cycle >=2020"
    )
  ) %>%
  group_by(deceased_audit_stratum, linkage_tier, confirmed_deactivated_npi) %>%
  summarise(
    n_clinicians = n(),
    pct_of_159_deceased = round(100 * n() / 159, 2),
    median_amcb_cert_exp_year = median(cert_exp_year, na.rm = TRUE),
    median_nppes_last_update_year = median(last_upd_year, na.rm = TRUE),
    n_in_pecos_2026 = sum(in_pecos_2026),
    .groups = "drop"
  )

cat("\n=== Priority 1: 2019 PECOS Group-Reassignment Join Cardinality Audit ===\n")
print(as.data.frame(pecos_2019_cardinality_audit_tbl), row.names = FALSE)

cat("\n=== Priority 2: 2019 PECOS 6-Tier Location-Specificity Hierarchy ===\n")
print(as.data.frame(pecos_2019_specificity_hierarchy_tbl), row.names = FALSE)

cat("\n=== Priority 3: 2019 Practice-Location Corroboration Substudy ===\n")
print(as.data.frame(pecos_2019_location_corroboration_tbl), row.names = FALSE)

cat("\n=== Priority 4: 2021-2026 Longitudinal Divergence & Right-Censoring Audit ===\n")
print(as.data.frame(longitudinal_2021_2026_censoring_tbl), row.names = FALSE)

cat("\n=== Priority 5: Deceased-in-AMCB NPI Deactivation & Temporal Audit (N = 159) ===\n")
print(as.data.frame(deceased_clinician_temporal_audit_tbl), row.names = FALSE)

# =============================================================================
# 10. Write Provenance-Stamped Aggregate Artifacts
# =============================================================================
declared_inputs <- prov_inputs(
  FROZEN_PATH,
  "dac_midwives.csv",
  "midwife_panel.csv",
  "artifacts/physician_compare_historical_midwives.csv",
  "artifacts/pecos_revalidation_cohort_state_by_year.csv",
  "artifacts/tmsis_medicaid_enrollment_state_by_year.csv",
  "artifacts/address_lead_lag_medicaid_nppes_moves.csv",
  unname(bon_files),
  quiet = TRUE
)

write_with_provenance(
  oig_table1_summary,
  file.path(OUT_DIR, "oig_table1_table2_accuracy_summary.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_table2_vars,
  file.path(OUT_DIR, "oig_table2_inaccuracy_subtypes_by_variable.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  bon_zip_concordance_tbl,
  file.path(OUT_DIR, "oig_state_bon_address_geographic_concordance.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  enum_cert_decomposition_tbl,
  file.path(OUT_DIR, "oig_enumeration_vs_certification_status_decomposition.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  deceased_clinician_temporal_audit_tbl,
  file.path(OUT_DIR, "oig_deceased_clinician_npi_temporal_audit.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_table3,
  file.path(OUT_DIR, "oig_table3_completeness_2019_and_2026.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  appendix_a_tbl,
  file.path(OUT_DIR, "oig_appendix_a_pecos_enrollment_location_linkage.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  pecos_2019_cardinality_audit_tbl,
  file.path(OUT_DIR, "oig_pecos_2019_join_cardinality_audit.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  pecos_2019_specificity_hierarchy_tbl,
  file.path(OUT_DIR, "oig_pecos_2019_location_specificity_hierarchy.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  pecos_2019_location_corroboration_tbl,
  file.path(OUT_DIR, "oig_pecos_2019_practice_location_corroboration_substudy.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_table4,
  file.path(OUT_DIR, "oig_table4_consistency_2019_and_2026.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_table4_any,
  file.path(OUT_DIR, "oig_table4_any_variable_inconsistent.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_lag_check_tbl,
  file.path(OUT_DIR, "oig_update_lag_and_staleness_check.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  longitudinal_2021_2026_censoring_tbl,
  file.path(OUT_DIR, "oig_longitudinal_2021_2026_censoring_audit.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_tmsis_three_way_tbl,
  file.path(OUT_DIR, "oig_tmsis_three_way_state_concordance_2018_2024.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_tmsis_participation_tbl,
  file.path(OUT_DIR, "oig_tmsis_medicare_vs_medicaid_participation_2018_2024.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_tmsis_transitions_tbl,
  file.path(OUT_DIR, "oig_tmsis_longitudinal_transitions_2018_2024.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  medicare_source_vintage_audit_tbl,
  file.path(OUT_DIR, "oig_medicare_coverage_source_vintage_audit_2018_2024.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  oig_2013_denominator_reconciliation_tbl,
  file.path(OUT_DIR, "oig_2013_historical_denominator_reconciliation.csv"),
  inputs = declared_inputs
)
write_with_provenance(
  prose_tbl,
  file.path(OUT_DIR, "oig_audit_narrative_prose.csv"),
  inputs = declared_inputs
)

cat(sprintf("\nAll 20 provenance-stamped OIG remake + T-MSIS extension + Location-Specificity audit artifacts and 2 HTML reports written to %s/\n", OUT_DIR))
