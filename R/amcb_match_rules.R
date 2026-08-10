# =============================================================================
# AMCB matching rules and defensive helpers, as testable functions
# =============================================================================
#
# WHY THESE ARE FUNCTIONS AND NOT INLINE EXPRESSIONS. Each one encodes a rule
# that has already been got wrong at least once in this pipeline. Inline in a
# 700-line script they can only be tested through a nine-minute full run and an
# artifact diff; here they are testable in milliseconds and a regression names
# itself. See tests/test_amcb_gates.R.
# =============================================================================

#' Count RIVAL NPIs: alternative candidates that are a different PERSON.
#'
#' THE DEFECT THIS EXISTS TO PREVENT (2026-08-10, cost two false demotions).
#' The temporal panel's unit is (NPI x snapshot x name variant), NOT NPI. One
#' person recorded with a middle initial in one snapshot and without it in
#' another supplies BOTH a conflicting and a non-conflicting candidate row. A
#' naive n_distinct(npi[conflict]) therefore counts a person as evidence
#' AGAINST the match that belongs to them:
#'
#'   NPI 1609834951  JOANNE ANDERSON, middle "L" then absent  -> self-vetoed
#'   NPI 1548261456  ANASTASIA OTT HALLISEY, "M." then absent -> self-vetoed
#'
#' The same root cause -- treating a name variant as a distinct person --
#' also produced the WILLIAMS/WRIGHT false mismatch. Anything in this pipeline
#' that counts "alternative candidates" must exclude the matched NPI.
#'
#' @param vetoed_pairs data frame with columns `amcb_id` and `vetoed_npi`:
#'   candidate NPIs removed by a veto, before the veto was applied.
#' @param matched data frame with columns `amcb_id` and `npi`: the NPI that
#'   actually won, one row per amcb_id.
#' @return data frame `amcb_id`, `n_rival_npis` -- distinct OTHER people vetoed.
count_rival_npis <- function(vetoed_pairs, matched) {
  require_cols(vetoed_pairs, c("amcb_id", "vetoed_npi"), "vetoed_pairs")
  require_cols(matched, c("amcb_id", "npi"), "matched")
  if (anyDuplicated(matched$amcb_id)) {
    stop("matched must hold one row per amcb_id; the bijection is upstream",
         call. = FALSE)
  }
  if (!nrow(vetoed_pairs)) {
    return(data.frame(amcb_id = character(0), n_rival_npis = integer(0),
                      stringsAsFactors = FALSE))
  }
  j <- merge(unique(vetoed_pairs[, c("amcb_id", "vetoed_npi")]),
             matched[, c("amcb_id", "npi")], by = "amcb_id", all.x = TRUE)
  # is.na(npi): the person matched nothing, so every vetoed candidate is a
  # rival. Otherwise a rival must carry a DIFFERENT NPI.
  j$is_rival <- is.na(j$npi) | j$vetoed_npi != j$npi
  agg <- stats::aggregate(is_rival ~ amcb_id, data = j, FUN = sum)
  names(agg)[2] <- "n_rival_npis"
  agg$n_rival_npis <- as.integer(agg$n_rival_npis)
  agg[order(agg$amcb_id), , drop = FALSE]
}

#' Fail loudly when a join key or required column is absent.
#'
#' THE DEFECT THIS EXISTS TO PREVENT. A check written as
#' `sum(q$amcb_id %in% co$amcb_id)` against a data frame with no `amcb_id`
#' column compares against NULL, returns 0, and reads as a clean result. An
#' unexpectedly clean answer from a key that does not exist is indistinguishable
#' from a real one -- so the column must be asserted, not assumed.
require_cols <- function(df, cols, what = deparse(substitute(df))) {
  if (!is.data.frame(df)) {
    stop(sprintf("%s is not a data frame (got %s)", what, class(df)[1]),
         call. = FALSE)
  }
  missing <- setdiff(cols, names(df))
  if (length(missing)) {
    stop(sprintf("%s is missing required column(s): %s\n  has: %s",
                 what, paste(missing, collapse = ", "),
                 paste(names(df), collapse = ", ")), call. = FALSE)
  }
  invisible(df)
}

#' Fail when a selection matched nothing.
#'
#' THE DEFECT THIS EXISTS TO PREVENT. A test harness whose file selector matched
#' zero files ran nothing and reported "ALL CLEAN". A selector that matches
#' nothing has not passed -- it has not run. Silence is not success.
assert_nonempty_selection <- function(x, what) {
  if (length(x) == 0L) {
    stop(sprintf(paste("%s selected NOTHING. A selector that matches nothing",
                       "has not passed -- it has not run."), what), call. = FALSE)
  }
  invisible(x)
}
