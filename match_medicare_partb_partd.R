#!/usr/bin/env Rscript
# =============================================================================
# Did these midwives bill Medicare? Part B and Part D, 2013-2023
# =============================================================================
# Matches the ACTIVE primary-linked cohort's NPIs against the CMS Medicare
# Physician & Other Practitioners file (Part B, renderer NPI) and the Medicare
# Part D Prescribers file (prescriber NPI), one row per provider per year.
#
# WHAT ABSENCE MEANS, AND IT IS NOT TWO THINGS. CMS suppresses any provider-year
# with fewer than 11 beneficiaries, so a midwife absent from a file billed
# NOTHING **or** billed fewer than 11 beneficiaries. Nothing here may be read as
# "billed zero" -- the same suppressed-is-not-zero error that produced wrong
# numbers three times in this repository (CDC WONDER cells, the apportioned CT
# regions, and the POS obstetric-service flag).
#
# Part B has a THIRD explanation, and it is the one that explains these
# results. The Physician & Other Practitioners file is keyed on the RENDERING
# NPI. A midwife whose encounter is billed under a supervising physician's or a
# group's number does not appear in it at all -- while her prescriptions carry
# her own NPI into Part D whoever billed the visit. Measured: Part B 19.5%,
# Part D 47.1%, with 3,364 prescribing and never rendering against 69 the
# reverse, and 97.0% of Part B billers also prescribing. Part B is nearly a
# subset of Part D. Both files suppress on comparable rules, so suppression
# alone does not produce a 2.4x gap in one direction for the same people.
#
# So the negative label is "no record under her own NPI", never "did not bill",
# and the asymmetry is printed as a finding rather than left in two independent
# rows for a reader to notice. Issue #246.
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
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
DB <- resolve_midwifery_duckdb()
if (!file.exists(DB)) {
  stop(sprintf(paste0("Medicare warehouse not found at %s. It lives on an ",
                      "external volume; mount it or set MEDICARE_DUCKDB. ",
                      "Refusing to emit participation counts from a partial ",
                      "source."), DB), call. = FALSE)
}

con <- duckdb_connect(DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

LINKAGE <- "artifacts/amcb_npi_linkage_FROZEN.csv"
link <- read_csv(LINKAGE, show_col_types = FALSE, progress = FALSE)
coh <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
N <- nrow(coh)
cat(sprintf("cohort with an NPI: %s\n", format(N, big.mark = ",")))

# Every percentage this script publishes -- and Table 1's two Medicare rows --
# is taken against N. The committed summary records cohort_n = 11,920 against a
# canonical 12,171 and carries no sidecar, so nothing said which freeze it read
# (#246). One comparison, and the next run either lands on the canonical count
# or stops and says by how much it missed.
N_CANON <- nrow(canonical_active_primary(
  read_csv(LINKAGE, show_col_types = FALSE, progress = FALSE,
           col_types = cols(.default = "c"))))
if (!identical(as.integer(N), as.integer(N_CANON))) {
  stop(sprintf(paste0(
    "cohort_n = %s, but canonical_active_primary() on the same linkage file gives %s.\n",
    "  These must agree: this script's filters ARE the canonical cohort rule.\n",
    "  linkage: %s"), format(N, big.mark = ","), format(N_CANON, big.mark = ","), LINKAGE),
    call. = FALSE)
}

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
# Through write_with_provenance(), like its neighbours: every count here rests
# on cohort_n, and without a sidecar a wrong denominator cannot be told from a
# different membership rule or an interrupted run (#246).
write_with_provenance(summ, "artifacts/medicare_participation_summary.csv",
                      inputs = LINKAGE)

f <- function(x, lab) cat(sprintf("  %-46s %6s (%4.1f%%)\n", lab,
                                  format(x, big.mark = ","), 100 * x / N))
f(summ$part_b_any,  "Part B, any year")
f(summ$part_d_any,  "Part D, any year")
f(summ$either,      "Either programme")
f(summ$both,        "Both programmes")
f(summ$neither,     "Neither (billed <11 benes, or nothing)")
f(summ$part_d_only, "Part D without Part B")
f(summ$part_b_only, "Part B without Part D")

# THE ASYMMETRY, REPORTED AS A FINDING RATHER THAN LEFT IN TWO ROWS. Part B is
# keyed on the RENDERING NPI; Part D on the prescriber's. A midwife whose
# encounter is billed under a supervising physician's or a group's number is
# invisible to the first and visible to the second, which is the shape this
# ratio has. Both files suppress on comparable rules, so suppression alone
# cannot produce it. See the header and issue #246.
if (summ$part_b_only > 0L) {
  cat(sprintf(paste0(
    "\n  ASYMMETRY: %s prescribe under Part D with no Part B record, against %s the\n",
    "  reverse -- %.0f to 1. Part B is %.1f%% of the cohort and Part D %.1f%%, and\n",
    "  %.1f%% of Part B billers also prescribe. Part B is nearly a SUBSET of Part D.\n",
    "  Part B is keyed on the rendering NPI, so an encounter billed under another\n",
    "  clinician's or a group's number leaves no Part B trace while the prescription\n",
    "  still carries hers. Absence from Part B is therefore three things, not two.\n"),
    format(summ$part_d_only, big.mark = ","), format(summ$part_b_only, big.mark = ","),
    summ$part_d_only / summ$part_b_only,
    100 * summ$part_b_any / N, 100 * summ$part_d_any / N,
    100 * summ$both / summ$part_b_any))
}
