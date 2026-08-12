#!/usr/bin/env Rscript
# =============================================================================
# Most recent Open Payments business address -> facility, by EXACT match only
# =============================================================================
# Open Payments is the widest non-NPPES location source for this cohort: 6,084
# midwives (51.0%) carry a business address, against 1,665 (14.0%) with a
# hospital privilege via CCN, and it adds 5,010 midwives the CCN route misses.
# Coverage starts in 2021, when CNMs became covered recipients (1-3 midwives in
# 2018-2020, then 2,370 in 2021).
#
# NO NEAREST-HOSPITAL ASSIGNMENT. The facility is resolved by EXACT normalized
# address only. Proximity is not employment: a business address 400m from a
# hospital is not evidence of working there, and a distance rule would
# manufacture a confident-looking affiliation that cannot be falsified and
# would then drive a Table 1 percentage. Unmatched addresses stay UNKNOWN as
# their own labelled state -- the same discipline that keeps "not enrolled in
# Medicare" separate from "enrolled, no privilege recorded".
#
# WHAT THIS ADDRESS IS. It is the business address a MANUFACTURER reported when
# disclosing a payment. It is not an employer of record, and some entries are
# PO boxes. Only 47.1% of midwives show a single stable address across years,
# so "most recent" is a choice, made explicit below rather than left to row
# order.
#
# RECENCY IS DETERMINISTIC. Latest payment year wins; within that year the most
# frequently reported address wins; ties break lexicographically. ARG_MAX alone
# picks arbitrarily among ties, which would make the output depend on scan
# order and quietly change between runs.
#
# FALSE NEGATIVES ARE THE SAFE DIRECTION. A hospital campus registers several
# addresses (main entrance, medical office building, billing office), so exact
# matching will miss true affiliations. That miss is reported, not hidden: a
# non-match means "no exact address match", never "works nowhere".
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          open_payments_2021..2024 (MEDICARE_DUCKDB)
#          artifacts/ob_hospitals_geocoded.csv
# Outputs: artifacts/open_payments_recent_address.csv   (person-level)
#          artifacts/open_payments_facility_match.csv   (person-facility)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
  library(stringr); library(tibble)
})
source("R/lib/common_helpers.R")

DB <- Sys.getenv("MEDICARE_DUCKDB",
                 "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb")
HOSP <- Sys.getenv("OB_HOSPITALS", "artifacts/ob_hospitals_geocoded.csv")
YEARS <- 2021:2024

for (f in c(DB, HOSP))
  if (!file.exists(f))
    stop(sprintf("Required input not found: %s", f), call. = FALSE)

#' Normalize a US street address for exact comparison
#'
#' Uppercases, strips punctuation, collapses whitespace and expands the common
#' thoroughfare abbreviations, so "3300 Main St." and "3300 MAIN STREET" agree.
#' Deliberately does NOT strip suite/unit: two suites in one building are
#' different workplaces, and merging them would assert an affiliation the
#' source does not record.
norm_addr <- function(x) {
  y <- toupper(str_trim(as.character(x)))
  y <- str_replace_all(y, "[.,#]", " ")
  y <- str_replace_all(y, "\\s+", " ")
  rep <- c("\\bSTREET\\b" = "ST", "\\bAVENUE\\b" = "AVE", "\\bROAD\\b" = "RD",
           "\\bDRIVE\\b" = "DR", "\\bBOULEVARD\\b" = "BLVD", "\\bPLACE\\b" = "PL",
           "\\bLANE\\b" = "LN", "\\bCOURT\\b" = "CT", "\\bPARKWAY\\b" = "PKWY",
           "\\bHIGHWAY\\b" = "HWY", "\\bSUITE\\b" = "STE", "\\bNORTH\\b" = "N",
           "\\bSOUTH\\b" = "S", "\\bEAST\\b" = "E", "\\bWEST\\b" = "W")
  for (p in names(rep)) y <- str_replace_all(y, p, rep[[p]])
  y <- str_trim(str_replace_all(y, "\\s+", " "))
  y[!nzchar(y)] <- NA_character_
  y
}
zip5 <- function(x) {
  # str_extract already yields NA when there is no 5-digit run, so no
  # emptiness guard is needed. The earlier one called tidyr::replace_na()
  # without tidyr loaded -- the same use-without-declare defect that kept the
  # Doximity scraper from ever running.
  str_extract(as.character(x), "[0-9]{5}")
}

# --- cohort ------------------------------------------------------------------
coh <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                show_col_types = FALSE, progress = FALSE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  select(certification_number, npi)
N <- nrow(coh)
cat(sprintf("cohort: %s\n", format(N, big.mark = ",")))

con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "c_npi", coh %>% select(npi), temporary = TRUE, overwrite = TRUE)

union_sql <- paste(sprintf(
  "SELECT CAST(a.Covered_Recipient_NPI AS VARCHAR) AS npi, %d AS yr,
          a.Recipient_Primary_Business_Street_Address_Line1 AS addr,
          a.Recipient_City AS city, a.Recipient_State AS st,
          a.Recipient_Zip_Code AS zip
     FROM open_payments_%d a
     INNER JOIN c_npi c ON CAST(a.Covered_Recipient_NPI AS VARCHAR) = c.npi
    WHERE NULLIF(TRIM(a.Recipient_Primary_Business_Street_Address_Line1), '') IS NOT NULL",
  YEARS, YEARS), collapse = " UNION ALL ")

raw <- dbGetQuery(con, sprintf("SELECT * FROM (%s)", union_sql))
cat(sprintf("open payments address rows: %s across %s midwives\n",
            format(nrow(raw), big.mark = ","),
            format(n_distinct(raw$npi), big.mark = ",")))

# Most recent address, deterministically resolved.
recent <- raw %>%
  mutate(addr_norm = norm_addr(addr), zip = zip5(zip)) %>%
  filter(!is.na(addr_norm)) %>%
  group_by(npi) %>% filter(yr == max(yr)) %>%
  count(npi, yr, addr, addr_norm, city, st, zip, name = "times_reported") %>%
  arrange(npi, desc(times_reported), addr_norm) %>%
  slice(1) %>% ungroup()

multi <- raw %>% group_by(npi) %>%
  summarise(n_addr = n_distinct(norm_addr(addr)), .groups = "drop")
cat(sprintf("midwives with a most-recent address: %s (%.1f%% of cohort)\n",
            format(nrow(recent), big.mark = ","), 100 * nrow(recent) / N))
cat(sprintf("  reporting >1 distinct address across %d-%d: %s (%.1f%%)\n",
            min(YEARS), max(YEARS),
            format(sum(multi$n_addr > 1), big.mark = ","),
            100 * mean(multi$n_addr > 1)))

recent <- coh %>% inner_join(recent, by = "npi")
write_csv(recent, "artifacts/open_payments_recent_address.csv", na = "")
cat("written: artifacts/open_payments_recent_address.csv\n")

# --- facility, by exact address only -----------------------------------------
hosp <- chr(HOSP) %>%
  mutate(cms_ccn   = pad_ccn(prvdr_num),
         addr_norm = norm_addr(geocode_address_1),
         zip       = zip5(geocode_zip)) %>%
  filter(!is.na(addr_norm), !is.na(cms_ccn)) %>%
  select(cms_ccn, hospital_name = fac_name, addr_norm, zip,
         hospital_city = geocode_city, hospital_state = geocode_state) %>%
  distinct(addr_norm, zip, .keep_all = TRUE)
cat(sprintf("\nOB hospital master: %s facilities with a usable address\n",
            format(nrow(hosp), big.mark = ",")))

m <- recent %>%
  left_join(hosp, by = c("addr_norm", "zip"), relationship = "many-to-one") %>%
  mutate(facility_status = if_else(
    !is.na(hospital_name), "Exact address match to an OB hospital",
    "No exact address match (facility unknown)"))

matched <- sum(!is.na(m$hospital_name))
cat(sprintf("\nEXACT address matches: %s of %s with an address (%.1f%%), %.1f%% of cohort\n",
            format(matched, big.mark = ","), format(nrow(m), big.mark = ","),
            100 * matched / nrow(m), 100 * matched / N))
cat(sprintf("unmatched (facility unknown, NOT 'works nowhere'): %s\n",
            format(sum(is.na(m$hospital_name)), big.mark = ",")))
if (matched > 0)
  cat(sprintf("distinct facilities identified: %s\n",
              format(n_distinct(m$cms_ccn[!is.na(m$cms_ccn)]), big.mark = ",")))

write_csv(m, "artifacts/open_payments_facility_match.csv", na = "")
cat("written: artifacts/open_payments_facility_match.csv\n")
