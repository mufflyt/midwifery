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
normalize_credential_class <- function(credential) {
  if (is.null(credential) || length(credential) != 1L || is.na(credential)) return("UNKNOWN")
  raw <- toupper(trimws(as.character(credential)))
  tokens <- unlist(strsplit(raw, "[^A-Z]+"))
  tokens <- tokens[nzchar(tokens)]
  # "C.N.M." tokenises to C / N / M, so also test the fully de-punctuated form.
  # Multi-letter codes are matched as substrings there; two-letter codes are
  # not, to avoid CM matching inside e.g. "BCMA".
  flat <- gsub("[^A-Z]", "", raw)
  if (!length(tokens) && !nzchar(flat)) return("UNKNOWN")
  # Most specific class wins: a "CNM, RN" is a midwife, not a nurse.
  for (cls in names(CREDENTIAL_CLASSES)) {
    codes <- CREDENTIAL_CLASSES[[cls]]
    if (any(tokens %in% codes)) return(cls)
    long <- codes[nchar(codes) > 2]
    if (length(long) && grepl(paste(long, collapse = "|"), flat)) return(cls)
    # Two-letter codes (MD, CM, RN, NP) are only accepted when the whole
    # de-punctuated credential IS that code -- "M.D." must read as physician
    # without "BCMA" reading as a midwife.
    if (flat %in% codes) return(cls)
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
are_credentials_compatible_midwifery <- function(amcb_credential, nppes_credential) {
  a <- normalize_credential_class(amcb_credential)
  b <- normalize_credential_class(nppes_credential)
  if (a == "UNKNOWN" || b == "UNKNOWN") return(TRUE)
  if (a == "midwifery" && b %in% c("physician", "other_doc")) return(FALSE)
  TRUE
}

#' Vectorised credential classification
#'
#' `normalize_credential_class()` is scalar, and calling it once per candidate
#' dominated the matcher's runtime -- the credential of an NPPES record is a
#' static property, so classify the whole table once instead. Kept in lockstep
#' with the scalar version by `stopifnot()` in the caller.
#'
#' @param credential `character`: vector of free-text credentials.
#' @return `character` vector of class labels.
classify_credentials <- function(credential) {
  raw   <- toupper(trimws(replace(as.character(credential),
                                  is.na(credential), "")))
  flat  <- gsub("[^A-Z]", "", raw)
  words <- gsub("[^A-Z]+", " ", raw)

  has_code <- function(cls) {
    codes <- CREDENTIAL_CLASSES[[cls]]
    long  <- codes[nchar(codes) > 2]
    hit <- flat %in% codes
    if (length(long)) hit <- hit | grepl(paste(long, collapse = "|"), flat)
    hit | grepl(paste0("\\b(", paste(codes, collapse = "|"), ")\\b"), words)
  }

  out <- rep("UNKNOWN", length(raw))
  # Reverse order so the most specific class (listed first) wins the assignment.
  for (cls in rev(names(CREDENTIAL_CLASSES))) out[has_code(cls)] <- cls
  out[!nzchar(flat)] <- "UNKNOWN"
  out
}
