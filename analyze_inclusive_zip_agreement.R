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

PL_FILE <- Sys.getenv(
  "NPPES_PL_FILE",
  "/Volumes/MufflySamsung/nppes_historical_downloads/extracted_2024/pl_pfile_20050523-20241208.csv")
SECONDARY_ZIP_COLUMN <-
  "Provider Secondary Practice Location Address - Postal Code"

if (!file.exists(PL_FILE)) {
  stop("read the NPPES secondary practice location file: ", PL_FILE,
       " is absent. Set NPPES_PL_FILE to its path rather than silently ",
       "reporting the primary-only number as if it were inclusive.",
       call. = FALSE)
}

#' First five digits of a postal code, or NA
#'
#' @param postal_code [character] raw value.
#' @return [character] five digits, or NA when fewer are present.
zip5_of <- function(postal_code) {
  digits <- substr(gsub("[^0-9]", "", postal_code), 1, 5)
  ifelse(nchar(digits) == 5, digits, NA_character_)
}

base::message("Reading the comparison source (Medicare clinician directory)")
directory_zips <- read_csv("dac_midwives.csv",
                           col_types = cols(.default = "c"),
                           progress = FALSE) %>%
  transmute(npi = trimws(.data$npi),
            directory_zip = zip5_of(.data$practice_zip)) %>%
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
            registry_zip = zip5_of(.data$practice_zip)) %>%
  filter(!is.na(.data$registry_zip)) %>%
  distinct()

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "comparison_npis", directory_zips %>% distinct(.data$npi),
             overwrite = TRUE)

base::message("Reading every secondary practice location for these midwives")
registry_secondary <- dbGetQuery(con, sprintf('
  SELECT DISTINCT TRIM(pl."NPI") AS npi,
         SUBSTR(REGEXP_REPLACE(pl."%s", \'[^0-9]\', \'\', \'g\'), 1, 5)
           AS registry_zip
  FROM read_csv_auto(\'%s\', ALL_VARCHAR = TRUE, SAMPLE_SIZE = -1) pl
  INNER JOIN comparison_npis c ON TRIM(pl."NPI") = c.npi',
  SECONDARY_ZIP_COLUMN, PL_FILE)) %>%
  filter(nchar(.data$registry_zip) == 5)

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
write_csv(result, "artifacts/inclusive_zip_agreement.csv")

base::message(sprintf(
  "  %s midwives compared; %s have a secondary practice location",
  format(n_compared, big.mark = ","),
  format(dplyr::n_distinct(registry_secondary$npi), big.mark = ",")))
base::message(sprintf(
  "  primary only %.1f%%, inclusive %.1f%%, a gain of %.1f points",
  result$pct_agree[1], result$pct_agree[2],
  result$pct_agree[2] - result$pct_agree[1]))
base::message("  wrote artifacts/inclusive_zip_agreement.csv")
