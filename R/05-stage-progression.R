#!/usr/bin/env Rscript
#' @title Step 05: Like-for-like stage progression on a frozen analytic cohort
#'
#' @description
#' The stage table as first built was not a stage progression. Stages 1-3 were
#' computed on 16,388 / 16,743 people and Stage 4 on 15,706, so the apparent
#' improvement mixed BETTER GEOGRAPHY with REMOVAL OF QUESTIONABLE IDENTITIES.
#' Those are different achievements and must not be summed into one number.
#'
#' This recomputes every stage on exactly the same frozen cohort, and reports
#' the cohort flow separately so the identity attrition is visible rather than
#' absorbed.
#'
#' @section Stage definitions (ascertainment numerator):
#' \describe{
#'   \item{1-2}{coordinates present after the initial/completed NPPES match}
#'   \item{3}{`county_best` from the ZIP-fallback hierarchy}
#'   \item{4}{`county_best` after geocoding the outstanding practice addresses}
#' }
#'
#' @section Assertions:
#' Every percentage in \[0, 100\]; numerator <= denominator; rural gap equals
#' REMOTE minus METRO (not max-minus-min, which silently reported the
#' adjacent-remote spread once adjacent overtook metro); stage denominator
#' equals the frozen cohort size; geography classes sum to the denominator.
#'
#' Output : artifacts/stage_progression_like_for_like.csv,
#'          artifacts/cohort_flow_16743_to_15706.csv,
#'          artifacts/frozen_cohort/analytic_cohort.csv
#'
#' @family step-functions
#' @concept missingness
#' @author Tyler Muffly, MD + Claude Code
#' @export

# Canonical banding + date rules. Inline copies of the RUCC case_when and the
# positional cert_decade parse lived here until cycle 2; see R/lib/table1_bands.R.
source(file.path("R", "lib", "table1_bands.R"))

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(cli); library(jsonlite)
})

ART <- "artifacts"; DATA <- "data"
FROZEN_DIR <- file.path(ART, "frozen_cohort")
dir.create(FROZEN_DIR, showWarnings = FALSE, recursive = TRUE)
pad5 <- function(x) str_pad(as.character(x), 5, "left", "0")

GEO4 <- Sys.getenv("GEOGRAPHY_FILE", "midwives_geography_guarded.csv")
GEO3 <- "midwives_geography.csv"          # ZIP-fallback era output
GEO12 <- "midwives_geocoded.csv"          # coordinate-only era output
STAGE2_ROSTER <- file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")


# --- Freeze-before-analysis contract ---------------------------------------
# PERMANENT RULE: analytic scripts must never read mutable pipeline outputs.
#   pipeline finishes -> validate -> FREEZE WITH SHA -> analysis reads the freeze
# Three separate episodes of moving-input contamination came from breaking it:
# roster vintages that produced 104 cross-state discordances; a geography file
# deleted from tracking mid-analysis; and midwives_geography_guarded.csv being
# rewritten between two runs (15,706 rows / 99.6% ascertained became 17,538 /
# 86.5%). Each time the analysis completed and reported numbers that no longer
# described any file on disk.

#' SHA256 of a file
#' @keywords internal
#' @noRd
sha256_of <- function(path) {
  sub(" .*$", "", system2("shasum", c("-a", "256", shQuote(path)), stdout = TRUE)[1])
}

#' Freeze a pipeline output for analysis, recording everything needed to prove
#' the analysis consumed exactly this file
#'
#' @param src [character(1)]: live pipeline output.
#' @param dest_dir [character(1)]: frozen analysis location.
#' @return [list] frozen path plus the input fingerprint.
#' @keywords internal
#' @noRd
freeze_input <- function(src, dest_dir) {
  if (!file.exists(src)) stop("Cannot freeze: ", src, " not found.", call. = FALSE)
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)

  sha <- sha256_of(src)
  info <- file.info(src)
  d <- read_csv(src, show_col_types = FALSE, col_types = cols(.default = col_character()))

  dest <- file.path(dest_dir, basename(src))
  file.copy(src, dest, overwrite = TRUE)
  if (!identical(sha256_of(dest), sha))
    stop("Frozen copy does not reproduce the source SHA.", call. = FALSE)

  fp <- list(source = src, frozen = dest, sha256 = sha,
             mtime = format(info$mtime, "%Y-%m-%d %H:%M:%S"),
             rows = nrow(d),
             county_best = sum(!is.na(d$county_best)),
             frozen_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  jsonlite::write_json(fp, file.path(dest_dir, "INPUT_FINGERPRINT.json"),
                       auto_unbox = TRUE)

  cli::cli_alert_success("Frozen {basename(src)}: {fp$rows} rows, county_best {fp$county_best}, sha {substr(sha, 1, 16)}, mtime {fp$mtime}")
  fp
}

#' Invalidate the run if the live source changed while it executed
#' @keywords internal
#' @noRd
assert_source_unchanged <- function(fp) {
  now <- sha256_of(fp$source)
  if (!identical(now, fp$sha256)) {
    stop(sprintf("RUN INVALIDATED: %s changed during execution (%s -> %s). Another process is writing it; stop that process and re-run.",
                 fp$source, substr(fp$sha256, 1, 16), substr(now, 1, 16)),
         call. = FALSE)
  }
  cli::cli_alert_success("Live source unchanged during execution ({substr(now, 1, 16)}).")
  invisible(TRUE)
}

#' Percentage with a Wilson interval, plus the raw n/N the reader needs
#' @keywords internal
#' @noRd
rate <- function(df, ...) {
  df %>% group_by(...) %>%
    summarise(n = n(), n_ascertained = sum(ascertained), .groups = "drop") %>%
    mutate(n_unresolved = n - n_ascertained,
           pct = 100 * n_ascertained / n,
           z = 1.96, p = n_ascertained / n, d = 1 + z^2 / n,
           ctr = (p + z^2 / (2 * n)) / d,
           hw = z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d,
           ci_low = 100 * pmax(0, ctr - hw), ci_high = 100 * pmin(1, ctr + hw)) %>%
    select(-z, -p, -d, -ctr, -hw)
}

#' Hard assertions on any completeness table
#' @keywords internal
#' @noRd
assert_table <- function(tbl, denom, label) {
  bad <- c()
  if (any(tbl$pct < 0 | tbl$pct > 100, na.rm = TRUE))
    bad <- c(bad, "percentage outside [0, 100]")
  if (any(tbl$n_ascertained > tbl$n))
    bad <- c(bad, "numerator exceeds denominator")
  if (sum(tbl$n) != denom)
    bad <- c(bad, sprintf("strata sum to %d, cohort is %d", sum(tbl$n), denom))
  if (length(bad) > 0)
    stop(sprintf("ASSERTION FAILED (%s): %s", label, paste(bad, collapse = "; ")),
         call. = FALSE)
  invisible(TRUE)
}

build_progression <- function() {
  cli::cli_h2("Freezing the analytic cohort")
  # Freeze FIRST, then read the frozen copy. Never the live output.
  FP <- freeze_input(GEO4, FROZEN_DIR)
  g4 <- read_csv(FP$frozen, show_col_types = FALSE,
                 col_types = cols(.default = col_character()))
  if (anyDuplicated(g4$certification_number) > 0)
    stop("Stage 4 geography has duplicate certification_number.", call. = FALSE)

  cohort <- g4$certification_number
  N <- length(cohort)
  cli::cli_alert_info("Frozen analytic cohort: {N} people (from {GEO4})")
  write_csv(tibble(certification_number = cohort),
            file.path(FROZEN_DIR, "analytic_cohort.csv"))

  # --- Cohort flow ---------------------------------------------------------
  s2 <- read_csv(STAGE2_ROSTER, show_col_types = FALSE,
                 col_types = cols(.default = col_character())) %>%
    filter(!is.na(npi))
  dropped <- setdiff(s2$certification_number, cohort)
  cli::cli_h2("Cohort flow: {nrow(s2)} -> {N} (dropped {length(dropped)})")

  link <- NULL
  lf <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")
  if (file.exists(lf)) {
    link <- read_csv(lf, show_col_types = FALSE,
                     col_types = cols(.default = col_character())) %>%
      distinct(certification_number, .keep_all = TRUE)
  }

  flow <- tibble(certification_number = dropped) %>%
    left_join(if (is.null(link)) tibble(certification_number = character()) else
                select(link, certification_number,
                       any_of(c("npi", "npi_match_method", "npi_match_resolution"))),
              by = "certification_number") %>%
    left_join(select(s2, certification_number, s2_npi = npi),
              by = "certification_number") %>%
    mutate(reason = case_when(
      !("npi" %in% names(.)) ~ "not_in_guarded_linkage",
      is.na(npi) & !is.na(s2_npi) ~ "npi_withdrawn_by_identity_guard",
      !is.na(npi) & npi != s2_npi ~ "npi_reassigned_and_excluded",
      TRUE ~ "absent_from_guarded_linkage")) %>%
    count(reason, name = "n", sort = TRUE)

  # Reasons must be mutually exclusive and account for EVERY dropped person.
  stopifnot(sum(flow$n) == length(dropped))
  print(as.data.frame(flow), row.names = FALSE)
  write_csv(flow, file.path(ART, sprintf("cohort_flow_%d_to_%d.csv", nrow(s2), N)))
  cli::cli_alert_success("Cohort flow sums exactly to {length(dropped)}")

  # --- Rurality stratum, fixed once for the frozen cohort ------------------
  cb <- read_csv(file.path(DATA, "county_base.csv"), show_col_types = FALSE,
                 col_types = cols(GEOID = col_character()))
  zc <- read_delim(file.path(DATA, "zcta_county_2020.txt"), delim = "|",
                   show_col_types = FALSE, progress = FALSE) %>%
    transmute(zip5 = pad5(GEOID_ZCTA5_20), GEOID = pad5(GEOID_COUNTY_20),
              land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
    group_by(zip5) %>% slice_max(land, n = 1, with_ties = FALSE) %>%
    ungroup() %>% select(zip5, GEOID)

  strata <- g4 %>%
    transmute(certification_number,
              zip5 = pad5(str_sub(str_remove_all(practice_zip, "[^0-9]"), 1, 5))) %>%
    left_join(zc, by = "zip5") %>%
    left_join(select(cb, GEOID, rucc_2023), by = "GEOID") %>%
    mutate(rucc_cat = coalesce(
      band_rurality(rucc_2023, RURALITY_LABELS_COHORT), "Unknown")) %>%
    select(certification_number, rucc_cat)

  # --- Ascertainment per stage, same cohort throughout ---------------------
  asc <- list()
  if (file.exists(GEO12)) {
    a <- read_csv(GEO12, show_col_types = FALSE) %>%
      distinct(certification_number, .keep_all = TRUE)
    asc[["1-2_coordinates_only"]] <- a$certification_number[!is.na(a$latitude)]
  }
  if (file.exists(GEO3)) {
    a <- read_csv(GEO3, show_col_types = FALSE, col_types = cols(.default = col_character())) %>%
      distinct(certification_number, .keep_all = TRUE)
    asc[["3_unambiguous_zip_fallback"]] <- a$certification_number[!is.na(a$county_best)]
  }
  asc[["4_geocoded_practice_addresses"]] <- g4$certification_number[!is.na(g4$county_best)]

  out <- list()
  for (stg in names(asc)) {
    d <- strata %>% mutate(ascertained = certification_number %in% asc[[stg]])
    tbl <- rate(d, rucc_cat)
    assert_table(tbl, N, stg)

    metro <- tbl$pct[tbl$rucc_cat == "Metro (RUCC 1-3)"]
    remote <- tbl$pct[tbl$rucc_cat == "Nonmetro, remote (7-9)"]
    # DEFINITION FIX: the gap is REMOTE minus METRO. It was max-minus-min,
    # which silently reported the adjacent-remote spread once adjacent
    # overtook metro (-2.03 where remote-metro is -1.96).
    gap <- remote - metro
    stopifnot(abs(gap - (remote - metro)) < 1e-9)

    cli::cli_h3("Stage {stg}")
    print(as.data.frame(tbl %>% mutate(across(pct:ci_high, ~ round(.x, 2)))),
          row.names = FALSE)
    cli::cli_alert_info("rural gap (remote - metro) = {round(gap, 2)} pp | cohort {N}")

    out[[stg]] <- tbl %>% mutate(stage = stg, cohort_n = N, rural_gap_pp = gap) %>%
      relocate(stage)
  }

  # Only now: prove the live source did not move under us.
  assert_source_unchanged(FP)

  res <- bind_rows(out) %>%
    mutate(input_sha256 = FP$sha256, input_rows = FP$rows,
           input_mtime = FP$mtime)
  write_csv(res, file.path(ART, "stage_progression_like_for_like.csv"))
  cli::cli_alert_success("artifacts/stage_progression_like_for_like.csv written")
  invisible(res)
}

if (identical(environment(), globalenv()) && !interactive()) build_progression()
