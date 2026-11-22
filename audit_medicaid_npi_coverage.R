#!/usr/bin/env Rscript
# =============================================================================
# Audit: the committed NPI-coverage rate against the released Medicaid file
# =============================================================================
# WHY THIS EXISTS SEPARATELY FROM THE GATE.
# tests/test_npi_rate_and_cluster_saboteurs.R (N1) checks that
# artifacts/medicaid_npi_population_by_state.csv is internally consistent --
# that its printed rate is reproduced by its own numerator and denominator --
# and that the producer's SQL does not divide COUNT(DISTINCT NPI) by COUNT(*).
# Both are necessary and neither is sufficient: an artifact can be perfectly
# self-consistent and still describe a file that has since been re-released,
# and the gate cannot tell, because it never reads the parquet. It cannot be
# made to -- the segments file lives on an external volume, so no CI runner
# will ever see it.
#
# This script closes that gap locally. It recomputes both formulas straight
# from the source and prints them beside the committed values, so the
# divergence that produced the defect is visible rather than argued about:
#
#   pct_correct   = COUNT(NPI)          / COUNT(*)   -- segments carrying an NPI
#   pct_as_coded  = COUNT(DISTINCT NPI) / COUNT(*)   -- the 2026-11-21 defect
#
# The second column is kept deliberately. It is the shape the artifact shipped
# with, and a state where the two agree (any state filing roughly one segment
# per provider, such as New York) is a state where the defect is invisible --
# which is exactly why reading the extrema did not catch it.
#
# Inputs : <volume>/doge_opendata/medicaid_provider_enrollment_segments_
#          2026_07_24/medicaid-provider-enrollment-segments.parquet
#          artifacts/medicaid_npi_population_by_state.csv
# Outputs: none -- prints a comparison and exits non-zero on disagreement.
# =============================================================================
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})
source(file.path("R", "lib", "medicare_duckdb.R"))

SEGMENTS_REL <- file.path("doge_opendata",
                          "medicaid_provider_enrollment_segments_2026_07_24",
                          "medicaid-provider-enrollment-segments.parquet")
COMMITTED <- "artifacts/medicaid_npi_population_by_state.csv"
TOL <- 0.011  # the artifact rounds to 2 dp

parquet <- tryCatch(samsung_volume_path(SEGMENTS_REL, must_exist = TRUE),
                    error = function(e) NULL)
if (is.null(parquet)) {
  cat("SKIP: the external volume holding the segments parquet is not mounted.\n")
  quit(status = 0)
}
stopifnot(file.exists(COMMITTED))

# The chokepoint, not a raw DBI::dbConnect(): duckdb_connect() defaults to an
# in-memory database, and routing through it is what gives this connection the
# encoding bootstrap and the temp-directory setting that a 66M-row parquet scan
# needs on an 8 GB machine. tests/duckdb_architecture_scan.R refuses a raw one.
con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# -----------------------------------------------------------------------------
# PRECONDITION: SQL NULL is the only way an NPI is absent
# -----------------------------------------------------------------------------
# COUNT(NPI) is the share of segments carrying a provider identifier only if
# absence is always NULL. NPI is a VARCHAR column, so a state spelling absence
# as "" or "0000000000" would be counted as PRESENT, and the rate would read
# high for exactly the worst-reporting states -- the same direction of error,
# state by state, as the COUNT(DISTINCT NPI) numerator this replaced. The
# precondition is therefore part of the published rate, not a detail, and it is
# checked here rather than asserted in a comment.
shape <- dbGetQuery(con, sprintf(
  "SELECT COUNT(*) AS n_segments,
          COUNT(NPI) AS n_non_null,
          SUM(CASE WHEN NPI IS NOT NULL AND trim(CAST(NPI AS VARCHAR)) = ''
                   THEN 1 ELSE 0 END) AS n_blank,
          SUM(CASE WHEN NPI IS NOT NULL
                    AND length(trim(CAST(NPI AS VARCHAR))) <> 10
                   THEN 1 ELSE 0 END) AS n_wrong_length,
          SUM(CASE WHEN CAST(NPI AS VARCHAR)
                       IN ('0', '0000000000', '9999999999')
                   THEN 1 ELSE 0 END) AS n_sentinel
   FROM read_parquet('%s')", parquet))

cat(sprintf(paste0("NPI column shape: %s segments, %s non-NULL (%.2f%%), ",
                   "%s blank, %s not ten characters, %s sentinel\n"),
            format(shape$n_segments, big.mark = ","),
            format(shape$n_non_null, big.mark = ","),
            100 * shape$n_non_null / shape$n_segments,
            format(shape$n_blank, big.mark = ","),
            format(shape$n_wrong_length, big.mark = ","),
            format(shape$n_sentinel, big.mark = ",")))

bad <- shape$n_blank + shape$n_wrong_length
if (bad > 0L) {
  cat(sprintf(paste("\nFAIL: %s segment(s) carry a non-NULL NPI that is blank",
                    "or not ten characters.\n  COUNT(NPI) counts them as",
                    "present, so pct_segments_with_npi overstates\n  ",
                    "completeness. Use COUNT(NULLIF(trim(NPI), '')) with a",
                    "length filter in\n  ",
                    "build_medicaid_npi_population_by_state.R before trusting",
                    "the rate.\n"),
              format(bad, big.mark = ",")))
  quit(status = 1)
}
# 104 all-zero/all-nine values on the 2026-07-24 release, 0.0002% of non-NULL,
# are left in the numerator: they cannot move a state's rate at the two
# decimals the artifact reports, and dropping them would need its own gate.

live <- dbGetQuery(con, sprintf(
  "SELECT STATE_CD AS state,
          COUNT(*) AS n_segments,
          COUNT(NPI) AS n_segments_with_npi,
          COUNT(DISTINCT NPI) AS n_distinct_npi,
          ROUND(100.0 * COUNT(NPI) / COUNT(*), 2) AS pct_correct,
          ROUND(100.0 * COUNT(DISTINCT NPI) / COUNT(*), 2) AS pct_as_coded
   FROM read_parquet('%s')
   GROUP BY STATE_CD
   ORDER BY pct_correct, state", parquet))

have <- read.csv(COMMITTED, stringsAsFactors = FALSE)
m <- merge(live, have[, c("state", "pct_segments_with_npi")],
           by = "state", all = TRUE)

m$delta <- round(m$pct_segments_with_npi - m$pct_correct, 2)
m$hidden_by_defect <- abs(m$pct_correct - m$pct_as_coded) < TOL

cat(sprintf("Segments file : %s\n", parquet))
cat(sprintf("Committed     : %s (%d states)\n\n", COMMITTED, nrow(have)))
print(m[order(m$pct_correct), c("state", "n_segments", "n_segments_with_npi",
                                "n_distinct_npi", "pct_correct", "pct_as_coded",
                                "pct_segments_with_npi", "delta")],
      row.names = FALSE)

off <- m[is.na(m$delta) | abs(m$delta) > TOL, ]
cat(sprintf("\nStates where the two formulas agree, so the defect is invisible: %d of %d\n",
            sum(m$hidden_by_defect, na.rm = TRUE), nrow(m)))
if (nrow(off)) {
  cat(sprintf("\nFAIL: %d state(s) disagree with the live file:\n", nrow(off)))
  print(off[, c("state", "pct_correct", "pct_segments_with_npi", "delta")],
        row.names = FALSE)
  cat("Rebuild with build_medicaid_npi_population_by_state.R.\n")
  quit(status = 1)
}
cat("OK: every committed rate matches COUNT(NPI) / COUNT(*) on the live file.\n")
