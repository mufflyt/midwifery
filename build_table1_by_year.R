#!/usr/bin/env Rscript
# =============================================================================
# Table 1, by year -- how often the FIXED cohort shows up in each year-level
# source, 2007-2026 where available
# =============================================================================
# Run as: Rscript build_table1_by_year.R
#
# WHAT THIS IS, AND WHAT IT IS NOT. Table 1 proper (build_table1_midwives.R)
# is cross-sectional: one row per midwife, characteristics as of today. Most
# of its variables have no year dimension at all -- sex, age, ACOG district,
# rurality, Healthgrades, CMS NDH and HPSA status are all single, current
# snapshots, because that is all their sources ever offer. This script does
# NOT attempt to reconstruct "who was ACTIVE as of year Y" -- the AMCB status
# field this project holds is a current snapshot, not a historical register,
# so there is no sound way to ask that question with the data in hand.
#
# What it DOES do: take the SAME fixed cohort Table 1 uses (today's ACTIVE,
# primary-tier-linked midwives) and ask, for the three sources that carry
# real per-year history, how often that same fixed population appears in
# each year. This is a trend in OBSERVABILITY within a stable population, not
# a reconstruction of the workforce's past composition.
#
# EIGHT SOURCES, EIGHT DIFFERENT WINDOWS, NONE OF THEM REDUCED TO ONE. (First
# built with three; the state-source audit's own per-year extracts for Open
# Payments, PECOS and Medicaid were already sitting in artifacts/ and simply
# not checked for on the first pass; PPEF (Public Provider Enrollment Files,
# CMS's Medicare enrollment roster, distinct from the revalidation extract
# already in use) was found on the external drive and extracted the same
# day -- both additions 2026-11-05.)
#   - NPPES annual panel presence, 2007-2026 (every year the backbone source
#     has run) -- is this midwife's NPI present in that year's NPPES
#     snapshot. A presence measure, not a clinical-activity measure, same
#     caveat Table 1's own "Years Observed in NPPES Panel" block carries.
#   - Medicare Part B / Part D, 2013-2023 (years matched on both programmes,
#     same raw per-year CMS tables match_medicare_partb_partd.R reads, re-
#     queried here per year rather than collapsed to an any-year flag).
#     Absence is not zero -- CMS suppresses under 11 beneficiaries, and Part B
#     is keyed on the RENDERING NPI, so a midwife billed under a supervising
#     physician's number never appears in it regardless of year. See that
#     script's own header for the full asymmetry.
#   - CCN hospital affiliation, 2013-2022, from the historical DAC vintages'
#     embedded CCN columns (extract_historical_facility_affiliation.R). CMS
#     dropped this field from the file itself starting 2023, so the window
#     ends there structurally, not from a gap in this project's extraction.
#   - Open Payments general payments, 2015-2025 (extract_open_payments_2025.R
#     and its siblings, one file per program year). 2015-2020 is real but
#     trace-only -- CNMs were not Open-Payments-reportable until the SUPPORT
#     Act expansion hit program year 2021 -- shown as measured, not
#     suppressed, so the trace years read as what they are.
#   - PECOS revalidation/reassignment, 2021-2026 (40 monthly CMS releases,
#     one row per NPI per year-end vintage, extract_pecos_revalidation_
#     state_history.R). Enrollment-derived, independent of NPPES self-report.
#   - Medicaid enrollment, 2018-2024 (build_state_source_audit.R's Medicaid
#     section, already a per-year classification aggregate against this
#     exact fixed cohort -- verified below rather than assumed). "Not
#     observed" is its own classification; any other one means an enrollment
#     record exists that year, concordant with NPPES or not.
#   - Medicare enrollment, CUMULATIVE, from PPEF (extract_ppef_enrollment_
#     history.R). The one line on a different footing from every other
#     source here: PPEF is a single current snapshot with no year series of
#     its own, but each enrollment ID embeds the provider's original
#     enrollment date, a one-time historical fact going back to 2003 --
#     earlier than any other source in this file. Plotted as a running
#     cumulative share, not a repeated-presence measure, and labelled as such.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          artifacts/midwife_panel_midwifeonly.csv
#          artifacts/historical_facility_affiliation_cohort_state_by_year.csv
#          artifacts/cohort_midwives_open_payments_general_2015..2025.csv
#          artifacts/pecos_revalidation_cohort_state_by_year.csv
#          artifacts/state_source_audit_medicaid_classification_by_year.csv
#          artifacts/ppef_cohort_enrollment_year.csv
#          /Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb (Medicare Part B/D)
# Outputs: artifacts/table1_by_year.csv
#          docs/table1_by_year.md
# =============================================================================
REF_YEAR <- 2026   # matches build_table1_midwives.R's own reference year

suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))

LINKAGE <- "artifacts/amcb_npi_linkage_FROZEN.csv"
link <- read_csv(LINKAGE, show_col_types = FALSE, progress = FALSE)
coh <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  assert_unique_keys("certification_number",
                     label = "Table 1 by year cohort (ACTIVE primary_midwifery)", dedupe = TRUE) %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
N <- nrow(coh)
cat(sprintf("fixed cohort: %s ACTIVE primary-linked midwives with an NPI\n", format(N, big.mark = ",")))

rows <- list()

# --- 1. NPPES annual panel presence, 2007-2026 -------------------------------
pnl <- "artifacts/midwife_panel_midwifeonly.csv"
if (file.exists(pnl)) {
  panel <- read_csv(pnl, show_col_types = FALSE, progress = FALSE,
                    col_types = cols(.default = "c")) %>%
    filter(!is.na(snapshot_year), npi %in% coh$npi) %>%
    mutate(snapshot_year = as.integer(snapshot_year))
  by_year <- panel %>% distinct(npi, snapshot_year) %>% count(snapshot_year, name = "n")
  rows[["nppes_panel"]] <- by_year %>%
    transmute(source = "NPPES annual panel", year = snapshot_year, n,
              pct = round(100 * n / N, 1))
  cat(sprintf("NPPES panel: %d years, %d-%d\n", nrow(by_year),
              min(by_year$snapshot_year), max(by_year$snapshot_year)))
} else {
  cat("NPPES panel: absent, skipped\n")
}

# --- 2. Medicare Part B / Part D, 2013-2023 ----------------------------------
# Same raw per-year CMS tables and the same scan_year() join pattern
# match_medicare_partb_partd.R uses -- re-queried here per year instead of
# collapsed to an any-year flag, restricted to this script's own fixed cohort.
DB <- resolve_midwifery_duckdb()
if (file.exists(DB)) {
  con <- duckdb_connect(DB, read_only = TRUE)
  on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
  dbWriteTable(con, "cohort_npi_by_year",
               coh %>% select(certification_number, npi) %>% distinct(),
               temporary = TRUE, overwrite = TRUE)
  tabs <- dbGetQuery(con, "SELECT table_name FROM information_schema.tables WHERE table_schema='main'")$table_name
  pb <- sort(grep("^medicare_part_b_[0-9]{4}$", tabs, value = TRUE))
  pd <- sort(grep("^medicare_part_d_[0-9]{4}_standardized$", tabs, value = TRUE))
  yr_of <- function(x) as.integer(sub("^medicare_part_[bd]_([0-9]{4}).*$", "\\1", x))
  scan_year <- function(tbl, npicol) {
    y <- yr_of(tbl)
    dbGetQuery(con, sprintf(
      "SELECT c.certification_number, %d AS year
         FROM cohort_npi_by_year c
         INNER JOIN (SELECT DISTINCT CAST(%s AS VARCHAR) AS npi
                       FROM %s WHERE %s IS NOT NULL) t
           ON t.npi = c.npi", y, npicol, tbl, npicol))
  }
  if (length(pb) && length(pd)) {
    b <- bind_rows(lapply(pb, scan_year, npicol = "Rndrng_NPI"))
    d <- bind_rows(lapply(pd, scan_year, npicol = "npi_char"))
    b_by_year <- b %>% distinct(certification_number, year) %>% count(year, name = "n")
    d_by_year <- d %>% distinct(certification_number, year) %>% count(year, name = "n")
    rows[["part_b"]] <- b_by_year %>%
      transmute(source = "Medicare Part B (rendering NPI)", year, n, pct = round(100 * n / N, 1))
    rows[["part_d"]] <- d_by_year %>%
      transmute(source = "Medicare Part D (prescriber NPI)", year, n, pct = round(100 * n / N, 1))
    cat(sprintf("Medicare: Part B %d years, Part D %d years\n", nrow(b_by_year), nrow(d_by_year)))
  } else {
    cat("Medicare: no per-year tables found in the warehouse, skipped\n")
  }
} else {
  cat(sprintf("Medicare warehouse absent (%s), skipped\n", DB))
}

# --- 3. CCN hospital affiliation, 2013-2022 ----------------------------------
fa <- "artifacts/historical_facility_affiliation_cohort_state_by_year.csv"
if (file.exists(fa)) {
  aff <- read_csv(fa, show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = "c")) %>%
    mutate(year = as.integer(year)) %>%
    filter(npi %in% coh$npi)
  by_year <- aff %>% distinct(npi, year) %>% count(year, name = "n")
  rows[["hospital_ccn"]] <- by_year %>%
    transmute(source = "Hospital affiliation (CCN, historical DAC)", year, n,
              pct = round(100 * n / N, 1))
  cat(sprintf("Hospital affiliation (CCN): %d years, %d-%d\n", nrow(by_year),
              min(by_year$year), max(by_year$year)))
} else {
  cat("Hospital affiliation (CCN) by year: absent, skipped\n")
}

# --- 4. Open Payments general payments, 2015-2025 ----------------------------
# One file per program year (extract_open_payments_2025.R and its siblings),
# payment-level rows -- several per provider per year is normal and expected,
# so presence is distinct(npi, year), not a row count. Filtered to
# payment_amount > 0 explicitly -- every row in the current extracts already
# is (verified 2026-11-05: zero $0/NA rows in any year), but the filter is
# written anyway rather than relied on as an implicit property of the input,
# so a future re-extraction that picks up a $0 placeholder or corrected-to-
# zero row doesn't silently count as "received a payment."
#
# 2015-2020 is trace-only (1-29 cohort NPIs/year). CNMs were not
# Open-Payments-reportable until the SUPPORT Act (Pub. L. 115-271 Sec. 6111)
# expanded covered-recipient types effective program year 2021 -- confirmed
# against CMS's own program-year documentation, not merely inferred from the
# count jump. That makes the 2015-2020 rows, small and real as the dollar
# amounts are, PROBABLY NPI-matching noise rather than genuine midwife
# Open Payments events: the reporting requirement did not exist yet for this
# provider type, so a real match in that window is the less likely
# explanation. Kept and labelled rather than dropped (no silent
# truncation), but read as a data-quality flag, not a finding.
op_years <- 2015:2025
op_rows <- list()
for (y in op_years) {
  f <- sprintf("artifacts/cohort_midwives_open_payments_general_%d.csv", y)
  if (!file.exists(f)) next
  op <- read_csv(f, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = "c")) %>%
    mutate(payment_amount = suppressWarnings(as.numeric(payment_amount))) %>%
    filter(npi %in% coh$npi, !is.na(payment_amount), payment_amount > 0)
  op_rows[[as.character(y)]] <- tibble(year = y, n = n_distinct(op$npi))
}
if (length(op_rows)) {
  by_year <- bind_rows(op_rows)
  rows[["open_payments"]] <- by_year %>%
    transmute(source = "Open Payments general payments", year, n,
              pct = round(100 * n / N, 1))
  cat(sprintf("Open Payments: %d years, %d-%d\n", nrow(by_year),
              min(by_year$year), max(by_year$year)))
} else {
  cat("Open Payments by-year files: absent, skipped\n")
}

# --- 5. PECOS revalidation/reassignment, 2021-2026 ---------------------------
pecos_f <- "artifacts/pecos_revalidation_cohort_state_by_year.csv"
if (file.exists(pecos_f)) {
  pecos <- read_csv(pecos_f, show_col_types = FALSE, progress = FALSE,
                    col_types = cols(.default = "c")) %>%
    mutate(year = as.integer(year)) %>%
    filter(npi %in% coh$npi)
  by_year <- pecos %>% distinct(npi, year) %>% count(year, name = "n")
  rows[["pecos"]] <- by_year %>%
    transmute(source = "PECOS revalidation/reassignment", year, n,
              pct = round(100 * n / N, 1))
  cat(sprintf("PECOS revalidation: %d years, %d-%d\n", nrow(by_year),
              min(by_year$year), max(by_year$year)))
} else {
  cat("PECOS revalidation by year: absent, skipped\n")
}

# --- 6. Medicaid enrollment, 2018-2024 ---------------------------------------
# Already a per-year aggregate, not person-level -- built by
# build_state_source_audit.R's Medicaid section (see
# docs/TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md Section 4) against
# this exact fixed cohort (every year's total is exactly N, verified below).
# "Not observed" is its own classification, not folded into the others; any
# OTHER classification means a Medicaid enrollment record exists that year,
# regardless of whether it's concordant with NPPES.
medicaid_f <- "artifacts/state_source_audit_medicaid_classification_by_year.csv"
if (file.exists(medicaid_f)) {
  mcaid <- read_csv(medicaid_f, show_col_types = FALSE, progress = FALSE,
                    col_types = cols(.default = "c")) %>%
    mutate(year = as.integer(year), n = as.integer(n))
  totals <- mcaid %>% group_by(year) %>% summarise(total = sum(n), .groups = "drop")
  if (!all(totals$total == N))
    warning(sprintf(
      "state_source_audit_medicaid_classification_by_year.csv's yearly totals do not all equal N=%d -- it may describe a different cohort than this script's fixed cohort. Skipping rather than publishing a mismatched denominator.",
      N), call. = FALSE)
  else {
    by_year <- mcaid %>%
      filter(classification != "Not observed") %>%
      group_by(year) %>% summarise(n = sum(n), .groups = "drop")
    rows[["medicaid"]] <- by_year %>%
      transmute(source = "Medicaid enrollment (any classification)", year, n,
                pct = round(100 * n / N, 1))
    cat(sprintf("Medicaid enrollment: %d years, %d-%d\n", nrow(by_year),
                min(by_year$year), max(by_year$year)))
  }
} else {
  cat("Medicaid classification by year: absent, skipped\n")
}

# --- 7. Medicare enrollment, cumulative, from PPEF ---------------------------
# A DIFFERENT KIND OF LINE FROM EVERY OTHER SOURCE ABOVE. Every source so far
# measures repeated observability: is this person present in THAT year's
# snapshot. PPEF (extract_ppef_enrollment_history.R) is one current file with
# no year series of its own -- what it carries instead is each provider's
# ORIGINAL Medicare enrollment date, parsed from ENRLMT_ID, a one-time
# historical fact. The only honest way to put that on a year axis is
# CUMULATIVE: the running share of the fixed cohort whose earliest Medicare
# enrollment falls on or before year Y. It is not comparable point-for-point
# to the presence lines above it, and is labelled "cumulative" so a reader
# does not read it as one.
ppef_f <- "artifacts/ppef_cohort_enrollment_year.csv"
if (file.exists(ppef_f)) {
  ppef <- read_csv(ppef_f, show_col_types = FALSE, progress = FALSE,
                   col_types = cols(.default = "c")) %>%
    mutate(first_enrlmt_year = as.integer(first_enrlmt_year)) %>%
    filter(npi %in% coh$npi)
  yr_range <- seq(min(ppef$first_enrlmt_year), REF_YEAR)
  by_year <- tibble(year = yr_range) %>%
    rowwise() %>%
    mutate(n = sum(ppef$first_enrlmt_year <= year)) %>%
    ungroup()
  rows[["ppef_cumulative"]] <- by_year %>%
    transmute(source = "Medicare enrollment, cumulative (PPEF)", year, n,
              pct = round(100 * n / N, 1))
  cat(sprintf("PPEF cumulative enrollment: %d years, %d-%d, ceiling %.1f%%\n",
              nrow(by_year), min(by_year$year), max(by_year$year),
              max(by_year$n) / N * 100))
} else {
  cat("PPEF enrollment history: absent, skipped\n")
}

if (!length(rows))
  stop("No year-level source was available on this machine; nothing to write.", call. = FALSE)

by_year_tbl <- bind_rows(rows) %>% arrange(source, year)

write_with_provenance(by_year_tbl, "artifacts/table1_by_year.csv", inputs = LINKAGE)

# --- markdown render ----------------------------------------------------------
md <- c("# Table 1, by year",
        "",
        sprintf(paste0("Fixed cohort: the same **%s** ACTIVE, primary-tier-linked midwives ",
                       "Table 1 describes -- not a reconstruction of who was ACTIVE in each ",
                       "past year. Each row below is how many of THIS cohort appear in that ",
                       "year's data, for every source that carries real year-level history. ",
                       "Percentages are against the fixed cohort N, not a per-year denominator."),
                format(N, big.mark = ",")),
        "",
        "| Source | Year | n | % of fixed cohort |",
        "|---|---:|---:|---:|")
for (i in seq_len(nrow(by_year_tbl)))
  md <- c(md, sprintf("| %s | %d | %s | %s |",
                      by_year_tbl$source[i], by_year_tbl$year[i],
                      format(by_year_tbl$n[i], big.mark = ","), sprintf("%.1f", by_year_tbl$pct[i])))
dir.create("docs", showWarnings = FALSE)
writeLines(md, "docs/table1_by_year.md")

cat("\n"); print(as.data.frame(by_year_tbl), row.names = FALSE)
cat("\nwritten: artifacts/table1_by_year.csv, docs/table1_by_year.md\n")
