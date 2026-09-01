#!/usr/bin/env Rscript
#' @title Content hash for every archived CMS revalidation snapshot
#'
#' @description
#' CMS republishes byte-identical content under a later month. 2024-03 and
#' 2024-08 have the same md5, the same size and the same row count, but were
#' downloaded from two different URLs under two different month directories.
#'
#' Left in, that manufactures continuity: between those two publication labels
#' CMS released nothing, so a relationship that ended in April 2024 still reads
#' as "on file" in the 2024-08 vintage. Five months of affiliation nobody
#' observed. A publication label is not an observation date.
#'
#' This writes the hash of every archived raw snapshot to a TRACKED manifest so
#' the duplication is a recorded fact rather than a comment in one script, and
#' so CI can assert it (tests/test_vintage_distinctness.R).
#'
#' The manifest carries hashes and counts only -- no person-level content -- so
#' it is safe to track in a public repo.
#'
#' @section Which of a duplicate pair is kept:
#' The EARLIER label. That is when the content was actually current; the later
#' label is a republication of it.
#'
#' Inputs : REVAL_RAW_DIR/revalidation_reassignment_YYYY-MM.csv
#' Outputs: artifacts/revalidation_vintage_manifest.csv (tracked)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(digest); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))

source(file.path("R", "lib", "medicare_duckdb.R"))
RAW_DIR <- Sys.getenv("REVAL_RAW_DIR", "")
if (!nzchar(RAW_DIR)) RAW_DIR <- samsung_volume_path("cms_revalidation_raw")
OUT <- "artifacts/revalidation_vintage_manifest.csv"

files <- Sys.glob(file.path(RAW_DIR, "revalidation_reassignment_*.csv"))
if (!length(files)) {
  stop(sprintf(paste("no raw snapshots in %s\n",
                     "  Run archive_revalidation_reassignment.R first, or set",
                     "REVAL_RAW_DIR.\n  Refusing to write an empty manifest,",
                     "which would read as 'no duplicate vintages exist'."),
               RAW_DIR), call. = FALSE)
}

cli::cli_h2("Hashing {length(files)} raw snapshots")
man <- purrr::map_dfr(files, function(p) {
  v <- sub(".*revalidation_reassignment_([0-9]{4}-[0-9]{2})\\.csv$", "\\1", basename(p))
  cli::cli_alert_info("{v} ...")
  # digest(file=TRUE) streams the file; no row count is taken here because
  # parsing 537 MB to learn something the warehouse already stores would double
  # the cost of the only expensive step for nothing.
  tibble::tibble(
    vintage      = v,
    bytes        = file.info(p)$size,
    sha256       = digest::digest(p, algo = "sha256", file = TRUE))
}) %>% arrange(vintage)

# --- duplicate detection, by CONTENT ------------------------------------------
man <- man %>%
  group_by(sha256) %>%
  arrange(vintage, .by_group = TRUE) %>%
  mutate(
    n_labels_with_this_content = dplyr::n(),
    is_republication = dplyr::row_number() > 1L,
    republication_of = if_else(is_republication, dplyr::first(vintage), NA_character_)) %>%
  ungroup() %>%
  # A republished label must not advance a spell. The panel builder drops it;
  # this column is the tracked statement of which labels that applies to.
  mutate(use_for_panel = !is_republication) %>%
  arrange(vintage)

dup <- man %>% filter(is_republication)
cli::cli_h2("Distinctness")
if (nrow(dup)) {
  cli::cli_alert_warning("{nrow(dup)} republished label(s) -- identical content under a later month:")
  for (i in seq_len(nrow(dup))) {
    cli::cli_alert_warning("  {dup$vintage[i]} == {dup$republication_of[i]} (sha256 {substr(dup$sha256[i],1,12)})")
  }
  cli::cli_alert_info("{sum(man$use_for_panel)} distinct content vintages of {nrow(man)} labels")
} else {
  cli::cli_alert_success("all {nrow(man)} labels carry distinct content")
}

write_with_provenance(man, OUT, na = "", inputs = prov_inputs(files))
cli::cli_alert_success("wrote {OUT}")
