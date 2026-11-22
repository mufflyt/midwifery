#!/usr/bin/env Rscript
# =============================================================================
# Billing gaps vs registry status (spec Workstream E)
# =============================================================================
# 27.1% of Part D midwives have an INTERIOR GAP -- a year inside their own
# observed span with no billing row. That rate has been quoted as evidence
# that the series is not carried forward, which it is. It has not been
# explained, and it has several possible causes: reduced billing, a change in
# insurance participation, a missing administrative record, retirement, or
# leaving the workforce.
#
# This separates the one cause that has dated evidence -- an NPI deactivation
# in NPPES -- from the ones that do not.
#
# THE SOURCE WAS ALREADY LOCAL. An earlier pass of this work recorded
# Workstream E as BLOCKED for want of an NPPES deactivation file. That was
# wrong: the data is in the warehouse as credentials.nppes_status (6,464,366
# rows; npi, deactivation_date, reactivation_date), under a schema that was
# never enumerated. Searching the filesystem for a *file* and concluding the
# *data* was absent is the mistake, and it is recorded here so the next
# reader checks schemas before concluding the same.
#
# WHAT THIS DOES NOT CLAIM. NPI deactivation is not retirement: an NPI is
# deactivated for death, for fraud, for duplicate enumeration, and at the
# provider's own request. Absence of Part D claims is not absence of
# practice: a midwife may bill no Medicare at all and have a full caseload.
# No row here is labelled "retired" or "left the workforce". The strongest
# label available is possible_workforce_exit, and it requires two signals.
#
# CONFLICTS ARE REPORTED, NOT RESOLVED. A midwife who bills AFTER her NPI was
# deactivated has an inconsistent timeline. That is a real and interesting
# condition -- it usually means the deactivation was reversed without a
# recorded reactivation, or the claim carries a stale NPI -- and the spec is
# explicit that such cases are to be identified rather than silently fixed.
#
# Inputs : artifacts/cohort_midwives_part_d_state_by_year.csv
#          artifacts/cohort_midwives_part_b_state_by_year.csv
#          credentials.nppes_status (MEDICARE_DUCKDB)
# Outputs: artifacts/billing_gap_registry_episodes.csv
#          artifacts/billing_gap_registry_summary.csv
#          artifacts/billing_gap_sensitivity.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
# gap_episodes() lives in R/lib so this script and
# audit_billing_gap_mechanisms.R cannot drift apart about what a gap is.
source(file.path("R", "lib", "billing_gaps.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

PART_D <- "artifacts/cohort_midwives_part_d_state_by_year.csv"
PART_B <- "artifacts/cohort_midwives_part_b_state_by_year.csv"

#' Classify one gap episode against registry evidence
#'
#' @param gap_start,gap_end [integer] the episode.
#' @param deact_year,react_year [integer] NPPES event years, NA when absent.
#' @return [character] one of the spec's classifications.
classify_gap <- function(gap_start, gap_end, deact_year, react_year) {
  has_d <- !is.na(deact_year)
  has_r <- !is.na(react_year)
  in_gap <- has_d && deact_year >= gap_start - 1L && deact_year <= gap_end
  if (in_gap && has_r && react_year <= gap_end + 1L)
    return("deactivated_and_reactivated_across_gap")
  if (in_gap) return("gap_with_dated_deactivation")
  if (has_d && deact_year < gap_start - 1L)
    return("deactivated_before_gap_then_billed")
  if (has_d) return("deactivated_after_gap")
  "gap_without_registry_evidence"
}

if (sys.nframe() == 0L) {
  pd <- readr::read_csv(PART_D, col_types = readr::cols(.default = "c"),
                        progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year)) %>% distinct()
  base::message(sprintf("Part D: %s npi-years, %s midwives",
                        format(nrow(pd), big.mark = ","),
                        format(dplyr::n_distinct(pd$npi), big.mark = ",")))

  con <- duckdb_connect(resolve_midwifery_duckdb(), read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "w", data.frame(npi = unique(pd$npi)),
                    temporary = TRUE, overwrite = TRUE)
  reg <- DBI::dbGetQuery(con, "
    SELECT trim(s.npi) AS npi,
           year(s.deactivation_date) AS deact_year,
           year(s.reactivation_date) AS react_year,
           s.deactivation_date, s.reactivation_date
      FROM credentials.nppes_status s
      JOIN w ON w.npi = trim(s.npi)
     WHERE s.deactivation_date IS NOT NULL OR s.reactivation_date IS NOT NULL")
  base::message(sprintf("registry events for %s of those midwives",
                        format(nrow(reg), big.mark = ",")))

  ep <- gap_episodes(pd)
  n_mid <- dplyr::n_distinct(pd$npi)
  n_gap_mid <- dplyr::n_distinct(ep$npi)
  base::message(sprintf("interior gaps: %s of %s midwives (%.1f%%) across %s episodes",
                        format(n_gap_mid, big.mark = ","),
                        format(n_mid, big.mark = ","),
                        100 * n_gap_mid / n_mid,
                        format(nrow(ep), big.mark = ",")))

  ep <- ep %>% left_join(reg[, c("npi", "deact_year", "react_year")], by = "npi")
  ep$classification <- mapply(classify_gap, ep$gap_start, ep$gap_end,
                              ep$deact_year, ep$react_year)
  # Every interior gap ends with resumed billing BY CONSTRUCTION -- that is
  # what makes it interior. Recorded explicitly so no reader has to infer it.
  ep$resumes_billing <- TRUE

  # Conflicting timelines: billing observed strictly after a deactivation with
  # no recorded reactivation. Reported, never resolved.
  conflict <- pd %>% inner_join(reg, by = "npi") %>%
    filter(!is.na(deact_year), is.na(react_year), year > deact_year) %>%
    group_by(npi, deact_year) %>%
    # max() on an empty group warns and returns -Inf. Zero conflicts is the
    # expected and (so far) observed result, so the empty case is the one
    # this must handle cleanly rather than the one it warns on.
    summarise(billed_years_after_deactivation = dplyr::n(),
              last_billed_year = if (dplyr::n() == 0L) NA_integer_
                                 else max(year), .groups = "drop")

  summ <- ep %>% count(classification, name = "n_episodes") %>%
    mutate(n_midwives = vapply(classification, function(k)
             dplyr::n_distinct(ep$npi[ep$classification == k]), integer(1)),
           pct_of_episodes = round(100 * n_episodes / nrow(ep), 1)) %>%
    arrange(desc(n_episodes))

  # SENSITIVITY: the interior-gap rate depends on what counts as activity and
  # on how long a gap must be to matter. Neither is a fact about midwives.
  pb <- if (file.exists(PART_B))
    readr::read_csv(PART_B, col_types = readr::cols(.default = "c"),
                    progress = FALSE) %>%
      transmute(npi = trimws(npi), year = as.integer(year)) %>% distinct()
    else NULL
  defs <- list(
    list(label = "part_d_only_any_gap", d = pd, min_len = 1L),
    list(label = "part_d_only_gap_ge_2yr", d = pd, min_len = 2L),
    list(label = "part_d_only_gap_ge_3yr", d = pd, min_len = 3L))
  if (!is.null(pb))
    defs <- c(defs, list(
      list(label = "part_b_or_part_d_any_gap",
           d = distinct(bind_rows(pd, pb)), min_len = 1L)))
  sens <- bind_rows(lapply(defs, function(s) {
    e <- gap_episodes(s$d); e <- e[e$gap_len >= s$min_len, , drop = FALSE]
    nm <- dplyr::n_distinct(s$d$npi)
    tibble(definition = s$label, n_midwives = nm,
           n_with_gap = dplyr::n_distinct(e$npi),
           pct_with_gap = round(100 * dplyr::n_distinct(e$npi) / nm, 1),
           n_episodes = nrow(e))
  }))

  write_with_provenance(ep, "artifacts/billing_gap_registry_episodes.csv",
                        inputs = c(PART_D), na = "")
  write_with_provenance(summ, "artifacts/billing_gap_registry_summary.csv",
                        inputs = c(PART_D), na = "")
  write_with_provenance(sens, "artifacts/billing_gap_sensitivity.csv",
                        inputs = c(PART_D, PART_B), na = "")
  # Written even when empty. Zero contradictory timelines is a FINDING -- it
  # says the registry and the claims agree about who was enumerated when --
  # and an absent file is indistinguishable from an unrun analysis.
  write_with_provenance(conflict, "artifacts/billing_gap_registry_conflicts.csv",
                        inputs = PART_D, na = "")

  cat("\n=== classification of interior-gap episodes ===\n")
  print(as.data.frame(summ), row.names = FALSE)
  cat("\n=== sensitivity ===\n")
  print(as.data.frame(sens), row.names = FALSE)
  cat(sprintf("\nconflicting timelines (billed after deactivation, no reactivation): %s midwives\n",
              format(nrow(conflict), big.mark = ",")))
}
