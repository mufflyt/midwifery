#' Validate and normalize a state abbreviation
#'
#' Upper-cases and trims, translates a full state/territory name or a
#' "XX - FULL NAME" combined form to its 2-letter code, and maps anything
#' else (a typo, a foreign place name, a military postal code) to NA rather
#' than passing it through as if it were comparable to a real code. Shared
#' by every script in the state-source audit (`build_state_source_audit.R`,
#' `build_state_source_pairwise_audit.R`, `build_cross_source_comparison.R`,
#' `extract_open_payments_profile_supplement.R`) so a change to which codes
#' count as valid only has to be made once.
#'
#' @details
#' **Full names are translated, not just rejected.** A field like
#' `"CALIFORNIA"` or `"New York"` is a real, unambiguous state -- treating it
#' as unparseable silently excludes a comparable record for no reason. Only
#' genuinely non-state values (a typo, `"N.Y."`, a foreign city, a military
#' postal code like `"AE"`/`"AP"`) still become `NA`.
#'
#' **The `"XX - FULL NAME"` form only resolves when both halves agree.** A
#' value like `"TX - TEXAS"` resolves to `TX`. A superficially similar value
#' whose two halves disagree, or whose prefix is not itself a valid code
#' (`"ON - ONTARIO"`, a Canadian province), is left `NA` rather than
#' guessed from one half alone.
#'
#' @param x `character`: raw state field from any source.
#' @return `character`: a valid 2-letter code, or `NA_character_`.
VALID_STATES <- c(state.abb, "DC", "PR", "VI", "GU", "AS", "MP")
# A SPELLED-OUT NAME IS THE SAME JURISDICTION, NOT A DIFFERENT ONE. Refusing
# every non-code protected against comparing "Colorado" to "CO" as though
# they disagreed, which was right. But it refused them by discarding, and
# discarding loses places the pipeline means to include: the 2026 registry
# panel spells "PUERTO RICO" 184 times, and PR is in VALID_STATES. Those
# rows were dropped for their spelling, not their geography. Pennsylvania's
# licensing portal is the other half of it -- it returns "Pennsylvania", and
# the board harvester had to parse a code out of an address line to work
# around this function. Which jurisdictions count is unchanged; only their
# spelling is.
FULL_STATE_NAME_TO_ABB <- stats::setNames(
  c(toupper(state.abb), "DC", "PR", "VI", "GU", "AS", "MP"),
  toupper(c(state.name, "DISTRICT OF COLUMBIA", "PUERTO RICO", "VIRGIN ISLANDS",
            "GUAM", "AMERICAN SAMOA", "NORTHERN MARIANA ISLANDS"))
)
clean_state <- function(x) {
  x <- toupper(trimws(x))
  out <- rep(NA_character_, length(x))

  is_abb <- x %in% VALID_STATES
  out[is_abb] <- x[is_abb]

  is_full_name <- !is_abb & x %in% names(FULL_STATE_NAME_TO_ABB)
  out[is_full_name] <- FULL_STATE_NAME_TO_ABB[x[is_full_name]]

  is_combo <- is.na(out) & grepl("^[A-Z]{2}\\s*-\\s*[A-Z ]+$", x)
  if (any(is_combo)) {
    halves <- strsplit(x[is_combo], "\\s*-\\s*")
    left <- vapply(halves, `[`, character(1L), 1L)
    right <- vapply(halves, `[`, character(1L), 2L)
    right_abb <- unname(FULL_STATE_NAME_TO_ABB[right])
    agrees <- !is.na(right_abb) & left %in% VALID_STATES & left == right_abb
    combo_idx <- which(is_combo)
    out[combo_idx[agrees]] <- left[agrees]
  }

  out
}

# =============================================================================
# What clean_state() threw away, and why
# =============================================================================
# clean_state() maps anything it does not recognise to NA. That is the right
# behaviour -- a typo or a full state name must not be compared as though it
# were a code -- but on its own it is silent, and silence is how this
# repository has lost data before. A source that changed format from "CO" to
# "Colorado" would have every row refused, the audit would publish a much
# smaller n, and nothing would fail.
#
# The 2026 registry panel carries 456 providers with a military postal code
# (AE 285, AP 162, AA 9) plus a tail of base names and Canadian provinces.
# None of them is a United States practice state, so none of them should be
# compared as one. All of them should be counted and reported rather than
# disappearing into a denominator.

#' USPS codes that are deliberately NOT practice states
#'
#' Armed Forces Africa/Canada/Europe/Middle East (AE), Armed Forces Americas
#' (AA) and Armed Forces Pacific (AP) are mail-routing designations for
#' service members posted outside the fifty states. A midwife with an AE
#' address does not practise in a US state, so she cannot enter a
#' state-agreement comparison -- but she must be counted as excluded, not
#' lost.
MILITARY_POSTAL_CODES <- c("AA", "AE", "AP")

#' Account for every value clean_state() refuses
#'
#' @param x [character] the same raw vector passed to clean_state().
#' @return [list] `n_input`, `n_kept`, `n_blank`, `n_military`,
#'   `n_unrecognised`, `pct_dropped`, and `dropped_values`, a frequency table
#'   of what was refused. The three n_ categories plus n_kept sum to n_input,
#'   so no row can go missing without appearing here.
#' @export
clean_state_report <- function(x) {
  raw <- toupper(trimws(x))
  blank <- is.na(raw) | !nzchar(raw)
  kept <- !blank & !is.na(clean_state(raw))
  military <- !blank & !kept & raw %in% MILITARY_POSTAL_CODES
  unrecognised <- !blank & !kept & !military
  stopifnot(sum(blank) + sum(kept) + sum(military) +
              sum(unrecognised) == length(raw))
  list(n_input = length(raw), n_kept = sum(kept), n_blank = sum(blank),
       n_military = sum(military), n_unrecognised = sum(unrecognised),
       pct_dropped = if (length(raw)) {
         round(100 * (sum(military) + sum(unrecognised)) / length(raw), 2)
       } else 0,
       dropped_values = sort(table(raw[military | unrecognised]),
                             decreasing = TRUE))
}

#' Log what a source lost to state cleaning, and refuse a total wipeout
#'
#' Called by the audit producers for every source. A source that loses ALL of
#' its non-blank values has almost certainly changed format rather than
#' changed content, and publishing that silently is the defect this guard
#' exists for.
#'
#' @param x [character] raw state values.
#' @param source_label [character] name for the message.
#' @param stop_on_total_loss [logical] stop rather than warn.
#' @return [list] the report, invisibly.
#' @export
report_state_cleaning <- function(x, source_label,
                                  stop_on_total_loss = TRUE) {
  r <- clean_state_report(x)
  base::message(sprintf(
    "  clean_state(%s): %s of %s kept, %s blank, %s military, %s unrecognised (%.2f%% dropped)",
    source_label, format(r$n_kept, big.mark = ","),
    format(r$n_input, big.mark = ","), format(r$n_blank, big.mark = ","),
    format(r$n_military, big.mark = ","),
    format(r$n_unrecognised, big.mark = ","), r$pct_dropped))
  if (r$n_unrecognised > 0) {
    top <- utils::head(r$dropped_values, 5)
    base::message(sprintf("    most common refused values: %s",
                          paste(sprintf("%s (%d)", names(top),
                                        as.integer(top)), collapse = ", ")))
  }
  n_nonblank <- r$n_input - r$n_blank
  if (n_nonblank > 0 && r$n_kept == 0) {
    msg <- sprintf(paste0(
      "clean_state(%s): every one of %s non-blank values was refused. ",
      "A source does not lose 100%% of its states by chance -- this is a ",
      "format change (full names where codes are expected, or a shifted ",
      "column), not an empty source. Refusing to continue."),
      source_label, format(n_nonblank, big.mark = ","))
    if (isTRUE(stop_on_total_loss)) stop(msg, call. = FALSE)
    base::message("WARNING: ", msg)
  }
  invisible(r)
}
