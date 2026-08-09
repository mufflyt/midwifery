#!/usr/bin/env Rscript
#' @title Step 09: B->C resolver interaction on the AMCB candidate universe
#'
#' @description
#' Step 08 showed that neutralizing one-sided middle-name missingness changes
#' which NPI ranks FIRST for some people. That is a changed input to the
#' resolver, not a proven corrected match. This step asks the follow-on
#' question: when those changed rankings reach a resolver, does the resolver
#' catch them?
#'
#' \itemize{
#'   \item B = neutral middle-name scoring with the OLD GREEDY allocator.
#'   \item C = byte-identical B scores and candidates with the NEW PERSON-FIRST
#'     non-greedy resolver.
#' }
#' Candidates are not regenerated and no score, threshold or evidence field
#' differs between the arms. The ONLY difference is the allocation rule, so any
#' B->C transition is attributable to the resolver and nothing else.
#'
#' @section What the two resolvers do:
#' Both share an identical own-evidence decision, replicated from
#' match_nppes.R: eligibility at `accept_floor[evidence]`, the `evidence ==
#' "none"` sole-candidate rule, the AMBIGUOUS margin band, and the review
#' threshold. They diverge only afterwards, when two people claim one NPI:
#' \itemize{
#'   \item GREEDY (B): the higher score keeps the NPI; the loser is demoted to
#'     Ambiguous. A score gap decides an identity.
#'   \item NON-GREEDY (C): ALL claimants are quarantined as
#'     `ambiguous_contested_npi`. No dominance exception -- deliberately, since
#'     whether one is warranted is the empirical question this run informs.
#' }
#'
#' @section This is a LEADING INDICATOR, not an ABOG production estimate:
#' It runs on the MIDWIFERY (AMCB) cohort because that data is local. AMCB has
#' no roster location, so pools are surname-blocked and larger and the scoring
#' omits ABOG's geography terms. The MECHANISM transfers; the MAGNITUDE must be
#' measured on ABOG directly.
#'
#' @section A structural limitation, stated up front:
#' AMCB's own-evidence rule already demotes to Ambiguous whenever a rival is
#' within AMBIGUOUS (0.02) of the best, and an exact tie satisfies that. So
#' C's tie guard can almost never fire on this cohort: `ambiguous_tied_evidence`
#' is near-zero BY CONSTRUCTION, not as a finding. Only the contested-NPI guard
#' is genuinely informative here. ABOG has no equivalent band and is where the
#' tie guard must actually be measured.
#'
#' Output : artifacts/bc_resolver/{decisions,crosstab,contested_evidence,manifest}
#'
#' @family step-functions
#' @concept matcher-audit
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr); library(cli); library(jsonlite)
})

source(file.path("R", "lib", "ab_middle_name_common.R"))

ART <- "artifacts"; OUT <- file.path(ART, "bc_resolver")
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

LEDGER <- file.path(ART, "match_ledger.csv")
ROSTER <- "midwives.csv"
CANDS  <- "nppes_candidates.csv"

# Replicated verbatim from match_nppes.R. Both arms use these identically.
ACCEPT_FLOOR <- c(strong = 0.82, weak = 0.88, none = 0.95)
AMBIGUOUS    <- 0.02
REVIEW       <- 0.75

#' Own-evidence decision for one scoring arm -- identical in B and C
#'
#' Depends only on one person's own candidates. No cross-person information
#' enters here; that is exactly the separation the non-greedy resolver exists
#' to enforce.
#' @keywords internal
#' @noRd
own_evidence_decision <- function(d, score_col) {
  d %>%
    mutate(.s = .data[[score_col]]) %>%
    group_by(roster_id) %>%
    mutate(
      n_cand = n(),
      # stage1a_exact is an exact-identity match with a single candidate; it
      # never enters the fuzzy eligibility rule.
      eligible = if (first(strategy_name) == "stage1a_exact") TRUE else
        .s >= ACCEPT_FLOOR[specialty_signal] &
        (specialty_signal != "none" | n_cand == 1L)) %>%
    mutate(eligible = coalesce(eligible, FALSE)) %>%
    arrange(desc(.s), candidate_npi, .by_group = TRUE) %>%
    summarise(
      n_cand = first(n_cand),
      any_elig = any(eligible),
      # Best ELIGIBLE candidate; ties broken by npi only for reporting, never
      # for the decision (a tie inside the band produces Ambiguous regardless).
      top_npi  = if (any(eligible)) candidate_npi[eligible][1] else NA_character_,
      top_score = if (any(eligible)) .s[eligible][1] else NA_real_,
      rival_score = if (sum(eligible) > 1L) .s[eligible][2] else NA_real_,
      n_best_tied = if (any(eligible))
        sum(abs(.s[eligible] - .s[eligible][1]) < 1e-12) else 0L,
      max_score = max(.s),
      .groups = "drop") %>%
    mutate(decision = case_when(
      any_elig & !is.na(rival_score) &
        rival_score >= top_score - AMBIGUOUS ~ "Ambiguous",
      any_elig                               ~ "Accept",
      max_score >= REVIEW                    ~ "Review",
      TRUE                                   ~ "No match"))
}

#' GREEDY allocator (arm B): the stronger claim keeps a contested NPI
#' @keywords internal
#' @noRd
resolve_greedy <- function(dec) {
  losers <- dec %>%
    filter(decision == "Accept") %>%
    group_by(top_npi) %>% filter(n() > 1L) %>%
    arrange(desc(top_score), roster_id, .by_group = TRUE) %>%
    slice(-1) %>% ungroup() %>% pull(roster_id)
  dec %>% mutate(
    status_B = case_when(
      roster_id %in% losers ~ "ambiguous_greedy_demoted",
      decision == "Accept"  ~ "accepted",
      decision == "Ambiguous" ~ "ambiguous",
      TRUE ~ tolower(gsub(" ", "_", decision))),
    npi_B = if_else(status_B == "accepted", top_npi, NA_character_))
}

#' PERSON-FIRST NON-GREEDY resolver (arm C): all claimants quarantined
#'
#' Mirrors isochrones R/npi_resolution.R::rank_one_to_one(): Phase A resolves
#' each person from their own evidence, Phase B quarantines EVERY claimant of a
#' contested NPI. No dominance exception.
#' @keywords internal
#' @noRd
resolve_non_greedy <- function(dec) {
  prov <- dec %>% filter(decision == "Accept")
  tied <- prov %>% filter(n_best_tied > 1L) %>% pull(roster_id)
  contested <- prov %>%
    filter(!roster_id %in% tied) %>%
    count(top_npi, name = "n_claimants") %>%
    filter(n_claimants > 1L) %>% pull(top_npi)

  dec %>% mutate(
    status_C = case_when(
      roster_id %in% tied                          ~ "ambiguous_tied_evidence",
      decision == "Accept" & top_npi %in% contested ~ "ambiguous_contested_npi",
      decision == "Accept"                          ~ "accepted",
      decision == "Ambiguous"                       ~ "ambiguous",
      TRUE ~ tolower(gsub(" ", "_", decision))),
    npi_C = if_else(status_C == "accepted", top_npi, NA_character_))
}

run_bc <- function() {
  cli::cli_alert_warning(paste(
    "LEADING INDICATOR on the midwifery (AMCB) cohort.",
    "NOT the isochrones ABOG production effect."))

  d <- build_ab_ledger(LEDGER, ROSTER, CANDS)

  dec <- own_evidence_decision(d, "score_B") %>%
    resolve_greedy() %>% resolve_non_greedy()

  # --- Invariants ---------------------------------------------------------
  # 1. B and C see identical candidate membership and byte-identical scores:
  #    both arms are computed from the SAME `dec`, which is derived once from
  #    one score column. Membership/score divergence is structurally impossible,
  #    and the assertions below prove the consequences of that.
  stopifnot(
    # 2. Only resolver decisions differ: the own-evidence decision, chosen NPI
    #    and score are shared, so any B/C difference is allocation alone.
    nrow(dec) == n_distinct(d$roster_id),
    # 3. C never lets two accepted people retain the same NPI.
    !any(duplicated(na.omit(dec$npi_C))),
    !any(duplicated(na.omit(dec$npi_B))),
    # 4. Neither arm can accept someone the own-evidence rule did not accept:
    #    a resolver may only REMOVE acceptances, never create them.
    all(dec$decision[dec$status_B == "accepted"] == "Accept"),
    all(dec$decision[dec$status_C == "accepted"] == "Accept"),
    # 5. C accepts a subset of what B accepts, and with the SAME npi.
    all(dec$status_B[dec$status_C == "accepted"] == "accepted"),
    all(dec$npi_C[!is.na(dec$npi_C)] ==
          dec$npi_B[!is.na(dec$npi_C)]))
  cli::cli_alert_success("Invariants passed: identical candidates and scores; only allocation differs; C accepts a same-NPI subset of B.")

  # 6. Row-order permutation produces identical C decisions.
  set.seed(20260808)
  ref <- dec %>% arrange(roster_id) %>% select(roster_id, status_C, npi_C)
  for (i in 1:5) {
    perm <- own_evidence_decision(d[sample(nrow(d)), ], "score_B") %>%
      resolve_non_greedy() %>% arrange(roster_id) %>%
      select(roster_id, status_C, npi_C)
    stopifnot(identical(as.data.frame(ref), as.data.frame(perm)))
  }
  cli::cli_alert_success("Row-order invariance: 5 permutations gave identical C decisions.")

  # --- B -> C decision classification -------------------------------------
  dec <- dec %>% mutate(bc = case_when(
    status_B == "accepted" & status_C == "accepted" & npi_B == npi_C ~ "accepted_same_npi",
    status_B == "accepted" & status_C == "accepted"                  ~ "accepted_different_npi",
    status_B == "accepted" & status_C == "ambiguous_tied_evidence"   ~ "accepted_to_ambiguous_tied_evidence",
    status_B == "accepted" & status_C == "ambiguous_contested_npi"   ~ "accepted_to_ambiguous_contested_npi",
    status_B != "accepted" & status_C == "accepted" &
      grepl("^ambiguous", status_B)                                  ~ "ambiguous_to_accepted",
    status_B != "accepted" & status_C == "accepted"                  ~ "unmatched_to_accepted",
    grepl("^ambiguous", status_B) & grepl("^ambiguous", status_C)    ~ "unchanged_ambiguous",
    TRUE                                                             ~ "unchanged_unmatched"))

  cli::cli_h2("B -> C decision transitions (all roster people, n = {nrow(dec)})")
  bc_tab <- dec %>% count(bc, name = "n", sort = TRUE) %>%
    mutate(pct = round(100 * n / sum(n), 2))
  print(as.data.frame(bc_tab), row.names = FALSE); write_csv(bc_tab, file.path(OUT, "bc_transitions.csv"))

  # --- Primary interaction: A->B ranking status x B->C resolver outcome ----
  ab <- d %>%
    group_by(roster_id) %>%
    summarise(
      n_cand = n(),
      topA = candidate_npi[order(-score_A, candidate_npi)][1],
      topB = candidate_npi[order(-score_B, candidate_npi)][1],
      mA = if (n() > 1) diff(sort(score_A, decreasing = TRUE)[2:1]) else NA_real_,
      mB = if (n() > 1) diff(sort(score_B, decreasing = TRUE)[2:1]) else NA_real_,
      .groups = "drop") %>%
    mutate(ab_status = case_when(
      n_cand < 2                      ~ "single_candidate",
      topA != topB                    ~ "top_npi_changed",
      abs(mA - mB) > 1e-12            ~ "margin_changed",
      TRUE                            ~ "completely_unchanged"))

  x <- dec %>% left_join(ab, by = "roster_id") %>%
    mutate(bc_outcome = case_when(
      status_C == "ambiguous_contested_npi" ~ "ambiguous_contested_npi",
      status_C == "ambiguous_tied_evidence" ~ "ambiguous_tied_evidence",
      status_C == "accepted"                ~ "accepted",
      TRUE                                  ~ "other"))

  cli::cli_h2("PRIMARY: A->B ranking status x B->C resolver outcome (counts)")
  ct <- x %>% filter(ab_status != "single_candidate") %>%
    count(ab_status, bc_outcome, name = "n") %>%
    pivot_wider(names_from = bc_outcome, values_from = n, values_fill = 0)
  print(as.data.frame(ct), row.names = FALSE)
  write_csv(ct, file.path(OUT, "crosstab_counts.csv"))

  cli::cli_h2("PRIMARY: same cross-tab, ROW percentages")
  ctp <- ct %>% rowwise() %>%
    mutate(total = sum(c_across(-ab_status))) %>%
    mutate(across(-c(ab_status, total), ~ round(100 * .x / total, 2))) %>%
    ungroup()
  print(as.data.frame(ctp), row.names = FALSE)
  write_csv(ctp, file.path(OUT, "crosstab_row_pct.csv"))

  # --- The four specific questions -----------------------------------------
  chg <- x %>% filter(ab_status == "top_npi_changed")
  unchg <- x %>% filter(ab_status %in% c("margin_changed", "completely_unchanged"))
  q <- tibble(
    metric = c("A->B top-NPI changes (n)",
               "  ... contested under C",
               "  ... tied-evidence under C",
               "  ... still accepted under C",
               "  ... accepted with the NEW (B) top NPI",
               "  ... not accepted by own evidence in either arm",
               "contested rate among A->B CHANGED (%)",
               "contested rate among A->B UNCHANGED (%)"),
    value = c(nrow(chg),
              sum(chg$bc_outcome == "ambiguous_contested_npi"),
              sum(chg$bc_outcome == "ambiguous_tied_evidence"),
              sum(chg$bc_outcome == "accepted"),
              sum(chg$bc_outcome == "accepted" & chg$npi_C == chg$topB, na.rm = TRUE),
              sum(chg$bc_outcome == "other"),
              round(100 * mean(chg$bc_outcome == "ambiguous_contested_npi"), 3),
              round(100 * mean(unchg$bc_outcome == "ambiguous_contested_npi"), 3)))
  cli::cli_h2("Targeted questions")
  print(as.data.frame(q), row.names = FALSE)
  write_csv(q, file.path(OUT, "targeted_questions.csv"))

  # --- Full evidence for every contested NPI --------------------------------
  # Preserved so a future dominance rule can be evaluated against real
  # collisions. NO dominance rule is created here.
  contested_ids <- x %>% filter(bc_outcome == "ambiguous_contested_npi") %>% pull(roster_id)
  contested_npis <- x %>% filter(roster_id %in% contested_ids) %>% pull(top_npi) %>% unique()
  ev <- d %>%
    filter(roster_id %in% contested_ids | candidate_npi %in% contested_npis) %>%
    left_join(select(x, roster_id, ab_status, status_B, status_C, npi_B, npi_C),
              by = "roster_id") %>%
    arrange(candidate_npi, roster_id, desc(score_B))
  write_csv(ev, file.path(OUT, "contested_evidence.csv"), na = "")
  cli::cli_alert_info("contested: {length(contested_ids)} people over {length(contested_npis)} NPIs; {nrow(ev)} evidence rows preserved")

  manifest <- c(list(
    analysis = "B->C resolver interaction (greedy vs person-first non-greedy)",
    label = "LEADING INDICATOR on the midwifery (AMCB) cohort -- NOT an ABOG production estimate",
    arm_B = "neutral middle-name scoring + OLD greedy allocator",
    arm_C = "identical scores/candidates + NEW person-first non-greedy resolver",
    structural_limitation = paste(
      "AMCB's own-evidence rule already demotes any rival within AMBIGUOUS",
      "(0.02) of the best, so exact ties are absorbed before C's tie guard can",
      "fire. ambiguous_tied_evidence is near-zero BY CONSTRUCTION here, not as",
      "a finding. The tie guard must be measured on ABOG."),
    accept_floor = as.list(ACCEPT_FLOOR), ambiguous_band = AMBIGUOUS,
    review_threshold = REVIEW),
    ab_manifest_inputs(LEDGER, ROSTER, CANDS, d),
    list(roster_people = nrow(dec),
         generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
  write_json(manifest, file.path(OUT, "manifest.json"), auto_unbox = TRUE)
  cli::cli_alert_success("manifest written (input SHAs + git commit pinned)")

  invisible(list(bc = bc_tab, crosstab = ct, questions = q))
}

if (identical(environment(), globalenv()) && !interactive()) run_bc()
