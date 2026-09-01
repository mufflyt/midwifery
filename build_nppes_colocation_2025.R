#!/usr/bin/env Rscript
#' @title Organization co-location from the November 2025 NPPES, both sides
#'
#' @description
#' The non-Medicare arm, rebuilt on the newest full NPPES dissemination.
#' A midwife's practice location is matched to the Type-2 (organization) NPIs
#' registered at the SAME location, which is what turns "3300 Main St" into a
#' named practice. It owes nothing to Medicare enrollment, so it can see the
#' midwives PECOS cannot.
#'
#' @section What is new here, and why it matters:
#' link_practice_locations_to_org_npi.R built this arm from a 2024 organization
#' cut and a separately-dated location file, and flagged that the two sides were
#' "not from the same instant". Here BOTH SIDES come from one file at one
#' vintage, so a match is co-location as recorded at a single moment rather than
#' an inference across two. Organizations move and close; matching a 2026
#' address to a 2024 organization list produces affiliations that were true at
#' neither date.
#'
#' @section EXACT KEYS ONLY, NEVER PROXIMITY:
#' Telephone, then ZIP+4 plus normalised street, then ZIP5 plus normalised
#' street. No distance rule and no nearest-facility fallback. A midwife
#' practising near a hospital is not employed by it, and a proximity assignment
#' produces an affiliation that cannot be falsified. Keys come from
#' R/lib/address_keys.R so both sides are normalised by the same code.
#'
#' @section AMBIGUITY IS REPORTED, NOT RESOLVED:
#' A medical office building holds many organizations at one street address, so
#' a location often matches several Type-2 NPIs. Where a key matches more than
#' one organization NO organization is assigned; the count is kept so the
#' ambiguity is visible. Picking the first, the largest or the nearest would
#' fabricate an affiliation.
#'
#' @section Deactivated organizations are excluded:
#' A Type-2 NPI with a deactivation date and no later reactivation is not an
#' organization anyone practises with. Matching to one manufactures a defunct
#' employer, which is worse than no answer.
#'
#' Inputs : NPPES_2025 full dissemination CSV; the AMCB->NPI crosswalk
#' Outputs: artifacts/nppes_colocation_2025.csv          (person-level, gitignored)
#'          artifacts/nppes_colocation_2025_summary.csv  (tracked, suppressed)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(DBI); library(duckdb)
  library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_keys.R"))

source(file.path("R", "lib", "medicare_duckdb.R"))

NPPES <- Sys.getenv("NPPES_2025", "")
if (!nzchar(NPPES))
  NPPES <- samsung_volume_path(file.path("nppes_historical_downloads",
                                         "extracted_2025",
                                         "npidata_pfile_20050523-20251109.csv"))
OUT     <- "artifacts/nppes_colocation_2025.csv"
OUT_SUM <- "artifacts/nppes_colocation_2025_summary.csv"
NPPES_VINTAGE <- "2025-11"

if (!file.exists(NPPES)) {
  stop(sprintf(paste("NPPES dissemination not found: %s\n",
                     "  Set NPPES_2025 or mount the volume. Refusing to write",
                     "an empty arm,\n  which would read as 'no midwife shares",
                     "an address with any organization'."), NPPES), call. = FALSE)
}

cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$|\\.provenance\\.json$", cw)]
if (!length(cw)) stop("no AMCB->NPI crosswalk in artifacts/", call. = FALSE)
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
cohort <- read_csv(cw, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct(certification_number = amcb_id, npi)
cli::cli_alert_info("cohort: {format(nrow(cohort), big.mark = ',')} resolved midwives")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "cohort", cohort %>% select(npi))

SRC <- sprintf("read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)",
               NPPES)
COLS <- '
  TRIM(CAST(d."NPI" AS VARCHAR))                                                  AS npi,
  TRIM(CAST(d."Provider Organization Name (Legal Business Name)" AS VARCHAR))     AS org_name,
  TRIM(CAST(d."Provider First Line Business Practice Location Address" AS VARCHAR)) AS addr,
  TRIM(CAST(d."Provider Business Practice Location Address City Name" AS VARCHAR))  AS city,
  TRIM(CAST(d."Provider Business Practice Location Address State Name" AS VARCHAR)) AS st,
  TRIM(CAST(d."Provider Business Practice Location Address Postal Code" AS VARCHAR)) AS zip,
  TRIM(CAST(d."Provider Business Practice Location Address Telephone Number" AS VARCHAR)) AS phone,
  TRIM(CAST(d."NPI Deactivation Date" AS VARCHAR))                                AS deact,
  TRIM(CAST(d."NPI Reactivation Date" AS VARCHAR))                                AS react'

# --- Type-2 organizations ----------------------------------------------------
cli::cli_h2("Type-2 organizations from {NPPES_VINTAGE}")
cli::cli_alert_info("scanning the dissemination file; this reads ~11 GB")
orgs <- dbGetQuery(con, sprintf('
  SELECT %s FROM %s d
  WHERE TRIM(CAST(d."Entity Type Code" AS VARCHAR)) = \'2\'', COLS, SRC))
cli::cli_alert_success("organizations: {format(nrow(orgs), big.mark = ',')}")

# A deactivated NPI with no later reactivation is not an organization anyone
# practises with.
dead <- nzchar(orgs$deact) & !nzchar(orgs$react)
cli::cli_alert_info("excluded as deactivated: {format(sum(dead), big.mark = ',')}")
orgs <- orgs[!dead, ]

# --- the cohort's own rows, from the SAME file -------------------------------
cli::cli_h2("Cohort practice locations from {NPPES_VINTAGE}")
mw <- dbGetQuery(con, sprintf('
  SELECT %s FROM %s d JOIN cohort c ON TRIM(CAST(d."NPI" AS VARCHAR)) = c.npi',
  COLS, SRC))
cli::cli_alert_success("cohort rows found in NPPES: {format(nrow(mw), big.mark = ',')}")

# --- keys, from the canonical library on BOTH sides --------------------------
addkeys <- function(d) {
  d %>% mutate(
    k_addr  = norm_addr(.data$addr),
    k_zip5  = zip5(.data$zip),
    k_zip9  = zip9(.data$zip),
    k_phone = phone10(.data$phone),
    key_phone = if_else(!is.na(k_phone), paste0("P:", k_phone), NA_character_),
    key_zip9  = if_else(!is.na(k_zip9)  & !is.na(k_addr),
                        paste0("9:", k_zip9, "|", k_addr), NA_character_),
    key_zip5  = if_else(!is.na(k_zip5)  & !is.na(k_addr),
                        paste0("5:", k_zip5, "|", k_addr), NA_character_))
}
orgs <- addkeys(orgs); mw <- addkeys(mw)

# --- match, strongest key first ----------------------------------------------
# A key that resolves to exactly ONE organization yields a name. A key matching
# several is recorded with its count and yields none.
cli::cli_h2("Matching")
match_on <- function(kname, strength) {
  o <- orgs %>% filter(!is.na(.data[[kname]])) %>%
    select(key = all_of(kname), org_npi = npi, organization_name = org_name)
  # Two rows for the same organization at one key is one organization.
  o <- o %>% distinct(key, org_npi, .keep_all = TRUE)
  cnt <- o %>% count(key, name = "n_org_at_key")
  m <- mw %>% filter(!is.na(.data[[kname]])) %>%
    select(npi, key = all_of(kname)) %>% distinct() %>%
    inner_join(cnt, by = "key") %>%
    inner_join(o, by = "key", relationship = "many-to-many") %>%
    mutate(match_key = strength)
  cli::cli_alert_info("{strength}: {format(n_distinct(m$npi[m$n_org_at_key == 1]), big.mark = ',')} midwives with an UNAMBIGUOUS organization ({format(n_distinct(m$npi), big.mark = ',')} matched at all)")
  m
}
all_m <- bind_rows(match_on("key_phone", "telephone"),
                   match_on("key_zip9",  "zip9_address"),
                   match_on("key_zip5",  "zip5_address"))

STRENGTH <- c(telephone = 1L, zip9_address = 2L, zip5_address = 3L)
resolved <- all_m %>%
  filter(.data$n_org_at_key == 1L) %>%
  mutate(rank = STRENGTH[.data$match_key]) %>%
  # Strongest key wins; ties broken deterministically on the identifier so the
  # output does not depend on row order.
  arrange(.data$npi, .data$rank, .data$org_npi) %>%
  group_by(.data$npi) %>% slice(1L) %>% ungroup() %>%
  transmute(npi, org_npi, organization_name, match_key,
            nppes_vintage = NPPES_VINTAGE)

ambiguous <- all_m %>% filter(!npi %in% resolved$npi) %>%
  group_by(npi) %>%
  summarise(min_orgs_at_key = min(n_org_at_key), .groups = "drop")

cli::cli_alert_success("resolved to ONE organization: {format(nrow(resolved), big.mark = ',')} midwives")
cli::cli_alert_info("matched but AMBIGUOUS at every key: {format(nrow(ambiguous), big.mark = ',')}")
cli::cli_alert_info("no location key matched any organization: {format(nrow(cohort) - nrow(resolved) - nrow(ambiguous), big.mark = ',')}")

out <- cohort %>% inner_join(resolved, by = "npi") %>%
  arrange(certification_number)
write_with_provenance(out, OUT, na = "", inputs = prov_inputs(c(cw, NPPES)))
cli::cli_alert_success("wrote {OUT}")

summ <- out %>% count(match_key, name = "n_midwives") %>%
  mutate(suppressed = n_midwives < 11L,
         n_midwives = if_else(suppressed, NA_integer_, as.integer(n_midwives)),
         nppes_vintage = NPPES_VINTAGE)
write_with_provenance(summ, OUT_SUM, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_SUM} (cells under 11 suppressed)")
