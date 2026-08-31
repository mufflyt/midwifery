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
#   * reads the LOCAL BULK NPPES Type-2 table, so the candidate universe is a
#     fixed snapshot rather than whatever the API returns that day. A SHA-256
#     over all rows of the consumed columns, deterministically ordered, is
#     written to provenance so any change is DETECTABLE. Note the specific
#     NPPES dissemination date is not established by the warehouse itself: set
#     NPPES_VINTAGE_DATE to record it, and vintage_verified reports whether it
#     was;
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

#' Collapse to the sorted distinct values, or NA when none are non-missing
#'
#' `paste(sort(unique(x)), collapse = sep)` silently returns "" -- not NA --
#' when every element of `x` is NA, because `sort()` drops NAs by default.
#' An empty STRING is indistinguishable from "we know the name and it is
#' blank"; NA correctly says "we do not know it". This matters because that
#' string sits next to `status == "unique_exact"`, which promises a resolved
#' organization -- "" there reads as a resolved-but-blank name, not a gap.
#' @param x [character]: values to collapse.
#' @param sep [character(1)]: separator between distinct values.
#' @return [character(1)] NA if `x` has no non-missing values, else the
#'   sorted distinct values joined by `sep`.
paste_sorted_unique <- function(x, sep) {
  u <- sort(unique(x))
  if (length(u) == 0L) NA_character_ else paste(u, collapse = sep)
}

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

  # TYPE CONTRACT: zip and addr must already be character. A numeric zip
  # (e.g. a data.frame column that lost its leading zero, turning "02138"
  # into 2138) silently fails op_zip5()'s 5-digit regex and every affected
  # id resolves to "no_match" -- identical, on the page, to a real
  # non-match. That is worse than an error: it is a New-England-and-PR-wide
  # silent match-rate drop with no signal that anything went wrong. Fail
  # loudly instead, matching the duplicate-id contract below.
  for (nm in c("addr_df", "org_df")) {
    df <- get(nm)
    bad <- c("addr", "zip")[!vapply(df[c("addr", "zip")], is.character, logical(1))]
    if (length(bad))
      stop(sprintf(paste0("resolve_type2_bulk(): %s$%s must be character, not %s. ",
                          "A numeric zip silently drops leading zeros (2138 vs ",
                          "\"02138\") and would misresolve as no_match rather ",
                          "than erroring; coerce explicitly before calling."),
                   nm, paste(bad, collapse = "/"),
                   paste(vapply(df[bad], function(x) class(x)[1], character(1)),
                         collapse = "/")),
           call. = FALSE)
  }

  # INPUT CONTRACT: one address per id. The function groups by `id`, so two
  # addresses for one id would be silently pooled into a single candidate set
  # and a person with two legitimate workplaces would be reported as
  # "ambiguous" rather than as having two locations. That must fail loudly
  # rather than be absorbed.
  dup <- addr_df$id[duplicated(addr_df$id)]
  if (length(dup))
    stop(sprintf(paste0("resolve_type2_bulk(): %d id(s) carry more than one ",
                        "address (e.g. %s). This function resolves ONE address ",
                        "per id. Match at address level and summarise to the ",
                        "provider separately rather than pooling."),
                 length(unique(dup)), paste(head(unique(dup), 3), collapse = ", ")),
         call. = FALSE)

  a <- addr_df %>%
    mutate(addr_norm = op_norm_addr(addr), z5 = op_zip5(zip)) %>%
    filter(!is.na(addr_norm), !is.na(z5))
  # DETERMINISTIC ALIAS HANDLING. This used
  #   distinct(type2_npi, addr_norm, z5, .keep_all = TRUE)
  # which keeps whichever organization_name happened to come FIRST. The NPI was
  # stable but the emitted name could change when the organization table was
  # reordered -- a silent violation of the order-invariance contract this
  # resolver claims. All observed aliases for one NPI at one address are now
  # retained, sorted, so the output is a function of content alone.
  o <- org_df %>%
    mutate(addr_norm = op_norm_addr(addr), z5 = op_zip5(zip)) %>%
    filter(!is.na(addr_norm), !is.na(z5)) %>%
    group_by(type2_npi, addr_norm, z5) %>%
    summarise(organization_name = paste_sorted_unique(organization_name, " / "),
              .groups = "drop")

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
              candidate_npis  = paste_sorted_unique(type2_npi, ";"),
              candidate_names = paste_sorted_unique(organization_name, " | "),
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
           CAST(practice_address_street AS VARCHAR) AS addr,
           CAST(practice_address_zip AS VARCHAR) AS zip
      FROM npi_org_all
     WHERE NULLIF(TRIM(organization_name), '') IS NOT NULL")

  # SOURCE FINGERPRINT.
  #
  # The first version hashed only nrow() plus the first 1,000 NPIs, with MD5.
  # That could not detect a change to any of the other ~1.74M records, could
  # not detect an edit to an address or organization NAME while the NPIs were
  # unchanged, and -- because head() was taken BEFORE sorting -- could return a
  # different digest for identical content merely returned in a different
  # database row order. It was not a fingerprint.
  #
  # This hashes ALL rows over the columns the resolver actually consumes,
  # deterministically ordered, with SHA-256.
  fp_cols <- c("type2_npi", "organization_name", "addr", "zip")
  ord <- do.call(order, unname(as.list(org[fp_cols])))
  content_sha256 <- digest::digest(org[ord, fp_cols], algo = "sha256")

  # HONEST LABELLING. `npi_org_all` is a table inside a 78 GB DuckDB warehouse.
  # It carries no NPPES dissemination date, and the warehouse is far too large
  # to hash as a file, so the specific immutable NPPES vintage is NOT
  # established here. The content hash makes any change DETECTABLE; it does not
  # by itself identify which dissemination this is. The word "pinned" is
  # therefore not used for the vintage -- only for the content.
  vintage_date <- Sys.getenv("NPPES_VINTAGE_DATE", NA_character_)
  prov <- tibble::tibble(
    source_db = DB, source_table = "npi_org_all",
    n_rows = nrow(org), content_sha256 = content_sha256,
    nppes_vintage_date = vintage_date,
    vintage_verified = !is.na(vintage_date))
  readr::write_csv(prov, "artifacts/audit/open_payments_type2_source_provenance.csv",
                   na = "")
  cat(sprintf("bulk Type-2 organizations: %s\n  content sha256: %s\n  vintage date: %s\n",
              format(nrow(org), big.mark = ","), content_sha256,
              if (is.na(vintage_date)) "NOT ESTABLISHED (set NPPES_VINTAGE_DATE)" else vintage_date))
  fp <- content_sha256

  src <- read_csv(SRC, show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = col_character()))
  addr_df <- src %>% transmute(id = certification_number, addr = addr, zip = zip)
  cat(sprintf("addresses to resolve: %s\n", format(nrow(addr_df), big.mark = ",")))

  res <- resolve_type2_bulk(addr_df, org) %>%
    mutate(nppes_content_sha256 = fp, nppes_vintage_date = vintage_date)
  print(res %>% count(status, sort = TRUE) %>% as.data.frame())
  write_csv(res, "artifacts/audit/open_payments_type2_bulk_links.csv", na = "")
  cat("written: artifacts/audit/open_payments_type2_bulk_links.csv\n")
}
