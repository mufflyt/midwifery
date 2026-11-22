# =============================================================================
# ZIP5 normalizers following OIG OEI-07-09-00440 Appendix A (p. 20)
# =============================================================================
# ONE DEFINITION: remake_oig_07_09_00440_midwifery.R and
# oig_phase2_candidate_set_and_intersection_analysis.R both need the same
# PECOS-BIGINT and generic-string ZIP5 normalization; tests/ci_hygiene.R's H4
# refuses a second copy of either.

#' Normalize a BIGINT-stored PECOS ZIP code to 5 digits, restoring leading
#' zeros. `ppef_addr_2019.zip_cd` is stored as BIGINT, which drops leading
#' zeros on 5-digit (len 3..5) and 9-digit ZIP+4 (len 7..9) codes.
norm_pecos_bigint_zip5 <- function(x) {
  s <- trimws(as.character(x))
  s[is.na(s) | !nzchar(s) | s == "0"] <- NA_character_
  s <- gsub("[^0-9]", "", s)
  n <- nchar(s)
  out <- rep(NA_character_, length(s))
  idx5 <- !is.na(n) & n >= 3L & n <= 5L
  idx9 <- !is.na(n) & n >= 7L & n <= 9L
  out[idx5] <- stringr::str_pad(s[idx5], width = 5L, side = "left", pad = "0")
  out[idx9] <- substr(stringr::str_pad(s[idx9], width = 9L, side = "left", pad = "0"), 1L, 5L)
  out[out == "00000"] <- NA_character_
  out
}

#' Normalize a plain string/character ZIP code (5 or 9 digit) to 5 digits.
norm_str_zip5 <- function(x) {
  s <- gsub("[^0-9]", "", trimws(as.character(x)))
  s[is.na(s) | nchar(s) < 3L] <- NA_character_
  n <- nchar(s)
  out <- rep(NA_character_, length(s))
  idx5 <- !is.na(n) & n >= 3L & n <= 5L
  idx9 <- !is.na(n) & n > 5L
  out[idx5] <- stringr::str_pad(s[idx5], width = 5L, side = "left", pad = "0")
  out[idx9] <- substr(s[idx9], 1L, 5L)
  out[out == "00000"] <- NA_character_
  out
}

#' The same normalization, as a SQL expression
#'
#' Seven producers extract a ZIP inside a DuckDB query, where an R function
#' cannot be called. Writing the padding by hand in each of those queries
#' would put eight definitions of "a ZIP code" in the repository, which is
#' the thing this file exists to prevent. So the SQL is generated from here
#' and the two forms are held to each other by
#' tests/test_zip_normalizer_saboteurs.R, which runs the same values through
#' both and fails if they ever disagree.
#'
#' Semantics match norm_str_zip5() exactly: strip non-digits, refuse fewer
#' than three, left-pad three-to-five, take the first five of anything
#' longer, and refuse "00000".
#'
#' @param column_expr [character] a SQL expression naming the raw column,
#'   for example `"TRIM(n.ploczip)"`.
#' @return [character] a SQL expression producing a 5-character ZIP or NULL.
#' @export
#' PASS A COLUMN, NOT A STRING EXPRESSION. This casts to VARCHAR itself, so
#' the cast wraps whatever it is handed: `zip5_sql("TRIM(n.ploczip)")` emits
#' `CAST(TRIM(n.ploczip) AS VARCHAR)`, and DuckDB binds the TRIM first. On the
#' core parquet `ploczip` is an INTEGER, so that is
#' `Binder Error: No function matches ... 'trim(INTEGER)'` and the whole panel
#' build dies. An outer TRIM is also pointless here: the regexp strips every
#' non-digit including whitespace.
zip5_sql <- function(column_expr) {
  # DROP A TRAILING DECIMAL FRACTION BEFORE STRIPPING NON-DIGITS. A ZIP read as
  # a DOUBLE casts to "501.0", and removing non-digits from that leaves "5010",
  # which LPADs to "05010" -- a different, entirely valid-looking ZIP. R's
  # as.character(501) is "501", so the two sides also disagreed. Found by
  # Z14b in tests/test_zip_normalizer_saboteurs.R, which probes an int, a text
  # and a double column because the original probe only ever passed strings.
  as_text <- sprintf("REGEXP_REPLACE(CAST(%s AS VARCHAR), '\\.[0-9]*$', '')",
                     column_expr)
  digits <- sprintf("REGEXP_REPLACE(%s, '[^0-9]', '', 'g')", as_text)
  sprintf(paste0(
    "NULLIF(CASE ",
    "WHEN LENGTH(%s) < 3 THEN NULL ",
    "WHEN LENGTH(%s) <= 5 THEN LPAD(%s, 5, '0') ",
    "ELSE SUBSTR(%s, 1, 5) END, '00000')"),
    digits, digits, digits, digits)
}
