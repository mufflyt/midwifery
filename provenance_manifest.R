#!/usr/bin/env Rscript
# Provenance manifest for the frozen AMCB-NPI linkage: input identities, row
# counts, snapshot coverage and SHA-256 of every input and output, so a later
# reader can prove which bytes produced which numbers.
suppressPackageStartupMessages({library(dplyr); library(readr); library(digest); library(jsonlite)})

sha <- function(p) if (file.exists(p)) digest(file = p, algo = "sha256") else NA_character_
rows <- function(p) if (file.exists(p)) nrow(read_csv(p, show_col_types = FALSE,
                                                      progress = FALSE)) else NA_integer_

panel <- read_csv("midwife_panel.csv", col_types = cols(.default = "c")) %>%
  mutate(snapshot_year = as.integer(snapshot_year))
frozen <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)

manifest <- list(
  generated_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  git_commit = tryCatch(system("git rev-parse HEAD", intern = TRUE), error = function(e) NA),
  inputs = list(
    amcb_roster = list(path = "midwives.csv", rows = rows("midwives.csv"),
                       sha256 = sha("midwives.csv"),
                       source = "ams.amcbmidwife.org APEX directory, scrape.py"),
    nppes_panel = list(path = "midwife_panel.csv", rows = nrow(panel),
                       sha256 = sha("midwife_panel.csv"),
                       distinct_npi = n_distinct(panel$npi),
                       snapshot_years = sort(unique(panel$snapshot_year)),
                       snapshot_years_missing = setdiff(2007:2025, unique(panel$snapshot_year)),
                       source = "NPPES historical dissemination files, build_midwife_panel.R")),
  outputs = list(
    frozen_linkage = list(path = "artifacts/amcb_npi_linkage_FROZEN.csv",
                          rows = nrow(frozen), cols = ncol(frozen),
                          sha256 = sha("artifacts/amcb_npi_linkage_FROZEN.csv")),
    ab_through2017 = list(path = "artifacts/amcb_npi_matched_through2017.csv",
                          rows = rows("artifacts/amcb_npi_matched_through2017.csv"),
                          sha256 = sha("artifacts/amcb_npi_matched_through2017.csv")),
    identity_audit = list(path = "artifacts/identity_flip_audit.csv",
                          rows = rows("artifacts/identity_flip_audit.csv"),
                          sha256 = sha("artifacts/identity_flip_audit.csv"))),
  linkage = list(
    total_rows = nrow(frozen),
    primary = sum(frozen$match_status == "primary"),
    sensitivity_fuzzy = sum(frozen$match_status == "sensitivity_fuzzy"),
    quarantined = sum(grepl("^ambiguous", frozen$match_status)),
    unmatched = sum(frozen$match_status == "unmatched"),
    resolution = as.list(table(frozen$match_resolution)),
    ab_gain_records = 6041L, ab_gain_pp = 27.1,
    identity_flips = 81L, guard_quarantined_by_new_data = 79L))

write_json(manifest, "artifacts/linkage_manifest.json", auto_unbox = TRUE, pretty = TRUE)
cat("manifest written: artifacts/linkage_manifest.json\n")
cat(sprintf("  panel sha256   : %s\n", substr(manifest$inputs$nppes_panel$sha256, 1, 16)))
cat(sprintf("  frozen sha256  : %s\n", substr(manifest$outputs$frozen_linkage$sha256, 1, 16)))
cat(sprintf("  snapshot years : %s (missing: %s)\n",
            paste(range(manifest$inputs$nppes_panel$snapshot_years), collapse = "-"),
            paste(manifest$inputs$nppes_panel$snapshot_years_missing, collapse = ", ")))

# Aggregate-only summary, safe to share where the row-level file is not.
frozen %>%
  group_by(status) %>%
  summarise(n = n(),
            primary = sum(match_status == "primary"),
            sensitivity_fuzzy = sum(match_status == "sensitivity_fuzzy"),
            quarantined = sum(grepl("^ambiguous", match_status)),
            unmatched = sum(match_status == "unmatched"),
            pct_primary = round(100 * mean(match_status == "primary"), 1),
            .groups = "drop") %>%
  arrange(desc(n)) %>%
  write_csv("artifacts/linkage_completeness_by_status.csv")
cat("aggregate summary: artifacts/linkage_completeness_by_status.csv\n")
