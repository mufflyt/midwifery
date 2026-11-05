#!/usr/bin/env Rscript
# =============================================================================
# Table 1, by year -- how often ELIGIBLE members of the fixed cohort show up
# in each year-level source, 2003-2026 where available
# =============================================================================
# Run as: Rscript build_table1_by_year.R
#
# WHAT THIS IS, AND WHAT IT IS NOT. Table 1 proper (build_table1_midwives.R)
# is cross-sectional: one row per midwife, characteristics as of today. Most
# of its variables have no year dimension at all -- sex, age, ACOG district,
# rurality, Healthgrades, CMS NDH and HPSA status are all single, current
# snapshots, because that is all their sources ever offer.
#
# WHO COUNTS TOWARD YEAR Y. The identity set is fixed -- today's ACTIVE,
# primary-tier-linked cohort, same as Table 1 proper, never reconstructed
# year to year. But a cohort member counts toward year Y's numerator AND
# denominator only if her AMCB certification covered year Y: cert_year <= Y
# <= expir_year, from certification_date/expiration_date (real historical
# facts on the linkage record, not the current `status` snapshot -- see the
# ELIGIBILITY WINDOW section below for why that distinction matters and what
# it does and does not claim to reconstruct). Before this restriction
# (versions of this file prior to 2026-11-05), every line divided by the
# full fixed N regardless of year, so a midwife certified in 2024 silently
# dragged down 2007's rate just by not existing yet -- real left-censoring,
# but it made early-year numbers read as a behavior measure when they were
# actually a composition artifact. One source (Medicaid, see section 6) is
# the sole exception -- its input is pre-aggregated and cannot be restricted
# this way, and is labelled accordingly.
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

# =============================================================================
# PER-YEAR ELIGIBILITY WINDOW, from certification_date/expiration_date
# =============================================================================
# Every line below now counts a cohort member toward year Y only if her AMCB
# certification covered year Y -- not just "is she in today's fixed cohort."
# This project does NOT hold a historical AMCB status register (the `status`
# field is a current value), but it does hold two real, fixed historical
# facts for every certificant: certification_date (when she was first
# certified) and expiration_date (when that certification's current window
# runs out -- for everyone in today's ACTIVE cohort this is a FUTURE date,
# her next recertification deadline; for someone who later lapsed it would be
# the date she stopped being in good standing). A person cannot sensibly
# count toward a year before her first certification, so that is the
# restriction applied -- without claiming to reconstruct full historical
# ACTIVE/INACTIVE status, which this data does not support.
#
# WHY THIS MATTERS. Before this restriction, "24.1% of the cohort" in NPPES'
# 2007 panel was computed against the FULL 12,170, including midwives
# certified decades later who could not possibly have appeared in 2007 data
# -- real left-censoring, but it makes the early-year rate uninterpretable as
# a behavior measure. Restricting the denominator to midwives who were
# actually certification-eligible that year turns "how many show up" into a
# real participation rate among people who could plausibly have shown up.
#
# certification_date / expiration_date are "MM/YYYY" strings (confirmed
# 2026-11-05: all 12,170 cohort members parse cleanly).
elig_base <- coh %>%
  transmute(npi, certification_number,
            cert_year = as.integer(substr(certification_date, 4, 7)),
            expir_year = as.integer(substr(expiration_date, 4, 7)))
if (any(is.na(elig_base$cert_year) | is.na(elig_base$expir_year)))
  stop("certification_date/expiration_date failed to parse for some cohort members; fix before trusting the eligibility window.", call. = FALSE)

ELIG_YEARS <- 2003:REF_YEAR   # covers every source's span, earliest (PPEF) to REF_YEAR
elig_long <- elig_base %>%
  tidyr::crossing(year = ELIG_YEARS) %>%
  filter(year >= cert_year, year <= expir_year) %>%
  select(npi, certification_number, year)
eligible_n_by_year <- elig_long %>% distinct(npi, year) %>% count(year, name = "eligible_n")
cat(sprintf("Eligibility window: %d-%d; eligible_n ranges %s-%s across the span\n",
            min(ELIG_YEARS), max(ELIG_YEARS),
            format(min(eligible_n_by_year$eligible_n), big.mark = ","),
            format(max(eligible_n_by_year$eligible_n), big.mark = ",")))

#' Restrict a (npi, year) presence table to certification-eligible pairs and
#' rate it against that year's eligible_n, not the fixed cohort N.
#'
#' @param all_years Optional: every year this source was actually checked
#'   (e.g. every program year a file exists for). A year with real zero
#'   matches is completed in as n = 0, eligible_n looked up, pct = 0 --
#'   count(year) on its own silently DROPS a year with no matching rows,
#'   which reads as "not checked" rather than "checked, found nothing." A
#'   genuinely absent year (no file, no table) should never be in all_years
#'   in the first place, so this never invents a year the source didn't run.
restrict_to_eligible <- function(presence_df, all_years = NULL) {
  out <- presence_df %>%
    distinct(npi, year) %>%
    inner_join(elig_long %>% distinct(npi, year), by = c("npi", "year")) %>%
    count(year, name = "n")
  if (!is.null(all_years))
    out <- tibble(year = all_years) %>% left_join(out, by = "year") %>%
      mutate(n = coalesce(n, 0L))
  out %>%
    left_join(eligible_n_by_year, by = "year") %>%
    mutate(pct = round(100 * n / eligible_n, 1))
}

rows <- list()

# --- 1. NPPES annual panel presence, 2007-2026 -------------------------------
pnl <- "artifacts/midwife_panel_midwifeonly.csv"
if (file.exists(pnl)) {
  panel_raw <- read_csv(pnl, show_col_types = FALSE, progress = FALSE,
                        col_types = cols(.default = "c")) %>%
    filter(!is.na(snapshot_year))
  panel_years <- sort(unique(as.integer(panel_raw$snapshot_year)))
  panel <- panel_raw %>% filter(npi %in% coh$npi) %>%
    transmute(npi, year = as.integer(snapshot_year))
  by_year <- restrict_to_eligible(panel, all_years = panel_years)
  rows[["nppes_panel"]] <- by_year %>%
    transmute(source = "NPPES annual panel", year, n, eligible_n, pct)
  cat(sprintf("NPPES panel: %d years, %d-%d\n", nrow(by_year),
              min(by_year$year), max(by_year$year)))
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
      "SELECT c.npi, %d AS year
         FROM cohort_npi_by_year c
         INNER JOIN (SELECT DISTINCT CAST(%s AS VARCHAR) AS npi
                       FROM %s WHERE %s IS NOT NULL) t
           ON t.npi = c.npi", y, npicol, tbl, npicol))
  }
  if (length(pb) && length(pd)) {
    b <- bind_rows(lapply(pb, scan_year, npicol = "Rndrng_NPI"))
    d <- bind_rows(lapply(pd, scan_year, npicol = "npi_char"))
    b_by_year <- restrict_to_eligible(b, all_years = yr_of(pb))
    d_by_year <- restrict_to_eligible(d, all_years = yr_of(pd))
    rows[["part_b"]] <- b_by_year %>%
      transmute(source = "Medicare Part B (rendering NPI)", year, n, eligible_n, pct)
    rows[["part_d"]] <- d_by_year %>%
      transmute(source = "Medicare Part D (prescriber NPI)", year, n, eligible_n, pct)
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
  aff_raw <- read_csv(fa, show_col_types = FALSE, progress = FALSE,
                      col_types = cols(.default = "c")) %>%
    transmute(npi, year = as.integer(year))
  aff_years <- sort(unique(aff_raw$year))
  aff <- aff_raw %>% filter(npi %in% coh$npi)
  by_year <- restrict_to_eligible(aff, all_years = aff_years)
  rows[["hospital_ccn"]] <- by_year %>%
    transmute(source = "Hospital affiliation (CCN, historical DAC)", year, n, eligible_n, pct)
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
op_years_checked <- integer(0)
for (y in op_years) {
  f <- sprintf("artifacts/cohort_midwives_open_payments_general_%d.csv", y)
  if (!file.exists(f)) next
  op_years_checked <- c(op_years_checked, y)
  op <- read_csv(f, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = "c")) %>%
    mutate(payment_amount = suppressWarnings(as.numeric(payment_amount))) %>%
    filter(npi %in% coh$npi, !is.na(payment_amount), payment_amount > 0)
  op_rows[[as.character(y)]] <- tibble(npi = op$npi, year = y)
}
if (length(op_rows)) {
  by_year <- restrict_to_eligible(bind_rows(op_rows), all_years = op_years_checked)
  rows[["open_payments"]] <- by_year %>%
    transmute(source = "Open Payments general payments", year, n, eligible_n, pct)
  cat(sprintf("Open Payments: %d years, %d-%d\n", nrow(by_year),
              min(by_year$year), max(by_year$year)))
} else {
  cat("Open Payments by-year files: absent, skipped\n")
}

# --- 5. PECOS revalidation/reassignment, 2021-2026 ---------------------------
pecos_f <- "artifacts/pecos_revalidation_cohort_state_by_year.csv"
if (file.exists(pecos_f)) {
  pecos_raw <- read_csv(pecos_f, show_col_types = FALSE, progress = FALSE,
                        col_types = cols(.default = "c")) %>%
    transmute(npi, year = as.integer(year))
  pecos_years <- sort(unique(pecos_raw$year))
  pecos <- pecos_raw %>% filter(npi %in% coh$npi)
  by_year <- restrict_to_eligible(pecos, all_years = pecos_years)
  rows[["pecos"]] <- by_year %>%
    transmute(source = "PECOS revalidation/reassignment", year, n, eligible_n, pct)
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
#
# THE ONE SOURCE NOT RESTRICTED TO THE ELIGIBILITY WINDOW. Every other block
# above restricts to cohort members certification-eligible that year
# (restrict_to_eligible()); this one can't, because the input is already a
# per-classification COUNT, not a person-level (npi, year) table this script
# can intersect against elig_long. Rated against the fixed cohort N, same as
# every line was before 2026-11-05 -- named explicitly in the source label so
# this isn't read as consistent with the other seven.
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
      transmute(source = "Medicaid enrollment (any classification, % of fixed cohort N -- not eligibility-restricted)",
                year, n, eligible_n = N, pct = round(100 * n / N, 1))
    cat(sprintf("Medicaid enrollment: %d years, %d-%d (fixed-N denominator, not eligibility-restricted)\n",
                nrow(by_year), min(by_year$year), max(by_year$year)))
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
  # Cumulative, so restrict_to_eligible() (built for a presence-per-year
  # table) doesn't apply directly -- for each year Y, the numerator is
  # eligible-in-Y npis whose Medicare enrollment began on or before Y, the
  # denominator is the same eligible_n(Y) every other line uses.
  yr_range <- seq(min(ppef$first_enrlmt_year), REF_YEAR)
  by_year <- lapply(yr_range, function(y) {
    elig_npis_y <- elig_long %>% filter(year == y) %>% pull(npi) %>% unique()
    n_enrolled <- sum(ppef$npi[ppef$first_enrlmt_year <= y] %in% elig_npis_y)
    tibble(year = y, n = n_enrolled, eligible_n = length(elig_npis_y))
  }) %>% bind_rows() %>%
    mutate(pct = round(100 * n / eligible_n, 1))
  rows[["ppef_cumulative"]] <- by_year %>%
    transmute(source = "Medicare enrollment, cumulative (PPEF)", year, n, eligible_n, pct)
  cat(sprintf("PPEF cumulative enrollment: %d years, %d-%d, ceiling %.1f%%\n",
              nrow(by_year), min(by_year$year), max(by_year$year),
              max(by_year$pct)))
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
        sprintf(paste0("Identity set: the same **%s** ACTIVE, primary-tier-linked midwives ",
                       "Table 1 describes -- never reconstructed year to year. But a cohort ",
                       "member counts toward year Y's numerator AND denominator only if her ",
                       "AMCB certification covered year Y (certification_date <= Y <= ",
                       "expiration_date, both real historical facts on the linkage record, ",
                       "not the current `status` snapshot). `eligible_n` is that year's ",
                       "denominator; percentages are against it, not the fixed %s. One source ",
                       "(Medicaid) is the exception -- its input is a pre-aggregated ",
                       "classification count this script cannot restrict person-by-person, so ",
                       "it is rated against the fixed %s and labelled as such."),
                format(N, big.mark = ","), format(N, big.mark = ","), format(N, big.mark = ",")),
        "",
        "| Source | Year | n | eligible_n | % |",
        "|---|---:|---:|---:|---:|")
for (i in seq_len(nrow(by_year_tbl)))
  md <- c(md, sprintf("| %s | %d | %s | %s | %s |",
                      by_year_tbl$source[i], by_year_tbl$year[i],
                      format(by_year_tbl$n[i], big.mark = ","),
                      format(by_year_tbl$eligible_n[i], big.mark = ","),
                      sprintf("%.1f", by_year_tbl$pct[i])))
dir.create("docs", showWarnings = FALSE)
writeLines(md, "docs/table1_by_year.md")

cat("\n"); print(as.data.frame(by_year_tbl), row.names = FALSE)
cat("\nwritten: artifacts/table1_by_year.csv, docs/table1_by_year.md\n")
