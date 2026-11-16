# =============================================================================
# Resolve a cohort artifact without hardcoding the panel's year window
# =============================================================================
# Thirty-four references across eighteen scripts name a cohort artifact by its
# full filename, with the panel's year window baked in:
#   artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv
# The window is not decoration. match_amcb_to_npi.R:438 builds its output name
# from year_window(panel), so the moment the panel gained a 2026 snapshot every
# one of those names became the name of a PREVIOUS cohort. Nothing breaks
# loudly; the scripts keep reading a file that still exists and quietly
# describe last year's linkage.
#
# WHY NOT COLLAPSE THEM ONTO ONE CANONICAL PATH. Because the four families are
# not interchangeable, and the differences are exactly the kind a single path
# would erase. Measured on the artifacts on disk: the c5guard crosswalk and
# amcb_npi_linkage_FROZEN.csv hold the SAME 22,309 certificants, but 156 of
# them carry an NPI in c5guard and a BLANK in FROZEN -- all 156 in that one
# direction, the class-5 absence demotion. Pointing thirty references at one
# file would hand 156 midwives an NPI the freeze deliberately withdrew. The
# year window must follow the panel; the FAMILY must not move.
#
# WHY NOT RESOLVE BY mtime. Six scripts already resolve this family
# year-agnostically -- build_reassignment_panel.R:75 and five others do
# `cw[order(file.mtime(cw), decreasing = TRUE)][1]`. That is newest FILE, not
# newest COHORT, and the two are different things: cp, rsync, a git checkout
# and a gate run all rewrite mtime without touching a byte of data. The same
# mistake dated a scraped artifact to "today" in a fresh worktree earlier in
# this work. Resolution here is by the YEAR WINDOW IN THE NAME, which is a fact
# about the cohort, and ties are refused rather than broken arbitrarily.
#
# AMBIGUITY IS AN ERROR, NOT A COIN FLIP. artifacts/ already holds both
# amcb_npi_linkage_panel-midwifery-plus-nursing_years-2007-2025.csv and
# ..._years-2007-2025_rerun20260901.csv. A glob sees two files for one window.
# Only the canonical shape is accepted; a suffixed variant is a different
# artifact and is listed, never silently chosen.
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

#' The families of cohort artifact, and how each one's name is built
#'
#' `linkage` is match_amcb_to_npi.R's direct output; the three `crosswalk_*`
#' families are later enrichment stages. Keyed by the short name a caller uses.
COHORT_ARTIFACT_PATTERNS <- c(
  linkage             = "amcb_npi_linkage_panel-%s_years-%s.csv",
  crosswalk_translit  = "amcb_npi_crosswalk_translit_panel-%s_years-%s.csv",
  crosswalk_component = "amcb_npi_crosswalk_component_panel-%s_years-%s.csv",
  crosswalk_c5guard   = "amcb_npi_crosswalk_c5guard_panel-%s_years-%s.csv")

COHORT_DEFINITION_DEFAULT <- "midwifery-plus-nursing"

#' Exact basename for one family/definition/window
cohort_artifact_basename <- function(family, window,
                                     definition = COHORT_DEFINITION_DEFAULT) {
  if (!family %in% names(COHORT_ARTIFACT_PATTERNS))
    stop(sprintf("unknown cohort artifact family '%s'; known: %s", family,
                 paste(names(COHORT_ARTIFACT_PATTERNS), collapse = ", ")), call. = FALSE)
  sprintf(COHORT_ARTIFACT_PATTERNS[[family]], definition, window)
}

#' Which windows of a family are actually on disk
#'
#' Only canonically-shaped names are returned. A name carrying anything after
#' the window -- `_rerun20260901`, `_arm2`, a date stamp -- is a deliberate
#' side artifact and is excluded, because including it would make "the newest
#' window" ambiguous and invite the arbitrary pick this file exists to prevent.
#'
#' @return [data.frame] path, window, start_year, end_year; zero rows if none.
cohort_artifact_available <- function(family, definition = COHORT_DEFINITION_DEFAULT,
                                      art_dir = "artifacts") {
  pat <- cohort_artifact_basename(family, "*", definition)
  hits <- Sys.glob(file.path(art_dir, pat))
  hits <- hits[!grepl("\\.(manifest|provenance)\\.json$", hits)]
  if (!length(hits))
    return(data.frame(path = character(0), window = character(0),
                      start_year = integer(0), end_year = integer(0),
                      stringsAsFactors = FALSE))
  # Re-derive the window from each name against the EXACT family shape, so a
  # suffixed variant fails the anchor and drops out instead of being parsed.
  esc <- function(x) gsub("([.|()\\^{}+$*?\\[\\]])", "\\\\\\1", x, perl = TRUE)
  rx <- paste0("^", esc(sprintf(COHORT_ARTIFACT_PATTERNS[[family]], definition, "\001")))
  rx <- sub("\001", "(\\\\d{4})-(\\\\d{4})", rx)
  rx <- sub("\\\\.csv$", "\\\\.csv$", rx)
  m <- regmatches(basename(hits), regexec(rx, basename(hits)))
  ok <- vapply(m, length, integer(1)) == 3L
  if (!any(ok))
    return(data.frame(path = character(0), window = character(0),
                      start_year = integer(0), end_year = integer(0),
                      stringsAsFactors = FALSE))
  hits <- hits[ok]; m <- m[ok]
  sy <- as.integer(vapply(m, `[`, "", 2L)); ey <- as.integer(vapply(m, `[`, "", 3L))
  d <- data.frame(path = hits, window = sprintf("%d-%d", sy, ey),
                  start_year = sy, end_year = ey, stringsAsFactors = FALSE)
  d[order(-d$end_year, -d$start_year), , drop = FALSE]
}

#' Resolve one cohort artifact
#'
#' @param family one of `names(COHORT_ARTIFACT_PATTERNS)`.
#' @param window `"2007-2026"`, or NULL to take the LATEST window on disk.
#' @param definition panel definition in the filename.
#' @param art_dir artifacts directory.
#' @param must_exist error if the resolved file is absent.
#' @return [character(1)] path.
cohort_artifact_path <- function(family, window = NULL,
                                 definition = COHORT_DEFINITION_DEFAULT,
                                 art_dir = "artifacts", must_exist = TRUE) {
  if (!is.null(window)) {
    p <- file.path(art_dir, cohort_artifact_basename(family, window, definition))
    if (must_exist && !file.exists(p))
      stop(sprintf("cohort artifact not found: %s\n  windows available for '%s': %s",
                   p, family,
                   { a <- cohort_artifact_available(family, definition, art_dir)
                     if (nrow(a)) paste(a$window, collapse = ", ") else "<none>" }),
           call. = FALSE)
    if (must_exist) return(assert_usable_cohort_artifact(p))
    return(p)
  }
  a <- cohort_artifact_available(family, definition, art_dir)
  if (!nrow(a)) {
    if (!must_exist) return(NA_character_)
    stop(sprintf(paste0("no '%s' cohort artifact in %s for definition '%s'.\n",
                        "  Expected something shaped like: %s"),
                 family, art_dir, definition,
                 cohort_artifact_basename(family, "YYYY-YYYY", definition)), call. = FALSE)
  }
  # A START YEAR THAT MOVED IS A DIFFERENT COHORT, NOT A NEWER ONE. Ordering by
  # end year alone made `years-2020-2026` the "latest" window and
  # `years-2007-2025` the older one, so a truncated rebuild, a test run with a
  # restricted window or a changed panel config would be picked up as the
  # newest cohort and frozen by freeze_cohort.R:133 -- every published
  # denominator moving at once, with nothing to fail. The panel's start year is
  # a property of the cohort definition and is fixed; only the end year follows
  # the panel forward. Where the start years on disk disagree, the choice is
  # between different cohorts and there is no "latest", so it is refused.
  distinct_starts <- sort(unique(a$start_year))
  if (length(distinct_starts) > 1L)
    stop(sprintf(paste0("cohort artifact '%s' has windows with DIFFERENT START YEARS ",
                        "(%s), so there is no latest window to take:\n  %s\n  A start ",
                        "year that moved means a different cohort, not a newer one. Pass ",
                        "window= explicitly to say which cohort you mean."),
                 family, paste(distinct_starts, collapse = ", "),
                 paste(sprintf("%s (window %s)", basename(a$path), a$window),
                       collapse = "\n  ")), call. = FALSE)

  # The start-year check above subsumes the shared-end-year ambiguity branch
  # that used to stand here. Two canonical files differ in their window by
  # definition -- the window IS the name -- so two sharing an end year must
  # differ in their start year, which is now refused one step earlier with a
  # message that names the real condition. Keeping both left a branch no
  # input could reach, and an unreachable guard is one nobody can test.
  assert_usable_cohort_artifact(a$path[which.max(a$end_year)])
}

#' A resolved cohort artifact must be a readable file with content
#'
#' `file.exists()` is TRUE for a directory and TRUE for a zero-byte file, and
#' this function's answer is handed straight to `read_csv()` by every caller.
#' A botched extract leaving a DIRECTORY named like the artifact, or a
#' truncated or interrupted write leaving nothing in it, would resolve as the
#' cohort and be read as a cohort with no records. Unlike a declared source
#' year, a zero-byte cohort linkage is never evidence of absence: a real empty
#' cohort still writes its header, so no bytes at all means no write happened.
#'
#' @param path [character(1)] the resolved path.
#' @return [character(1)] the same path, or an error.
assert_usable_cohort_artifact <- function(path) {
  if (dir.exists(path))
    stop(sprintf(paste0("cohort artifact resolved to a DIRECTORY, not a file: %s\n",
                        "  file.exists() is TRUE for a directory, so this would have ",
                        "been read as the cohort."), path), call. = FALSE)
  if (file.exists(path) && file.size(path) == 0L)
    stop(sprintf(paste0("cohort artifact is ZERO BYTES: %s\n  A cohort with no ",
                        "certificants still writes its header, so an empty file means ",
                        "the write did not finish, not that the cohort is empty."),
                 path), call. = FALSE)
  path
}
