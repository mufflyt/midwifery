#!/usr/bin/env Rscript
# =============================================================================
# Open Payments address -> NPPES Type-2 organization, from the bulk table
# =============================================================================
# Replaces the candidate-generation path in crossref_all_open_payments_type2.py.
#
# WHAT THE PREVIOUS PATH DID (observed behaviour; no intent is inferred):
#   * queried the live NPPES API by CITY/STATE/ZIP only -- the street address
#     was never sent -- with "limit": 10;
#   * the API returns organizations in ALPHABETICAL order (verified against the
#     live endpoint), so a ZIP holding 200+ Type-2 organizations was truncated
#     to the alphabetically first ten, and any organization sorting after
#     roughly "C" was unreachable regardless of its address;
#   * compared streets with a bidirectional EIGHT-character substring test,
#     so "1 PARK A" matched "11 PARK AVE";
#   * returned the FIRST passing candidate from inside the loop.
# Measured over its 819 assignments: 96.3% came from a truncated universe,
# 83.2% of selections sat within the alphabetical first ten, and only 51.0%
# matched the Open Payments address exactly.
#
# THIS IMPLEMENTATION:
#   * reads a PINNED BULK NPPES Type-2 table, so the candidate universe is
#     reproducible -- rerunning in six months yields the same candidates rather
#     than whatever the API returns that day;
#   * evaluates the COMPLETE candidate universe for the address, with no limit
#     and no ordering;
#   * matches on deterministic normalized street + ZIP5 equality;
#   * NEVER reduces several plausible candidates to one. Zero, one, and many
#     are three distinct outcomes and stay that way.
#
# ORDER INVARIANCE IS A CONTRACT. The result must not depend on the order of
# the organization table or of the input rows. Tests assert this directly,
# because the defect being replaced was precisely an order dependence.
#
# CORRECTNESS IS NOT DEFINED AS AGREEMENT WITH THE R RESOLVER. This matcher
# answers to its own evidence contract; where it and the resolver disagree,
# both cases are preserved for review rather than one being tuned toward the
# other.
#
# Outputs (candidate/audit only -- nothing analytic is promoted):
#   artifacts/audit/open_payments_type2_bulk_links.csv
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
  library(stringr); library(tibble); library(digest)
})

#' Normalize a US street address for exact comparison
#' @param x [vector]: raw street line.
#' @return [character] normalized, NA when empty.
op_norm_addr <- function(x) {
  y <- toupper(str_trim(as.character(x)))
  y <- str_replace_all(y, "[.,#]", " ")
  rep <- c("\\bSTREET\\b"="ST","\\bAVENUE\\b"="AVE","\\bROAD\\b"="RD",
           "\\bDRIVE\\b"="DR","\\bBOULEVARD\\b"="BLVD","\\bPLACE\\b"="PL",
           "\\bLANE\\b"="LN","\\bCOURT\\b"="CT","\\bPARKWAY\\b"="PKWY",
           "\\bHIGHWAY\\b"="HWY","\\bSUITE\\b"="STE","\\bNORTH\\b"="N",
           "\\bSOUTH\\b"="S","\\bEAST\\b"="E","\\bWEST\\b"="W")
  for (p in names(rep)) y <- str_replace_all(y, p, rep[[p]])
  y <- str_trim(str_replace_all(y, "\\s+", " "))
  y[!nzchar(y)] <- NA_character_
  y
}
#' @param x [vector]: postal code.
#' @return [character] first five digits, NA when absent.
op_zip5 <- function(x) str_extract(as.character(x), "[0-9]{5}")

#' Resolve addresses to Type-2 organizations over a COMPLETE candidate universe
#'
#' @param addr_df [data.frame]: needs `id`, `addr`, `zip`.
#' @param org_df [data.frame]: needs `type2_npi`, `organization_name`,
#'   `addr`, `zip`; the complete bulk table, unordered.
#' @return [tbl_df] one row per id: n_candidates, status, and an organization
#'   only when exactly one candidate exists.
resolve_type2_bulk <- function(addr_df, org_df) {
  stopifnot(all(c("id", "addr", "zip") %in% names(addr_df)))
  stopifnot(all(c("type2_npi", "organization_name", "addr", "zip") %in% names(org_df)))

  a <- addr_df %>%
    mutate(addr_norm = op_norm_addr(addr), z5 = op_zip5(zip)) %>%
    filter(!is.na(addr_norm), !is.na(z5))
  o <- org_df %>%
    mutate(addr_norm = op_norm_addr(addr), z5 = op_zip5(zip)) %>%
    filter(!is.na(addr_norm), !is.na(z5)) %>%
    distinct(type2_npi, addr_norm, z5, .keep_all = TRUE)

  # Complete candidate set: every organization at the same normalized street
  # and ZIP5. No limit, no ordering, no substring test.
  hits <- a %>%
    inner_join(o %>% select(type2_npi, organization_name, addr_norm, z5),
               by = c("addr_norm", "z5"), relationship = "many-to-many") %>%
    group_by(id) %>%
    summarise(n_candidates = n_distinct(type2_npi),
              # Sorted purely so the CANDIDATE LIST STRING is stable for
              # diffing. Sorting never chooses a winner: an organization is
              # emitted below only when n_candidates == 1.
              candidate_npis  = paste(sort(unique(type2_npi)), collapse = ";"),
              candidate_names = paste(sort(unique(organization_name)), collapse = " | "),
              .groups = "drop")

  addr_df %>%
    select(id) %>% distinct() %>%
    left_join(hits, by = "id") %>%
    mutate(
      n_candidates = coalesce(n_candidates, 0L),
      status = case_when(n_candidates == 1L ~ "unique_exact",
                         n_candidates >  1L ~ "multiple_plausible",
                         TRUE               ~ "no_match"),
      type2_npi = if_else(n_candidates == 1L, candidate_npis, NA_character_),
      organization_name = if_else(n_candidates == 1L, candidate_names, NA_character_))
}

# --- CLI ---------------------------------------------------------------------
if (sys.nframe() == 0) {
  DB <- Sys.getenv("MEDICARE_DUCKDB",
                   "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb")
  SRC <- Sys.getenv("OP_ADDRESS_FILE", "artifacts/open_payments_recent_address.csv")
  dir.create("artifacts/audit", showWarnings = FALSE, recursive = TRUE)

  con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  org <- dbGetQuery(con, "
    SELECT CAST(npi AS VARCHAR) AS type2_npi, organization_name,
           practice_address_street AS addr, practice_address_zip AS zip
      FROM npi_org_all
     WHERE NULLIF(TRIM(organization_name), '') IS NOT NULL")

  # PINNED VINTAGE FINGERPRINT. Recorded so a rerun that silently picked up a
  # different NPPES cut is detectable rather than invisible.
  fp <- digest::digest(list(n = nrow(org),
                            npi = sort(head(org$type2_npi, 1000))), algo = "md5")
  cat(sprintf("bulk Type-2 organizations: %s | vintage fingerprint: %s\n",
              format(nrow(org), big.mark = ","), fp))

  src <- read_csv(SRC, show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = col_character()))
  addr_df <- src %>% transmute(id = certification_number, addr = addr, zip = zip)
  cat(sprintf("addresses to resolve: %s\n", format(nrow(addr_df), big.mark = ",")))

  res <- resolve_type2_bulk(addr_df, org) %>%
    mutate(nppes_vintage_fingerprint = fp)
  print(res %>% count(status, sort = TRUE) %>% as.data.frame())
  write_csv(res, "artifacts/audit/open_payments_type2_bulk_links.csv", na = "")
  cat("written: artifacts/audit/open_payments_type2_bulk_links.csv\n")
}
