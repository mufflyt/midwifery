#!/usr/bin/env Rscript
#' @title Do NPPES endpoints or secondary locations resolve the unresolved 1,544?
#'
#' @description
#' The primary NPPES address graph has reached its information ceiling. Taxonomy
#' compatibility bought ~107 of 835 ambiguous cases; clinician density was
#' destructive; and ~709 still have several MATERNITY-COMPATIBLE organizations
#' at one address, which no address-derived signal can separate.
#'
#' This tests two sources that are not more address heuristics:
#'
#'   ENDPOINT REFERENCE FILE. Carries `Affiliation Legal Business Name` and an
#'   affiliation address per NPI. That is the provider ASSERTING an
#'   organizational association, not us inferring one from a shared building. It
#'   is therefore stronger evidence than co-location and outranks it.
#'
#'   PRACTICE LOCATION REFERENCE FILE. Non-primary practice locations. Aimed at
#'   the 702 with no organization at their PRIMARY address: a midwife whose
#'   primary NPPES address is administrative or residential may have the actual
#'   clinic recorded as a secondary location. Still location-derived, so it is
#'   kept as a separate, weaker evidence class.
#'
#' @section Evidence ranking, stated so it cannot drift:
#'   1 endpoint affiliation   an explicit asserted organization
#'   2 secondary location     co-location, at a different address
#' A conflict between them is reported, never silently resolved by precedence.
#'
#' @section Fail-closed, unchanged:
#' Resolved means EXACTLY ONE organization survives. Several remains ambiguous.
#' No endpoint is absence of evidence, never evidence of no affiliation.
#'
#' @section ONE VINTAGE THROUGHOUT:
#' Provider, endpoint and practice-location files all come from the 2026-08-09
#' dissemination. An earlier draft paired 2024-12 reference files with a 2025-11
#' provider file; every count would then have been an upper bound, because a
#' midwife who moved between those dates could match a stale organization.
#'
#' Inputs : NPPES_2025 provider file, ENDPOINT_FILE, PL_FILE,
#'          artifacts/unresolved_affiliation_reasons.csv
#' Outputs: artifacts/endpoint_location_yield.csv        (tracked)
#'          artifacts/endpoint_location_candidates.csv   (person-level, gitignored)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "org_names.R"))

source(file.path("R", "lib", "duckdb_guards.R"))

source(file.path("R", "lib", "medicare_duckdb.R"))
BASE  <- samsung_volume_path("nppes_historical_downloads")
# ALL THREE FROM ONE DISSEMINATION (2026-08-09). The first draft of this
# experiment paired 2024-12 reference files with a 2025-11 provider file, which
# would have made every count an upper bound: a midwife who moved between the
# two dates could match a stale organization. Same vintage throughout turns the
# result from an upper bound into a measurement.
V2026 <- file.path(BASE, "extracted_2026")
NPPES <- Sys.getenv("NPPES_2026",    file.path(V2026, "npidata_pfile_20050523-20260809.csv"))
ENDP  <- Sys.getenv("ENDPOINT_FILE", file.path(V2026, "endpoint_pfile_20050523-20260809.csv"))
PLF   <- Sys.getenv("PL_FILE",       file.path(V2026, "pl_pfile_20050523-20260809.csv"))
for (f in c(NPPES, ENDP, PLF))
  if (!file.exists(f)) stop("missing input: ", f, call. = FALSE)

OUT_Y <- "artifacts/endpoint_location_yield.csv"
OUT_C <- "artifacts/endpoint_location_candidates.csv"

rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)
reasons <- rd("artifacts/unresolved_affiliation_reasons.csv")
grp <- reasons %>% select(npi, reason)
cli::cli_alert_info("unresolved cohort: {format(nrow(grp), big.mark = ',')}")
print(as.data.frame(count(grp, reason, sort = TRUE)), row.names = FALSE)

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "tgt", grp)

# --- source 1: endpoint affiliations -----------------------------------------
cli::cli_h2("Endpoint affiliations")
ep <- dbGetQuery(con, sprintf("
  SELECT TRIM(CAST(e.\"NPI\" AS VARCHAR)) AS npi,
         TRIM(CAST(e.\"Affiliation\" AS VARCHAR)) AS affiliation_flag,
         TRIM(CAST(e.\"Affiliation Legal Business Name\" AS VARCHAR)) AS affil_name,
         TRIM(CAST(e.\"Affiliation Address Line One\" AS VARCHAR)) AS affil_addr,
         TRIM(CAST(e.\"Affiliation Address Postal Code\" AS VARCHAR)) AS affil_zip
  FROM read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE) e
  JOIN tgt t ON TRIM(CAST(e.\"NPI\" AS VARCHAR)) = t.npi", ENDP))
refuse_if_large(ep, "endpoint join")
cli::cli_alert_success("endpoint rows for the cohort: {format(nrow(ep), big.mark = ',')} over {format(dplyr::n_distinct(ep$npi), big.mark = ',')} midwives")

ep_named <- ep %>% filter(!is.na(affil_name), nzchar(affil_name)) %>%
  mutate(org_key = norm_org(affil_name)) %>% filter(nzchar(org_key))
ep_unique <- ep_named %>% distinct(npi, org_key, .keep_all = TRUE) %>%
  count(npi, name = "n_orgs") %>% filter(n_orgs == 1L)
cli::cli_alert_info("midwives with an endpoint affiliation NAME: {format(dplyr::n_distinct(ep_named$npi), big.mark = ',')}")
cli::cli_alert_info("of those, exactly ONE distinct organization named: {format(nrow(ep_unique), big.mark = ',')}")

# --- source 2: secondary practice locations ----------------------------------
cli::cli_h2("Secondary practice locations")
pl <- dbGetQuery(con, sprintf("
  SELECT TRIM(CAST(p.\"NPI\" AS VARCHAR)) AS npi,
         REGEXP_REPLACE(UPPER(TRIM(CAST(p.\"Provider Secondary Practice Location Address- Address Line 1\" AS VARCHAR))), '[^A-Z0-9]+', ' ', 'g') AS ka,
         SUBSTR(REGEXP_REPLACE(TRIM(CAST(p.\"Provider Secondary Practice Location Address - Postal Code\" AS VARCHAR)), '[^0-9]', '', 'g'),1,5) AS k5
  FROM read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE) p
  JOIN tgt t ON TRIM(CAST(p.\"NPI\" AS VARCHAR)) = t.npi", PLF))
refuse_if_large(pl, "practice location join")
cli::cli_alert_success("secondary locations for the cohort: {format(nrow(pl), big.mark = ',')} over {format(dplyr::n_distinct(pl$npi), big.mark = ',')} midwives")

# Type-2 organizations keyed the same way, in SQL.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE org2 AS
SELECT TRIM(CAST(\"NPI\" AS VARCHAR)) AS org_npi,
       TRIM(CAST(\"Provider Organization Name (Legal Business Name)\" AS VARCHAR)) AS org_name,
       SUBSTR(REGEXP_REPLACE(TRIM(CAST(\"Provider Business Practice Location Address Postal Code\" AS VARCHAR)), '[^0-9]', '', 'g'),1,5)
         || '|' || REGEXP_REPLACE(UPPER(TRIM(CAST(\"Provider First Line Business Practice Location Address\" AS VARCHAR))), '[^A-Z0-9]+', ' ', 'g') AS key_addr
FROM read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)
WHERE TRIM(CAST(\"Entity Type Code\" AS VARCHAR)) = '2'
  AND (\"NPI Deactivation Date\" IS NULL OR TRIM(CAST(\"NPI Deactivation Date\" AS VARCHAR)) = ''
       OR (\"NPI Reactivation Date\" IS NOT NULL AND TRIM(CAST(\"NPI Reactivation Date\" AS VARCHAR)) <> ''))", NPPES))
cli::cli_alert_success("Type-2 organizations keyed: {format(dbGetQuery(con,'SELECT COUNT(*) n FROM org2')$n, big.mark = ',')}")

pl_keyed <- pl %>% filter(nchar(k5) == 5, nzchar(trimws(ka))) %>%
  mutate(key_addr = paste0(k5, "|", trimws(ka))) %>% distinct(npi, key_addr)
duckdb::duckdb_register(con, "plk", pl_keyed)
pl_match <- dbGetQuery(con, "
  SELECT p.npi, COUNT(DISTINCT o.org_npi) AS n_orgs,
         MIN(o.org_npi) AS one_org_npi, MIN(o.org_name) AS one_org_name
  FROM plk p JOIN org2 o ON o.key_addr = p.key_addr GROUP BY p.npi")
pl_unique <- pl_match %>% filter(n_orgs == 1L)
cli::cli_alert_info("midwives whose SECONDARY location matches exactly one organization: {format(nrow(pl_unique), big.mark = ',')}")

# --- yield by original group -------------------------------------------------
cli::cli_h2("Yield by group")
mark <- grp %>%
  mutate(endpoint_resolved = npi %in% ep_unique$npi,
         endpoint_any      = npi %in% ep_named$npi,
         location_resolved = npi %in% pl_unique$npi,
         location_any      = npi %in% pl$npi)

# NOTE: compute the combined columns BEFORE summarise. Naming a summarise
# output the same as its input column shadows it, so a later expression sees the
# scalar just computed rather than the original logical vector -- which silently
# turned "either resolved" into the group size.
mark <- mark %>% mutate(either_resolved = endpoint_resolved | location_resolved,
                        both_resolved   = endpoint_resolved & location_resolved)
yield <- mark %>% group_by(reason) %>%
  summarise(n = dplyr::n(),
            endpoint_evidence = sum(endpoint_any),
            endpoint_resolved = sum(endpoint_resolved),
            secondary_evidence = sum(location_any),
            secondary_resolved = sum(location_resolved),
            either_resolved = sum(either_resolved),
            both_resolved = sum(both_resolved),
            .groups = "drop") %>%
  mutate(pct_either = round(100 * either_resolved / n, 1))
print(as.data.frame(yield), row.names = FALSE)

tot <- mark %>% summarise(n = dplyr::n(),
                          either = sum(endpoint_resolved | location_resolved))
cli::cli_alert_success("TOTAL newly resolvable: {format(tot$either, big.mark = ',')} of {format(tot$n, big.mark = ',')} ({round(100*tot$either/tot$n,1)}%)")

# Agreement between the two sources, where both fire. A disagreement is a
# finding, not something to resolve by precedence.
both <- mark %>% filter(endpoint_resolved, location_resolved) %>% pull(npi)
if (length(both)) {
  a <- ep_named %>% filter(npi %in% both) %>% distinct(npi, org_key)
  b <- pl_match %>% filter(npi %in% both) %>% transmute(npi, org_key_b = norm_org(one_org_name))
  cmp <- a %>% inner_join(b, by = "npi") %>% mutate(agree = org_key == org_key_b)
  cli::cli_alert_info("both sources fired for {length(both)}; agree on the organization: {sum(cmp$agree)}; DISAGREE: {sum(!cmp$agree)}")
}

write_with_provenance(yield, OUT_Y, na = "", inputs = prov_inputs(c(ENDP, PLF, NPPES)))
write_with_provenance(mark, OUT_C, na = "", inputs = prov_inputs(c(ENDP, PLF)))
cli::cli_alert_success("wrote {OUT_Y} and {OUT_C}")
