#!/usr/bin/env Rscript
#' @title Many clinicians, no organization: keying failure or facility registered elsewhere?
#'
#' @description
#' 113 unresolved ACTIVE midwives sit at an address shared with many other
#' clinicians, yet no live Type-2 organization keys to that address. That
#' combination should be rare: where several clinicians practise together, an
#' organizational NPI usually exists. It is the last unexplained group, and the
#' explanation changes what the 702 "no organization" count means.
#'
#' @section The two hypotheses this separates, and why it matters:
#'
#'   H1 KEYING FAILURE. The organization is there, but its address string keys
#'      differently -- a suite on one record and not the other, "BLDG A", "ST"
#'      versus "STREET". This would be OUR defect, it would mean the 702 count
#'      is too high, and it would cast doubt on the no-organization
#'      classification generally.
#'
#'   H3 REGISTERED ELSEWHERE. The organization exists but its NPPES address is
#'      a headquarters or parent site, not the clinic. Hospital departments,
#'      VA sites, university clinics and FQHC satellites routinely do this. Not
#'      an error -- a structural feature of NPPES -- and it would mean these
#'      midwives are facility-affiliated in a way the address graph cannot show.
#'
#' @section The discriminator:
#' TELEPHONE. It is orthogonal to the address string, so it is unaffected by
#' address normalisation.
#'
#'   a Type-2 shares the PHONE but sits at a DIFFERENT address  -> H3
#'   a Type-2 is at a NEARLY IDENTICAL address (same ZIP + same
#'     street number) but keys differently                      -> H1
#'   neither                                                    -> H2/H4/H5,
#'     reported as unexplained rather than assigned a story
#'
#' Both tests are run for every case, because they are not exclusive: a hospital
#' campus can produce both signals, and a case matching both is reported as
#' such rather than forced into one bucket.
#'
#' @section What this does NOT do:
#' It does not resolve affiliations. A phone-sharing organization at another
#' address is evidence about the MECHANISM, not a defensible affiliation for
#' this midwife -- the fail-closed rule still applies, and a shared switchboard
#' at a hospital is not an employer.
#'
#' Inputs : NPPES_2026 dissemination, artifacts/unresolved_affiliation_reasons.csv
#' Outputs: artifacts/no_org_anomaly_mechanism.csv (tracked summary)
#'          artifacts/no_org_anomaly_cases.csv     (person-level, gitignored)
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
source(file.path("R", "lib", "duckdb_guards.R"))

NPPES <- Sys.getenv("NPPES_2026",
  "/Volumes/MufflySamsung 1/nppes_historical_downloads/extracted_2026/npidata_pfile_20050523-20260809.csv")
if (!file.exists(NPPES)) stop("NPPES 2026 not found: ", NPPES, call. = FALSE)

reasons <- read_csv("artifacts/unresolved_affiliation_reasons.csv",
                    col_types = cols(.default = "c"), progress = FALSE)
noorg <- reasons$npi[reasons$reason == "key_matched_no_org"]
cli::cli_alert_info("no-organization group: {format(length(noorg), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "noorg", data.frame(npi = noorg, stringsAsFactors = FALSE))

# One keyed view. Everything downstream is SQL over this.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE k AS
SELECT TRIM(CAST(\"NPI\" AS VARCHAR)) AS npi,
       TRIM(CAST(\"Entity Type Code\" AS VARCHAR)) AS entity,
       TRIM(CAST(\"Provider Organization Name (Legal Business Name)\" AS VARCHAR)) AS org_name,
       TRIM(CAST(\"Provider First Line Business Practice Location Address\" AS VARCHAR)) AS addr,
       TRIM(CAST(\"Provider Business Practice Location Address City Name\" AS VARCHAR)) AS city,
       TRIM(CAST(\"Provider Business Practice Location Address State Name\" AS VARCHAR)) AS st,
       SUBSTR(REGEXP_REPLACE(TRIM(CAST(\"Provider Business Practice Location Address Postal Code\" AS VARCHAR)),'[^0-9]','','g'),1,5) AS z5,
       REGEXP_REPLACE(UPPER(TRIM(CAST(\"Provider First Line Business Practice Location Address\" AS VARCHAR))),'[^A-Z0-9]+',' ','g') AS ka,
       REGEXP_REPLACE(TRIM(CAST(\"Provider Business Practice Location Address Telephone Number\" AS VARCHAR)),'[^0-9]','','g') AS kp,
       TRIM(CAST(\"NPI Deactivation Date\" AS VARCHAR)) AS deact,
       TRIM(CAST(\"NPI Reactivation Date\" AS VARCHAR)) AS react
FROM read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)", NPPES))

# MATERIALISED, not a view. `k` reads an 11.6 GB CSV; as a view every
# downstream query re-parses the whole file, and this script issues six of
# them. One scan into a table, then everything else is in-memory.
dbExecute(con, "CREATE OR REPLACE TABLE kk AS
  SELECT *, CASE WHEN LENGTH(z5)=5 AND LENGTH(TRIM(ka))>0 THEN z5 || '|' || TRIM(ka) END AS key_addr,
            -- the STREET NUMBER only: the part least mangled by suite text,
            -- abbreviation or building names. Used for the H1 relaxed match.
            CASE WHEN LENGTH(z5)=5 THEN z5 || '#' || REGEXP_EXTRACT(TRIM(ka), '^[0-9]+') END AS key_loose,
            (deact IS NULL OR deact='' OR (react IS NOT NULL AND react<>'')) AS live
  FROM k")

dbExecute(con, "CREATE OR REPLACE TABLE dens AS
  SELECT key_addr, COUNT(*) n_clin FROM kk WHERE entity='1' AND key_addr IS NOT NULL GROUP BY key_addr")

# The anomaly set: many co-located clinicians, no LIVE Type-2 at the exact key.
dbExecute(con, "CREATE OR REPLACE TABLE anom AS
  WITH mw AS (SELECT kk.* FROM kk JOIN noorg n ON kk.npi=n.npi WHERE kk.entity='1'),
       -- NOT NULL is load-bearing. key_addr is NULL wherever the ZIP or street
       -- is unusable, and `x NOT IN (set containing NULL)` is never TRUE in
       -- SQL -- it yields UNKNOWN. Without this filter the anomaly set came
       -- back EMPTY and looked like a clean null result rather than a bug.
       live2 AS (SELECT DISTINCT key_addr FROM kk
                 WHERE entity='2' AND live AND key_addr IS NOT NULL)
  SELECT m.npi, m.addr, m.city, m.st, m.z5, m.ka, m.kp, m.key_addr, m.key_loose, d.n_clin
  FROM mw m JOIN dens d ON d.key_addr=m.key_addr
  WHERE d.n_clin > 5
    AND NOT EXISTS (SELECT 1 FROM live2 l WHERE l.key_addr = m.key_addr)")
n_anom <- dbGetQuery(con, "SELECT COUNT(*) n FROM anom")$n
cli::cli_alert_success("anomaly cases (>5 clinicians, no live Type-2 at the exact key): {n_anom}")

# --- the discriminating tests ------------------------------------------------
# Built as PRECOMPUTED AGGREGATES then joined, not correlated subqueries. The
# first version put four correlated subqueries in the SELECT, each rescanning
# an 8.9M-row view per anomaly row; it ran 12 minutes at 30% CPU without
# finishing. Aggregate once, join once.
dbExecute(con, "CREATE OR REPLACE TABLE org_by_phone AS
  SELECT kp, key_addr, COUNT(DISTINCT npi) n_org, MIN(org_name) example
  FROM kk WHERE entity='2' AND live AND LENGTH(kp)=10 GROUP BY kp, key_addr")
dbExecute(con, "CREATE OR REPLACE TABLE org_by_loose AS
  SELECT key_loose, key_addr, COUNT(DISTINCT npi) n_org, MIN(org_name) example
  FROM kk WHERE entity='2' AND live AND key_loose IS NOT NULL GROUP BY key_loose, key_addr")
dbExecute(con, "CREATE OR REPLACE TABLE org_dead_here AS
  SELECT key_addr, COUNT(DISTINCT npi) n_org FROM kk
  WHERE entity='2' AND NOT live AND key_addr IS NOT NULL GROUP BY key_addr")

res <- dbGetQuery(con, "
SELECT a.npi, a.addr, a.city, a.st, a.n_clin,
       COALESCE(p.n_org, 0)  AS h3_phone_org_elsewhere,
       p.example             AS h3_example_org,
       COALESCE(l.n_org, 0)  AS h1_loose_org_same_building,
       l.example             AS h1_example_org,
       COALESCE(x.n_org, 0)  AS deactivated_org_here
FROM anom a
LEFT JOIN (SELECT kp, SUM(n_org) n_org, MIN(example) example FROM org_by_phone GROUP BY kp) p
       ON p.kp = a.kp AND LENGTH(a.kp) = 10
LEFT JOIN (SELECT key_loose, SUM(n_org) n_org, MIN(example) example FROM org_by_loose GROUP BY key_loose) l
       ON l.key_loose = a.key_loose
LEFT JOIN org_dead_here x ON x.key_addr = a.key_addr")
refuse_if_large(res, "anomaly discriminator")

res <- res %>% mutate(
  mechanism = case_when(
    h1_loose_org_same_building > 0 & h3_phone_org_elsewhere > 0 ~ "both_signals",
    h1_loose_org_same_building > 0                              ~ "H1_keying_failure",
    h3_phone_org_elsewhere > 0                                  ~ "H3_org_registered_elsewhere",
    deactivated_org_here > 0                                    ~ "org_deactivated_here",
    TRUE                                                        ~ "unexplained"))

cli::cli_h2("Mechanism")
tab <- res %>% count(mechanism, sort = TRUE) %>% mutate(pct = round(100 * n / sum(n), 1))
print(as.data.frame(tab), row.names = FALSE)

cli::cli_h2("Examples")
for (m in setdiff(tab$mechanism, "unexplained")) {
  ex <- res %>% filter(mechanism == m) %>%
    transmute(addr = substr(addr, 1, 34), city, st, n_clin,
              org = substr(coalesce(h1_example_org, h3_example_org, ""), 1, 34)) %>%
    head(4)
  cat("\n", m, ":\n", sep = "")
  print(as.data.frame(ex), row.names = FALSE)
}

write_with_provenance(tab, "artifacts/no_org_anomaly_mechanism.csv", na = "",
                      inputs = prov_inputs(NPPES))
write_with_provenance(res, "artifacts/no_org_anomaly_cases.csv", na = "",
                      inputs = prov_inputs(NPPES))
cli::cli_alert_success("wrote artifacts/no_org_anomaly_mechanism.csv and _cases.csv")
