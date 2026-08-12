#!/usr/bin/env Rscript
# =============================================================================
# DIAGNOSTIC audit of the Python Open Payments -> Type-2 organization matcher
# =============================================================================
# This is a DIAGNOSTIC recomputation, not a repaired production matcher. It
# does not change limit=10, does not pick a different candidate, and does not
# write any production artifact. It answers one question: what survives when
# arbitrary first-candidate assignment is removed?
#
# THE DEFECT BEING AUDITED, in crossref_all_open_payments_type2.py:
#   line 68  "limit": 10          - the NPPES API returns organizations in
#                                   ALPHABETICAL order (verified live), so a
#                                   ZIP holding 200+ Type-2 organizations is
#                                   truncated to the alphabetically first ten.
#                                   Anything after roughly "C" is unreachable.
#   line 88  op_addr_clean[:8] in a1 || a1[:8] in op_addr_clean
#                                 - a bidirectional EIGHT-CHARACTER substring
#                                   test, so "1 PARK A" matches "11 PARK AVE".
#   line 89  return {...}         - inside the candidate loop: the first
#                                   passing candidate wins, silently.
# The query keys on city/state/ZIP only; the street address is never sent.
#
# NO INTENT IS INFERRED. This is characterised as an arbitrary-selection defect
# arising from an incomplete, ordered candidate universe plus loose address
# matching. Nothing here describes what anyone meant to do.
#
# PINNED BULK VINTAGE, NOT THE LIVE API. The candidate universe is rebuilt from
# the local bulk NPPES Type-2 table so the audit is reproducible. An audit that
# depended on whatever the API returned today could not be re-run.
#
# Outputs (audit path only, nothing production):
#   artifacts/audit/python_selection_defect_records.csv
#   artifacts/audit/python_forensic_sample.csv
#   artifacts/audit/cross_method_comparison.csv
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
  library(stringr); library(tibble)
})
source("R/lib/common_helpers.R")
dir.create("artifacts/audit", showWarnings = FALSE, recursive = TRUE)

DB <- Sys.getenv("MEDICARE_DUCKDB",
                 "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb")
API_LIMIT <- 10L   # the value the Python matcher used; audited, not changed

norm_addr <- function(x) {
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
zip5 <- function(x) str_extract(as.character(x), "[0-9]{5}")

# --- their assignments -------------------------------------------------------
th <- chr("artifacts/cohort_midwives_open_payments_type2_organizations_full.csv")
# "ADDR, CITY, ST ZIP" -> parts
th <- th %>%
  mutate(op_addr  = str_trim(str_split_fixed(open_payments_address, ",", 3)[, 1]),
         op_city  = str_trim(str_split_fixed(open_payments_address, ",", 3)[, 2]),
         tail_    = str_trim(str_split_fixed(open_payments_address, ",", 3)[, 3]),
         op_state = str_extract(tail_, "^[A-Z]{2}"),
         op_zip   = zip5(tail_),
         op_addr_norm = norm_addr(op_addr))
cat(sprintf("Python assignments audited: %s (%s midwives)\n",
            format(nrow(th), big.mark = ","),
            format(n_distinct(th$certification_number), big.mark = ",")))
cat(sprintf("  parsed a usable ZIP for: %s\n",
            format(sum(!is.na(th$op_zip)), big.mark = ",")))

# --- complete Type-2 candidate universe, from the pinned bulk file -----------
con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
org <- dbGetQuery(con, "
  SELECT CAST(npi AS VARCHAR) AS type2_npi, organization_name,
         practice_address_street AS addr, practice_address_zip AS zip,
         taxonomy_1 AS taxonomy
    FROM npi_org_all
   WHERE NULLIF(TRIM(organization_name), '') IS NOT NULL") %>%
  mutate(z5 = zip5(zip), addr_norm = norm_addr(addr)) %>%
  filter(!is.na(z5))
cat(sprintf("bulk Type-2 organizations (pinned): %s\n", format(nrow(org), big.mark = ",")))

zip_size <- org %>% count(z5, name = "n_orgs_in_zip")

# Alphabetical position of the selected organization within its ZIP. The API
# returns names in alphabetical order, so this is how far into the list the
# selection sits -- and whether limit=10 could ever have reached it.
org_rank <- org %>% arrange(z5, organization_name) %>%
  group_by(z5) %>% mutate(alpha_rank = row_number()) %>% ungroup() %>%
  select(type2_npi, z5, alpha_rank)

a <- th %>%
  left_join(zip_size, by = c("op_zip" = "z5")) %>%
  left_join(org_rank %>% select(type2_npi, alpha_rank),
            by = c("type2_organization_npi" = "type2_npi")) %>%
  left_join(org %>% select(type2_npi, sel_addr_norm = addr_norm),
            by = c("type2_organization_npi" = "type2_npi")) %>%
  mutate(
    n_orgs_in_zip = coalesce(n_orgs_in_zip, 0L),
    truncated_universe = n_orgs_in_zip > API_LIMIT,
    # Exact evidence: does the selected organization's own registered street
    # address equal the Open Payments address after normalization?
    exact_addr_match = !is.na(sel_addr_norm) & !is.na(op_addr_norm) &
                        sel_addr_norm == op_addr_norm,
    # Would the 8-character test have passed where exact equality fails? Those
    # are the assignments that exist only because the test is loose.
    substr8_only = !exact_addr_match & !is.na(sel_addr_norm) & !is.na(op_addr_norm) &
      (str_starts(sel_addr_norm, fixed(substr(op_addr_norm, 1, 8))) |
       str_starts(op_addr_norm, fixed(substr(sel_addr_norm, 1, 8)))),
    reachable_within_limit = !is.na(alpha_rank) & alpha_rank <= API_LIMIT)

# Complete street-compatible candidate set per record: every organization in
# the same ZIP whose normalized address equals the Open Payments address.
cand <- th %>% select(certification_number, midwife_npi, op_zip, op_addr_norm) %>%
  filter(!is.na(op_zip), !is.na(op_addr_norm)) %>%
  inner_join(org, by = c("op_zip" = "z5", "op_addr_norm" = "addr_norm"),
             relationship = "many-to-many") %>%
  group_by(certification_number) %>%
  summarise(n_exact_candidates = n_distinct(type2_npi),
            exact_candidate_npis = paste(unique(type2_npi), collapse = ";"),
            exact_candidate_names = paste(unique(organization_name), collapse = " | "),
            .groups = "drop")

a <- a %>% left_join(cand, by = "certification_number") %>%
  mutate(n_exact_candidates = coalesce(n_exact_candidates, 0L),
         status = case_when(
           n_exact_candidates == 1L ~ "unique_exact",
           n_exact_candidates >  1L ~ "multiple_plausible",
           n_orgs_in_zip == 0L      ~ "incomplete_candidate_universe",
           TRUE                     ~ "no_match"))

cat("\n=== 1. CONSERVATIVE RECLASSIFICATION ===\n")
print(a %>% count(status, sort = TRUE) %>% as.data.frame())

cat("\n=== 3. DEFECT EXPOSURE (overlaps reported, not summed) ===\n")
f <- function(x, lab) cat(sprintf("  %-56s %5s (%.1f%%)\n", lab,
                                  format(sum(x), big.mark = ","), 100*mean(x)))
cat(sprintf("  total Python assignments%*s%5s\n", 32, "", format(nrow(a), big.mark = ",")))
f(a$truncated_universe,      "exposed to >10 Type-2 orgs in their ZIP (truncated)")
f(a$reachable_within_limit,  "selected org within the alphabetical first 10")
f(a$exact_addr_match,        "selected org matches OP address EXACTLY")
f(a$substr8_only,            "selected only via the 8-character substring test")
f(a$status == "unique_exact","remain uniquely defensible (unique exact match)")
f(a$status == "multiple_plausible", "become AMBIGUOUS (several exact candidates)")
f(a$status %in% c("no_match", "incomplete_candidate_universe"),
  "become UNMATCHED / universe incomplete")
cat(sprintf("\n  overlap: truncated AND not exact-matched: %s\n",
            format(sum(a$truncated_universe & !a$exact_addr_match), big.mark = ",")))
cat(sprintf("  overlap: truncated AND within first 10:    %s\n",
            format(sum(a$truncated_universe & a$reachable_within_limit), big.mark = ",")))

write_csv(a %>% select(certification_number, midwife_npi, open_payments_address,
                       op_zip, n_orgs_in_zip, type2_organization_name,
                       type2_organization_npi, alpha_rank, truncated_universe,
                       reachable_within_limit, exact_addr_match, substr8_only,
                       n_exact_candidates, exact_candidate_names, status),
          "artifacts/audit/python_selection_defect_records.csv", na = "")

# --- 2. forensic sample ------------------------------------------------------
implausible <- "ANESTH|PSYCHIATR|ARTHRITIS|TRANSPORT|DENTAL|OPTOM|OPHTHAL|PODIATR|CHIROPRAC|\\.COM"
forensic <- a %>%
  filter(truncated_universe) %>%
  mutate(implaus = str_detect(toupper(type2_organization_name), implausible)) %>%
  arrange(desc(implaus), desc(n_orgs_in_zip)) %>%
  head(12) %>%
  select(certification_number, open_payments_address, op_zip, n_orgs_in_zip,
         selected = type2_organization_name, alpha_rank, exact_addr_match,
         n_exact_candidates, defensible_candidates = exact_candidate_names, status)
write_csv(forensic, "artifacts/audit/python_forensic_sample.csv", na = "")
cat("\n=== 2. FORENSIC SAMPLE (worst cases) ===\n")
print(forensic %>% select(op_zip, n_orgs_in_zip, selected, alpha_rank,
                          exact_addr_match, n_exact_candidates) %>% as.data.frame())

# --- 4. corrected cross-method comparison -----------------------------------
mine <- chr("artifacts/midwife_org_affiliations_candidate.csv")
py_unique <- a %>% filter(status == "unique_exact") %>%
  transmute(certification_number,
            py_npi = if_else(n_exact_candidates == 1L,
                             exact_candidate_npis, NA_character_))
r_by <- mine %>% group_by(certification_number) %>%
  summarise(r_npis = paste(unique(type2_npi), collapse = ";"), .groups = "drop")

cmp <- full_join(py_unique, r_by, by = "certification_number") %>%
  mutate(py_res = !is.na(py_npi), r_res = !is.na(r_npis),
         agree = py_res & r_res &
           mapply(function(p, r) p %in% str_split(r, ";")[[1]], py_npi, r_npis))
both <- cmp %>% filter(py_res, r_res)
cat("\n=== 4. CORRECTED CROSS-METHOD COMPARISON ===\n")
cat(sprintf("  A. R resolves, corrected Python ambiguous/unmatched: %s\n",
            format(sum(cmp$r_res & !cmp$py_res), big.mark = ",")))
cat(sprintf("  B. corrected Python resolves, R does not          : %s\n",
            format(sum(cmp$py_res & !cmp$r_res), big.mark = ",")))
cat(sprintf("  C+D. both resolve                                 : %s\n",
            format(nrow(both), big.mark = ",")))
if (nrow(both)) {
  cat(sprintf("     C. agree (same Type-2 NPI): %s (%.1f%%)\n",
              format(sum(both$agree), big.mark = ","), 100*mean(both$agree)))
  cat(sprintf("     D. disagree               : %s\n",
              format(sum(!both$agree), big.mark = ",")))
  cat(sprintf("\n  >>> NEW AGREEMENT RATE (both uniquely resolve): %.1f%%  (was 16.4%%)\n",
              100*mean(both$agree)))
}
write_csv(cmp, "artifacts/audit/cross_method_comparison.csv", na = "")
cat("\nwritten: artifacts/audit/ (diagnostic only, no production artifact touched)\n")
