#!/usr/bin/env Rscript
#' @title Can any discriminating signal resolve the ambiguous 835? And what are the 702?
#'
#' @description
#' The unresolved ACTIVE cohort splits into two problems that must not be
#' collapsed, because they need opposite treatments:
#'
#'   835 (54.1%)  candidate organizations exist; the shared key does not
#'                discriminate between them. A LINKAGE problem.
#'   702 (45.5%)  no Type-2 organization at the address at all. Not a linkage
#'                failure -- possibly a practice-structure finding.
#'
#' Zero have unique evidence the resolver failed to use, so tie-breaking on the
#' existing keys is exhausted. The only way forward is a signal ORTHOGONAL to
#' address and phone.
#'
#' @section EVERYTHING HEAVY HAPPENS IN SQL, and that is a correctness rule:
#' The first version of this script keyed 8,910,888 NPPES rows in R. It
#' garbage-collection thrashed at ~19% CPU and was killed after 20 minutes of
#' CPU time without producing output. That was the THIRD time in one session
#' that a large NPPES table was pulled into R after the lesson had been written
#' down, so the rule is now enforced by refuse_if_large() below rather than by
#' remembering it. R receives only the small candidate-level result.
#'
#' @section What counts as resolved:
#' The fail-closed rule is unchanged: a midwife is resolved only when a signal
#' leaves EXACTLY ONE candidate. A signal that narrows five candidates to two
#' has not resolved anything, and is reported as narrowing. No signal picks
#' "the most plausible" candidate.
#'
#' @section The density thresholds are EXPLORATORY, and labelled so:
#' The <=10 and <=3 clinician cutoffs were chosen by the author, not derived
#' from a rule specified independently of these 835 cases. A threshold that
#' happens to leave one organization standing can MANUFACTURE uniqueness. Their
#' rows are reported as exploratory and must not be read as yield until an
#' independently-specified rule replaces them. Where candidates share one
#' address, density is identical evidence for all of them and discriminates
#' nothing -- the output records that case separately.
#'
#' Care Compare and PECOS are deliberately not tested: every one of these
#' midwives is by construction invisible to those arms, so the result is a
#' guaranteed zero and the scan would be wasted.
#'
#' Inputs : NPPES_2025 dissemination; artifacts/unresolved_affiliation_reasons.csv
#' Outputs: artifacts/unresolved_disambiguation_candidates.csv (person-level, gitignored)
#'          artifacts/unresolved_disambiguation_yield.csv       (tracked)
#'          artifacts/unresolved_no_org_character.csv           (tracked)
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

source(file.path("R", "lib", "medicare_duckdb.R"))

NPPES <- Sys.getenv("NPPES_2025", "")
if (!nzchar(NPPES))
  NPPES <- samsung_volume_path(file.path("nppes_historical_downloads",
                                         "extracted_2025",
                                         "npidata_pfile_20050523-20251109.csv"))
OUT_C <- "artifacts/unresolved_disambiguation_candidates.csv"
OUT_Y <- "artifacts/unresolved_disambiguation_yield.csv"
OUT_N <- "artifacts/unresolved_no_org_character.csv"

rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)
reasons <- rd("artifacts/unresolved_affiliation_reasons.csv")
amb   <- reasons$npi[reasons$reason == "ambiguous_many_orgs"]
noorg <- reasons$npi[reasons$reason == "key_matched_no_org"]
cli::cli_alert_info("ambiguous: {format(length(amb), big.mark = ',')}; no-organization: {format(length(noorg), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "amb",   data.frame(npi = amb,   stringsAsFactors = FALSE))
duckdb::duckdb_register(con, "noorg", data.frame(npi = noorg, stringsAsFactors = FALSE))

# --- keying in SQL -----------------------------------------------------------
# A deliberately SIMPLER normalisation than R/lib/address_keys.R: upper-case,
# strip non-alphanumerics, collapse spaces. It does not abbreviate street types.
# That makes it slightly stricter than norm_addr(), so it can only MISS matches,
# never invent them -- the safe direction for an experiment asking "is there a
# discriminating signal here at all".
cli::cli_h2("Building keyed NPPES view in DuckDB")
dbExecute(con, sprintf("
CREATE OR REPLACE VIEW npi_keyed AS
SELECT TRIM(CAST(\"NPI\" AS VARCHAR)) AS npi,
       TRIM(CAST(\"Entity Type Code\" AS VARCHAR)) AS entity,
       TRIM(CAST(\"Provider Organization Name (Legal Business Name)\" AS VARCHAR)) AS org_name,
       TRIM(CAST(\"Healthcare Provider Taxonomy Code_1\" AS VARCHAR)) AS tax1,
       TRIM(CAST(\"Provider First Line Business Practice Location Address\" AS VARCHAR)) AS addr,
       REGEXP_REPLACE(UPPER(TRIM(CAST(\"Provider First Line Business Practice Location Address\" AS VARCHAR))), '[^A-Z0-9]+', ' ', 'g') AS ka,
       SUBSTR(REGEXP_REPLACE(TRIM(CAST(\"Provider Business Practice Location Address Postal Code\" AS VARCHAR)), '[^0-9]', '', 'g'), 1, 5) AS k5,
       REGEXP_REPLACE(TRIM(CAST(\"Provider Business Practice Location Address Telephone Number\" AS VARCHAR)), '[^0-9]', '', 'g') AS kp
FROM read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)
WHERE (\"NPI Deactivation Date\" IS NULL OR TRIM(CAST(\"NPI Deactivation Date\" AS VARCHAR)) = ''
       OR (\"NPI Reactivation Date\" IS NOT NULL AND TRIM(CAST(\"NPI Reactivation Date\" AS VARCHAR)) <> ''))", NPPES))

dbExecute(con, "CREATE OR REPLACE VIEW keyed AS
  SELECT *, CASE WHEN LENGTH(k5)=5 AND LENGTH(TRIM(ka))>0 THEN k5 || '|' || TRIM(ka) END AS key_addr,
            CASE WHEN LENGTH(kp)=10 THEN 'P:' || kp END AS key_phone FROM npi_keyed")

# Clinician density per address key, computed once in SQL over all Type-1 NPIs.
dbExecute(con, "CREATE OR REPLACE TABLE dens AS
  SELECT key_addr, COUNT(*) AS n_clin FROM keyed
  WHERE entity='1' AND key_addr IS NOT NULL GROUP BY key_addr")
cli::cli_alert_success("density table: {format(dbGetQuery(con,'SELECT COUNT(*) n FROM dens')$n, big.mark = ',')} address keys")

# --- candidates for the ambiguous group, aggregated in SQL -------------------
cli::cli_h2("Candidates (SQL)")
cand <- dbGetQuery(con, "
WITH mw AS (SELECT k.npi, k.key_addr, k.key_phone FROM keyed k JOIN amb a ON k.npi=a.npi),
     org AS (SELECT npi AS org_npi, org_name, tax1 AS org_tax, key_addr AS org_key_addr, key_phone
             FROM keyed WHERE entity='2'),
     by_addr AS (SELECT mw.npi, o.org_npi, o.org_name, o.org_tax, o.org_key_addr, 'address' AS via
                 FROM mw JOIN org o ON o.org_key_addr = mw.key_addr WHERE mw.key_addr IS NOT NULL),
     by_phone AS (SELECT mw.npi, o.org_npi, o.org_name, o.org_tax, o.org_key_addr, 'phone' AS via
                  FROM mw JOIN org o ON o.key_phone = mw.key_phone WHERE mw.key_phone IS NOT NULL),
     u AS (SELECT * FROM by_addr UNION SELECT * FROM by_phone)
SELECT u.npi, u.org_npi, u.org_name, u.org_tax, u.org_key_addr, u.via,
       COALESCE(d.n_clin, 0) AS n_clinicians_at_org_addr
FROM u LEFT JOIN dens d ON d.key_addr = u.org_key_addr")
refuse_if_large(cand, "candidate query")
cli::cli_alert_success("candidate pairs: {format(nrow(cand), big.mark = ',')} over {format(dplyr::n_distinct(cand$npi), big.mark = ',')} midwives")

# --- signal 1: taxonomy compatibility ---------------------------------------
# Deliberately INCLUSIVE. The job is to exclude the dialysis centre sharing a
# building, not to guess which clinic is likeliest; an over-narrow list would
# manufacture uniqueness.
COMPATIBLE <- c("261Q", "282N", "282E", "3416", "251E", "207V", "363L", "176B",
                "281P", "273Y", "261QM", "261QP", "261QB", "282NC")
cand <- cand %>%
  mutate(tax_compatible = vapply(toupper(replace(org_tax, is.na(org_tax), "")),
                                 function(t) any(startsWith(t, COMPATIBLE)),
                                 logical(1), USE.NAMES = FALSE))

# Does density discriminate at all for this midwife, or is it identical across
# candidates? If identical it supplies ZERO information and must not be scored.
disc <- cand %>% group_by(npi) %>%
  summarise(n_cand = dplyr::n(),
            density_discriminates = dplyr::n_distinct(n_clinicians_at_org_addr) > 1L,
            .groups = "drop")

# --- yield -------------------------------------------------------------------
cli::cli_h2("Yield")
n_amb <- dplyr::n_distinct(cand$npi)
tally <- function(d, label, exploratory = FALSE) {
  s <- d %>% count(npi, name = "k")
  gone <- setdiff(unique(cand$npi), s$npi)
  tibble::tibble(signal = label,
                 resolved_uniquely = sum(s$k == 1L),
                 narrowed_still_ambiguous = sum(s$k > 1L),
                 eliminated_all_candidates = length(gone),
                 pct_resolved = round(100 * sum(s$k == 1L) / n_amb, 1),
                 exploratory = exploratory)
}
yield <- bind_rows(
  tally(cand, "0 baseline (no signal)"),
  tally(cand %>% filter(tax_compatible), "1 taxonomy compatible"),
  tally(cand %>% filter(n_clinicians_at_org_addr <= 10L), "2 org address <=10 clinicians", TRUE),
  tally(cand %>% filter(n_clinicians_at_org_addr <= 3L),  "3 org address <=3 clinicians", TRUE),
  tally(cand %>% filter(tax_compatible, n_clinicians_at_org_addr <= 10L), "1+2 cumulative", TRUE),
  tally(cand %>% filter(tax_compatible, n_clinicians_at_org_addr <= 3L),  "1+2+3 cumulative", TRUE)
) %>% mutate(n_ambiguous_input = n_amb)
print(as.data.frame(yield), row.names = FALSE)

cli::cli_alert_info("density supplies NO discrimination for {format(sum(!disc$density_discriminates), big.mark = ',')} of {format(nrow(disc), big.mark = ',')} midwives (all candidates share one clinician count)")

# --- adversarial: removing a signal must undo what it resolved ---------------
cli::cli_h2("Leave-one-out")
res_tax <- cand %>% filter(tax_compatible) %>% count(npi, name = "k") %>% filter(k == 1L) %>% pull(npi)
back <- cand %>% filter(npi %in% res_tax) %>% count(npi, name = "k")
still_unique_without <- sum(back$k == 1L)
cli::cli_alert_info("taxonomy resolved {length(res_tax)}; of those, {still_unique_without} remain unique WITHOUT it")
if (length(res_tax) && still_unique_without == length(res_tax))
  cli::cli_alert_danger("taxonomy supplied NO discrimination -- those cases were already unique; investigate")
if (length(res_tax) && still_unique_without == 0L)
  cli::cli_alert_success("every case taxonomy resolved reverts to ambiguous without it: the signal did the work")

write_with_provenance(cand %>% left_join(disc, by = "npi"), OUT_C, na = "",
                      inputs = prov_inputs(NPPES))
write_with_provenance(yield, OUT_Y, na = "", inputs = prov_inputs(OUT_C))

# --- the 702, characterised in NEUTRAL terms --------------------------------
# "Residential" is an inference, not a measurement. These labels describe what
# was observed -- clinician count and suite designator -- and stop there.
cli::cli_h2("No-organization group")
nc <- dbGetQuery(con, "
SELECT CASE WHEN COALESCE(d.n_clin,0) <= 1 AND NOT has_suite THEN 'single_clinician_no_suite'
            WHEN COALESCE(d.n_clin,0) <= 1                    THEN 'single_clinician_with_suite'
            WHEN COALESCE(d.n_clin,0) <= 5                    THEN 'few_clinicians_same_address'
            WHEN k.key_addr IS NULL                           THEN 'address_unclassifiable'
            ELSE 'many_clinicians_same_address_no_type2_org' END AS character,
       COUNT(*) AS n
FROM (SELECT k.*, REGEXP_MATCHES(UPPER(k.addr), '(STE|SUITE|APT|UNIT|#)') AS has_suite
      FROM keyed k JOIN noorg n ON k.npi=n.npi) k
LEFT JOIN dens d ON d.key_addr = k.key_addr
GROUP BY 1 ORDER BY n DESC")
nc <- nc %>% mutate(pct = round(100 * n / sum(n), 1))
print(as.data.frame(nc), row.names = FALSE)
write_with_provenance(nc, OUT_N, na = "", inputs = prov_inputs(NPPES))
cli::cli_alert_success("wrote {OUT_C}, {OUT_Y}, {OUT_N}")
