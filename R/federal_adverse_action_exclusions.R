#!/usr/bin/env Rscript

#' Build NPI-linked federal adverse-action flags and apply them to the cohort.
#'
#' The accepted input is deliberately NPI-linked evidence. DEA Federal Register
#' and FDA notices are commonly name-based; unresolved or ambiguous name-only
#' matches must remain in a review queue rather than remove a midwife.

build_federal_adverse_action_flags <- function(sources) {
  empty <- data.frame(
    npi = character(0),
    federal_adverse_action_excluded = logical(0),
    federal_adverse_action_source = character(0),
    stringsAsFactors = FALSE)
  if (!length(sources)) return(empty)

  rows <- lapply(seq_along(sources), function(i) {
    x <- sources[[i]]
    if (is.character(x) && length(x) == 1L && file.exists(x)) {
      x <- utils::read.csv(x, stringsAsFactors = FALSE, check.names = FALSE)
    }
    if (!is.data.frame(x) || !"npi" %in% names(x)) {
      stop(sprintf("Federal adverse-action source %d must contain `npi`", i),
           call. = FALSE)
    }
    npi <- gsub("[^0-9]", "", as.character(x$npi))
    valid_npi <- grepl("^[0-9]{10}$", npi)
    listed <- if ("listed" %in% names(x)) {
      tolower(trimws(as.character(x$listed))) %in%
        c("true", "t", "yes", "y", "1", "listed", "active",
          "revoked", "excluded")
    } else {
      rep(TRUE, nrow(x))
    }
    src <- if ("source" %in% names(x)) as.character(x$source) else
      if ("signal_source" %in% names(x)) as.character(x$signal_source) else
        names(sources)[i]
    if (is.null(src) || !length(src) ||
        all(is.na(src) | !nzchar(trimws(src)))) src <- "Federal adverse action"
    src <- rep(src, length.out = nrow(x))
    data.frame(
      npi = npi[valid_npi & listed],
      federal_adverse_action_excluded = TRUE,
      federal_adverse_action_source = trimws(src[valid_npi & listed]),
      stringsAsFactors = FALSE)
  })

  out <- do.call(rbind, rows)
  if (!nrow(out)) return(empty)
  by_npi <- split(out$federal_adverse_action_source, out$npi)
  data.frame(
    npi = names(by_npi),
    federal_adverse_action_excluded = TRUE,
    federal_adverse_action_source = vapply(
      by_npi, function(x) paste(sort(unique(x)), collapse = "; "), character(1)),
    row.names = NULL,
    stringsAsFactors = FALSE)
}

#' Apply NPI-linked federal adverse-action exclusions.
#' @return List with `all`, `excluded`, and `included` data frames.
exclude_federal_adverse_actions <- function(cohort, flags, npi_col = "npi") {
  if (!is.data.frame(cohort) || !npi_col %in% names(cohort))
    stop("cohort must contain the requested NPI column", call. = FALSE)
  need <- c("npi", "federal_adverse_action_excluded")
  miss <- setdiff(need, names(flags))
  if (length(miss)) stop("flags missing: ", paste(miss, collapse = ", "), call. = FALSE)

  f <- flags[!duplicated(flags$npi), , drop = FALSE]
  key <- gsub("[^0-9]", "", as.character(cohort[[npi_col]]))
  hit <- match(key, gsub("[^0-9]", "", as.character(f$npi)))
  flag <- rep(FALSE, nrow(cohort))
  flag[!is.na(hit)] <- tolower(trimws(as.character(
    f$federal_adverse_action_excluded[hit[!is.na(hit)]]))) %in%
    c("true", "t", "yes", "y", "1")
  src <- rep(NA_character_, nrow(cohort))
  if ("federal_adverse_action_source" %in% names(f))
    src[!is.na(hit)] <- as.character(f$federal_adverse_action_source[hit[!is.na(hit)]])

  all <- cohort
  all$federal_adverse_action_excluded <- flag
  all$federal_adverse_action_source <- src
  all$exclusion_reason <- ifelse(
    flag, paste0("Federal adverse action: ", src), NA_character_)
  list(
    all = all,
    excluded = all[flag, , drop = FALSE],
    included = all[!flag, , drop = FALSE])
}

