#!/usr/bin/env Rscript
#' @title Re-pin the frozen Stage-2 (NPPES-matched) snapshot
#'
#' @description
#' `artifacts/frozen_stage2/midwives_with_nppes.csv` is a pinned copy of
#' `midwives_with_nppes.csv`, the NPPES-matched output of `match_nppes.R`.
#' `R/07-cohort-composition.R` reads it as the "before" side of the four-way
#' cohort-composition comparison and requires it to be from the SAME pinned
#' vintage as `artifacts/frozen_cohort/` -- see that script's own header.
#'
#' UNLIKE `artifacts/frozen_cohort/`, this snapshot had no re-pin tool at all
#' until this file: `R/05-stage-progression.R` only ever READS
#' `frozen_stage2/midwives_with_nppes.csv`, nothing wrote it. It was copied in
#' by hand once, and by 2026-09-11 the file itself was gone from every machine
#' checked that night -- only its `SHA256SUMS` sidecar (dated 2026-08-14)
#' survived. A manual step with no script behind it is a step that silently
#' stops happening; see `reconcile_linkage.R`'s `cohort_member` column for the
#' identical shape of failure earlier this same session. Recorded in
#' `DEBT.md` D10.
#'
#' THIS SCRIPT NEEDS THE PERSON-LEVEL FILES and therefore only runs on a
#' machine holding them. It is a dry run by default and reports what it
#' would do.
#'
#' Usage:
#'   Rscript repin_frozen_stage2.R                # dry run
#'   REPIN_APPLY=1 Rscript repin_frozen_stage2.R  # execute
#'
#' After applying, in this order:
#'   1. Rebuild the composition table   -> Rscript R/07-cohort-composition.R
#'   2. Confirm the vintages agree      -> Rscript tests/test_cohort_vintage.R
#'   3. Rebuild the selection bounds    -> Rscript analyze_linkage_selection_bias.R
#'   4. Redraw the affected figures     -> make_cohort_flow_figure.R,
#'      make_linkage_figures.R, make_linkage_upset_figure.R
#'
#' @family maintenance
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(jsonlite); library(readr); library(dplyr)})

APPLY <- nzchar(Sys.getenv("REPIN_APPLY"))
LINKAGE_MANIFEST <- "artifacts/linkage_manifest.json"
FINGER <- "artifacts/frozen_stage2/INPUT_FINGERPRINT.json"
SOURCE <- "midwives_with_nppes.csv"   # repo root -- match_nppes.R's own output path
PINNED <- "artifacts/frozen_stage2/midwives_with_nppes.csv"
LEGACY_SUMS <- "artifacts/frozen_stage2/SHA256SUMS"

cat("================ RE-PIN FROZEN STAGE-2 ================\n")
cat(sprintf("mode: %s\n\n", if (APPLY) "APPLY (will overwrite the pin)" else
                            "DRY RUN (default; nothing is written)"))

if (!file.exists(LINKAGE_MANIFEST)) stop("No linkage manifest at ", LINKAGE_MANIFEST, call. = FALSE)
man <- fromJSON(LINKAGE_MANIFEST)
roster_total <- man$linkage$total_rows
cat(sprintf("current roster (linkage_manifest.json total_rows): %s\n",
            format(roster_total, big.mark = ",")))

if (file.exists(FINGER)) {
  fp <- fromJSON(FINGER)
  cat(sprintf("pinned snapshot  : %s rows, frozen %s\n",
              format(fp$rows, big.mark = ","), fp$frozen_at))
} else if (file.exists(LEGACY_SUMS)) {
  cat(sprintf("pinned snapshot  : absent, but a legacy %s exists (pre-dates this\n", LEGACY_SUMS))
  cat("                   tool's JSON fingerprint; superseded once this applies)\n")
} else {
  cat("pinned snapshot  : absent\n")
}

if (!file.exists(SOURCE)) {
  stop("\n", SOURCE, " is not present.\n",
       "  It is person-level and gitignored. Re-pinning requires the machine\n",
       "  that holds it; rebuild it with fetch_npi_candidates.py + match_nppes.R\n",
       "  first.", call. = FALSE)
}

src <- read_csv(SOURCE, show_col_types = FALSE, guess_max = 50000)
cat(sprintf("\nsource to pin    : %s, %s rows\n", SOURCE,
            format(nrow(src), big.mark = ",")))

# SANITY, NOT AN EXACT TARGET. Unlike frozen_cohort (which has a declared
# cohort_members count in a manifest), midwives_with_nppes.csv holds only the
# ACCEPTED matches from match_nppes.R -- an empirical outcome of that run, not
# a number this script can know in advance. What IS knowable and checkable:
# it can never exceed the roster it was matched against (one accepted row per
# certificant, at most), and match_nppes.R's own hard gate
# (validate_pipeline_output(), match rate floor 65%) already ran and passed
# by the time this file exists -- a completed run is itself the quality
# signal this script defers to, rather than re-deriving it.
if (nrow(src) > roster_total) {
  stop(sprintf(paste0(
    "\nRefusing to pin: the source has %s rows but the roster has only %s.\n",
    "  midwives_with_nppes.csv should hold at most one accepted row per\n",
    "  certificant. More rows than the roster means match_nppes.R produced\n",
    "  duplicates or was run against a different roster than the one\n",
    "  linkage_manifest.json currently describes."),
    format(nrow(src), big.mark = ","), format(roster_total, big.mark = ",")),
    call. = FALSE)
}
if (!"npi" %in% names(src) || anyDuplicated(src$npi[!is.na(src$npi)]))
  stop("Refusing to pin: source is missing an npi column or has a duplicate NPI.",
       call. = FALSE)

`%||%` <- function(a, b) if (is.null(a)) b else a
county_best <- if ("county_best" %in% names(src)) sum(!is.na(src$county_best)) else NA_integer_
new_fp <- list(source = basename(SOURCE), frozen = PINNED,
               sha256 = as.character(tools::md5sum(SOURCE)),  # placeholder, replaced below
               mtime = format(file.mtime(SOURCE), "%Y-%m-%d %H:%M:%S"),
               rows = nrow(src), county_best = county_best,
               frozen_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
               repinned_for = man$git_commit %||% NA_character_,
               matched_against_roster_total = roster_total)
if (requireNamespace("digest", quietly = TRUE))
  new_fp$sha256 <- digest::digest(file = SOURCE, algo = "sha256")

cat("\nwould write:\n")
cat(sprintf("  %s\n  %s\n", PINNED, FINGER))
cat(sprintf("  rows %s of %s roster (%.1f%%), county_best %s\n",
            format(new_fp$rows, big.mark = ","), format(roster_total, big.mark = ","),
            100 * new_fp$rows / roster_total,
            format(new_fp$county_best, big.mark = ",")))

if (!APPLY) {
  cat("\nDry run. Set REPIN_APPLY=1 to execute.\n")
  quit(status = 0L)
}

dir.create(dirname(PINNED), showWarnings = FALSE, recursive = TRUE)
if (file.exists(PINNED)) {
  bak <- paste0(PINNED, ".pre_repin_", format(Sys.time(), "%Y%m%dT%H%M%S"))
  file.rename(PINNED, bak)
  cat(sprintf("\nprevious pin kept at %s\n", bak))
}
file.copy(SOURCE, PINNED, overwrite = TRUE)
write_json(new_fp, FINGER, auto_unbox = TRUE, pretty = FALSE)
cat("re-pinned.\n\nNow run, in order:\n",
    "  Rscript R/07-cohort-composition.R\n",
    "  Rscript tests/test_cohort_vintage.R\n",
    "  Rscript analyze_linkage_selection_bias.R\n",
    "  Rscript make_cohort_flow_figure.R\n",
    "  Rscript make_linkage_figures.R\n",
    "  Rscript make_linkage_upset_figure.R\n", sep = "")
