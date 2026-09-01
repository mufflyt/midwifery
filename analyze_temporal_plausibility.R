#!/usr/bin/env Rscript
#' @title What the unused temporal signal would buy
#'
#' @description
#' The matcher blocks on names and taxonomy and nothing else:
#' `certification_date` appears ZERO times in match_amcb_to_npi.R. Yet the
#' roster carries it, and the NPPES panel carries the year each NPI was first
#' seen, so a temporal comparison is available and has never been made.
#'
#' This measures what it would buy, WITHOUT changing any published linkage. It
#' answers two questions and deliberately keeps them apart:
#'
#'   VALIDATION -- among matches already accepted, how many pair a certificant
#'   with an NPI first seen implausibly early relative to her certification?
#'   These are candidate false positives the name rules had no way to see.
#'
#'   SEPARATION -- among records quarantined as tied, in how many does the
#'   temporal signal leave exactly one survivor? That is an upper bound on what
#'   a temporal tiebreak could recover, not a recommendation to apply one.
#'
#' @section Why this does not simply break the ties:
#' The resolver's stated rule is that indistinguishable candidates are
#' quarantined rather than separated by evidence that does not speak to
#' identity, which is why taxonomy may not break a tie either. A temporal
#' constraint is closer to identity evidence than taxonomy is, but adopting it
#' is a ruling, not a refactor. This script measures; DECISIONS_CONTRACT.md is
#' where it would be decided.
#'
#' @section The censoring that makes this hard:
#' The panel begins in 2007 and NPPES began enumerating in 2006, so an NPI first
#' seen in the earliest snapshot may have enumerated before it. Those are
#' LEFT-CENSORED and can only ever produce a bound. The convention is the one
#' build_reassignment_panel.R already uses: first-seen is a bound, not a date,
#' and a censored row is reported as censored rather than as evidence.
#'
#' Output: artifacts/temporal_plausibility_summary.csv   (aggregate, publishable)
#'         qa/temporal_implausible_accepted.csv          (person-level, gitignored)
#'
#' Usage:
#'   Rscript analyze_temporal_plausibility.R
#'   Rscript analyze_temporal_plausibility.R --grace=2
#'
#' @family linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})
source(file.path("R", "lib", "artifact_provenance.R"))

tp_arg <- function(k, d) {
  h <- grep(paste0("^--", k, "="), commandArgs(TRUE), value = TRUE)
  if (length(h)) sub(paste0("^--", k, "="), "", h[1]) else d
}
CROSSWALK <- tp_arg("crosswalk", file.path("artifacts", "amcb_npi_linkage_FROZEN.csv"))
PANEL     <- tp_arg("panel", "midwife_panel.csv")
# Years an NPI may precede certification before the pairing is called
# implausible. NOT zero: an RN enumerates years before she certifies as a
# midwife, and that is the normal career order, so only a LONG lead is
# informative. The default is deliberately generous.
GRACE     <- as.numeric(tp_arg("grace", "25"))

for (f in c(CROSSWALK, PANEL))
  if (!file.exists(f))
    stop("Missing ", f, "\n  Person-level and gitignored; run this on the machine\n",
         "  holding the panel and the frozen crosswalk.", call. = FALSE)

x <- read_csv(CROSSWALK, show_col_types = FALSE, guess_max = 50000)
p <- read_csv(PANEL, show_col_types = FALSE, guess_max = 50000,
              col_select = any_of(c("npi", "snapshot_year")))
message(sprintf("crosswalk %s rows | panel %s rows",
                format(nrow(x), big.mark = ","), format(nrow(p), big.mark = ",")))

PANEL_MIN <- min(p$snapshot_year, na.rm = TRUE)

# first_seen is a BOUND. Rows at the panel floor may have enumerated earlier.
first_seen <- p %>%
  filter(!is.na(.data$npi), !is.na(.data$snapshot_year)) %>%
  group_by(.data$npi) %>%
  summarise(first_seen_year = min(.data$snapshot_year), .groups = "drop") %>%
  mutate(left_censored = .data$first_seen_year == PANEL_MIN)

cert_year <- function(v) suppressWarnings(as.integer(substr(as.character(v), 1, 4)))

acc <- x %>%
  filter(!is.na(.data$npi), nzchar(as.character(.data$npi))) %>%
  mutate(cert_year = cert_year(.data$certification_date)) %>%
  left_join(first_seen, by = "npi") %>%
  mutate(
    lead_years = .data$cert_year - .data$first_seen_year,
    verdict = case_when(
      is.na(.data$cert_year) | is.na(.data$first_seen_year) ~ "not assessable",
      .data$left_censored                                   ~ "left-censored (bound only)",
      .data$lead_years > GRACE                              ~ "implausibly early NPI",
      TRUE                                                  ~ "consistent"))

summ <- acc %>%
  count(.data$name_evidence_class, .data$verdict, name = "n") %>%
  rename(evidence_class = name_evidence_class)

message("\n-- VALIDATION: accepted matches against the temporal signal --")
tot <- acc %>% count(.data$verdict, name = "n") %>% arrange(desc(.data$n))
for (i in seq_len(nrow(tot)))
  message(sprintf("  %-28s %6s  %5.1f%%", tot$verdict[i],
                  format(tot$n[i], big.mark = ","), 100 * tot$n[i] / nrow(acc)))
message(sprintf("  grace = %g years; panel floor %d, so %s accepted matches are\n"
                , GRACE, PANEL_MIN,
                format(sum(acc$verdict == "left-censored (bound only)"), big.mark = ",")),
        "  censored and can never be more than a bound.")

flagged <- acc %>%
  filter(.data$verdict == "implausibly early NPI") %>%
  arrange(desc(.data$lead_years))

if (nrow(flagged)) {
  message(sprintf("\n  by evidence class (implausible only):"))
  fc <- flagged %>% count(.data$name_evidence_class, name = "n")
  for (i in seq_len(nrow(fc)))
    message(sprintf("    class %s  %s", fc$name_evidence_class[i],
                    format(fc$n[i], big.mark = ",")))
  dir.create("qa", showWarnings = FALSE)
  keep <- intersect(c("certification_number", "amcb_name_original", "npi",
                      "nppes_last_name", "nppes_first_name", "certification_date",
                      "first_seen_year", "lead_years", "name_evidence_class",
                      "npi_match_method", "npi_match_status", "status"),
                    names(flagged))
  write_csv(flagged[, keep, drop = FALSE], "qa/temporal_implausible_accepted.csv")
  message("  person-level list -> qa/temporal_implausible_accepted.csv (gitignored)")
}

# --- SEPARATION: an upper bound on tie recovery -----------------------------
# Reported only if the crosswalk carries the tied pool. Without per-candidate
# rows the honest answer is "not computable here", not an estimate.
message("\n-- SEPARATION: could the signal break the quarantined ties? --")
tied_n <- sum(x$npi_match_status == "ambiguous_tied_names", na.rm = TRUE)
# The crosswalk is one row per CERTIFICANT by construction -- the losing
# candidates are not in it -- so separation can never be computed from this file
# alone, whatever columns it happens to carry. Saying so beats an estimate.
message(sprintf("  %s records are quarantined as tied. This crosswalk holds one row",
                format(tied_n, big.mark = ",")))
message("  per certificant, so the rival candidates are not present to test and no")
message("  separation rate is computable here.")
message("  To compute it: in match_amcb_to_npi.R the ranked candidate table exists")
message("  before the resolver collapses it. Join first_seen to that table, then")
message("  count tied pools in which exactly one candidate survives the grace rule.")

write_with_provenance(summ, file.path("artifacts", "temporal_plausibility_summary.csv"),
                      inputs = c(CROSSWALK, PANEL))
message("\nwrote artifacts/temporal_plausibility_summary.csv")
message("NOTHING in the published linkage was changed. This measures only.")
