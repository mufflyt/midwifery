#!/usr/bin/env Rscript

#' @title Payer saturation table for the AccessMRF pilot
#'
#' @description
#' Step 4 of 8. One row per payer, in descending Colorado commercial enrollment
#' order, answering the pilot's question: as market coverage rises, does
#' midwife discovery flatten?
#'
#' @section Two coverage columns, deliberately separate:
#' \describe{
#'   \item{`cumulative_market_share_attempted`}{payer was selected for pulling}
#'   \item{`cumulative_market_share_successfully_parsed`}{payer's files actually
#'     yielded provider rows}
#' }
#'
#' A payer attempted but not parsed must never count as observed coverage.
#' Doing so inflates the denominator and makes absence look like evidence of
#' non-participation when it is really evidence of our own parse failure. This
#' is not hypothetical: Kaiser's files are malformed JSON (trailing commas)
#' inside a ZIP served from a URL ending `.json`, and failed on first contact.
#'
#' @section The measure that is deliberately absent:
#' There is no `zero_networks` column and no column describing an unobserved
#' midwife as out-of-network. Until market coverage is characterised,
#' `observed_in_sampled_mrfs` is the only defensible statement. The endpoint is
#' *CNM observed in payer MRF provider groups* -- not network participation,
#' not employment, not access.
#'
#' @section History is preserved:
#' The table is recomputed from accumulated observations on every run, which
#' keeps it deterministic and independent of the order runs happened to occur,
#' and each run also writes a timestamped copy. No earlier result is ever
#' overwritten.
#'
#' @section Inputs and outputs:
#' Reads `colorado_cnm_cohort.csv`, `colorado_payer_market.csv`,
#' `colorado_provider_observations.csv` and `colorado_file_manifest.csv`.
#' Writes `colorado_saturation_table.csv` plus a timestamped copy.
#'
#' @family accessmrf
#' @concept provider-billing-graph
#' @seealso `accessmrf_06_build_relationships.py` for the deduplicated build.
#' @keywords internal

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
artifact_dir <- file.path("artifacts", "accessmrf")

COHORT <- file.path(artifact_dir, "colorado_cnm_cohort.csv")
MARKET <- file.path(artifact_dir, "colorado_payer_market.csv")
OBS <- file.path(artifact_dir, "colorado_provider_observations.csv")
MANIFEST <- file.path(artifact_dir, "colorado_file_manifest.csv")

stopifnot(file.exists(COHORT), file.exists(MARKET))

cohort <- read_csv(COHORT, col_types = cols(.default = col_character()))
market <- read_csv(MARKET, show_col_types = FALSE)

cohort_npis <- unique(cohort$npi)
cohort_n <- length(cohort_npis)

empty_obs <- tibble::tibble(
  npi = character(), tin = character(), business_name = character(),
  payer_group = character(), payer_source = character(),
  network_name = character(), source_file_id = character(),
  source_file_stem = character(), source_month = character(),
  source_url = character(), schema_type = character()
)

observations <- if (file.exists(OBS) && file.size(OBS) > 10) {
  read_csv(OBS, col_types = cols(.default = col_character()))
} else {
  empty_obs
}

manifest <- if (file.exists(MANIFEST) && file.size(MANIFEST) > 10) {
  read_csv(MANIFEST, col_types = cols(.default = col_character()))
} else {
  tibble::tibble(payer_group = character(), status = character(),
                 file_id = character())
}

# Payers are walked in enrollment order so the curve's x-axis is the market,
# not the order we happened to process things.
payer_order <- market |>
  filter(.data$mrf_available) |>
  arrange(desc(.data$commercial_enrollment_estimate))

attempted <- unique(manifest$payer_group)

rows <- list()
seen_cnms <- character(0)

for (i in seq_len(nrow(payer_order))) {

  payer <- payer_order$payer_group[[i]]
  share <- payer_order$market_share[[i]]

  files <- manifest |> filter(.data$payer_group == payer)
  obs <- observations |> filter(.data$payer_group == payer)

  parsed_files <- files |> filter(.data$status == "parsed")
  failures <- files |> filter(.data$status != "parsed", !is.na(.data$status))

  payer_was_attempted <- payer %in% attempted
  payer_parsed_anything <- nrow(parsed_files) > 0L && nrow(obs) > 0L

  cnm_obs <- obs |> filter(.data$npi %in% cohort_npis)
  payer_cnms <- unique(cnm_obs$npi)
  newly <- setdiff(payer_cnms, seen_cnms)
  seen_cnms <- union(seen_cnms, payer_cnms)

  rows[[i]] <- tibble::tibble(
    payer_group = payer,
    colorado_enrollment_share = share,
    attempted = payer_was_attempted,
    parsed = payer_parsed_anything,
    files_attempted = nrow(files),
    files_parsed = nrow(parsed_files),
    parse_failures = nrow(failures),
    parse_failure_reasons = if (nrow(failures)) {
      paste(unique(str_trunc(failures$status, 60)), collapse = "; ")
    } else NA_character_,
    total_observations = nrow(obs),
    distinct_npis = dplyr::n_distinct(obs$npi),
    distinct_tins = dplyr::n_distinct(obs$tin),
    cnms_newly_discovered = length(newly),
    cnms_cumulative = length(seen_cnms),
    pct_of_colorado_cohort = 100 * length(seen_cnms) / cohort_n,
    distinct_cnm_tin_pairs = nrow(distinct(cnm_obs, .data$npi, .data$tin)),
    distinct_tins_containing_cnms = dplyr::n_distinct(cnm_obs$tin),
    business_name_availability = if (nrow(obs)) {
      mean(!is.na(obs$business_name) & nzchar(obs$business_name))
    } else NA_real_,
    network_name_availability = if (nrow(obs)) {
      mean(!is.na(obs$network_name) & nzchar(obs$network_name))
    } else NA_real_
  )
}

saturation <- bind_rows(rows) |>
  mutate(
    cumulative_market_share_attempted =
      cumsum(if_else(.data$attempted, .data$colorado_enrollment_share, 0)),
    cumulative_market_share_successfully_parsed =
      cumsum(if_else(.data$parsed, .data$colorado_enrollment_share, 0))
  )

write_with_provenance(
  saturation,
  file.path(artifact_dir, "colorado_saturation_table.csv"),
  inputs = c(COHORT, MARKET, OBS, MANIFEST)[file.exists(c(COHORT, MARKET, OBS, MANIFEST))]
)

# Timestamped copy: the running table is recomputed, the history is not.
write_csv(saturation,
          file.path(artifact_dir,
                    paste0("colorado_saturation_table_", timestamp, ".csv")))

accessmrf_pct <- function(x) if (is.na(x)) "  n/a" else sprintf("%5.1f%%", 100 * x)

base::message("")
base::message("=========================================================================")
base::message("COLORADO SATURATION  (cohort N = ", cohort_n, ")")
base::message("=========================================================================")
base::message(sprintf("%-26s %7s %7s %6s %6s %7s %7s",
                      "payer", "share", "cum(ok)", "files", "new", "cum", "% coh"))
for (i in seq_len(nrow(saturation))) {
  s <- saturation[i, ]
  base::message(sprintf(
    "%-26s %7s %7s %3s/%-2s %6d %7d %6.1f%%%s",
    substr(s$payer_group, 1, 26),
    accessmrf_pct(s$colorado_enrollment_share),
    accessmrf_pct(s$cumulative_market_share_successfully_parsed),
    s$files_parsed, s$files_attempted,
    s$cnms_newly_discovered, s$cnms_cumulative, s$pct_of_colorado_cohort,
    if (!s$attempted) "  (not yet attempted)" else
      if (!s$parsed) "  PARSE FAILED" else ""
  ))
}
base::message("-------------------------------------------------------------------------")
base::message("attempted coverage: ",
              accessmrf_pct(max(saturation$cumulative_market_share_attempted)),
              "   parsed coverage: ",
              accessmrf_pct(max(saturation$cumulative_market_share_successfully_parsed)))
base::message("Colorado CNMs observed in >=1 sampled payer: ",
              max(saturation$cnms_cumulative), " / ", cohort_n)
base::message("=========================================================================")
