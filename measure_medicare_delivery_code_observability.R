#!/usr/bin/env Rscript
# =============================================================================
# What Medicare public data can and cannot say about delivery attendance
# =============================================================================
# Replaces filter_midwife_cpt_delivery_claims.py, which never read a procedure
# code. Its test was `"midw" in pri_spec.lower()` on the Doctors & Clinicians
# (DAC) national file -- true for every Medicare-enrolled clinician whose
# primary specialty is CERTIFIED NURSE MIDWIFE (CNM) -- and it labelled each
# such row "TRUE (Active Attending Delivery Provider)". The DAC has one row per
# clinician per practice location, so its 7,470 "attenders" were 4,806 distinct
# NPIs. Downstream, that flag became "7,470 midwives (62.67%) actively
# attending deliveries", a README headline, a map filter and a Table 1 split.
# None of it was delivery evidence. See docs/PROVENANCE_DEFECT_BON_LICENSE_
# IDENTIFIERS.md and artifacts/bon_contamination_inventory.csv.
#
# This script records the two things the sources actually say:
#
#   1. DAC ENROLLMENT. Which cohort NPIs are Medicare-enrolled with a primary
#      specialty of CNM. That is an enrollment and specialty attribute, not a
#      behaviour: it says nothing about whether the midwife attends births.
#
#   2. PART B DELIVERY CODES. How many rows the Medicare Physician & Other
#      Practitioners by-provider-and-service file carries for the global and
#      delivery-only obstetric codes, for any provider, in every year the
#      warehouse holds. CMS suppresses any provider-code cell under 11
#      beneficiaries, and Medicare covers very few births, so this is expected
#      to be zero -- and it is reported as observed rather than assumed.
#      A zero here means "not observable in public Medicare data", never "did
#      not attend a delivery".
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (FROZEN_CSV to override)
#          DAC_NationalDownloadableFile_2026-06.csv (DAC_FILE)
#          medicare_part_b_by_service_all_years (MEDICARE_DUCKDB warehouse)
# Outputs: artifacts/medicare_delivery_code_observability.csv   (aggregate, tracked)
#          artifacts/cohort_midwives_dac_primary_specialty_cnm.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tibble); library(DBI)
})
source("R/lib/common_helpers.R")
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

FROZEN   <- Sys.getenv("FROZEN_CSV", "artifacts/amcb_npi_linkage_FROZEN.csv")
DAC      <- Sys.getenv("DAC_FILE", "DAC_NationalDownloadableFile_2026-06.csv")
PARTB    <- "medicare_part_b_by_service_all_years"
OUT      <- "artifacts/medicare_delivery_code_observability.csv"
OUT_PERS <- "artifacts/cohort_midwives_dac_primary_specialty_cnm.csv"

# Global obstetric care, delivery-only and delivery-plus-postpartum codes for
# vaginal, cesarean and VBAC/TOLAC births. The first five are the ones the
# retired script named; the rest close the obvious gap (cesarean and TOLAC
# delivery-only), so a zero cannot be blamed on a short list.
DELIVERY_HCPCS <- c("59400", "59409", "59410", "59510", "59514", "59515",
                    "59610", "59612", "59614", "59618", "59620", "59622")
DAC_CNM_SPECIALTY <- "CERTIFIED NURSE MIDWIFE (CNM)"

for (f in c(FROZEN, DAC)) {
  if (!file.exists(f))
    stop(sprintf(paste0("Required input not found: %s. The FROZEN linkage is ",
                        "gitignored and the DAC is a manual download; set ",
                        "FROZEN_CSV / DAC_FILE. Refusing to report counts from ",
                        "a partial source."), f), call. = FALSE)
}

# --- cohort ------------------------------------------------------------------
# Same definition as Table 1 and extract_dac_facility_affiliations.R.
coh <- read_csv(FROZEN, show_col_types = FALSE, progress = FALSE,
                col_types = cols(.default = col_character())) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  select(certification_number, npi)
N <- nrow(coh)
cat(sprintf("cohort (ACTIVE, primary-linked, with an NPI): %s\n", format(N, big.mark = ",")))

# --- 1. DAC enrollment and primary specialty ---------------------------------
# One row per clinician per practice location, and a clinician with more than
# one Medicare enrollment can carry a different primary specialty on each. So
# the specialty is collapsed to the set seen, and "primary specialty CNM" means
# CNM on at least one enrollment. Counting rows instead of NPIs is how 4,806
# people became 7,470 "attenders".
dac <- read_csv(DAC, col_select = c(NPI, pri_spec), show_col_types = FALSE,
                progress = FALSE, col_types = cols(.default = col_character())) %>%
  transmute(npi = str_trim(NPI), pri_spec = str_trim(pri_spec)) %>%
  filter(npi %in% coh$npi) %>%
  group_by(npi) %>%
  summarise(dac_primary_specialty_cnm = any(pri_spec %in% DAC_CNM_SPECIALTY),
            dac_primary_specialties = paste(sort(unique(pri_spec)), collapse = "; "),
            .groups = "drop")

person <- coh %>%
  left_join(dac, by = "npi") %>%
  mutate(in_dac = !is.na(dac_primary_specialties),
         dac_primary_specialty_cnm = coalesce(dac_primary_specialty_cnm, FALSE),
         dac_file = basename(DAC))
write_csv(person, OUT_PERS, na = "")
cat(sprintf("written: %s (person-level, gitignored)\n", OUT_PERS))

n_in_dac <- sum(person$in_dac)
n_cnm    <- sum(person$dac_primary_specialty_cnm)
cat(sprintf("  in the DAC (Medicare-enrolled)       : %s\n", format(n_in_dac, big.mark = ",")))
cat(sprintf("  of those, primary specialty CNM      : %s\n", format(n_cnm, big.mark = ",")))

# --- 2. Part B delivery codes ------------------------------------------------
con <- open_medicare_duckdb(PARTB)
dbWriteTable(con, "tmp_cohort_npi",
             tibble(npi = as.numeric(coh$npi)), temporary = TRUE)
codes_sql <- paste0("'", DELIVERY_HCPCS, "'", collapse = ", ")

by_year <- dbGetQuery(con, sprintf("
  SELECT data_year,
         COUNT(*)                                                     AS part_b_rows_all_codes,
         MIN(Tot_Benes)                                               AS smallest_published_beneficiary_count,
         COUNT(*) FILTER (WHERE HCPCS_Cd IN (%1$s))                   AS delivery_code_rows_any_provider,
         COUNT(DISTINCT Rndrng_NPI) FILTER (WHERE HCPCS_Cd IN (%1$s)) AS delivery_code_npis_any_provider,
         COUNT(*) FILTER (WHERE Rndrng_Prvdr_Type = 'Certified Nurse Midwife') AS cnm_provider_type_rows,
         COUNT(DISTINCT Rndrng_NPI) FILTER (WHERE Rndrng_Prvdr_Type = 'Certified Nurse Midwife') AS cnm_provider_type_npis,
         COUNT(DISTINCT Rndrng_NPI) FILTER (WHERE Rndrng_NPI IN (SELECT npi FROM tmp_cohort_npi)) AS cohort_npis_any_code,
         COUNT(*) FILTER (WHERE HCPCS_Cd IN (%1$s)
                            AND Rndrng_NPI IN (SELECT npi FROM tmp_cohort_npi)) AS cohort_delivery_code_rows
    FROM %2$s
   GROUP BY data_year
   ORDER BY data_year", codes_sql, PARTB)) %>%
  as_tibble() %>%
  mutate(across(everything(), as.numeric))
dbDisconnect(con, shutdown = TRUE)
print(by_year, width = Inf)

# --- the artifact ------------------------------------------------------------
# Long format, one measure per row. Each row says what was counted and in
# which file, so a zero cannot be read as anything other than what it is.
codes_txt <- paste(DELIVERY_HCPCS, collapse = "/")
DEFINITIONS <- c(
  cohort_n = "ACTIVE certificants at linkage_tier primary_midwifery with an NPI",
  cohort_in_dac = "cohort NPIs present in the DAC national file, i.e. enrolled in Medicare",
  cohort_dac_primary_specialty_cnm = sprintf("cohort NPIs whose DAC primary specialty is %s on at least one enrollment; an enrollment attribute, not delivery evidence", DAC_CNM_SPECIALTY),
  part_b_rows_all_codes = "published provider-by-HCPCS rows, any provider, any code",
  smallest_published_beneficiary_count = "smallest Tot_Benes in any published row; CMS suppresses cells under 11 beneficiaries",
  delivery_code_rows_any_provider = sprintf("published rows for HCPCS %s, any provider", codes_txt),
  delivery_code_npis_any_provider = sprintf("distinct rendering NPIs with a published row for HCPCS %s", codes_txt),
  cnm_provider_type_rows = "published rows whose provider type is Certified Nurse Midwife, any code",
  cnm_provider_type_npis = "distinct NPIs whose provider type is Certified Nurse Midwife, any code",
  cohort_npis_any_code = "cohort NPIs with at least one published row, any code",
  cohort_delivery_code_rows = sprintf("published rows for HCPCS %s rendered by a cohort NPI", codes_txt))
SOURCES <- c(
  cohort_n = sprintf("%s (status, linkage_tier)", basename(FROZEN)),
  cohort_in_dac = sprintf("%s (NPI, pri_spec)", basename(DAC)),
  cohort_dac_primary_specialty_cnm = sprintf("%s (NPI, pri_spec)", basename(DAC)))

out <- bind_rows(
  tibble(measure = c("cohort_n", "cohort_in_dac", "cohort_dac_primary_specialty_cnm"),
         data_year = NA_real_, value = c(N, n_in_dac, n_cnm)),
  by_year %>%
    tidyr::pivot_longer(-data_year, names_to = "measure", values_to = "value")
) %>%
  mutate(definition = unname(DEFINITIONS[measure]),
         source = coalesce(unname(SOURCES[measure]),
                           sprintf("%s (Medicare Physician & Other Practitioners by provider and service)", PARTB)),
         # cohort_n on every row so tests/ci_science_laws.R L1 can check the vintage.
         cohort_n = N)
stopifnot(!anyNA(out$definition))
write_with_provenance(out, OUT, inputs = c(FROZEN, DAC), na = "")
cat(sprintf("written: %s\n", OUT))

tot <- sum(by_year$delivery_code_rows_any_provider)
cat(sprintf(paste0("\nDelivery-code rows in public Part B, any provider, %d-%d: %s.\n",
                   "Delivery attendance is %s observable in this source.\n"),
            as.integer(min(by_year$data_year)), as.integer(max(by_year$data_year)),
            format(tot, big.mark = ","), if (tot == 0) "NOT" else "partly"))
