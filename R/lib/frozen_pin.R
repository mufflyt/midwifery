# =============================================================================
# Refusing to re-pin a frozen artifact as a side effect
# =============================================================================
# R/05-stage-progression.R already argues this case, in the comment above its
# freeze_input(): a freeze that silently re-freezes is a copy, and re-pinning
# "changes the analytic population and every downstream count", so the decision
# "belongs to a person, not to whoever happened to run this script". It records
# that the accident happened twice -- once caught and reverted, once shipped in
# a commit claiming no estimand had changed, having moved the cohort from
# 17,538 to 16,892.
#
# That guard protects an INPUT being frozen. This one protects an OUTPUT that
# other scripts treat as frozen, which had no guard at all: R/03 writes
# artifacts/midwives_geography_FROZEN.csv wherever STAGE3_OUT points, so a
# plain `Rscript R/03-geography-hierarchy.R` re-pinned the geography every
# published county figure rests on. Running the pipeline should not be able to
# move the analytic population.
#
# Not merged with freeze_input(). The two are different operations -- that one
# copies a source in and fingerprints it, this one intercepts a computed frame
# on its way out -- and collapsing them would mean one function with a mode
# flag, which is how a guard acquires the branch that skips it.
#
# The comparison is on CONTENT, not mtime or hash: a rebuild that reproduces the
# artifact byte for byte is not a re-pin and must not require a ceremony. Only a
# rebuild that would CHANGE the file stops.
# =============================================================================

#' Count rows in which a column genuinely differs
#'
#' NUMERIC COLUMNS ARE COMPARED AS NUMBERS. Comparing them as strings reports a
#' change whenever the formatting differs, and it always does: the frame in
#' memory renders through as.character() at 15 significant digits while the
#' committed CSV carries whatever the writer rounded to. The first version of
#' this guard reported 2,435 changed rows in zip_top_land_share, and the two
#' files agree on that column exactly -- zero rows differ numerically.
#'
#' That is not a cosmetic defect. A guard that fires on formatting noise gets
#' bypassed with ALLOW_REFREEZE=1 as a matter of routine, and then it is not a
#' guard, it is a speed bump with a habit attached.
#'
#' @param o,n [character]: the pinned and the rebuilt column.
#' @return [integer] number of rows that differ.
#' @keywords internal
#' @noRd
frozen_col_diff <- function(o, n) {
  o[is.na(o)] <- ""; n[is.na(n)] <- ""
  po <- suppressWarnings(as.numeric(o)); pn <- suppressWarnings(as.numeric(n))
  # Numeric only if every non-empty value on BOTH sides parses. A column of
  # county FIPS that happens to be all digits is still compared numerically,
  # which is correct: 06075 and 6075 are the same county, and the width gate
  # in ci_semantic_contracts.R is what polices the padding.
  numeric_col <- all(nzchar(o) == !is.na(po)) && all(nzchar(n) == !is.na(pn)) &&
                 any(!is.na(po))
  if (numeric_col) {
    both <- !is.na(po) & !is.na(pn)
    sum(xor(is.na(po), is.na(pn))) + sum(abs(po[both] - pn[both]) > 1e-9)
  } else {
    sum(o != n)
  }
}

#' Refuse to overwrite a frozen artifact whose content would change
#'
#' @param new [data.frame]: the frame about to be written.
#' @param path [character]: destination. Absent means first write; proceed.
#' @param what [character]: name used in the message.
#' @param allow_env [character]: env var that makes the overwrite deliberate.
#' @return `new`, invisibly, when the write may proceed. Otherwise stops.
#' @keywords internal
#' @noRd
guard_frozen_write <- function(new, path, what = basename(path),
                               allow_env = "ALLOW_REFREEZE") {
  if (!file.exists(path)) return(invisible(new))

  old <- tryCatch(
    utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                    colClasses = "character"),
    error = function(e) NULL)
  if (is.null(old)) return(invisible(new))

  # Compare as character so 1 and 1.0 do not read as a change; the artifact is
  # a CSV and the CSV is what downstream reads.
  cmp <- as.data.frame(lapply(new, as.character), stringsAsFactors = FALSE,
                       check.names = FALSE)

  same_shape <- identical(dim(old), dim(cmp)) &&
                identical(sort(names(old)), sort(names(cmp)))
  if (same_shape) {
    cmp <- cmp[, names(old), drop = FALSE]
    if (identical(old, cmp)) return(invisible(new))   # byte-identical rebuild
    # Not byte-identical is not the same as changed: check each column on its
    # own terms before refusing.
    if (!any(vapply(names(old), function(cc) frozen_col_diff(old[[cc]], cmp[[cc]]) > 0L,
                    logical(1)))) return(invisible(new))
  }

  if (nzchar(Sys.getenv(allow_env))) {
    message(sprintf("%s=1: re-pinning %s deliberately.", allow_env, what))
    return(invisible(new))
  }

  detail <- if (!same_shape) {
    sprintf("  shape  : %d x %d pinned, %d x %d rebuilt",
            nrow(old), ncol(old), nrow(cmp), ncol(cmp))
  } else {
    diffs <- vapply(names(old), function(cc) frozen_col_diff(old[[cc]], cmp[[cc]]),
                    integer(1))
    diffs <- sort(diffs[diffs > 0], decreasing = TRUE)
    paste(sprintf("  %-22s %d row(s) differ", names(diffs), diffs),
          collapse = "\n")
  }

  stop(sprintf(paste0(
    "FROZEN ARTIFACT WOULD CHANGE -- refusing to re-pin %s.\n%s\n",
    "Every published county, rurality and access figure rests on this file.\n",
    "A rebuild that reproduces it exactly passes this guard untouched, so a\n",
    "difference here means an input moved -- most often the shared geocoding\n",
    "cache resolving addresses it previously could not.\n",
    "If re-pinning is intended, re-run with %s=1 and regenerate what depends\n",
    "on it. To inspect first, point the output elsewhere and diff:\n",
    "  STAGE3_OUT=/tmp/rebuild.csv Rscript R/03-geography-hierarchy.R"),
    what, detail, allow_env), call. = FALSE)
}
