#!/usr/bin/env Rscript
# =============================================================================
# Does accepting EVERY practice location the registry holds change the picture?
# =============================================================================
# WHY THIS EXISTS. The OIG replication reports a row called
# `practice_zip5_with_nppes_pl`, which reads as the inclusive comparison: a
# midwife counts as agreeing if the outside source's postal code matches any
# practice location the National Plan and Provider Enumeration System holds
# for her, not only her primary one. It is not that comparison. Its input,
# `nppes.practice_locations_enhanced`, holds exactly one row per provider
# (1,827,784 rows, 1,827,784 distinct identifiers), so the union with the
# primary postal code adds nothing and the row comes out byte-identical to
# `practice_zip5` in all twelve fields. An inclusive comparison that is
# arithmetically incapable of differing from the strict one is not a
# sensitivity analysis; it is a label.
#
# The real secondary-practice-location file does exist, as the separate
# `pl_pfile` published alongside each NPPES dissemination. This script uses it
# to answer the question the mislabelled row implied: how much of the postal
# code disagreement is explained by midwives practising at more than one
# address that the registry already knows about?
#
# Output: artifacts/inclusive_zip_agreement.csv (aggregate only).
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(dplyr); library(readr)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
# ONE DEFINITION OF A ZIP CODE. R/lib/oig_zip_normalizers.R already holds the
# repository's normalizers and tests/ci_hygiene.R H4 refuses a second copy.
# An earlier draft of this script defined its own five-digit helper, which
# dropped a ZIP whose leading zero had been lost upstream (a four-digit
# "1234" became NA instead of "01234") and silently mis-read a ZIP+4 in the
# same state ("12345678" became "12345" rather than "01234"). Neither is
# hypothetical: the secondary-location file carries both shapes.
source(file.path("R", "lib", "oig_zip_normalizers.R"))

# RESOLVED, NOT SPELLED OUT. This default was the volume literal, and it is
# what failed H1/H2 of tests/test_duckdb_volume_resolution.R on every nightly
# since the 2026-11-16 ZIP sweep: the original incident was a second drive
# called "MufflySamsung 1" answering for the first, so a path written at a call
# site cannot be corrected centrally when the mount is renamed.
# medicare_duckdb.R is already sourced above, so the resolver was available the
# whole time. must_exist = FALSE and the canonical fallback keep the existing
# check below as the thing that reports the absence, because its message says
# what is at stake -- a resolver error would only say the file is missing.
PL_REL <- file.path("nppes_historical_downloads", "extracted_2024",
                    "pl_pfile_20050523-20241208.csv")
PL_FILE <- Sys.getenv("NPPES_PL_FILE", "")
if (!nzchar(PL_FILE)) {
  PL_FILE <- samsung_volume_path(PL_REL, must_exist = FALSE)
  if (is.na(PL_FILE)) PL_FILE <- file.path(SAMSUNG_VOLUME_CANONICAL, PL_REL)
}
SECONDARY_ZIP_COLUMN <-
  "Provider Secondary Practice Location Address - Postal Code"

if (!file.exists(PL_FILE)) {
  stop("read the NPPES secondary practice location file: ", PL_FILE,
       " is absent. Set NPPES_PL_FILE to its path rather than silently ",
       "reporting the primary-only number as if it were inclusive.",
       call. = FALSE)
}

base::message("Reading the comparison source (Medicare clinician directory)")
directory_zips <- read_csv("dac_midwives.csv",
                           col_types = cols(.default = "c"),
                           progress = FALSE) %>%
  transmute(npi = trimws(.data$npi),
            directory_zip = norm_str_zip5(.data$practice_zip)) %>%
  filter(!is.na(.data$npi), nzchar(.data$npi),
         !is.na(.data$directory_zip)) %>%
  distinct()

base::message("Reading the registry's primary practice postal code")
registry_primary <- read_csv("midwife_panel.csv",
                             col_types = cols(.default = "c"),
                             progress = FALSE) %>%
  mutate(snapshot_year = as.integer(.data$snapshot_year)) %>%
  filter(.data$snapshot_year == max(.data$snapshot_year, na.rm = TRUE)) %>%
  transmute(npi = trimws(.data$npi),
            registry_zip = norm_str_zip5(.data$practice_zip)) %>%
  filter(!is.na(.data$registry_zip)) %>%
  distinct()

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "comparison_npis", directory_zips %>% distinct(.data$npi),
             overwrite = TRUE)

base::message("Reading every secondary practice location for these midwives")
registry_secondary <- dbGetQuery(con, sprintf('
  SELECT DISTINCT TRIM(pl."NPI") AS npi,
         REGEXP_REPLACE(pl."%s", \'[^0-9]\', \'\', \'g\') AS raw_zip
  FROM read_csv_auto(\'%s\', ALL_VARCHAR = TRUE, SAMPLE_SIZE = -1) pl
  INNER JOIN comparison_npis c ON TRIM(pl."NPI") = c.npi',
  SECONDARY_ZIP_COLUMN, PL_FILE)) %>%
  mutate(registry_zip = norm_pecos_bigint_zip5(.data$raw_zip)) %>%
  filter(!is.na(.data$registry_zip)) %>%
  select(npi, registry_zip)

every_registry_zip <- bind_rows(registry_primary, registry_secondary) %>%
  distinct()

# The denominator is midwives the strict comparison could evaluate, so the
# two percentages are taken over the same people and the difference is the
# effect of inclusivity alone rather than of a changed sample.
strict <- directory_zips %>%
  inner_join(registry_primary, by = "npi") %>%
  group_by(.data$npi) %>%
  summarise(agrees = any(.data$directory_zip == .data$registry_zip),
            .groups = "drop")
inclusive <- directory_zips %>%
  inner_join(every_registry_zip, by = "npi",
             relationship = "many-to-many") %>%
  group_by(.data$npi) %>%
  summarise(agrees = any(.data$directory_zip == .data$registry_zip),
            .groups = "drop") %>%
  filter(.data$npi %in% strict$npi)

n_compared <- nrow(strict)
result <- tibble::tibble(
  comparison = c("primary practice location only",
                 "any practice location the registry holds"),
  n_compared = n_compared,
  n_agree = c(sum(strict$agrees), sum(inclusive$agrees)),
  pct_agree = round(100 * c(sum(strict$agrees), sum(inclusive$agrees)) /
                      n_compared, 1),
  n_with_secondary_location = dplyr::n_distinct(registry_secondary$npi),
  n_secondary_locations = nrow(registry_secondary),
  source_file = basename(PL_FILE))
# write_with_provenance(), not write_csv(): ci_artifact_contracts A3 requires a
# tracked artifact to carry a sidecar recording its inputs and their SHA-256.
# This one shipped without, and the baseline carries it until a run re-records
# it -- a sidecar has to be written AT production time, not reconstructed.
source(file.path("R", "lib", "artifact_provenance.R"))
write_with_provenance(result, "artifacts/inclusive_zip_agreement.csv",
                      inputs = PL_FILE)

base::message(sprintf(
  "  %s midwives compared; %s have a secondary practice location",
  format(n_compared, big.mark = ","),
  format(dplyr::n_distinct(registry_secondary$npi), big.mark = ",")))
base::message(sprintf(
  "  primary only %.1f%%, inclusive %.1f%%, a gain of %.1f points",
  result$pct_agree[1], result$pct_agree[2],
  result$pct_agree[2] - result$pct_agree[1]))
base::message("  wrote artifacts/inclusive_zip_agreement.csv")
