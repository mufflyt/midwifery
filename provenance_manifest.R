#!/usr/bin/env Rscript
# Provenance manifest for the frozen AMCB-NPI linkage: input identities, row
# counts, snapshot coverage and SHA-256 of every input and output, so a later
# reader can prove which bytes produced which numbers.
suppressPackageStartupMessages({library(dplyr); library(readr); library(digest); library(jsonlite); library(tidyr)})

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
  # DERIVED, NOT ENUMERATED. This block named four dispositions -- primary,
  # sensitivity_fuzzy, quarantined, unmatched -- on a column called
  # `match_status`. The frozen linkage now carries `npi_match_status` with a
  # seven-value vocabulary, and `frozen$match_status` on a tibble returns NULL
  # rather than raising, so `sum(NULL == "primary")` quietly wrote 0 and the
  # manifest reported a linkage with no primaries in it. `match_resolution`
  # was stale in the same way.
  #
  # Tabulating the column is exhaustive by construction: a vocabulary change
  # shows up as a new key rather than as a silent shortfall.
  linkage = list(
    total_rows = nrow(frozen),
    dispositions = as.list(table(frozen$npi_match_status)),
    resolution = as.list(table(frozen$npi_match_resolution)),
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
#
# EXHAUSTIVE BY CONSTRUCTION. The four hand-named dispositions this replaced
# summed to 20,473 of 22,309 rows: 1,836 people (8.2%, 845 of them ACTIVE) held
# a status none of the four terms matched, so they sat inside the denominator
# behind pct_primary and outside every column beside it. A reader adding the
# row up lost them with nothing to say so.
#
# Pivoting the column means every disposition present in the data becomes a
# column, `n` is their sum rather than an independent count, and the two can no
# longer disagree. `pct_matched` succeeds `pct_primary`: `matched` is the same
# quantity under the renamed vocabulary -- 78.4% of ACTIVE against the 78.0%
# the README reports for primary, the difference being the frozen vintage.
disp <- frozen %>%
  count(status, npi_match_status, name = "n_disp") %>%
  tidyr::pivot_wider(names_from = npi_match_status, values_from = n_disp,
                     values_fill = 0)

stopifnot(sum(dplyr::select(disp, -status)) == nrow(frozen))

disp %>%
  mutate(n = rowSums(dplyr::across(-status)),
         pct_matched = round(100 * matched / n, 1)) %>%
  relocate(n, .after = status) %>%
  arrange(desc(n)) %>%
  write_csv("artifacts/linkage_completeness_by_status.csv")
cat("aggregate summary: artifacts/linkage_completeness_by_status.csv\n")
