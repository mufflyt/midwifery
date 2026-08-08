#' Midwifery-aware credential compatibility
#'
#' The isochrones credential gate cannot be reused as-is for this cohort.
#' `normalize_credential()` (R/pipeline/blocking_filters.R) maps everything
#' outside MD/DO to "UNKNOWN", and the hardened
#' `are_credentials_compatible()` (canonical_specialty_npi_pipeline.R:2657,
#' 2026-04-23) fails CLOSED on any value outside the MD/DO/UNKNOWN enum. A CNM
#' therefore either degrades to UNKNOWN (gate does nothing) or is rejected
#' outright (gate rejects everything), depending on which one is called.
#'
#' Extending the enum turns a dead gate into a real precision lever: an AMCB
#' certified midwife matching an NPPES record credentialed MD or DO is almost
#' certainly a different person who happens to share the name.
#'
#' Gender blocking is deliberately NOT used here. apply_batch_blocking()'s
#' gender layer discriminates poorly in a cohort that is ~99% women, silently
#' no-ops if a column is missing, and infers a person's gender from their first
#' name -- risk without benefit for this dataset.

CREDENTIAL_CLASSES <- list(
  midwifery  = c("CNM", "CM", "LM", "CPM", "RM", "MIDWIFE"),
  nursing    = c("RN", "APRN", "NP", "WHNP", "FNP", "CNS", "MSN", "DNP", "BSN", "ARNP"),
  physician  = c("MD", "DO", "MBBS", "MBBCH", "MBCHB"),
  other_doc  = c("PHD", "DDS", "DPM", "DC", "PA", "PAC", "DPT", "PSYD", "EDD")
)

#' Normalise a credential string to a class label
#'
#' @param credential `character(1)`: free-text credential, e.g. "CNM, MSN".
#' @return One of "midwifery", "nursing", "physician", "other_doc", "UNKNOWN".
#' @examples
#' normalize_credential_class("CNM, RN")  # -> "midwifery" (most specific wins)
#' normalize_credential_class("MD")       # -> "physician"
#' normalize_credential_class(NA)         # -> "UNKNOWN"
normalize_credential_class <- function(credential) {
  if (is.null(credential) || length(credential) != 1L || is.na(credential)) return("UNKNOWN")
  tokens <- unlist(strsplit(toupper(trimws(as.character(credential))), "[^A-Z]+"))
  tokens <- tokens[nzchar(tokens)]
  if (!length(tokens)) return("UNKNOWN")
  # Most specific class wins: a "CNM, RN" is a midwife, not a nurse.
  for (cls in names(CREDENTIAL_CLASSES)) {
    if (any(tokens %in% CREDENTIAL_CLASSES[[cls]])) return(cls)
  }
  "UNKNOWN"
}

#' Are an AMCB certificant and an NPPES record credential-compatible?
#'
#' @param amcb_credential `character(1)`: implied by AMCB certification type.
#' @param nppes_credential `character(1)`: NPPES free-text credential.
#' @return Logical. UNKNOWN on either side allows the match (missing data is
#'   never treated as evidence); physician credentials are incompatible with a
#'   midwifery certificant.
#' @examples
#' are_credentials_compatible_midwifery("CNM", "MD")        # -> FALSE (namesake)
#' are_credentials_compatible_midwifery("CNM", "CNM, MSN")  # -> TRUE
#' are_credentials_compatible_midwifery("CNM", "")          # -> TRUE (unknown)
are_credentials_compatible_midwifery <- function(amcb_credential, nppes_credential) {
  a <- normalize_credential_class(amcb_credential)
  b <- normalize_credential_class(nppes_credential)
  if (a == "UNKNOWN" || b == "UNKNOWN") return(TRUE)
  if (a == "midwifery" && b %in% c("physician", "other_doc")) return(FALSE)
  TRUE
}
