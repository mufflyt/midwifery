#!/usr/bin/env Rscript
# =============================================================================
# Reconstructed transitions vs independently dated source observations
# =============================================================================
# A "transition" is one midwife's adjacent-year pair. Thousands of them can
# rest on a handful of real measurements, and the difference decides whether a
# temporal finding is evidence or arithmetic. Reporting 28,357 Part D
# transitions without also reporting that they come from 12 annual CMS
# publications across 11 intervals overstates the evidence by three orders of
# magnitude.
#
# This script computes both numbers for every longitudinal source, plus the
# INTERIOR GAP rate -- years inside a midwife's own observed span where she has
# no row. That rate is the empirical test for carry-forward: a series built by
# propagating a value cannot contain interior gaps at all. Finding 27.1% of
# Part D midwives with one is positive evidence that no reconstruction function
# in this pipeline fills a missing year.
#
# It computes, and does not judge. The counts of dated source artifacts are
# declared in SOURCE_VINTAGES below because they are facts about how each
# upstream publishes, not something derivable from the extract: a file that
# collapses 41 monthly releases into 6 year-end values has destroyed the
# evidence of the 41 by the time it is written.
#
# Inputs : midwife_panel.csv
#          artifacts/pecos_revalidation_cohort_state_by_year.csv
#          artifacts/cohort_midwives_part_b_state_by_year.csv
#          artifacts/cohort_midwives_part_d_state_by_year.csv
# Outputs: artifacts/source_series_independence.csv
#          artifacts/source_series_interior_gaps.csv
# See    : docs/source-series-reconstruction.md S1 and S4
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

SERIES <- list(
  nppes = list(
    path = "midwife_panel.csv", year_col = "snapshot_year",
    artifacts_n = 20L,
    artifacts_desc = "NPPES dissemination files, one per year, 2007-11-12 to 2026-08-09"),
  pecos_revalidation = list(
    path = "artifacts/pecos_revalidation_cohort_state_by_year.csv", year_col = "year",
    artifacts_n = 41L,
    artifacts_desc = "monthly CMS Revalidation Reassignment releases, 2021-12 to 2026-11, collapsed to year-end"),
  medicare_part_b = list(
    path = "artifacts/cohort_midwives_part_b_state_by_year.csv", year_col = "year",
    artifacts_n = 12L,
    artifacts_desc = "annual CMS Physician & Other Practitioners by-Provider publications, 2013-2024"),
  medicare_part_d = list(
    path = "artifacts/cohort_midwives_part_d_state_by_year.csv", year_col = "year",
    artifacts_n = 12L,
    artifacts_desc = "annual CMS Part D Prescribers by-Provider publications, 2013-2024")
)

#' Load one series as distinct (npi, year) pairs
#'
#' State is deliberately not carried: this audit counts observations and
#' intervals, and a value's content cannot change how many times it was
#' measured.
#'
#' @param spec [list] one SERIES entry.
#' @return [data.frame] npi, year -- distinct; NULL when the file is absent, so
#'   a clone missing a person-level extract reports that series as unmeasured
#'   rather than as having zero transitions.
load_pairs <- function(spec) {
  if (!file.exists(spec$path)) {
    cat(sprintf("  %-20s absent, skipped (%s)\n", "", spec$path)); return(NULL)
  }
  d <- read_csv(spec$path, col_types = cols(.default = "c"), progress = FALSE)
  if (!all(c("npi", spec$year_col) %in% names(d)))
    stop(sprintf("%s lacks npi/%s", spec$path, spec$year_col), call. = FALSE)
  d %>% transmute(npi = trimws(.data[["npi"]]),
                  year = suppressWarnings(as.integer(.data[[spec$year_col]]))) %>%
    filter(!is.na(npi), nzchar(npi), !is.na(year)) %>% distinct()
}

#' Adjacent-year transitions, and the intervals they fall in
#'
#' An adjacent pair is (year, year+1) for one midwife. Non-adjacent pairs are
#' NOT transitions: a midwife observed in 2015 and again in 2019 did not make
#' one transition over four years, she made an unknown number, and counting it
#' as one would invent a measurement.
#'
#' @param d [data.frame] npi, year.
#' @return [data.frame] npi, year (the earlier year of each adjacent pair).
adjacent_transitions <- function(d) {
  d %>% arrange(npi, year) %>% group_by(npi) %>%
    mutate(nxt = lead(year)) %>% ungroup() %>%
    filter(!is.na(nxt), nxt == year + 1L) %>% select(npi, year)
}

cat("Source-series independence audit\n\n")
ind <- list(); gaps <- list()
for (nm in names(SERIES)) {
  spec <- SERIES[[nm]]
  d <- load_pairs(spec)
  if (is.null(d)) next
  tr <- adjacent_transitions(d)
  ind[[nm]] <- tibble(
    source                   = nm,
    dated_source_artifacts   = spec$artifacts_n,
    source_artifact_detail   = spec$artifacts_desc,
    distinct_years           = n_distinct(d$year),
    year_min                 = min(d$year), year_max = max(d$year),
    distinct_npis            = n_distinct(d$npi),
    npi_years                = nrow(d),
    adjacent_transitions     = nrow(tr),
    distinct_year_intervals  = n_distinct(tr$year),
    transitions_per_interval = if (nrow(tr)) round(nrow(tr) / n_distinct(tr$year)) else NA_real_)

  # interior gap: observed fewer years than the span between first and last
  g <- d %>% group_by(npi) %>%
    summarise(span = max(year) - min(year) + 1L, observed = n(), .groups = "drop") %>%
    mutate(has_interior_gap = observed < span)
  gaps[[nm]] <- tibble(source = nm, n_npis = nrow(g),
                       n_with_interior_gap = sum(g$has_interior_gap),
                       pct_with_interior_gap = round(100 * mean(g$has_interior_gap), 1))
  cat(sprintf("  %-20s %2d dated artifacts -> %s transitions over %d intervals; %.1f%% have interior gaps\n",
              nm, spec$artifacts_n, format(nrow(tr), big.mark = ","),
              n_distinct(tr$year), 100 * mean(g$has_interior_gap)))
}
stopifnot(length(ind) > 0)
ind <- bind_rows(ind); gaps <- bind_rows(gaps)

write_with_provenance(ind, "artifacts/source_series_independence.csv",
                      inputs = unlist(lapply(SERIES, `[[`, "path")), na = "")
write_with_provenance(gaps, "artifacts/source_series_interior_gaps.csv",
                      inputs = unlist(lapply(SERIES, `[[`, "path")), na = "")
cat("\nwrote artifacts/source_series_independence.csv and _interior_gaps.csv\n")
cat("\nREAD THIS BEFORE QUOTING A TRANSITION COUNT: adjacent_transitions is\n")
cat("npi-pairs, not independent observations. The independent time points are\n")
cat("distinct_years. Confidence intervals computed over transitions treat\n")
cat("repeated measurements of the same midwife as independent and are\n")
cat("anticonservative -- see docs/source-series-reconstruction.md S8, A2.\n")
