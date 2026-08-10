#!/usr/bin/env Rscript
#' @title Step 06: Bidirectional cohort flow, Stage 2 -> final analytic cohort
#'
#' @description
#' The first cohort-flow artifact was one-sided: it itemised only the 1,352
#' removals and left the 2,147 additions unexplained. A net change of +795
#' hides substantial churn, and the churn is the linkage story.
#'
#' The accounting identity this enforces:
#' \preformatted{
#'   16,743 Stage-2 cohort + 2,147 additions - 1,352 removals = 17,538 final
#' }
#'
#' @section Additions are not new people:
#' Every added certification number is already present in the Stage-2 roster
#' FILE; what changed is its linkage state, not its existence. They are
#' therefore reported as additions to the ANALYTIC cohort caused by
#' linkage/resolution changes, never as "new midwives". The classifier asserts
#' this rather than assuming it.
#'
#' @section Classification:
#' Every added person is classified mutually exclusively from their prior
#' Stage-2 state and their final linkage state. Categories are populated from
#' the data, not presumed; any person left unclassified is a hard failure.
#'
#' Output : artifacts/cohort_flow_bidirectional.csv,
#'          artifacts/cohort_additions_16743_to_17538.csv,
#'          artifacts/cohort_additions_by_mechanism.csv
#'
#' @family step-functions
#' @concept cohort-flow
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr); library(cli)
})

# CYCLE 21b. Inputs recorded beside every artifact this script writes, so a
# reader can tell whether the numbers were built from the bytes still on disk.
source(file.path("R", "lib", "artifact_provenance.R"))

# Helpers shared with the other numbered scripts. Defined once: these were
# duplicated across files sourced into one environment, where load order
# decided which definition won.
source(file.path("R", "lib", "common_helpers.R"))

ART <- "artifacts"
STAGE2 <- file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")
COHORT <- file.path(ART, "frozen_cohort", "analytic_cohort.csv")
LINKAGE <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")


build_flow <- function() {
  s2_all <- chr(STAGE2)
  final <- chr(COHORT)
  link <- if (file.exists(LINKAGE)) {
    chr(LINKAGE) %>% distinct(certification_number, .keep_all = TRUE)
  } else NULL

  # The Stage-2 COHORT is the matched subset, not the whole roster file.
  s2_cohort <- s2_all$certification_number[!is.na(s2_all$npi)]
  fin_cohort <- final$certification_number

  added    <- setdiff(fin_cohort, s2_cohort)
  removed  <- setdiff(s2_cohort, fin_cohort)
  retained <- intersect(s2_cohort, fin_cohort)

  cli::cli_h2("Set arithmetic")
  cli::cli_alert_info("stage2 {length(s2_cohort)} | added {length(added)} | removed {length(removed)} | retained {length(retained)} | final {length(fin_cohort)}")

  # CYCLE 13. These four assertions were one stopifnot(), and they are two
  # DIFFERENT KINDS of claim whose failures mean opposite things.
  #
  #   An INVARIANT is arithmetic. retained + added == final holds for any three
  #   sets, on any vintage, forever. If it fails, the CODE is wrong.
  #
  #   A PROVENANCE PIN is a fact about these specific frozen inputs. added ==
  #   2147 holds because artifacts/frozen_stage2 and artifacts/frozen_cohort
  #   are the files this analysis was written against. If it fails, the DATA
  #   moved -- which may be entirely legitimate.
  #
  # Conflated, a failure gave the same message for "you broke the code" and
  # "someone refroze the cohort", and a reader could not tell which assertions
  # were mathematical truths and which were this vintage's answers. Separated,
  # each says what it is.

  # --- Invariants: true of any sets, in any vintage ---
  stopifnot(
    length(retained) + length(added) == length(fin_cohort),
    length(s2_cohort) + length(added) - length(removed) == length(fin_cohort),
    length(intersect(added, removed)) == 0L,
    length(intersect(added, retained)) == 0L,
    length(intersect(removed, retained)) == 0L
  )

  # --- Provenance pins: true of THESE frozen inputs ---
  PIN_ADDED   <- 2147L
  PIN_REMOVED <- 1352L
  if (length(added) != PIN_ADDED || length(removed) != PIN_REMOVED) {
    stop(sprintf(paste0(
      "[PROVENANCE] The frozen inputs no longer produce the pinned cohort deltas.\n",
      "  added:   %d (pinned %d)\n  removed: %d (pinned %d)\n",
      "  The set arithmetic above still HOLDS, so this is not a code fault -- the\n",
      "  frozen artifacts have changed. If that was deliberate, update the pins and\n",
      "  say why in the commit; every published count downstream moves with them."),
      length(added), PIN_ADDED, length(removed), PIN_REMOVED), call. = FALSE)
  }
  cli::cli_alert_success("Identity holds: {length(s2_cohort)} + {length(added)} - {length(removed)} = {length(fin_cohort)}")

  # Additions must already exist in the roster; otherwise they would be new
  # people and the framing above would be wrong.
  n_new_people <- sum(!(added %in% s2_all$certification_number))
  if (n_new_people > 0) {
    stop(sprintf("%d added certification numbers are absent from the Stage-2 roster file; they are NOT linkage-driven additions and need separate treatment.",
                 n_new_people), call. = FALSE)
  }
  cli::cli_alert_success("All {length(added)} additions already existed in the Stage-2 roster; none are new people.")

  # --- Classify additions --------------------------------------------------
  prior <- s2_all %>%
    select(certification_number, s2_decision = match_decision, s2_npi = npi,
           any_of(c("match_tier", "evidence", "match_stage", "match_score"))) %>%
    rename(s2_tier = any_of("match_tier"), s2_evidence = any_of("evidence"))

  fin_state <- if (is.null(link)) {
    tibble(certification_number = fin_cohort)
  } else {
    link %>% select(certification_number,
                    any_of(c("npi", "npi_match_method", "npi_match_resolution",
                             "npi_match_confidence", "match_strategy",
                             "nppes_location_year", "npi_match_status",
                             "match_status", "match_resolution")))
  }

  adds <- tibble(certification_number = added) %>%
    left_join(prior, by = "certification_number", relationship = "many-to-one") %>%
    left_join(fin_state, by = "certification_number", suffix = c("", ".fin"),
              relationship = "many-to-one")

  npi_fin <- if ("npi.fin" %in% names(adds)) adds$npi.fin else
    if ("npi" %in% names(adds)) adds$npi else NA_character_

  adds <- adds %>%
    mutate(
      final_npi = npi_fin,
      addition_reason = case_when(
        s2_decision == "No match" & !is.na(final_npi) ~
          "Previously unmatched -> newly accepted linkage",
        s2_decision %in% c("Ambiguous") & !is.na(final_npi) ~
          "Previously ambiguous -> newly resolved",
        s2_decision %in% c("Review") & !is.na(final_npi) ~
          "Previously held for review -> newly resolved",
        is.na(s2_npi) & !is.na(final_npi) ~
          "Previously lacked usable NPI -> newly resolved",
        !is.na(s2_decision) & is.na(final_npi) ~
          "Admitted to cohort without a final NPI",
        TRUE ~ NA_character_))

  unclassified <- sum(is.na(adds$addition_reason))
  if (unclassified > 0) {
    write_with_provenance(filter(adds, is.na(addition_reason)),
              file.path(ART, "cohort_additions_UNCLASSIFIED.csv"), inputs = prov_inputs(file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
    stop(sprintf("%d of %d additions remain unclassified; see artifacts/cohort_additions_UNCLASSIFIED.csv",
                 unclassified, nrow(adds)), call. = FALSE)
  }

  reasons <- adds %>% count(addition_reason, name = "n", sort = TRUE) %>%
    mutate(pct_of_additions = round(100 * n / sum(n), 1))
  stopifnot(sum(reasons$n) == length(added))

  cli::cli_h2("Addition reasons (n = {length(added)})")
  print(as.data.frame(reasons), row.names = FALSE)

  # --- Second breakdown: the mechanism that finally resolved them -----------
  mech_cols <- intersect(c("npi_match_resolution", "npi_match_method",
                           "match_strategy", "npi_match_confidence",
                           "nppes_location_year"), names(adds))
  mech <- lapply(mech_cols, function(cc) {
    adds %>% count(.data[[cc]], name = "n", sort = TRUE) %>%
      rename(level = 1) %>%
      mutate(field = cc, pct = round(100 * n / sum(n), 1))
  }) %>% bind_rows() %>% select(field, level, n, pct)

  if (nrow(mech) > 0) {
    cli::cli_h2("Final resolution mechanism for the additions")
    print(as.data.frame(mech), row.names = FALSE)
    write_with_provenance(mech, file.path(ART, "cohort_additions_by_mechanism.csv"), inputs = prov_inputs(file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
  }

  # Historical NPPES panel dependence, when the field exists.
  if ("nppes_location_year" %in% names(adds)) {
    yr <- suppressWarnings(as.integer(adds$nppes_location_year))
    cli::cli_alert_info("additions relying on a pre-2024 NPPES snapshot: {sum(yr < 2024, na.rm = TRUE)} of {length(added)}")
  }

  # --- Person-level audit --------------------------------------------------
  audit <- adds %>%
    select(certification_number, s2_decision, s2_npi, final_npi,
           any_of(c("npi_match_resolution", "npi_match_method", "match_strategy",
                    "npi_match_confidence", "nppes_location_year",
                    "npi_match_status", "match_status", "match_resolution",
                    "s2_tier", "s2_evidence")),
           addition_reason)
  write_with_provenance(audit, file.path(ART, "cohort_additions_16743_to_17538.csv"), na = "", inputs = prov_inputs(file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
  cli::cli_alert_success("Person-level audit: artifacts/cohort_additions_16743_to_17538.csv ({nrow(audit)} rows)")

  rem <- tibble(certification_number = removed) %>%
    left_join(select(s2_all, certification_number, s2_npi = npi),
              by = "certification_number", relationship = "many-to-one") %>%
    left_join(fin_state, by = "certification_number", suffix = c("", ".fin"),
              relationship = "many-to-one") %>%
    mutate(final_npi = if ("npi.fin" %in% names(.)) npi.fin else
             if ("npi" %in% names(.)) npi else NA_character_,
           reason = case_when(
             is.na(final_npi) & !is.na(s2_npi) ~ "npi_withdrawn_by_identity_guard",
             !is.na(final_npi) & final_npi != s2_npi ~ "npi_reassigned_and_excluded",
             TRUE ~ "absent_from_guarded_linkage")) %>%
    count(reason, name = "n")
  stopifnot(sum(rem$n) == length(removed))

  # --- Transition table: prior status -> final state -----------------------
  # Prior status is the Stage-2 match_decision; final state splits on whether a
  # usable NPI actually arrived. Collapsing everything to "-> Accepted" would
  # erase the 674 people who entered the cohort with NO final NPI, whose
  # linkage did not in fact improve.
  transitions <- adds %>%
    mutate(final_state = if_else(is.na(final_npi),
                                 "In cohort, NO final NPI",
                                 "Accepted (final NPI present)")) %>%
    count(s2_decision, final_state, name = "n") %>%
    transmute(transition = paste(s2_decision, "->", final_state), n) %>%
    bind_rows(
      tibble(transition = "Accept -> Accept (retained)", n = length(retained)),
      rem %>% transmute(transition = paste("Accept ->", reason), n)) %>%
    arrange(desc(n))
  stopifnot(sum(transitions$n) == length(retained) + length(added) + length(removed))

  cli::cli_h2("Transition table")
  print(as.data.frame(transitions), row.names = FALSE)
  write_with_provenance(transitions, file.path(ART, "cohort_transitions.csv"), inputs = prov_inputs(file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))

  # --- Resolution mechanism WITHIN each prior-status group ------------------
  res_col <- intersect(c("npi_match_resolution", "npi_match_method"), names(adds))
  if (length(res_col) > 0) {
    by_prior <- adds %>%
      mutate(mechanism = coalesce(.data[[res_col[1]]],
                                  if (length(res_col) > 1) .data[[res_col[2]]] else NA_character_,
                                  "no_resolution_recorded")) %>%
      count(s2_decision, mechanism, name = "n") %>%
      group_by(s2_decision) %>%
      mutate(pct_of_group = round(100 * n / sum(n), 1)) %>%
      ungroup() %>% arrange(s2_decision, desc(n))
    stopifnot(sum(by_prior$n) == length(added))
    cli::cli_h2("Final resolution mechanism, within prior status")
    print(as.data.frame(by_prior), row.names = FALSE)
    write_with_provenance(by_prior, file.path(ART, "newly_resolved_by_prior_status.csv"), inputs = prov_inputs(file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
  }

  # --- Bidirectional flow, replacing the one-sided artifact ----------------


  flow <- bind_rows(
    tibble(population = "retained", reason = "in both cohorts", n = length(retained)),
    adds %>% count(addition_reason, name = "n") %>%
      transmute(population = "added", reason = addition_reason, n),
    rem %>% transmute(population = "removed", reason, n)
  ) %>%
    mutate(stage2_cohort = length(s2_cohort), final_cohort = length(fin_cohort))

  stopifnot(
    sum(flow$n[flow$population == "added"]) == length(added),
    sum(flow$n[flow$population == "removed"]) == length(removed),
    sum(flow$n[flow$population == "retained"]) == length(retained))

  write_with_provenance(flow, file.path(ART, "cohort_flow_bidirectional.csv"), inputs = prov_inputs(file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
  cli::cli_h2("Bidirectional flow")
  print(as.data.frame(flow %>% select(population, reason, n)), row.names = FALSE)
  cli::cli_alert_success("artifacts/cohort_flow_bidirectional.csv written")

  invisible(list(added = adds, flow = flow, reasons = reasons))
}

if (identical(environment(), globalenv()) && !interactive()) build_flow()
