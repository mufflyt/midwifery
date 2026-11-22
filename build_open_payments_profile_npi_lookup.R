#!/usr/bin/env Rscript
# =============================================================================
# profile_id -> NPI, learned from the years CMS publishes both
# =============================================================================
# Open Payments program years 2013 and 2014 carry no NPI column. They do carry
# Physician_Profile_ID, the same identifier that later years carry as
# Covered_Recipient_Profile_ID alongside an NPI. So the link is recoverable:
# learn profile_id -> NPI where both are published, then apply it backwards.
#
# WHY 2021 ONWARDS. That is when the SUPPORT Act expansion made certified
# nurse-midwives covered recipients, so those are the years where this
# cohort's profiles actually appear with an NPI beside them. Learning the map
# from years where the cohort is largely absent would mostly teach it about
# physicians.
#
# THE RESULT IS EVIDENCE CLASS B, NOT A. An NPI observed on a profile in 2022
# and applied to that profile's 2013 payment row is a RETROSPECTIVE
# attribution: it assumes the profile's NPI is the same one it had nine years
# earlier. That is usually true and is not guaranteed, so every backfilled row
# is labelled retrospective and the two are never pooled without the label.
#
# A PROFILE WITH TWO NPIS IS NOT RESOLVED, IT IS DROPPED. If a profile_id
# appears with more than one NPI across the learning years, the mapping is not
# a function for that profile and picking one would invent an identity. Those
# are counted and excluded, and the count is an output.
#
# WHAT THIS CANNOT FIX. CNMs were not reportable before program year 2021.
# Recovering the 2013-2014 link does not make absence in those years
# meaningful -- it makes absence MEASURABLE, which is different and is the
# point. Until now "no 2013 rows" could mean either "we could not link" or
# "we linked and found nobody". After this it can only mean the second.
#
# Inputs : <volume>/open_payments_data/<2021..2023,2025>/unzipped_files/
#            OP_DTL_GNRL_*.csv, plus op_2024 in the merged DuckDB
# Outputs: artifacts/open_payments_profile_npi_lookup.csv
#          artifacts/open_payments_profile_npi_conflicts.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "open_payments_schema.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

OP_REL <- "open_payments_data"
MERGED <- file.path(OP_REL, "open_payments_merged_2013_2024.duckdb")
LEARN_YEARS <- c(2021L, 2022L, 2023L, 2024L, 2025L)

#' The profile-ID column name for a program year
#'
#' @param year [integer] program year.
#' @return [character] column name. CMS renamed it with the 2016 release.

#' The NPI column name for a program year, or NA when there is none
#'
#' @param year [integer] program year.
#' @return [character] column name, or NA for 2013-2014.

#' Distinct profile/NPI pairs observed in one program year
#'
#' @param con [DBIConnection] DuckDB.
#' @param src [character] quoted table name or read_csv() expression.
#' @param year [integer] program year, for the profile/NPI column names.
#' @return [data.frame] profile_id, npi, year. Rows missing either are
#'   dropped: a pair is only evidence when both halves are present.
op_profile_pairs <- function(con, src, year) {
  pc <- op_profile_column(year); nc <- op_npi_column(year)
  if (is.na(nc)) return(NULL)
  r <- DBI::dbGetQuery(con, sprintf("
    SELECT DISTINCT trim(CAST(t.%s AS VARCHAR)) AS profile_id,
                    trim(CAST(t.%s AS VARCHAR)) AS npi
      FROM %s t
     WHERE t.%s IS NOT NULL AND length(trim(CAST(t.%s AS VARCHAR))) > 0
       AND t.%s IS NOT NULL AND length(trim(CAST(t.%s AS VARCHAR))) > 0",
    DBI::dbQuoteIdentifier(con, pc), DBI::dbQuoteIdentifier(con, nc), src,
    DBI::dbQuoteIdentifier(con, pc), DBI::dbQuoteIdentifier(con, pc),
    DBI::dbQuoteIdentifier(con, nc), DBI::dbQuoteIdentifier(con, nc)))
  if (nrow(r)) r$year <- as.integer(year)
  r
}

if (sys.nframe() == 0L) {
  # duckdb_connect() rather than a raw DBI::dbConnect(): it applies the
  # encoding bootstrap every ingestion needs, and the architecture gate
  # requires every connection to route through it.
  con <- duckdb_connect()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("SET temp_directory=%s",
                              DBI::dbQuoteString(con, tempdir())))
  merged <- samsung_volume_path(MERGED, must_exist = FALSE)
  if (!is.na(merged))
    DBI::dbExecute(con, sprintf("ATTACH %s AS m (READ_ONLY)",
                                DBI::dbQuoteString(con, merged)))

  pairs <- list()
  for (y in LEARN_YEARS) {
    src <- if (identical(y, 2024L)) {
      if (is.na(merged)) NA_character_ else "m.op_2024"
    } else {
      d <- samsung_volume_path(file.path(OP_REL, as.character(y),
                                         "unzipped_files"), must_exist = FALSE)
      f <- if (is.na(d)) character(0) else
        list.files(d, pattern = "^OP_DTL_GNRL_.*\\.csv$", full.names = TRUE)
      if (!length(f)) NA_character_ else
        sprintf("read_csv(%s, all_varchar = true, ignore_errors = true)",
                DBI::dbQuoteString(con, f[1]))
    }
    if (is.na(src)) { base::message(sprintf("  %d absent", y)); next }
    r <- tryCatch(op_profile_pairs(con, src, y), error = function(e) {
      base::message(sprintf("  %d failed: %s", y, conditionMessage(e))); NULL })
    if (is.null(r) || !nrow(r)) next
    pairs[[length(pairs) + 1L]] <- r
    base::message(sprintf("  %d  %s distinct profile/NPI pairs", y,
                          format(nrow(r), big.mark = ",")))
  }
  stopifnot(length(pairs) > 0)
  all_pairs <- bind_rows(pairs) %>% distinct(profile_id, npi)

  # A profile mapping to several NPIs is not a function. Count and exclude.
  multi <- all_pairs %>% count(profile_id, name = "n_npis") %>%
    filter(n_npis > 1L)
  lookup <- all_pairs %>% anti_join(multi, by = "profile_id") %>%
    mutate(learned_from = paste(range(LEARN_YEARS), collapse = "-"),
           evidence_type = "observed")
  conflicts <- all_pairs %>% semi_join(multi, by = "profile_id") %>%
    arrange(profile_id, npi)

  write_with_provenance(lookup,
    "artifacts/open_payments_profile_npi_lookup.csv", na = "")
  write_with_provenance(conflicts,
    "artifacts/open_payments_profile_npi_conflicts.csv", na = "")

  base::message(sprintf(
    "\nlookup: %s profiles -> NPI\nconflicts: %s profiles with >1 NPI (%.3f%%), excluded",
    format(nrow(lookup), big.mark = ","),
    format(nrow(multi), big.mark = ","),
    100 * nrow(multi) / dplyr::n_distinct(all_pairs$profile_id)))
}
