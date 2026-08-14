#!/usr/bin/env Rscript
#' @title Shared A/B middle-name scoring arms (single definition)
#'
#' @description
#' One definition of the A and B scoring arms, sourced by both
#' `R/08-middle-name-ab-leading-indicator.R` (ranking instability) and
#' `R/09-bc-resolver-interaction.R` (resolver interaction). These two analyses
#' MUST agree on what arm B is; two copies would guarantee they eventually
#' didn't, which is the exact "fixing one fixes none" trap already found three
#' times in this codebase (gender gate, credential helpers, rank_one_to_one).
#'
#' A = production scoring: one-sided middle-name missingness earns +5 / +3.
#' B = neutral scoring: one-sided missingness earns 0.
#'
#' @section Why the arithmetic is exact rather than re-run:
#' match_nppes.R consumes the changed function as
#'   middle_points <- score_middle_name_match(...)
#'   middle_sim    <- pmax(0, middle_points) / 15
#' weighted at 0.12, so one-sided missingness contributes exactly
#' 0.12 * 5/15 = 0.040 (roster has a middle name, NPPES does not) or
#' 0.12 * 3/15 = 0.024 (the reverse). Every other component is untouched by
#' construction -- a stronger guarantee than re-running the matcher and hoping
#' nothing else moved.
#'
#' @family step-functions
#' @concept matcher-audit
#' @author Tyler Muffly, MD + Claude Code
#' @name ab_middle_name_common
NULL

MIDDLE_WEIGHT <- 0.12    # CFG$weights$middle in match_nppes.R
PTS_PER_SIM   <- 15      # middle_sim = pmax(0, points) / 15

# The middle-name term exists ONLY in the fuzzy scorer. stage1a_exact rows are
# exact-identity matches emitted at score 1 with a single candidate and never
# pass through score_middle_name_match(), so neutralization cannot touch them.
# Applying the delta there would invent a 1.000 -> 0.960 drop that the matcher
# never produces, and in step 09 that would change their ACCEPT eligibility.
FUZZY_STRATEGY <- "surname_block_jw_evidence"

source(file.path("R", "lib", "provenance.R"))  # canonical sha256_of()

#' Does this name field actually carry a middle name?
#'
#' @param x `character`: middle-name field, possibly `NA`, empty, or
#'   whitespace-only.
#' @return `logical` the length of `x`; never `NA`.
#'
#' @details
#' Whitespace-only counts as ABSENT. NPPES and the AMCB roster both use `""`
#' and `" "` interchangeably for "no middle name", so testing `!is.na(x)` alone
#' would treat a blank as a present middle name and turn a both-missing pair
#' into a spurious conflict.
#'
#' @examples
#' has_middle(c("MAE", "", " ", NA))          # TRUE FALSE FALSE FALSE
#'
#' @keywords internal
has_middle <- function(x) !is.na(x) & nzchar(trimws(x))

#' Classify the middle-name state of a (roster, candidate) pair
#'
#' @param roster_mid `character`: middle name as recorded on the AMCB roster.
#' @param cand_mid `character`: middle name on the candidate NPPES record.
#'
#' @return `character` the length of the inputs, one of
#'   `"both_missing"`, `"missing_npi_side"`, `"missing_roster_side"`,
#'   `"initial_agreement"`, `"conflict"`.
#'
#' @details
#' The five states exist because ONE-SIDED MISSINGNESS IS NOT DISAGREEMENT.
#' A roster middle name absent from NPPES tells you nothing about whether the
#' two records are the same person; scoring it as a mismatch penalises exactly
#' the people whose records are least complete. Arms A and B of the sensitivity
#' analysis differ only in how the two `missing_*` states are weighted.
#'
#' Comparison is on the INITIAL only, so "MAE" and "M" agree.
#'
#' @examples
#' middle_state("MAE", "M")                   # "initial_agreement"
#' middle_state("MAE", NA)                    # "missing_npi_side"
#' middle_state(NA, NA)                       # "both_missing"
#' middle_state("MAE", "LOUISE")              # "conflict"
#'
#' @keywords internal
#' @noRd
middle_state <- function(roster_mid, cand_mid) {
  r <- has_middle(roster_mid); c <- has_middle(cand_mid)
  ri <- substr(toupper(trimws(roster_mid)), 1, 1)
  ci <- substr(toupper(trimws(cand_mid)), 1, 1)
  dplyr::case_when(
    !r & !c            ~ "both_missing",
    r & !c             ~ "missing_npi_side",
    !r & c             ~ "missing_roster_side",
    ri == ci           ~ "initial_agreement",
    TRUE               ~ "conflict")
}

#' Build the candidate ledger carrying both scoring arms
#'
#' @param ledger_path `character(1)`: pinned candidate-ledger CSV.
#' @param roster_path `character(1)`: pinned AMCB roster CSV.
#' @param cands_path `character(1)`: pinned candidate-pair CSV.
#'
#' @return `data.frame`: the ledger plus `mid_state`, `delta`, `score_A`,
#'   `score_B`, and the roster/candidate name fields used for adjudication.
#'
#' @details
#' All three paths must exist; the function stops rather than silently
#' producing a short ledger. `delta` is `score_A - score_B` and is non-zero
#' only for the one-sided-missingness states, which is the whole point of the
#' comparison.
#'
#' @examples
#' \dontrun{
#' d <- build_ab_ledger("artifacts/ledger.csv", "artifacts/roster.csv",
#'                      "artifacts/candidates.csv")
#' table(d$mid_state)
#' }
#'
#' @seealso [middle_state()] for the classification, [ab_manifest_inputs()]
#'   for the provenance block.
#' @family step-functions
#' @export
build_ab_ledger <- function(ledger_path, roster_path, cands_path) {
  stopifnot(file.exists(ledger_path), file.exists(roster_path),
            file.exists(cands_path))

  led <- readr::read_csv(ledger_path, show_col_types = FALSE, progress = FALSE)
  ros <- readr::read_csv(roster_path, show_col_types = FALSE, progress = FALSE) |>
    dplyr::transmute(roster_id = as.character(certification_number),
                     roster_middle = middle_name,
                     roster_first = first_name, roster_last = last_name)
  cand <- readr::read_csv(cands_path,
                          col_types = readr::cols(.default = readr::col_character()),
                          progress = FALSE) |>
    dplyr::transmute(candidate_npi = npi, cand_middle = middle_name,
                     cand_first = first_name, cand_last = last_name) |>
    dplyr::distinct(candidate_npi, .keep_all = TRUE)

  d <- led |>
    dplyr::mutate(roster_id = as.character(roster_id),
                  candidate_npi = as.character(candidate_npi)) |>
    dplyr::left_join(ros, by = "roster_id") |>
    dplyr::left_join(cand, by = "candidate_npi") |>
    dplyr::mutate(
      mid_state = middle_state(roster_middle, cand_middle),
      delta = dplyr::case_when(
        strategy_name != FUZZY_STRATEGY    ~ 0,
        mid_state == "missing_npi_side"    ~ -MIDDLE_WEIGHT * 5 / PTS_PER_SIM,
        mid_state == "missing_roster_side" ~ -MIDDLE_WEIGHT * 3 / PTS_PER_SIM,
        TRUE                               ~ 0),
      score_A = score_total,
      score_B = score_total + delta)

  # Invariants that hold for BOTH consumers of this function.
  stopifnot(
    nrow(d) == nrow(led),
    all(d$delta[!d$mid_state %in% c("missing_npi_side", "missing_roster_side")] == 0),
    all(d$delta[d$strategy_name != FUZZY_STRATEGY] == 0),
    all(d$score_A[d$mid_state %in% c("initial_agreement", "conflict", "both_missing")] ==
          d$score_B[d$mid_state %in% c("initial_agreement", "conflict", "both_missing")]),
    all(d$score_B <= d$score_A + 1e-12))
  d
}

#' Manifest block describing the pinned inputs and both scoring arms
#'
#' @param ledger_path `character(1)`: pinned candidate-ledger CSV.
#' @param roster_path `character(1)`: pinned AMCB roster CSV.
#' @param cands_path `character(1)`: pinned candidate-pair CSV.
#' @param d `data.frame`: the built ledger, used only for its row count.
#'
#' @return `list` recording both scoring arms, the weights, and a SHA-256 for
#'   each of the three inputs plus the git commit.
#'
#' @details
#' The hashes are what make an A/B result re-checkable: a rerun against a
#' changed roster produces a different digest rather than a quietly different
#' answer. `git_commit` degrades to `NA` outside a repository rather than
#' erroring.
#'
#' @examples
#' \dontrun{
#' m <- ab_manifest_inputs("artifacts/ledger.csv", "artifacts/roster.csv",
#'                         "artifacts/candidates.csv", d)
#' m$inputs$roster$sha256
#' }
#'
#' @seealso [build_ab_ledger()], and `sha256_of()` in R/lib/provenance.R.
#' @family step-functions
#' @export
ab_manifest_inputs <- function(ledger_path, roster_path, cands_path, d) {
  list(
    scoring_A = "one-sided middle-name missingness +5 / +3",
    scoring_B = "one-sided middle-name missingness 0 / 0",
    middle_weight = MIDDLE_WEIGHT, pts_per_sim = PTS_PER_SIM,
    delta_applies_to_strategy = FUZZY_STRATEGY,
    inputs = list(
      ledger = list(path = ledger_path, sha256 = sha256_of(ledger_path),
                    rows = nrow(d)),
      roster = list(path = roster_path, sha256 = sha256_of(roster_path)),
      candidates = list(path = cands_path, sha256 = sha256_of(cands_path))),
    git_commit = tryCatch(system2("git", c("rev-parse", "HEAD"), stdout = TRUE)[1],
                          error = function(e) NA_character_))
}
