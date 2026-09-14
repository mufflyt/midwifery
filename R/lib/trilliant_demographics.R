# Trilliant's provider directory as a BACKUP demographic source.
#
# The directory (snapshot 2026-06-25) carries a gender, a "medical school" and
# graduation year, an estimated age and a patient-panel mix for 7.5 million
# NPIs. It is used here only where the repository's own sources are silent, and
# only after showing that it agrees with them where both speak. Measured on the
# 2026-08-10 freeze (artifacts/trilliant_demographics_validation_<sha8>.csv):
#
#   gender   agrees with NPPES sex for every midwife who has both, so it can fill
#            the NPPES blanks.
#   school   is CMS DAC's medical-school string, character for character, so it
#            is DAC's field for people the current DAC file no longer carries.
#            It inherits DAC's limit: it can only name a university with a
#            medical school, never Frontier Nursing University.
#   age      is NOT a measurement. For every midwife who has it, estimated age
#            plus graduation year is one constant (2052): the directory assumes
#            everyone graduated at 26. Against a directly measured age it runs
#            about eight years young, which is worse than the repository's own
#            calibration from certification year. trl_age_admission() is the
#            test a Trilliant age has to pass before it may fill anything; today
#            it fails.
#   panel    has no counterpart in the repository. It is the directory's
#            claims-derived patient mix (median age, share female, age bands),
#            present only for providers it flags active.
#
# Pure functions: no I/O. strip_med_suffix() comes from
# R/lib/training_institution.R, which callers source first.

suppressPackageStartupMessages({
  library(dplyr); library(stringr)
})

#' Trilliant gender to an NPPES-style sex code
#'
#' FEMALE -> "F", MALE -> "M". "UNSPECIFIED/OTHER" is NA, not "X" or "U": NPPES
#' distinguishes the two and the directory does not say which it means, so it
#' cannot fill an NPPES blank with either.
trl_sex_code <- function(provider_gender) {
  g <- toupper(str_squish(as.character(provider_gender)))
  case_when(g == "FEMALE" ~ "F",
            g == "MALE"   ~ "M",
            TRUE          ~ NA_character_)
}

#' Trilliant school name, cleaned exactly as DAC's med_sch_clean
#'
#' "Other" is the directory's placeholder, like DAC's "OTHER", and is dropped.
#' The string is upper-cased first because DAC's raw strings are upper case and
#' strip_med_suffix() is applied to those; the result then matches
#' med_sch_clean character for character.
trl_school_clean <- function(provider_medical_school_name) {
  if (!exists("strip_med_suffix", mode = "function"))
    stop("source R/lib/training_institution.R before trl_school_clean()", call. = FALSE)
  x <- toupper(str_squish(as.character(provider_medical_school_name)))
  x[is.na(x) | !nzchar(x) | x == "OTHER"] <- NA_character_
  strip_med_suffix(x)
}

#' Is the estimated age computed from the graduation year?
#'
#' If one value of age + graduation year accounts for (nearly) every row that
#' has both, the age is graduation year plus a constant and carries no
#' information that years since certification does not already hold.
#' @return a one-row tibble: n_both, modal_sum, share_at_modal, derived.
trl_age_derivation <- function(age, grad_year, share = 0.99) {
  ok <- !is.na(age) & !is.na(grad_year)
  s <- as.integer(age[ok]) + as.integer(grad_year[ok])
  if (!length(s))
    return(tibble(n_both = 0L, modal_sum = NA_integer_, share_at_modal = NA_real_, derived = NA))
  tab <- sort(table(s), decreasing = TRUE)
  # Ties are broken by the smaller sum, so the reported mode does not depend on
  # row order.
  top <- min(as.integer(names(tab)[tab == tab[1]]))
  at <- mean(s == top)
  tibble(n_both = length(s), modal_sum = top, share_at_modal = at, derived = at >= share)
}

#' Must a Trilliant age be allowed to fill an imputed age?
#'
#' Compared on the people whose age is directly measured, a backup age is
#' admitted only if it is not derived from graduation year AND it is closer to
#' the truth than the calibration it would replace. A backup that is worse than
#' the imputation is not a backup.
#' @param trl_age,grad_year Trilliant estimated age and graduation year.
#' @param known_age,fitted_age the measured age and the calibrated age.
#' @param is_direct TRUE where known_age is a direct measurement.
#' @return a one-row tibble; `admitted` is the decision.
trl_age_admission <- function(trl_age, grad_year, known_age, fitted_age, is_direct,
                              min_n = 100L) {
  der <- trl_age_derivation(trl_age, grad_year)
  cmp <- is_direct %in% TRUE & !is.na(trl_age) & !is.na(known_age) & !is.na(fitted_age) &
    known_age >= 21 & known_age <= 85
  e_t <- trl_age[cmp] - known_age[cmp]
  e_o <- fitted_age[cmp] - known_age[cmp]
  n <- sum(cmp)
  tibble(n_compared   = n,
         trl_bias     = if (n) mean(e_t) else NA_real_,
         trl_mae      = if (n) mean(abs(e_t)) else NA_real_,
         ols_bias     = if (n) mean(e_o) else NA_real_,
         ols_mae      = if (n) mean(abs(e_o)) else NA_real_,
         derived      = der$derived,
         modal_sum    = der$modal_sum,
         admitted     = isFALSE(der$derived) && n >= min_n && mean(abs(e_t)) < mean(abs(e_o)))
}

TRL_PANEL_AGE_BANDS <- c("panel_percent_age_0_19", "panel_percent_age_20_44",
                         "panel_percent_age_45_64", "panel_percent_age_65_84",
                         "panel_percent_age_85_plus")

#' Is a provider's patient panel usable?
#'
#' The panel exists and its age bands add to one. A panel whose bands do not
#' sum is a broken record, not a small practice, and is not summarised.
trl_panel_ok <- function(panel, tol = 0.01) {
  miss <- setdiff(c("panel_median_age", TRL_PANEL_AGE_BANDS), names(panel))
  if (length(miss)) stop("panel is missing column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  s <- rowSums(as.matrix(panel[TRL_PANEL_AGE_BANDS]))
  !is.na(panel$panel_median_age) & !is.na(s) & abs(s - 1) <= tol
}
