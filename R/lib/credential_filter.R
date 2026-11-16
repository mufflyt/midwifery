# =============================================================================
# Credential filter
# =============================================================================
# Keep rows whose credential field does NOT contain any excluded credential.
# Word-boundary match so "MD" doesn't also match "DMD"; default excludes
# physicians (MD, DO) so APRNs -- including CNMs -- pass through, the inverse
# of isochrones' R/C-filter_physician_compare_physicians_only.R, which keeps
# only MD/DO.
#
# PERIODS ARE STRIPPED BEFORE MATCHING. A word boundary cannot see through
# punctuation: the pattern for MD does not match "M.D.", because that string
# holds no adjacent M and D at all. A physician whose credential was written
# in the dotted form would have passed straight into a midwife cohort,
# changing the denominator of every table with nothing failing. Neither
# current source writes the dotted form -- 0 of 4,944 Doctors and Clinicians
# rows and 0 of 36,339 historical rows, checked directly -- so this is a
# latent gap rather than an active one, and the fix changes nothing on
# today's inputs.
#
# Stripping periods does not create a false exclusion: "D.O.M." becomes
# "DOM", which still has no word boundary around DO, and "PH.D." becomes
# "PHD", which contains neither credential.
# =============================================================================

#' Keep rows whose credential does not name an excluded profession
#'
#' @param credential [character] raw credential field. NA and blank are KEPT,
#'   deliberately: an absent credential is not evidence of being a physician.
#'   `grepl()` returns FALSE on NA rather than NA, so the result is always a
#'   usable logical and never injects an all-NA row when used as an index.
#' @param exclude [character] credentials to exclude, matched whole-word and
#'   case-insensitively with periods removed from the input first. Values are
#'   escaped, so a caller passing "M.D" cannot turn the "." into a wildcard.
#' @return [logical] same length and order as `credential`; TRUE to keep.
#' @export
exclude_by_credential <- function(credential, exclude = c("MD", "DO")) {
  # AN EMPTY EXCLUDE LIST MUST REMOVE NOBODY. Built naively the pattern
  # becomes "\\b()\\b", an empty alternation that matches at every word
  # boundary, so asking to exclude nothing excluded everyone and silently
  # emptied the cohort. Caught by saboteur E10.
  if (!length(exclude)) return(rep(TRUE, length(credential)))

  # PERIODS COME OUT OF BOTH SIDES. Stripping them from the credential but
  # not from the exclude list meant a caller passing "M.D" could never match
  # anything, because the credential had already become "MD". Normalize the
  # two the same way, then escape what remains so a metacharacter in the
  # caller's list stays literal. Caught by saboteur E9.
  undotted_exclude <- gsub(".", "", exclude, fixed = TRUE)
  escaped <- gsub("([][(){}.*+?^$|\\])", "\\\\\\1", undotted_exclude)
  pattern <- paste0("\\b(", paste(escaped, collapse = "|"), ")\\b")
  undotted <- gsub(".", "", credential, fixed = TRUE)
  !grepl(pattern, undotted, ignore.case = TRUE)
}
