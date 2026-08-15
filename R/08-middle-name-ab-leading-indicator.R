#!/usr/bin/env Rscript
#' @title Step 08: A/B leading indicator for the middle-name neutralization
#'
#' @description
#' Measures whether neutralizing one-sided middle-name missingness changes
#' CANDIDATE RANKING. The endpoint is deliberately not acceptance: the change
#' shifts a candidate by a few points on a scale where other evidence is worth
#' more, so its effect is expected to land on ordering within near-ties rather
#' than on crossing a threshold.
#'
#' @section This is a LEADING INDICATOR, not the production effect:
#' It runs on the MIDWIFERY (AMCB) cohort because that data is local. It is NOT
#' the isochrones ABOG production cohort. What transfers is the MECHANISM --
#' whether removing a missingness bonus reorders top candidates at all. The
#' MAGNITUDE should not be assumed to transfer in either direction. AMCB has no
#' roster location, so its candidate pools are surname-blocked and larger and
#' its scoring omits ABOG's geography terms; that architecture gives reason to
#' EXPECT a larger effect here than in ABOG, but monotonicity has not been
#' demonstrated and must be tested directly on ABOG.
#'
#' The endpoint is CANDIDATE RANKING, not final linkage. A changed top NPI is a
#' changed input to the resolver, not a proven corrected match.
#'
#' @section Why the arithmetic is exact rather than re-run:
#' match_nppes.R consumes the changed function as
#'   middle_points <- score_middle_name_match(...)
#'   middle_sim    <- pmax(0, middle_points) / 15
#' and weights middle at 0.12. So one-sided missingness contributes exactly
#' 0.12 * 5/15 = 0.040 (roster has middle, NPPES does not) or
#' 0.12 * 3/15 = 0.024 (the reverse), and neutralization subtracts precisely
#' that. Every other score component is untouched by construction, which is a
#' stronger guarantee than re-running the matcher and hoping nothing else moved.
#'
#' A = old scoring (+5 / +3). B = neutral scoring (0 / 0).
#' The non-greedy resolver is deliberately NOT applied; this is about ranking.
#'
#' Output : artifacts/ab_middle_name/{transitions,exposure,evidence,manifest}
#'
#' @family step-functions
#' @concept matcher-audit
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
  library(cli); library(jsonlite)
})

# CYCLE 21b. Inputs recorded beside every artifact this script writes, so a
# reader can tell whether the numbers were built from the bytes still on disk.
source(file.path("R", "lib", "artifact_provenance.R"))

ART <- "artifacts"; OUT <- file.path(ART, "ab_middle_name")
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

LEDGER <- file.path(ART, "match_ledger.csv")
ROSTER <- "midwives.csv"
CANDS  <- "nppes_candidates.csv"

# Scoring arms live in ONE place, shared with R/09. Two copies of "what arm B
# is" would eventually disagree -- the failure mode already hit three times
# here (gender gate, credential helpers, rank_one_to_one).
source(file.path("R", "lib", "ab_middle_name_common.R"))

run_ab <- function() {
  stopifnot(file.exists(LEDGER), file.exists(ROSTER), file.exists(CANDS))

  cli::cli_alert_warning(paste(
    "LEADING INDICATOR on the midwifery (AMCB) cohort.",
    "NOT the isochrones ABOG production effect.",
    "Endpoint is candidate ranking, not final linkage."))

  cli::cli_h2("Loading pinned inputs")
  # build_ab_ledger() asserts internally: membership identical between arms,
  # only one-sided-missingness fuzzy rows change, and only downward.
  d <- build_ab_ledger(LEDGER, ROSTER, CANDS)
  cli::cli_alert_success("Assertions passed: only one-sided-missingness rows change, and only downward.")

  #' Top-two summary under one scoring arm
  top2 <- function(df, score_col, suffix) {
    df %>%
      group_by(roster_id) %>%
      arrange(desc(.data[[score_col]]), candidate_npi, .by_group = TRUE) %>%
      summarise(
        top_npi = candidate_npi[1],
        run_npi = if (n() > 1) candidate_npi[2] else NA_character_,
        top_score = .data[[score_col]][1],
        run_score = if (n() > 1) .data[[score_col]][2] else NA_real_,
        n_cand = n(),
        # An exact tie at the top is the population the resolver reclassifies.
        top_tie = n() > 1 && isTRUE(all.equal(.data[[score_col]][1],
                                              .data[[score_col]][2])),
        .groups = "drop") %>%
      mutate(margin = top_score - run_score) %>%
      rename_with(~ paste0(.x, suffix), -roster_id)
  }

  A <- top2(d, "score_A", "_A")
  B <- top2(d, "score_B", "_B")

  # top2() summarise()s to one row per roster_id on both sides, so this is a
  # strict one-to-one. Declaring it is the assertion that arms A and B still
  # see identical roster membership -- the premise the whole A/B comparison
  # rests on. If either arm ever gains or duplicates a roster_id, this stops.
  cmp <- inner_join(A, B, by = "roster_id", relationship = "one-to-one") %>%
    filter(n_cand_A >= 2) %>%
    mutate(
      top_changed = top_npi_A != top_npi_B,
      new_tie     = !top_tie_A & top_tie_B,
      tie_broken  =  top_tie_A & !top_tie_B,
      margin_changed = abs(margin_A - margin_B) > 1e-12,
      transition = case_when(
        top_changed    ~ "different_top_npi",
        new_tie        ~ "new_top_tie",
        tie_broken     ~ "tie_broken",
        margin_changed ~ "same_top_margin_changed",
        TRUE           ~ "completely_unchanged"))

  cli::cli_h2("Ranking transitions (people with >= 2 candidates)")
  tr <- cmp %>% count(transition, name = "n", sort = TRUE) %>%
    mutate(pct = round(100 * n / sum(n), 2))
  print(as.data.frame(tr), row.names = FALSE)
  write_with_provenance(tr, file.path(OUT, "transitions_all.csv"), inputs = prov_inputs(LEDGER, ROSTER, CANDS))

  # --- Exposure population -------------------------------------------------
  exposed_ids <- d %>%
    semi_join(cmp, by = "roster_id") %>%
    group_by(roster_id) %>%
    arrange(desc(score_A), candidate_npi, .by_group = TRUE) %>%
    slice_head(n = 2) %>%
    summarise(exposed = any(mid_state %in% c("missing_npi_side",
                                             "missing_roster_side")),
              .groups = "drop") %>%
    filter(exposed) %>% pull(roster_id)

  cli::cli_h2("Exposure population: one-sided missingness in the top two (n = {length(exposed_ids)})")
  tre <- cmp %>% filter(roster_id %in% exposed_ids) %>%
    count(transition, name = "n", sort = TRUE) %>%
    mutate(pct = round(100 * n / sum(n), 2))
  print(as.data.frame(tre), row.names = FALSE)
  write_with_provenance(tre, file.path(OUT, "transitions_exposed.csv"), inputs = prov_inputs(LEDGER, ROSTER, CANDS))

  # --- Evidence vectors: changed + matched unchanged comparison group ------
  changed <- cmp %>% filter(transition != "completely_unchanged")
  # Deterministic matched sample: same candidate-count and top-score bins as
  # the changed records. Prespecified strata, no cherry-picking.
  binned <- cmp %>%
    mutate(cand_bin = cut(n_cand_A, c(1, 2, 3, 5, 10, Inf), right = TRUE),
           score_bin = cut(top_score_A, seq(0, 1, by = 0.05)))
  want <- binned %>% filter(transition != "completely_unchanged") %>%
    count(cand_bin, score_bin, name = "n_want")
  set.seed(20260808)
  matched <- binned %>%
    filter(transition == "completely_unchanged") %>%
    # want is count(cand_bin, score_bin): one row per stratum, many binned
    # rows meet it.
    inner_join(want, by = c("cand_bin", "score_bin"),
               relationship = "many-to-one") %>%
    group_by(cand_bin, score_bin) %>%
    arrange(roster_id, .by_group = TRUE) %>%
    # row_number() rather than slice_head(n = first(n_want)): slice_head
    # requires a constant n, and the quota varies per stratum.
    filter(row_number() <= n_want) %>%
    ungroup()

  keep_ids <- c(changed$roster_id, matched$roster_id)
  evidence <- d %>%
    filter(roster_id %in% keep_ids) %>%
    group_by(roster_id) %>%
    arrange(desc(score_A), candidate_npi, .by_group = TRUE) %>%
    slice_head(n = 2) %>%
    ungroup() %>%
    # cmp is one row per roster_id; evidence carries up to two (slice_head).
    left_join(select(cmp, roster_id, transition), by = "roster_id",
              relationship = "many-to-one") %>%
    mutate(arm_group = if_else(roster_id %in% changed$roster_id,
                               "changed", "matched_unchanged")) %>%
    select(roster_id, arm_group, transition, candidate_npi, strategy_name,
           score_A, score_B, delta, mid_state, roster_middle, cand_middle,
           roster_first, roster_last, cand_first, cand_last,
           confidence_score, last_match, first_match, state_match, zip_match,
           specialty_signal, accepted)
  write_with_provenance(evidence, file.path(OUT, "evidence_top2.csv"), na = "", inputs = prov_inputs(LEDGER, ROSTER, CANDS))
  cli::cli_alert_info("evidence vectors: {nrow(changed)} changed + {nrow(matched)} matched-unchanged people")

  # --- Manifest: data AND code provenance ---------------------------------
  manifest <- c(list(
    analysis = "A/B middle-name neutralization, ranking instability",
    label = "LEADING INDICATOR on the midwifery (AMCB) cohort -- NOT the isochrones ABOG production effect"),
    ab_manifest_inputs(LEDGER, ROSTER, CANDS, d),
    list(
    people_with_2plus_candidates = nrow(cmp),
    exposed_people = length(exposed_ids),
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
  write_json(manifest, file.path(OUT, "manifest.json"), auto_unbox = TRUE)
  cli::cli_alert_success("manifest written (input SHAs + git commit pinned)")

  invisible(list(transitions = tr, exposed = tre, cmp = cmp))
}

if (identical(environment(), globalenv()) && !interactive()) run_ab()
