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
norm_addr_canonical <- function(x, quiet = TRUE) {
  load_isochrones_address_parser(quiet = quiet)

  x <- as.character(x)
  usable <- !is.na(x) & nzchar(trimws(x))
  out <- rep(NA_character_, length(x))
  if (!any(usable)) return(out)

  u <- unique(x[usable])

  # The parser resolves its config relative to the working directory. Restore
  # unconditionally: leaving it changed would redirect every later
  # write_with_provenance() in the calling script into the isochrones repo.
  owd <- getwd()
  on.exit(setwd(owd), add = TRUE)
  setwd(dirname(Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))))
  parsed <- normalize_addresses_canonical(u)
  setwd(owd)

  m <- stats::setNames(parsed, u)
  out[usable] <- unname(m[x[usable]])
  out[!is.na(out) & !nzchar(trimws(out))] <- NA_character_
  out
}
