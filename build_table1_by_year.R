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
# THREE SOURCES, THREE DIFFERENT WINDOWS, NONE OF THEM REDUCED TO ONE:
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
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          artifacts/midwife_panel_midwifeonly.csv
#          artifacts/historical_facility_affiliation_cohort_state_by_year.csv
#          /Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb (Medicare Part B/D)
# Outputs: artifacts/table1_by_year.csv
#          docs/table1_by_year.md
# =============================================================================
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
