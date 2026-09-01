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
# amcb_certification_year(): defined ONCE beside amcb_temporal_separation(),
# which consumes the year it produces.
source(file.path("R", "amcb_resolver.R"))

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

cert_year <- amcb_certification_year

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
tied_ids <- x$amcb_id[x$npi_match_status == "ambiguous_tied_names" &
                        !is.na(x$npi_match_status)]
AUDIT <- tp_arg("audit", file.path("artifacts", "linkage_candidate_audit.csv"))

if (!file.exists(AUDIT)) {
  message(sprintf("  %s records are quarantined as tied, but %s is absent, so the",
                  format(tied_n, big.mark = ","), AUDIT))
  message("  rival candidates are not available and no separation rate is computable.")
  message("  Rerun match_amcb_to_npi.R to write it; its first_year column is now")
  message("  populated from the panel, where it used to be left NA.")
} else {
  ca <- read_csv(AUDIT, show_col_types = FALSE, guess_max = 50000)
  if (!"first_year" %in% names(ca) || all(is.na(ca$first_year))) {
    message("  The candidate audit predates the populated first_year column and")
    message("  carries no usable years. Rerun match_amcb_to_npi.R.")
  } else {
    pool <- ca %>% filter(.data$amcb_id %in% tied_ids)
    cy <- x %>% transmute(.data$amcb_id, cert_year = cert_year(.data$certification_date))
    sep <- amcb_temporal_separation(pool, cy, grace = GRACE)
    n_sep <- sum(sep$separated, na.rm = TRUE)
    n_blk <- sum(sep$separation_blocked_by_censoring, na.rm = TRUE)
    n_emp <- sum(sep$n_surviving == 0L, na.rm = TRUE)
    message(sprintf("  tied pools tested            %s", format(nrow(sep), big.mark = ",")))
    message(sprintf("  WOULD separate               %s  (%.1f%% of tied)",
                    format(n_sep, big.mark = ","), 100 * n_sep / max(1, nrow(sep))))
    message(sprintf("  blocked by censoring         %s", format(n_blk, big.mark = ",")))
    message(sprintf("  every candidate ruled out    %s  <- would LOSE these, not gain them",
                    format(n_emp, big.mark = ",")))
    message("\n  Read the last two rows before the second. A rule that separates")
    message("  some pools and empties others is not free: an emptied pool moves a")
    message("  record from `tied` to `no candidate`, which reads to a user as")
    message("  absence from the registry. Net recovery is separations MINUS")
    message("  emptied pools, and the sign of that is the whole decision.")
    write_with_provenance(sep, file.path("artifacts", "temporal_separation_by_pool.csv"),
                          inputs = c(CROSSWALK, AUDIT))
    message("  per-pool detail -> artifacts/temporal_separation_by_pool.csv")
  }
}

write_with_provenance(summ, file.path("artifacts", "temporal_plausibility_summary.csv"),
                      inputs = c(CROSSWALK, PANEL))
message("\nwrote artifacts/temporal_plausibility_summary.csv")
message("NOTHING in the published linkage was changed. This measures only.")
