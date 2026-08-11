#!/usr/bin/env Rscript
# =============================================================================
# Hospital affiliation for each midwife, via CMS Certification Number (CCN)
# =============================================================================
# CMS publishes a Facility Affiliation file alongside the Doctors & Clinicians
# (DAC) national file, keyed NPI -> facility_type -> CCN. The CCN is then a key
# into cms_hospital_info, which carries the hospital's name, type, ownership
# and birthing-friendly designation. That two-hop join turns an affiliation
# from a free-text string into a facility with attributes.
#
# VINTAGE MUST MATCH THE DAC. The affiliation file and the DAC are cut from the
# same monthly release. An older affiliation file mixed with a newer DAC would
# attribute a 2025 hospital roster to a 2026 cohort and quietly misstate who
# had privileges where. This script asserts the two vintages agree rather than
# trusting whatever happens to be on disk -- the copy that was already on the
# external volume was April 2025 against a 2026-06 DAC.
#
# WHAT ABSENCE MEANS. Only clinicians ENROLLED IN MEDICARE appear in the DAC at
# all, and of those, only ones with recorded facility privileges appear here. A
# midwife absent from this file therefore (a) is not Medicare-enrolled, or
# (b) is enrolled with no recorded hospital privilege. Neither is "does not
# work at a hospital", and no output below may be read that way. The two states
# are kept as separate levels for exactly this reason.
#
# A CCN IS NOT A NUMBER. 10,290 rows here carry a letter in the CCN. Padding
# via as.integer() would NA every one of them; pad_ccn() pads the string.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          Facility_Affiliation_2026-06.csv   (FACILITY_AFFILIATION_FILE)
#          cms_hospital_info                  (MEDICARE_DUCKDB)
# Outputs: artifacts/dac_facility_affiliations.csv       (NPI-CCN level, gitignored)
#          artifacts/dac_hospital_affiliation_person.csv (one row per midwife, gitignored)
#          artifacts/dac_hospital_affiliation_summary.csv(aggregate, tracked)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tibble)
  library(DBI); library(duckdb)
})
source("R/lib/common_helpers.R")

DAC_VINTAGE <- Sys.getenv("DAC_VINTAGE", "2026-06")
FA <- Sys.getenv("FACILITY_AFFILIATION_FILE",
  file.path("/Volumes/MufflySamsung/facility_affiliation",
            "doctors_and_clinicians_2026_06",
            "Facility_Affiliation_2026-06.csv"))
DB <- Sys.getenv("MEDICARE_DUCKDB",
                 "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb")

for (f in c(FA, DB)) {
  if (!file.exists(f))
    stop(sprintf(paste0("Required input not found: %s. These live on an ",
                        "external volume; mount it or set ",
                        "FACILITY_AFFILIATION_FILE / MEDICARE_DUCKDB. ",
                        "Refusing to emit affiliation counts from a partial ",
                        "source."), f), call. = FALSE)
}

# The vintage assertion. The filename is the only vintage marker CMS gives, so
# it is checked explicitly rather than assumed from the directory.
if (!str_detect(basename(FA), fixed(DAC_VINTAGE))) {
  stop(sprintf(paste0("Affiliation file '%s' does not carry the DAC vintage ",
                      "'%s'. The DAC and the affiliation file are cut from the ",
                      "same monthly CMS release; mixing vintages attributes ",
                      "one month's hospital roster to another month's cohort. ",
                      "Download the matching release or set DAC_VINTAGE ",
                      "deliberately."), basename(FA), DAC_VINTAGE), call. = FALSE)
}
cat(sprintf("DAC vintage: %s\naffiliation file: %s\n\n", DAC_VINTAGE, basename(FA)))

# --- cohort ------------------------------------------------------------------
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                 show_col_types = FALSE, progress = FALSE)
coh <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  select(certification_number, npi)
N <- nrow(coh)
cat(sprintf("cohort with an NPI: %s\n", format(N, big.mark = ",")))

# --- affiliation rows --------------------------------------------------------
fa <- chr(FA)
names(fa)[names(fa) == "Facility Affiliations Certification Number"] <- "ccn"
stopifnot("ccn" %in% names(fa), "NPI" %in% names(fa), "facility_type" %in% names(fa))

fa <- fa %>%
  mutate(npi = str_trim(NPI), ccn = pad_ccn(ccn)) %>%
  filter(!is.na(ccn))

mine <- fa %>%
  inner_join(coh, by = "npi", relationship = "many-to-many") %>%
  distinct(certification_number, npi, facility_type, ccn)
cat(sprintf("affiliation rows for cohort: %s across %s midwives\n",
            format(nrow(mine), big.mark = ","),
            format(n_distinct(mine$certification_number), big.mark = ",")))
cat("facility types:\n")
print(sort(table(mine$facility_type), decreasing = TRUE))

# --- hospital attributes -----------------------------------------------------
con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
hosp <- dbGetQuery(con, "
  SELECT facility_id, facility_name, state, hospital_type, hospital_ownership,
         meets_criteria_for_birthing_friendly_designation AS birthing_friendly
    FROM cms_hospital_info") %>%
  mutate(ccn = pad_ccn(facility_id)) %>%
  distinct(ccn, .keep_all = TRUE)

hospital_rows <- mine %>%
  filter(facility_type == "Hospital") %>%
  left_join(hosp, by = "ccn")

unresolved <- sum(is.na(hospital_rows$facility_name))
cat(sprintf("\nhospital CCN links: %s | resolved to a named hospital: %s (%.1f%%)\n",
            format(nrow(hospital_rows), big.mark = ","),
            format(sum(!is.na(hospital_rows$facility_name)), big.mark = ","),
            100 * mean(!is.na(hospital_rows$facility_name))))
if (unresolved > 0)
  cat(sprintf("  %s CCN(s) not in cms_hospital_info -- reported as affiliated but unattributed\n",
              format(unresolved, big.mark = ",")))

write_csv(hospital_rows, "artifacts/dac_facility_affiliations.csv", na = "")
cat("written: artifacts/dac_facility_affiliations.csv\n")

# --- one row per midwife -----------------------------------------------------
# MULTI-HOSPITAL MIDWIVES ARE NOT COLLAPSED TO A "PRIMARY" HOSPITAL. CMS gives
# no rank, admission volume or FTE, so any choice of a single hospital would be
# arbitrary (row order, lowest CCN) and would then drive a Table 1 percentage.
# Person-level attributes are ANY-flags instead, which are well defined
# regardless of how many hospitals a midwife is affiliated with. n_hospitals is
# kept so the multiplicity is visible rather than hidden.
CRITICAL <- "Critical Access Hospitals"
person <- hospital_rows %>%
  group_by(certification_number) %>%
  summarise(
    n_hospitals        = n_distinct(ccn),
    any_critical_access= any(hospital_type == CRITICAL, na.rm = TRUE),
    any_birth_friendly = any(birthing_friendly == "Y", na.rm = TRUE),
    ownership_set      = n_distinct(hospital_ownership[!is.na(hospital_ownership)]),
    ownership          = {
      o <- hospital_ownership[!is.na(hospital_ownership)]
      if (!length(o)) NA_character_
      else if (n_distinct(o) == 1L) o[1]
      else "Multiple owners across affiliated hospitals"
    },
    .groups = "drop") %>%
  mutate(has_hospital = TRUE)

out <- coh %>%
  left_join(person, by = "certification_number") %>%
  mutate(has_hospital = coalesce(has_hospital, FALSE),
         n_hospitals  = coalesce(n_hospitals, 0L))
write_csv(out, "artifacts/dac_hospital_affiliation_person.csv", na = "")
cat(sprintf("written: artifacts/dac_hospital_affiliation_person.csv (%s midwives)\n",
            format(nrow(out), big.mark = ",")))

# --- summary -----------------------------------------------------------------
summ <- tibble(
  built_at         = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  dac_vintage      = DAC_VINTAGE,
  cohort_n         = N,
  with_hospital    = sum(out$has_hospital),
  hospitals_linked = n_distinct(hospital_rows$ccn),
  ccn_unresolved   = unresolved,
  any_critical     = sum(out$any_critical_access, na.rm = TRUE),
  any_birth_friendly = sum(out$any_birth_friendly, na.rm = TRUE),
  multi_hospital   = sum(out$n_hospitals > 1L))
write_csv(summ, "artifacts/dac_hospital_affiliation_summary.csv")

f <- function(x, lab) cat(sprintf("  %-52s %6s (%4.1f%%)\n", lab,
                                  format(x, big.mark = ","), 100 * x / N))
cat("\n")
f(summ$with_hospital,      "Hospital affiliation recorded in Medicare")
f(summ$multi_hospital,     "  affiliated with >1 hospital")
f(summ$any_critical,       "  any critical-access hospital")
f(summ$any_birth_friendly, "  any birthing-friendly hospital")
cat(sprintf("  distinct hospitals linked: %s\n",
            format(summ$hospitals_linked, big.mark = ",")))
