#!/usr/bin/env Rscript
# =============================================================================
# WHEN is each source from, is a closer vintage available, and how far apart are
# the pairs we actually compare?
# =============================================================================
# build_cross_source_comparison.R builds its current-snapshot pairwise matrix by
# taking every year-indexed source at `filter(year == max(year))` -- each at its
# OWN newest vintage, chosen independently. That is the freshest view of each
# source separately, and it is NOT the closest-dated pairing between them. The
# two objectives conflict directly: maximising freshness per source MAXIMISES
# the spread across sources, because each one's newest release lands on its own
# schedule.
#
# Nothing downstream could see that. artifacts/cross_source_pairwise_matrix.csv
# carries source_a, source_b, n_comparable, n_agree, pct_agree -- and no date.
# So a pairing eleven months apart was published in the same column, in the same
# units, as one a month apart.
#
# This script does not change any comparison. It MEASURES the situation: for
# each source, the vintage currently used, where that date comes from, whether a
# closer one is sitting on disk unused, and then the full pairwise gap matrix.
# Fixing a pairing is a decision per source; knowing the gap is a prerequisite,
# and it should not require reading six loaders to work out.
#
# PROVENANCE QUALITY IS A COLUMN, because it genuinely differs and the weak
# cases are the dangerous ones. A vintage read out of a filename, a record or a
# program year is a fact about the data. FILE MTIME IS NOT A VINTAGE AT ALL,
# and this script refuses to publish it as one. Two measurements settled that:
# dac_midwives.csv has an mtime of 2026-08-08 and was built from the 2026-06 DAC
# release, overstating freshness by two months; and artifacts/cms_ndh_midwives.csv
# checked out into a fresh worktree reported an mtime of TODAY, because git sets
# mtime at checkout. An mtime can be the moment a script ran, or the moment a
# clone happened, and neither is when the data was true.
#
# So sources with no recorded date are reported as vintage_quality =
# "unrecorded", with an EMPTY vintage, and are left out of the gap matrix
# entirely -- a gap against an unknown date is not a number, and inventing one
# is the failure this script exists to catch. Being unable to date four sources
# is itself the finding: their vintage has to be captured when they are
# scraped, because it cannot be recovered afterwards.
#
# Outputs: artifacts/source_vintage_inventory.csv  one row per source
#          artifacts/source_vintage_gap_matrix.csv one row per comparable pair
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
})
source(file.path("R", "lib", "source_vintage.R"))
suppressPackageStartupMessages(library(tibble))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()

MAX_GAP_MONTHS <- as.numeric(Sys.getenv("MAX_GAP_MONTHS", "6"))
vol <- function(rel) tryCatch(samsung_volume_path(rel, must_exist = FALSE),
                              error = function(e) NA_character_)

inv <- source_vintage_table()

cat("\n=== SOURCE VINTAGE INVENTORY ===\n")
print(as.data.frame(inv %>% select(source, time_kind, vintage_used, vintage_quality,
                                   n_vintages_available, closest_unused)), row.names = FALSE)
cat("\n")
for (i in seq_len(nrow(inv)))
  cat(sprintf("  %-26s %s\n", inv$source[i], inv$detail[i]))
# The INPUTS here are the dated files themselves, so the sidecar records the
# sha256 of every source whose vintage this inventory asserts. A source that
# is re-released without the inventory being rebuilt then shows as stale,
# which is the whole point: a vintage table that has gone out of date is
# worse than none, because everything downstream trusts its dates.
# source_files is recorded repo-relative (see R/lib/source_vintage.R). The
# sidecar needs paths this run can actually open, and it should RECORD the
# relative form -- an absolute /Users/<someone>/ path in a tracked sidecar is
# true on one machine. So: use the relative path wherever it resolves from here,
# fall back to data_root only when it does not, and leave absolute paths (the
# Samsung volume) alone. write_with_provenance() drops anything that still does
# not exist, so a missing input is omitted rather than recorded with no hash.
DATA_ROOT <- Sys.getenv("MIDWIFERY_DATA_ROOT", ".")
prov_files <- function(df) {
  f <- unique(unlist(strsplit(
    df$source_files[!is.na(df$source_files) & nzchar(df$source_files)], ";", fixed = TRUE)))
  ifelse(file.exists(f), f, file.path(DATA_ROOT, f))
}
write_with_provenance(inv, "artifacts/source_vintage_inventory.csv",
                      inputs = prov_files(inv), na = "")

# --- the pairwise gap matrix the comparison output is missing -----------------
dated <- inv %>% filter(!is.na(vintage_used))
undated <- inv %>% filter(is.na(vintage_used))
gm <- expand_grid(a = dated$source, b = dated$source) %>%
  filter(a < b) %>%
  left_join(dated %>% select(a = source, va = vintage_used), by = "a") %>%
  left_join(dated %>% select(b = source, vb = vintage_used), by = "b") %>%
  mutate(gap_months = round(abs(vintage_gap_months(va, vb)), 1),
         over_limit = gap_months > MAX_GAP_MONTHS) %>%
  select(source_a = a, vintage_a = va, source_b = b, vintage_b = vb,
         gap_months, over_limit) %>%
  arrange(desc(gap_months))
write_with_provenance(gm, "artifacts/source_vintage_gap_matrix.csv",
                      inputs = prov_files(dated), na = "")

cat(sprintf("\n=== PAIRWISE VINTAGE GAPS (%d pairs; limit %.1f months) ===\n",
            nrow(gm), MAX_GAP_MONTHS))
print(as.data.frame(head(gm, 15)), row.names = FALSE)
cat(sprintf("\n%d of %d pairs exceed %.1f months; widest is %s vs %s at %.1f months.\n",
            sum(gm$over_limit), nrow(gm), MAX_GAP_MONTHS,
            gm$source_a[1], gm$source_b[1], gm$gap_months[1]))
cat(sprintf("median pair gap: %.1f months\n", median(gm$gap_months, na.rm = TRUE)))
if (nrow(undated))
  cat(sprintf(paste0("\n%d source(s) CANNOT be dated at all and are excluded from the matrix: %s\n",
                     "  Their vintage is not in a filename, a record or a program year, and mtime\n",
                     "  is not a vintage. It has to be captured at scrape time.\n"),
              nrow(undated), paste(undated$source, collapse = ", ")))
