# =============================================================================
# A claim carries the year its VALUES are from, not the year of its frame
# =============================================================================
# WHY THIS MOVED HERE. remake_oig_07_09_00440_midwifery.R builds every number
# in the OIG rebuild out of "claims": one row per (npi, year, source,
# attribute, value), compared pair against pair to produce
# artifacts/oig_remake/oig_table4_consistency_2019_and_2026.csv and Table 1 of
# the audit artifact. The builder lived inside that 2,600-line script, so
# nothing could call it without a 91 GB DuckDB warehouse attached, and
# nothing ever tested it.
#
# WHAT IT LET THROUGH. The year was a LITERAL argument and the values were a
# bare vector, so nothing connected the two:
#
#   nppes_2026_gender <- nppes_2026 %>% select(npi, gender)
#   nppes_2019 <- nppes_2019_panel %>% left_join(nppes_2026_gender, by = "npi")
#   ...
#   make_parent_field_claims(nppes_2019, 2019L, "nppes", "gender", ...)
#
# The 2019 panel carries no sex code, so gender was borrowed from the
# FEBRUARY 2026 NPPES file and then stamped 2019. The published row
# `2019,nppes,pecos,gender` is therefore 2026 NPPES values compared against
# 2019 PECOS values -- seven years apart, in a table whose whole purpose is
# to compare two records of the same vintage. Gender barely moves, so the
# number is barely wrong; the mechanism is wrong, and it would have been
# invisible on a column that does move, such as practice_state.
#
# So `value_year` is now REQUIRED and is not defaulted to `yr`. A default is
# precisely what let this pass: whoever wrote that line was never asked what
# year the values were from. Where the two genuinely differ, a reason has to
# be given, and the borrow is announced on every run instead of living in a
# frame nobody re-reads.
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

#' One claim per identifier about one attribute, at a stated vintage
#'
#' @param df [data.frame] the frame supplying `npi`.
#' @param yr [integer] the year this claim is recorded under.
#' @param src [character] which record system is claiming it.
#' @param attr_name [character] the attribute being claimed.
#' @param val_vec [vector] the values, same length and order as `df$npi`.
#' @param value_year [integer] the year `val_vec` is FROM. Required. Equal to
#'   `yr` in every honest case; stating it is the point.
#' @param cross_vintage_reason [character] why values from another year are
#'   being stamped with this one. Required when they differ, and recorded in
#'   the run log.
#' @return [tbl_df] npi, year, source, attribute, value; distinct.
#' @export
make_parent_field_claims <- function(df, yr, src, attr_name, val_vec,
                                     value_year, cross_vintage_reason = NULL) {
  if (missing(value_year)) {
    stop(sprintf(paste0(
      "make_parent_field_claims(): '%s' claims %s for year %s without saying ",
      "what year the VALUES are from.\n  The year used to be a literal and the ",
      "values a bare vector, which is how 2026 NPPES sex codes were published ",
      "as a 2019 claim and compared against 2019 PECOS.\n  Pass value_year = ",
      "%dL if the values are this year's, or the year they really come from."),
      src, attr_name, yr, as.integer(yr)), call. = FALSE)
  }
  # LENGTH IS PART OF THE PAIRING. val_vec is positional against df$npi, so a
  # vector of the wrong length is recycled by tibble() into a column that
  # pairs each npi with somebody else's value -- a silent re-labelling of
  # every row rather than an error.
  if (length(val_vec) != nrow(df)) {
    stop(sprintf(paste0(
      "make_parent_field_claims(): '%s' %s has %d value(s) for %d row(s) of ",
      "npi. A recycled vector pairs identifiers with values that belong to ",
      "other people."), src, attr_name, length(val_vec), nrow(df)),
      call. = FALSE)
  }
  if (!identical(as.integer(value_year), as.integer(yr))) {
    if (is.null(cross_vintage_reason) || !nzchar(cross_vintage_reason)) {
      # Not routed through assert_same_vintage_year(): the message has to name
      # the attribute and the source, because "two sides 84 months apart" is
      # not enough to find which of 27 claim calls borrowed the column.
      stop(sprintf(paste0(
        "make_parent_field_claims(): '%s' %s is being stamped year %s from ",
        "values that are from year %s. That is a cross-vintage claim, and it ",
        "will be compared against the other source's %s values as though both ",
        "were %s.\n  Either use %s values, or pass cross_vintage_reason= to ",
        "say why borrowing is right here."),
        src, attr_name, yr, value_year, yr, yr, yr), call. = FALSE)
    }
    base::message(sprintf(
      "  CROSS-VINTAGE CLAIM: %s %s stamped %s from %s values -- %s",
      src, attr_name, yr, value_year, cross_vintage_reason))
  }
  tibble::tibble(
    npi = trimws(df$npi),
    year = as.integer(yr),
    source = src,
    attribute = attr_name,
    value = as.character(val_vec)
  ) %>%
    dplyr::distinct()
}
