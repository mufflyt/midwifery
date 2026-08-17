# =============================================================================
# Canonical address normalisation for join keys
# =============================================================================
# This file deliberately contains NO parsing logic and NO street-abbreviation
# table. It holds one function: the vectorised, deduplicated wrapper that turns
# the canonical parser's output into a join key.
#
# The parser itself lives in mufflyt/isochrones and is loaded through
# load_isochrones_address_parser() in R/lib/isochrones_dep.R, alongside the
# three other isochrones dependencies this project has. That file explains why
# a path dependency beats vendoring, and why the resolution goes through
# ISOCHRONES_R rather than ISOCHRONES_HOME.
#
# An earlier version of this file carried its own isochrones_home(), which
# duplicated the one in isochrones_dep.R and resolved to a DIFFERENT checkout.
# ci_hygiene.R's H4 caught it before it landed.
# =============================================================================

#' Normalise street addresses with the canonical parser
#'
#' @section Deduplicated before parsing, which is not an optimisation:
#' The parser is orders of magnitude slower per string than a regex table, and
#' NPPES address strings repeat heavily -- one hospital campus contributes
#' hundreds of identical rows. A national-scale key build over 125,786
#' organizations reduces to 82,578 distinct strings; parsing row-wise instead
#' of value-wise does not finish.
#'
#' @section Alignment:
#' The result is element-for-element aligned with `x`, including `NA` and blank
#' inputs, so it can be used directly in a `mutate()`. A parser that silently
#' dropped unparseable rows would shift every key after the first bad address.
#'
#' @param x [character] raw address lines.
#' @param quiet [logical(1)] suppress the parser's load message.
#' @return [character] normalised addresses, `NA` where the input was `NA`,
#'   blank, or normalised to nothing.
#' @examples
#' \dontrun{
#'   norm_addr_canonical(c("3130 HIGHLAND AVENUE", "4881 SUGAR MAPLE DR BLDG 830"))
#'   #> "3130 highland ave"  "4881 sugar maple dr"
#' }
#' @family address-keys
#' Derive a bulk-mode config from the canonical one
#'
#' @description
#' Two settings in `config/address_parsing_config.yml` are tuned for
#' interactive geocoding and are pathological for a key build. Both are changed
#' HERE, in a derived copy, rather than upstream: the interactive defaults are
#' right for the callers that chose them.
#'
#' \describe{
#'   \item{`caching$cache_database_path`}{Redirected to a PRIVATE, empty
#'     database per call. Caching is NOT disabled -- `initialize_address_cache()`
#'     stops outright when it is, by explicit upstream design -- so the shared
#'     cache is bypassed instead. It had grown to 160 MB, and an 11,164-address
#'     run slowed to roughly one 10-address chunk per 40 seconds, slower in
#'     absolute terms than the same parser had processed 2,467 addresses earlier
#'     in the same session. The shared file is also a lock: a second R process
#'     touching it dies with "Conflicting lock is held", which killed one run
#'     outright. Bulk normalisation deduplicates its own input, so a warm cache
#'     buys nothing here, and a private one makes the result independent of
#'     whatever an unrelated geocoding session happened to leave behind.}
#'   \item{`performance$batch_processing_threshold`}{Raised above the input
#'     size, which routes the call to the single-pass path instead of batch
#'     mode. Batch mode uses `chunk_size: 10` with a checkpoint per chunk --
#'     8,258 chunks and 8,258 checkpoint writes for one key build.}
#' }
#'
#' The copy is generated FROM the canonical YAML at call time, so any other
#' setting the upstream maintainer changes is inherited rather than frozen.
#'
#' @param n [integer] number of distinct addresses about to be parsed.
#' @param iso_root [character] isochrones repository root.
#' @return [character] path to a temporary YAML config.
#' @noRd
.bulk_parser_config <- function(n, iso_root) {
  src <- file.path(iso_root, "config", "address_parsing_config.yml")
  if (!file.exists(src))
    stop("canonical parser config not found: ", src, call. = FALSE)
  cfg <- yaml::read_yaml(src)
  # Absolute: the parser runs with the working directory at the isochrones root,
  # and a relative path would put this project's scratch cache inside that repo.
  cfg$caching$cache_database_path <-
    tempfile(pattern = "address_cache_", fileext = ".duckdb")
  cfg$performance$batch_processing_threshold <- as.integer(n) + 1L
  cfg$performance$save_checkpoints <- FALSE
  p <- tempfile(pattern = "address_parsing_bulk_", fileext = ".yml")
  yaml::write_yaml(cfg, p)
  p
}

#' Unit designators, canonicalised to one spelling each
#'
#' NOT a street-suffix table -- those belong to the canonical parser and a copy
#' here would be the fork SCI5 exists to prevent. These are the SUITE-level
#' tokens the canonical parser DISCARDS, kept here only so they can be put back.
#'
#' `#` maps to STE deliberately. "1 PEARL ST # 2300" and "1 PEARL ST STE 2300"
#' are one suite written two ways, and under `norm_addr()` they key differently
#' because `#` becomes whitespace.
.UNIT_CANON <- c(
  "SUITE" = "STE", "STE" = "STE", "#" = "STE",
  "APARTMENT" = "APT", "APT" = "APT",
  "BUILDING" = "BLDG", "BLDG" = "BLDG",
  "FLOOR" = "FL", "FL" = "FL",
  "ROOM" = "RM", "RM" = "RM",
  "UNIT" = "UNIT", "STOP" = "STOP", "DEPARTMENT" = "DEPT", "DEPT" = "DEPT",
  "PMB" = "PMB", "PENTHOUSE" = "PH", "PH" = "PH")

#' Extract and canonicalise the unit portion of an address
#'
#' @return [character] e.g. "STE 200", or `NA` when the address names no unit.
#' @noRd
.unit_suffix <- function(x) {
  u <- toupper(trimws(as.character(x)))
  u <- gsub("[.,]", " ", u)
  rx <- paste0("\\b(", paste(setdiff(names(.UNIT_CANON), "#"), collapse = "|"),
               ")\\b\\s*([A-Z0-9-]+)|#\\s*([A-Z0-9-]+)")
  out <- rep(NA_character_, length(u))
  got <- ifelse(grepl(rx, u), sub(paste0("^.*?(", rx, ").*$"), "\\1", u), NA_character_)
  for (i in which(!is.na(got))) {
    tok <- trimws(got[i])
    if (startsWith(tok, "#")) {
      out[i] <- paste("STE", trimws(sub("^#", "", tok)))
    } else {
      parts <- strsplit(gsub("\\s+", " ", tok), " ")[[1]]
      key <- parts[1]
      val <- paste(parts[-1], collapse = " ")
      canon <- .UNIT_CANON[[key]]
      out[i] <- if (nzchar(val)) paste(canon, val) else canon
    }
  }
  out
}

#' Canonical street normalisation that KEEPS the suite
#'
#' @description
#' The canonical parser discards unit designators: "1315 JESSE JEWELL PKWY NE
#' STE 200" becomes "1315 jesse jewell pkwy ne". That is correct for
#' building-level matching and WRONG as a drop-in replacement for `norm_addr()`,
#' whose documented policy is that two suites in one building are two
#' workplaces.
#'
#' Substituting the parser wholesale therefore bundles a POLICY change with a
#' normalisation fix. Measured on the 1,544 unresolved ACTIVE cohort, the bundle
#' is +46 uniquely resolved, of which +39 is also achieved by
#' `norm_addr_drop_unit()` -- i.e. by dropping suites alone. Only the ~7
#' remainder is street normalisation, and only that part is unambiguously a fix.
#'
#' This function isolates it: the canonical parser normalises the street, and the
#' unit is put back from the raw input in one canonical spelling. So
#' "361 THIRD STREET" and "361 3RD ST" converge, while "STE 100" and "STE 500"
#' stay apart.
#'
#' @param x [character] raw address lines.
#' @param quiet [logical(1)] suppress the parser's load message.
#' @return [character] normalised address retaining a canonical unit suffix.
#' @examples
#' \dontrun{
#'   norm_addr_canonical_keep_unit(c("361 THIRD STREET", "1315 JESSE JEWELL PKWY NE STE 200"))
#'   #> "361 3rd st"  "1315 jesse jewell pkwy ne STE 200"
#' }
#' @family address-keys
norm_addr_canonical_keep_unit <- function(x, quiet = TRUE) {
  street <- norm_addr_canonical(x, quiet = quiet)
  unit <- .unit_suffix(x)
  # Lower-cased to match the parser's own output. A key that is half lowercase
  # and half uppercase still joins correctly -- both sides get the same
  # treatment -- but it reads as a bug in every log and diff it appears in.
  out <- ifelse(is.na(street), NA_character_,
                ifelse(is.na(unit), street, paste(street, tolower(unit))))
  out[!is.na(out) & !nzchar(trimws(out))] <- NA_character_
  out
}

norm_addr_canonical <- function(x, quiet = TRUE) {
  load_isochrones_address_parser(quiet = quiet)

  x <- as.character(x)
  usable <- !is.na(x) & nzchar(trimws(x))
  out <- rep(NA_character_, length(x))
  if (!any(usable)) return(out)

  u <- unique(x[usable])
  iso_root <- dirname(Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R")))
  cfg_path <- .bulk_parser_config(length(u), iso_root)

  # The parser resolves sibling source() calls relative to the working
  # directory. Restore unconditionally: leaving it changed would redirect every
  # later write_with_provenance() in the calling script into the isochrones repo.
  owd <- getwd()
  on.exit(setwd(owd), add = TRUE)
  setwd(iso_root)
  # parse_addresses_canonical(), not normalize_addresses_canonical(): the latter
  # is marked deprecated upstream and is a thin wrapper around this call.
  res <- parse_addresses_canonical(addresses = u, config_path = cfg_path,
                                  return_components = FALSE,
                                  return_normalized = TRUE, verbose = FALSE)
  setwd(owd)

  parsed <- res$normalized_address
  if (length(parsed) != length(u))
    stop(sprintf(paste("canonical parser returned %d rows for %d addresses.",
                       "Alignment is not recoverable -- refusing to guess."),
                 length(parsed), length(u)), call. = FALSE)

  m <- stats::setNames(parsed, u)
  out[usable] <- unname(m[x[usable]])
  out[!is.na(out) & !nzchar(trimws(out))] <- NA_character_
  out
}
