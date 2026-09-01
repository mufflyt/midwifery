#!/usr/bin/env Rscript
#' @title Re-pin the frozen cohort snapshot to the current freeze
#'
#' @description
#' `artifacts/frozen_cohort/` is a pinned copy of the geography-guarded cohort.
#' Every geography artifact descends from it, so when the crosswalk is re-frozen
#' and this snapshot is not re-pinned, the geography half of the pipeline keeps
#' describing the previous cohort while the linkage half describes the current
#' one. Nothing else reports that, because each half is internally consistent.
#'
#' That is exactly what happened on 2026-08-10: the snapshot was pinned at
#' 05:31 and `refreeze_option2_20260810T192207` landed at 19:22, moving
#' membership 16,892 -> 16,898. It went unnoticed for three weeks.
#'
#' THIS SCRIPT NEEDS THE PERSON-LEVEL FILES and therefore only runs on a machine
#' holding them. It is a dry run by default and reports what it would do.
#'
#' Usage:
#'   Rscript repin_frozen_cohort.R                # dry run
#'   REPIN_APPLY=1 Rscript repin_frozen_cohort.R  # execute
#'
#' After applying, in this order:
#'   1. Rebuild the composition table   -> Rscript R/07-cohort-composition.R
#'   2. Confirm the vintages agree      -> Rscript tests/test_cohort_vintage.R
#'   3. Redraw the flow figure          -> Rscript make_cohort_flow_figure.R
#'   4. Rebuild the provider panel, then update panel.cohort_n_at_panel_build,
#'      panel.observed and panel.provider_years in
#'      manuscript/R/build_stats_catalog.R together. Changing one alone makes
#'      `observed` a count against a denominator it was never taken from.
#'
#' @family maintenance
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(jsonlite); library(readr); library(dplyr)})

APPLY <- nzchar(Sys.getenv("REPIN_APPLY"))
MANIFEST <- "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json"
FINGER   <- "artifacts/frozen_cohort/INPUT_FINGERPRINT.json"
SOURCE   <- "artifacts/midwives_geography_guarded.csv"
PINNED   <- "artifacts/frozen_cohort/midwives_geography_guarded.csv"

cat("================ RE-PIN FROZEN COHORT ================\n")
cat(sprintf("mode: %s\n\n", if (APPLY) "APPLY (will overwrite the pin)" else
                            "DRY RUN (default; nothing is written)"))

if (!file.exists(MANIFEST)) stop("No crosswalk manifest at ", MANIFEST, call. = FALSE)
man <- fromJSON(MANIFEST)
cat(sprintf("freeze of record : %s\n", man$run_id))
cat(sprintf("cohort_members   : %s\n", format(man$cohort_members, big.mark = ",")))

if (file.exists(FINGER)) {
  fp <- fromJSON(FINGER)
  cat(sprintf("pinned snapshot  : %s rows, frozen %s\n",
              format(fp$rows, big.mark = ","), fp$frozen_at))
  if (identical(as.integer(fp$rows), as.integer(man$cohort_members))) {
    cat("\nAlready in agreement. Nothing to do.\n")
    quit(status = 0L)
  }
  cat(sprintf("DRIFT            : %+d rows\n", fp$rows - man$cohort_members))
} else {
  cat("pinned snapshot  : absent\n")
}

if (!file.exists(SOURCE)) {
  stop("\n", SOURCE, " is not present.\n",
       "  It is person-level and gitignored. Re-pinning requires the machine\n",
       "  that holds it; rebuild it with the geography stages first.", call. = FALSE)
}

src <- read_csv(SOURCE, show_col_types = FALSE, guess_max = 50000)
cat(sprintf("\nsource to pin    : %s, %s rows\n", SOURCE,
            format(nrow(src), big.mark = ",")))

if (nrow(src) != man$cohort_members) {
  stop(sprintf(paste0(
    "\nRefusing to pin: the source has %s rows but the freeze declares %s.\n",
    "  Re-pinning a source that does not match the freeze would replace one\n",
    "  vintage mismatch with another. Rebuild the geography stages against\n",
    "  the current crosswalk first."),
    format(nrow(src), big.mark = ","),
    format(man$cohort_members, big.mark = ",")), call. = FALSE)
}

county_best <- if ("county_best" %in% names(src)) sum(!is.na(src$county_best)) else NA_integer_
new_fp <- list(source = basename(SOURCE), frozen = PINNED,
               sha256 = as.character(tools::md5sum(SOURCE)),  # placeholder, replaced below
               mtime = format(file.mtime(SOURCE), "%Y-%m-%d %H:%M:%S"),
               rows = nrow(src), county_best = county_best,
               frozen_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
               repinned_for = man$run_id)
if (requireNamespace("digest", quietly = TRUE))
  new_fp$sha256 <- digest::digest(file = SOURCE, algo = "sha256")

cat("\nwould write:\n")
cat(sprintf("  %s\n  %s\n", PINNED, FINGER))
cat(sprintf("  rows %s, county_best %s, repinned_for %s\n",
            format(new_fp$rows, big.mark = ","),
            format(new_fp$county_best, big.mark = ","), new_fp$repinned_for))

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
    "  Rscript make_cohort_flow_figure.R\n", sep = "")
