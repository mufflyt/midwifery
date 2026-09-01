#!/usr/bin/env Rscript
# =============================================================================
# Did these midwives bill Medicare? Part B and Part D, 2013-2023
# =============================================================================
# Matches the ACTIVE primary-linked cohort's NPIs against the CMS Medicare
# Physician & Other Practitioners file (Part B, renderer NPI) and the Medicare
# Part D Prescribers file (prescriber NPI), one row per provider per year.
#
# WHAT ABSENCE MEANS. CMS suppresses any provider-year with fewer than 11
# beneficiaries. A midwife absent from a file therefore billed NOTHING **or**
# billed fewer than 11 beneficiaries, and the two are indistinguishable here.
# Every count below is labelled accordingly; nothing in this script may be read
# as "billed zero". This is the same suppressed-is-not-zero error that produced
# wrong numbers three times in this repository (CDC WONDER cells, the
# apportioned CT regions, and the POS obstetric-service flag).
#
# ONE TABLE PER YEAR PER PROGRAMME. Part D 2022 and 2023 exist twice in the
# warehouse -- raw and `_standardized`, identical row counts -- so the
# `_standardized` series is used throughout and the raw duplicates are ignored.
# A first version of this analysis matched `^medicare_part_d_[0-9]{4}$`, which
# caught only those two raw tables: Part D scanned 2 years against Part B's 11
# and came out at 29.8% instead of 47.1%, which would have reversed the
# headline. The year sets are asserted equal below rather than assumed.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          /Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb
# Outputs: artifacts/medicare_participation.csv          (person-level, gitignored)
#          artifacts/medicare_participation_summary.csv  (aggregate, tracked)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
DB <- resolve_midwifery_duckdb()
if (!file.exists(DB)) {
  stop(sprintf(paste0("Medicare warehouse not found at %s. It lives on an ",
                      "external volume; mount it or set MEDICARE_DUCKDB. ",
                      "Refusing to emit participation counts from a partial ",
                      "source."), DB), call. = FALSE)
}

con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                 show_col_types = FALSE, progress = FALSE)
coh <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
N <- nrow(coh)
cat(sprintf("cohort with an NPI: %s\n", format(N, big.mark = ",")))

dbWriteTable(con, "cohort_npi",
             coh %>% select(certification_number, npi) %>% distinct(),
             temporary = TRUE, overwrite = TRUE)

tabs <- dbGetQuery(con, "SELECT table_name FROM information_schema.tables WHERE table_schema='main'")$table_name
pb <- sort(grep("^medicare_part_b_[0-9]{4}$", tabs, value = TRUE))
pd <- sort(grep("^medicare_part_d_[0-9]{4}_standardized$", tabs, value = TRUE))
yr_of <- function(x) as.integer(sub("^medicare_part_[bd]_([0-9]{4}).*$", "\\1", x))

# The comparison is only meaningful across the same window.
if (!identical(yr_of(pb), yr_of(pd))) {
  stop(sprintf(paste0("Part B covers %s and Part D covers %s. Participation ",
                      "rates across different windows are not comparable."),
               paste(yr_of(pb), collapse = ","), paste(yr_of(pd), collapse = ",")),
       call. = FALSE)
}
cat(sprintf("years matched on both sides: %d-%d (%d years)\n",
            min(yr_of(pb)), max(yr_of(pb)), length(pb)))

scan_year <- function(tbl, npicol) {
  y <- yr_of(tbl)
  dbGetQuery(con, sprintf(
    "SELECT c.certification_number, %d AS year
       FROM cohort_npi c
       INNER JOIN (SELECT DISTINCT CAST(%s AS VARCHAR) AS npi
                     FROM %s WHERE %s IS NOT NULL) t
         ON t.npi = c.npi", y, npicol, tbl, npicol))
}
b <- bind_rows(lapply(pb, scan_year, npicol = "Rndrng_NPI"))
d <- bind_rows(lapply(pd, scan_year, npicol = "npi_char"))

# Year counts by join, not by `lengths(split(...)) %||% 0`. The standard
# null-coalescing operator replaces NULL only -- not integer(0) or NA -- so that
# idiom silently yields the wrong length rather than a zero. It cost a
# 16 GB cross join earlier in this project's history; it is not used here.
b_yrs <- b %>% count(certification_number, name = "part_b_years")
d_yrs <- d %>% count(certification_number, name = "part_d_years")
part <- coh %>%
  select(certification_number, npi) %>%
  left_join(b_yrs, by = "certification_number", relationship = "one-to-one") %>%
  left_join(d_yrs, by = "certification_number", relationship = "one-to-one") %>%
  mutate(
    part_b_years = coalesce(part_b_years, 0L),
    part_d_years = coalesce(part_d_years, 0L),
    part_b_any   = part_b_years > 0L,
    part_d_any   = part_d_years > 0L,
    medicare_any = part_b_any | part_d_any,
    medicare_both = part_b_any & part_d_any)

write_csv(part, "artifacts/medicare_participation.csv", na = "")
cat("written: artifacts/medicare_participation.csv (person-level)\n")

summ <- tibble(
  built_at   = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  cohort_n   = N,
  years_from = min(yr_of(pb)), years_to = max(yr_of(pb)),
  part_b_any = sum(part$part_b_any), part_d_any = sum(part$part_d_any),
  either     = sum(part$medicare_any), both = sum(part$medicare_both),
  neither    = sum(!part$medicare_any),
  part_d_only = sum(part$part_d_any & !part$part_b_any),
  part_b_only = sum(part$part_b_any & !part$part_d_any))
write_csv(summ, "artifacts/medicare_participation_summary.csv")

f <- function(x, lab) cat(sprintf("  %-46s %6s (%4.1f%%)\n", lab,
                                  format(x, big.mark = ","), 100 * x / N))
f(summ$part_b_any,  "Part B, any year")
f(summ$part_d_any,  "Part D, any year")
f(summ$either,      "Either programme")
f(summ$both,        "Both programmes")
f(summ$neither,     "Neither (billed <11 benes, or nothing)")
f(summ$part_d_only, "Part D without Part B")
f(summ$part_b_only, "Part B without Part D")
