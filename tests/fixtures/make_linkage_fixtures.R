#!/usr/bin/env Rscript
#' @title Synthetic fixtures for the three person-level linkage scripts
#'
#' @description
#' `build_linkage_case_gallery.R`, `make_evidence_class_figure.R` and
#' `analyze_temporal_plausibility.R` all read the frozen crosswalk, which is
#' person-level and gitignored. On a clean checkout that means none of them can
#' be exercised at all, and they were built and merged with no CI coverage
#' whatsoever -- verified only against fixtures that lived in a scratch
#' directory and evaporated with the session.
#'
#' This regenerates those fixtures deterministically instead.
#'
#' @section Why a generator and not committed CSVs:
#' Committing files of invented names, certification numbers and NPIs into a
#' repository whose entire discipline is that person-level rows stay out of git
#' would put something in the tree that LOOKS like the real cohort. Someone
#' would eventually read it as data. A seeded generator writes to a temp
#' directory, is reproducible from the seed, and leaves nothing behind.
#'
#' The names are deliberately implausible as a set -- six surnames repeated
#' across every stratum -- so that no output of these fixtures could be mistaken
#' for a cohort even at a glance.
#'
#' @section What it covers:
#' The schema is read from the real crosswalk's tracked manifest, so a column
#' added upstream appears here without anyone remembering to add it. Rows are
#' built to populate every stratum the three scripts branch on, including the
#' three that matter most: uniqueness manufactured by the middle-name veto, a
#' sole candidate vetoed away, and an NPPES record renamed since the match.
#'
#' Usage:
#'   src <- source("tests/fixtures/make_linkage_fixtures.R")$value
#'   f   <- mw_make_linkage_fixtures(tempfile("fx"))
#'   f$crosswalk; f$panel; f$audit
#'
#' @family fixtures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(jsonlite)})

#' @param dir directory to write into; created if absent.
#' @param seed integer seed; the same seed gives byte-identical fixtures.
#' @param manifest path to the crosswalk manifest supplying the column list.
#' @return list(crosswalk=, panel=, audit=, n_rows=)
mw_make_linkage_fixtures <- function(dir = tempfile("linkage_fixtures"),
                                     seed = 20260902L,
                                     manifest = file.path(
                                       "artifacts",
                                       "amcb_npi_linkage_FROZEN.csv.manifest.json")) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  set.seed(seed)

  cols <- if (file.exists(manifest)) fromJSON(manifest)$columns else
    c("certification", "certification_number", "status", "certification_date",
      "last_name", "first_name", "middle_name", "amcb_id", "amcb_name_original",
      "npi", "npi_match_method", "nppes_matched_last", "nppes_matched_first",
      "npi_tax_class", "name_evidence_class", "npi_match_resolution",
      "npi_match_confidence", "match_strategy", "nppes_first_name",
      "nppes_middle_name", "nppes_last_name", "nppes_credential", "nppes_city",
      "nppes_state", "nppes_zip", "nppes_location_year", "n_candidates_pre_rank",
      "n_midwifery_candidates", "n_nursing_only_candidates", "best_evidence_class",
      "n_at_best_class", "n_mid_vetoed_c5", "resolved_by_absence_c5",
      "npi_demoted_absence_c5", "npi_match_status", "has_candidate",
      "linkage_tier", "candidate_count", "nppes_name_changed_since_match",
      "ambiguity_flag", "match_reason", "class5_candidate_npi", "cohort_member")

  L <- c("SMITH", "JOHNSON", "OKONKWO", "MARTINEZ-REYES", "NGUYEN", "OBRIEN")
  F <- c("MARY", "ELIZABETH", "AISHA", "JOHN", "PRIYA", "SUSAN")
  M <- c("ANN", "", "B", "MARIE", "", "LOUISE")
  fake_npi <- function() sprintf("1%09d", sample.int(1e9, 1))

  blank <- setNames(as.list(rep("", length(cols))), cols)
  base <- function(i) {
    k <- (i %% 6L) + 1L
    r <- blank
    mid <- M[k]
    r$certification <- "Certified Nurse-Midwife"
    r$certification_number <- sprintf("CNM%05d", 10000L + i)
    r$amcb_id <- r$certification_number
    r$status <- sample(c("ACTIVE", "LAPSED", "RETIRED", "DECEASED"), 1)
    r$certification_date <- sprintf("%d-06-01", sample(1995:2024, 1))
    r$last_name <- L[k]; r$first_name <- F[k]; r$middle_name <- mid
    r$amcb_name_original <- trimws(gsub("  ", " ", paste(F[k], mid, L[k])))
    r$nppes_credential <- "RN, CNM"; r$nppes_city <- "DENVER"
    r$nppes_state <- "CO"; r$nppes_zip <- "80204"; r$nppes_location_year <- "2025"
    r$cohort_member <- "TRUE"; r$has_candidate <- "TRUE"
    r$n_candidates_pre_rank <- "3"; r$n_at_best_class <- "1"
    r$n_midwifery_candidates <- "2"; r$n_nursing_only_candidates <- "1"
    r$n_mid_vetoed_c5 <- "0"; r$resolved_by_absence_c5 <- "FALSE"
    r$npi_demoted_absence_c5 <- "FALSE"
    r$nppes_name_changed_since_match <- "FALSE"
    r$match_reason <- "unique at best class"
    r
  }
  accept <- function(r, cls, method, tier = "primary_midwifery") {
    r$npi <- fake_npi()
    r$nppes_last_name <- r$last_name; r$nppes_first_name <- r$first_name
    r$nppes_middle_name <- r$middle_name
    r$nppes_matched_last <- r$last_name; r$nppes_matched_first <- r$first_name
    r$npi_match_status <- "matched"; r$name_evidence_class <- as.character(cls)
    r$best_evidence_class <- as.character(cls); r$npi_match_method <- method
    r$npi_match_resolution <- "unique_best_class"; r$linkage_tier <- tier
    r$npi_tax_class <- "midwife"
    r
  }

  rows <- list(); add <- function(r) rows[[length(rows) + 1L]] <<- r
  i <- 0L; nxt <- function() { i <<- i + 1L; base(i) }

  for (k in 1:9) add(accept(nxt(), 1, "exact_last_first"))
  for (k in 1:9) add(accept(nxt(), 2, "exact_last_first"))
  for (k in 1:9) { r <- accept(nxt(), 3, "exact_last_first_initial")
                   r$nppes_first_name <- "JOANNE"; r$n_candidates_pre_rank <- "14"; add(r) }
  for (k in 1:9) { r <- accept(nxt(), 4, "fuzzy_last_exact_first", "sensitivity_fuzzy")
                   r$nppes_last_name <- paste0(r$last_name, "Z"); add(r) }
  for (k in 1:9) { r <- accept(nxt(), 2, "exact_last_first", "sensitivity_nursing")
                   r$npi_match_status <- "matched_nursing_taxonomy"
                   r$npi_tax_class <- "nursing"; r$nppes_credential <- "RN"; add(r) }
  for (k in 1:9) { r <- nxt(); r$npi_match_status <- "ambiguous_tied_names"
                   r$n_at_best_class <- as.character(sample(c(2, 3, 18, 348), 1))
                   r$name_evidence_class <- "3"; r$best_evidence_class <- "3"
                   r$linkage_tier <- "quarantined"; r$n_candidates_pre_rank <- "348"
                   r$cohort_member <- "FALSE"; r$ambiguity_flag <- "tied_at_best_class"
                   r$match_reason <- "multiple candidates at strongest class"; add(r) }
  for (k in 1:9) { r <- nxt(); r$npi_match_status <- "unmatched"
                   r$has_candidate <- "FALSE"; r$n_candidates_pre_rank <- "0"
                   r$n_at_best_class <- "0"; r$n_midwifery_candidates <- "0"
                   r$n_nursing_only_candidates <- "0"; r$linkage_tier <- "unmatched"
                   r$cohort_member <- "FALSE"; r$certification_date <- "1998-06-01"
                   r$match_reason <- "no candidate generated"; add(r) }
  for (k in 1:6) { r <- accept(nxt(), 1, "exact_last_first")
                   r$npi <- "1999999999"
                   r$npi_match_status <- "ambiguous_contested_npi"
                   r$linkage_tier <- "quarantined"; r$cohort_member <- "FALSE"
                   r$ambiguity_flag <- "contested"; add(r) }
  for (k in 1:6) { r <- nxt(); r$npi_match_status <- "unmatched"
                   r$name_evidence_class <- "5"; r$best_evidence_class <- "5"
                   r$npi_demoted_absence_c5 <- "TRUE"
                   r$class5_candidate_npi <- "1888888888"
                   r$linkage_tier <- "quarantined"; r$cohort_member <- "FALSE"
                   r$match_reason <- "class-5 candidate held out by guard"; add(r) }
  # The three that matter most.
  for (k in 1:6) { r <- accept(nxt(), 2, "exact_last_first")
                   r$resolved_by_absence_c5 <- "TRUE"
                   r$n_mid_vetoed_c5 <- as.character(sample(1:4, 1))
                   r$n_candidates_pre_rank <- "5"
                   r$match_reason <- "sole survivor after middle-name veto"; add(r) }
  for (k in 1:6) { r <- nxt(); r$npi_match_status <- "unmatched"
                   r$has_candidate <- "FALSE"; r$n_mid_vetoed_c5 <- "1"
                   r$n_candidates_pre_rank <- "1"; r$n_at_best_class <- "0"
                   r$linkage_tier <- "unmatched"; r$cohort_member <- "FALSE"
                   r$match_reason <- "only candidate vetoed on middle initial"; add(r) }
  for (k in 1:6) { r <- accept(nxt(), 1, "exact_last_first")
                   r$nppes_name_changed_since_match <- "TRUE"
                   r$nppes_last_name <- paste0(r$last_name, "-WALSH"); add(r) }

  cw <- do.call(rbind, lapply(rows, function(r) as.data.frame(r, stringsAsFactors = FALSE)))
  cw <- cw[, cols, drop = FALSE]
  f_cw <- file.path(dir, "fixture_FROZEN.csv")
  write.csv(cw, f_cw, row.names = FALSE, na = "")

  # Panel: one row per NPI per year, first-seen varying so censoring is exercised.
  pan <- do.call(rbind, lapply(cw$npi[nzchar(cw$npi)], function(n) {
    y0 <- sample(c(2007L, 2011L, 2016L), 1)
    data.frame(npi = n, snapshot_year = y0:2025L, stringsAsFactors = FALSE)
  }))
  f_pan <- file.path(dir, "fixture_panel.csv")
  write.csv(pan, f_pan, row.names = FALSE)

  # Candidate audit: rival candidates for the tied records only.
  tied <- cw$amcb_id[cw$npi_match_status == "ambiguous_tied_names"]
  aud <- do.call(rbind, lapply(tied, function(id) {
    do.call(rbind, lapply(seq_len(sample(2:3, 1)), function(k) {
      fy <- sample(c(2007L, 1998L, 2012L, 2015L), 1)
      data.frame(amcb_id = id, npi = fake_npi(), name_evidence_class = 3L,
                 first_year = fy, last_year = 2025L,
                 first_year_censored = fy == 2007L, stringsAsFactors = FALSE)
    }))
  }))
  f_aud <- file.path(dir, "fixture_audit.csv")
  write.csv(aud, f_aud, row.names = FALSE)

  list(crosswalk = f_cw, panel = f_pan, audit = f_aud, dir = dir, n_rows = nrow(cw))
}

mw_make_linkage_fixtures
