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
