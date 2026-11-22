# =============================================================================
# Which laws have stopped being enforced, and were they declared?
# =============================================================================
# A law's `privacy` column in tests/science_law_registry.tsv decides whether a
# skip is legitimate. `public` means its inputs are tracked, so a skip is a
# failure and the law is evaluated on every runner. `private-ok` and
# `derived-ok` both make a skip legal, which converts an enforced law into one
# that no runner evaluates.
#
# ci_law_coverage.R counted and named that outcome but never failed on it, so
# the number could grow one word at a time while the gate stayed green and
# merely printed a larger total. The registry's own comment records the mistake
# being made: registering L5 `private-ok` asserted that a 31 MB derived
# isochrone surface was person-level data.
#
# A PURE FUNCTION, DELIBERATELY. The comparison lives here rather than inline in
# the gate so that tests/test_law_privacy_ratchet.R can exercise it against
# fixtures in milliseconds. Inline, the only way to test it was to perturb the
# registry and run the whole coverage gate -- which re-runs every law, takes
# minutes, and (because ci_fail() buffers until ci_finish()) cannot even be
# observed without letting it finish.
# =============================================================================

#' Laws that are non-public without a declaration, and declarations gone stale
#'
#' @param law [character] law identifiers, in registry order.
#' @param privacy [character] each law's privacy class.
#' @param declared [character] laws declared in the privacy baseline.
#' @return [list] `undeclared` (non-public, not declared) and `stale`
#'   (declared, but public again). Both may only shrink.
law_privacy_violations <- function(law, privacy, declared) {
  if (length(law) != length(privacy))
    stop(sprintf("law and privacy differ in length (%d vs %d)",
                 length(law), length(privacy)), call. = FALSE)
  non_public <- law[!is.na(privacy) & trimws(privacy) != "public"]
  declared <- trimws(declared[!is.na(declared) & nzchar(trimws(declared))])
  list(non_public = non_public,
       undeclared = setdiff(non_public, declared),
       # A declaration must not outlive its cause, the same rule N1 enforces on
       # tests/ci_nightly_exceptions.txt: left in place it silently licenses the
       # next downgrade of that law.
       stale      = setdiff(declared, non_public))
}

#' Parse the privacy baseline's declared law identifiers
#' @param path [character(1)] tests/law_privacy_baseline.tsv
#' @return [character] law ids, empty when the file is absent or header-only.
law_privacy_declared <- function(path) {
  if (!file.exists(path)) return(character(0))
  ln <- readLines(path, warn = FALSE)
  ln <- ln[!grepl("^#", ln) & nzchar(trimws(ln))]
  if (length(ln) < 2L) return(character(0))
  vapply(strsplit(ln[-1], "\t"), function(p) trimws(p[1]), character(1))
}
