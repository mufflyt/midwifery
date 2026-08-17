#!/usr/bin/env Rscript
#' @title Does the canonical address parser change the unresolved decomposition?
#'
#' @description
#' An experiment measured three address normalisers against the 702 midwives
#' with no organization at their practice address and found the canonical
#' isochrones parser resolved 27 where the hand-rolled `norm_addr()` resolved 9.
#' That comparison was internally valid and externally incomparable: the
#' experiment used the 2026-08-09 NPPES dissemination and a single ZIP5 key,
#' while `diagnose_unresolved_affiliations.R` -- which produced the published
#' 835 / 702 / 7 decomposition -- uses the 2025-11-09 dissemination, includes
#' reactivated NPIs, and ranks THREE keys.
#'
#' This holds every one of those fixed and varies only the address normaliser.
#'
#' @section What is held identical to production:
#' \itemize{
#'   \item the same cohort: ACTIVE certificants on the newest AMCB panel whose
#'     NPI is absent from `organization_affiliation_resolved.csv`;
#'   \item the same dissemination, `NPPES_2025`;
#'   \item the same organization eligibility -- Entity Type 2, and the LIVE rule
#'     INCLUDING the reactivation clause, which the experiment omitted;
#'   \item the same three keys and the same rank precedence
#'     (no_usable_key < key_matched_no_org < ambiguous_many_orgs <
#'     unique_org_available);
#'   \item no ZIP or state restriction on the organization universe.
#' }
#' Only `norm_addr()` is swapped. Nothing else in the classification moves.
#'
#' @section The validation that makes the other two arms trustworthy:
#' Arm 1 IS production's normaliser, so arm 1 must reproduce the published
#' decomposition exactly. If it does not, the harness is wrong and the other two
#' arms mean nothing -- the script says so and stops short of any conclusion
#' rather than reporting a difference that is really a harness artifact.
#'
#' @section Why a reduced organization universe is EXACT, not a sample:
#' The national live Type-2 universe is ~1.9M rows and the canonical parser runs
#' at roughly 10 addresses/second, which is weeks. It is not sampled. An address
#' key matches only when the normalised strings are EQUAL, and all three
#' normalisers preserve a leading house number, so an organization can only
#' share an address key with a cohort member if it shares BOTH the ZIP5 and the
#' house number. Organizations failing that test cannot match under any of the
#' three, so excluding them cannot change a single count.
#'
#' Addresses with no leading house number are handled as their own stratum --
#' same ZIP5, also no leading number -- because the reduction above would drop
#' them all. These are the installation-name cases (NAVAL MEDICAL CENTER, LRMC)
#' that no address key can resolve anyway, and the stratum exists so that claim
#' is measured rather than assumed.
#'
#' The phone key touches no address, so it is identical across all three arms
#' and is computed once over the FULL national universe.
#'
#' Inputs : NPPES_2025 dissemination, the newest AMCB panel,
#'          artifacts/organization_affiliation_resolved.csv,
#'          artifacts/cohort_membership_four_way.csv
#' Outputs: artifacts/address_parser_reconciliation.csv (tracked summary)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(cli)
  library(stringr); library(postmastr); library(yaml)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_keys.R"))
source(file.path("R", "lib", "isochrones_dep.R"))
source(file.path("R", "lib", "address_parser_canonical.R"))
source(file.path("R", "lib", "duckdb_guards.R"))

# The SAME default as diagnose_unresolved_affiliations.R:58. Deliberately not
# the 2026 file: a newer vintage would reintroduce the very mismatch this
# script exists to remove.
NPPES <- Sys.getenv("NPPES_2025",
  "/Volumes/MufflySamsung 1/nppes_historical_downloads/extracted_2025/npidata_pfile_20050523-20251109.csv")
if (!file.exists(NPPES)) stop("NPPES 2025 not found: ", NPPES, call. = FALSE)

OUT <- "artifacts/address_parser_reconciliation.csv"
rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)

# --- the cohort, built exactly as production builds it -----------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("manifest|provenance", cw)]
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
spine <- rd(cw) %>% filter(!is.na(npi), nzchar(npi)) %>%
  distinct(certification_number = amcb_id, npi)
res <- rd("artifacts/organization_affiliation_resolved.csv")
status <- rd("artifacts/cohort_membership_four_way.csv") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  select(certification_number, status)

unres <- spine %>% left_join(status, by = "certification_number") %>%
  filter(status == "ACTIVE", !npi %in% res$npi)
cli::cli_alert_info("ACTIVE and unresolved: {format(nrow(unres), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "target", unres %>% select(npi))

SRC <- sprintf("read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)", NPPES)
COLS <- 'TRIM(CAST(d."NPI" AS VARCHAR)) AS npi,
  TRIM(CAST(d."Provider First Line Business Practice Location Address" AS VARCHAR)) AS addr,
  TRIM(CAST(d."Provider Business Practice Location Address Postal Code" AS VARCHAR)) AS zip,
  TRIM(CAST(d."Provider Business Practice Location Address Telephone Number" AS VARCHAR)) AS phone'
# Byte-for-byte the LIVE rule from diagnose_unresolved_affiliations.R. The
# reactivation clause is the part the earlier experiment dropped.
LIVE <- '(d."NPI Deactivation Date" IS NULL OR TRIM(CAST(d."NPI Deactivation Date" AS VARCHAR)) = \'\'
          OR (d."NPI Reactivation Date" IS NOT NULL AND TRIM(CAST(d."NPI Reactivation Date" AS VARCHAR)) <> \'\'))'

# One materialised pass over the 11.6 GB CSV. As a view, each of the queries
# below re-parses the whole file.
cli::cli_h2("Reading NPPES 2025")
dbExecute(con, sprintf(
  "CREATE OR REPLACE TABLE org2 AS SELECT %s FROM %s d
   WHERE TRIM(CAST(d.\"Entity Type Code\" AS VARCHAR)) = '2' AND %s", COLS, SRC, LIVE))
n_org <- dbGetQuery(con, "SELECT COUNT(*) n FROM org2")$n
cli::cli_alert_success("live Type-2 organizations (national, unrestricted): {format(n_org, big.mark = ',')}")

mw <- dbGetQuery(con, sprintf(
  'SELECT %s FROM %s d JOIN target t ON TRIM(CAST(d."NPI" AS VARCHAR)) = t.npi', COLS, SRC))
refuse_if_large(mw, "cohort NPPES rows")
cli::cli_alert_success("cohort rows found in NPPES: {format(nrow(mw), big.mark = ',')}")

# --- the phone key: address-free, so identical in all three arms -------------
# Computed once over the full national universe. Nothing here depends on the
# normaliser, so recomputing it per arm would cost three scans for one answer.
mw$kp <- phone10(mw$phone)
dbExecute(con, "CREATE OR REPLACE TABLE org_phone AS
  SELECT REGEXP_REPLACE(phone, '[^0-9]', '', 'g') AS kp, COUNT(DISTINCT npi) AS n
  FROM org2 WHERE LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '', 'g')) = 10 GROUP BY 1")
ph <- dbGetQuery(con, "SELECT * FROM org_phone")
phone_n <- setNames(ph$n, ph$kp)

# --- exact candidate reduction ----------------------------------------------
# See the header: an org can share an ADDRESS key with a cohort member only if
# it shares the ZIP5 and the leading house number. Two strata, because the
# house-number rule would silently drop every installation-name address.
house_no <- function(a) {
  a <- trimws(as.character(a))
  ifelse(grepl("^[0-9]+", a), sub("^([0-9]+).*$", "\\1", a), NA_character_)
}
mw$z5 <- zip5(mw$zip)
mw$hn <- house_no(mw$addr)

numbered <- mw %>% filter(!is.na(z5), !is.na(hn)) %>% distinct(z5, hn)
nameonly <- mw %>% filter(!is.na(z5), is.na(hn)) %>% distinct(z5)
cli::cli_alert_info("cohort with a house number: {sum(!is.na(mw$hn))}; without: {sum(is.na(mw$hn))}")

duckdb::duckdb_register(con, "cand_num", numbered)
duckdb::duckdb_register(con, "cand_name", nameonly)
cand <- dbGetQuery(con, "
  WITH k AS (
    SELECT *, SUBSTR(REGEXP_REPLACE(zip, '[^0-9]', '', 'g'), 1, 5) AS z5,
           CASE WHEN REGEXP_MATCHES(TRIM(addr), '^[0-9]+')
                THEN REGEXP_EXTRACT(TRIM(addr), '^[0-9]+') END AS hn
    FROM org2)
  SELECT k.npi, k.addr, k.zip, k.phone FROM k JOIN cand_num c ON c.z5 = k.z5 AND c.hn = k.hn
  UNION
  SELECT k.npi, k.addr, k.zip, k.phone FROM k JOIN cand_name c ON c.z5 = k.z5
    WHERE k.hn IS NULL")
refuse_if_large(cand, "candidate organizations")
cli::cli_alert_success("candidate organizations (exact, not sampled): {format(nrow(cand), big.mark = ',')} of {format(n_org, big.mark = ',')}")

# --- one classification per normaliser ---------------------------------------
RANK <- c(no_usable_key = 0L, key_matched_no_org = 1L,
          ambiguous_many_orgs = 2L, unique_org_available = 3L)

classify <- function(norm_fn, label) {
  cli::cli_h2(label)
  t0 <- Sys.time()
  mka <- norm_fn(mw$addr)
  oka <- norm_fn(cand$addr)
  cli::cli_alert_info("normalised {format(length(mka) + length(oka), big.mark = ',')} addresses in {round(as.numeric(difftime(Sys.time(), t0, units = 'mins')), 1)} min")

  m5 <- zip5(mw$zip); m9 <- zip9(mw$zip)
  o5 <- zip5(cand$zip); o9 <- zip9(cand$zip)

  mk <- list(
    key_zip5  = ifelse(!is.na(m5) & !is.na(mka), paste0("5:", m5, "|", mka), NA_character_),
    key_zip9  = ifelse(!is.na(m9) & !is.na(mka), paste0("9:", m9, "|", mka), NA_character_),
    key_phone = ifelse(!is.na(mw$kp), paste0("P:", mw$kp), NA_character_))
  ok <- list(
    key_zip5  = ifelse(!is.na(o5) & !is.na(oka), paste0("5:", o5, "|", oka), NA_character_),
    key_zip9  = ifelse(!is.na(o9) & !is.na(oka), paste0("9:", o9, "|", oka), NA_character_))

  reason <- setNames(rep("no_usable_key", nrow(mw)), mw$npi)
  n_at   <- setNames(rep(NA_integer_, nrow(mw)), mw$npi)

  bump <- function(keys, counts) {
    lab <- ifelse(is.na(counts), "key_matched_no_org",
                  ifelse(counts == 1L, "unique_org_available", "ambiguous_many_orgs"))
    lab[is.na(keys)] <- NA_character_
    ix <- !is.na(lab) & RANK[lab] > RANK[reason[mw$npi]]
    reason[mw$npi[ix]] <<- lab[ix]
    n_at[mw$npi[ix]]   <<- as.integer(counts[ix])
  }

  for (kn in c("key_zip5", "key_zip9")) {
    # DISTINCT organization NPIs per key, matching production: two rows for one
    # organization must not read as two organizations.
    cnt <- tibble(key = ok[[kn]], org = cand$npi) %>% filter(!is.na(key)) %>%
      distinct(key, org) %>% count(key, name = "n")
    n <- cnt$n[match(mk[[kn]], cnt$key)]
    bump(mk[[kn]], n)
  }
  bump(mk$key_phone, unname(phone_n[mw$kp]))

  tibble(parser = label, npi = mw$npi, reason = unname(reason),
         n_orgs_at_best_key = unname(n_at))
}

arms <- bind_rows(
  classify(norm_addr,           "norm_addr (production)"),
  classify(norm_addr_drop_unit, "norm_addr_drop_unit"),
  classify(function(a) norm_addr_canonical(a, quiet = TRUE), "canonical postmastr")
)

# --- the validation gate -----------------------------------------------------
# Arm 1 IS production. If it does not reproduce the published decomposition,
# every difference below is a harness artifact and no conclusion follows.
cli::cli_h2("Validation: does the production arm reproduce the published counts?")
published <- rd("artifacts/unresolved_affiliation_reasons.csv") %>%
  count(reason, name = "published")
repro <- arms %>% filter(parser == "norm_addr (production)") %>%
  count(reason, name = "reproduced")
cmp <- full_join(published, repro, by = "reason") %>%
  mutate(across(c(published, reproduced), ~tidyr::replace_na(., 0L)),
         delta = reproduced - published)
print(as.data.frame(cmp), row.names = FALSE)

VALID <- all(cmp$delta == 0L)
if (VALID) {
  cli::cli_alert_success("production arm reproduces the published decomposition exactly")
} else {
  cli::cli_alert_danger("production arm does NOT reproduce the published decomposition (max |delta| = {max(abs(cmp$delta))})")
  cli::cli_alert_warning("The comparison below is NOT interpretable. Fix the harness before reading it.")
}

# --- the three decompositions ------------------------------------------------
cli::cli_h2("Decomposition by parser")
dec <- arms %>% count(parser, reason) %>%
  tidyr::pivot_wider(names_from = reason, values_from = n, values_fill = 0L)
print(as.data.frame(dec), row.names = FALSE)

cli::cli_h2("Incremental effect versus the production parser")
base <- arms %>% filter(parser == "norm_addr (production)") %>%
  select(npi, base_reason = reason)
delta <- arms %>% filter(parser != "norm_addr (production)") %>%
  left_join(base, by = "npi") %>%
  group_by(parser) %>%
  summarise(
    newly_unique      = sum(reason == "unique_org_available" &
                            base_reason != "unique_org_available"),
    lost_unique       = sum(reason != "unique_org_available" &
                            base_reason == "unique_org_available"),
    no_org_to_matched = sum(base_reason == "key_matched_no_org" &
                            reason %in% c("unique_org_available", "ambiguous_many_orgs")),
    .groups = "drop") %>%
  mutate(net_unique = newly_unique - lost_unique)
print(as.data.frame(delta), row.names = FALSE)

# `lost_unique` is not a rounding artifact and is reported rather than netted
# away silently: a normaliser that merges two genuinely distinct suites turns a
# resolved midwife into an ambiguous one, and that is a cost, not noise.
if (any(delta$lost_unique > 0))
  cli::cli_alert_warning("a normaliser turned {max(delta$lost_unique)} resolved midwife/midwives AMBIGUOUS -- inspect before promoting")

summary_out <- dec %>%
  left_join(delta %>% select(parser, newly_unique, lost_unique, net_unique), by = "parser") %>%
  mutate(harness_validated = VALID, nppes_vintage = basename(NPPES),
         org_universe = n_org, candidate_orgs = nrow(cand))
write_with_provenance(summary_out, OUT, na = "", inputs = prov_inputs(c(NPPES, cw)))
cli::cli_alert_success("wrote {OUT}")

if (!VALID) quit(status = 1)
