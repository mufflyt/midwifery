#!/usr/bin/env Rscript
# =============================================================================
# Why do the two corrected methods disagree? Classification by cause
# =============================================================================
# 20 midwives are resolved uniquely by BOTH the corrected bulk Open Payments
# matcher and the R practice-location resolver, to DIFFERENT organizations.
# With the arbitrary-selection defect removed these are no longer artefacts of
# candidate ordering, so each one is a substantive disagreement about where a
# midwife works.
#
# THIS SCRIPT DOES NOT ADJUDICATE. It classifies the CAUSE so the cases can be
# reviewed efficiently; it does not decide which method is right. Deciding by
# rule here would be exactly the "pick the more plausible organization" move
# that was rejected earlier.
#
# CAUSES, tested in order of specificity. The first matching cause is assigned
# and the full set of matched causes is also recorded, because several can be
# true at once and reporting only the first would understate the overlap:
#
#   organization_name_normalization
#       Different Type-2 NPIs whose names normalize to the same string --
#       duplicate registrations of one organization, not a real conflict.
#   same_address_collision
#       Both organizations are registered at the SAME normalized address. The
#       evidence cannot separate them; neither method is wrong.
#   different_source_location
#       The two methods used DIFFERENT addresses. The Open Payments business
#       address and the NPPES practice location disagree, so the methods are
#       answering about different places. Sub-classified by whether the R
#       evidence came from a primary or secondary NPPES location.
#   evidence_key_strength
#       R resolved on a weaker key (ZIP5) than an exact address match.
#   address_normalization
#       The addresses differ only after normalization is accounted for.
#   other
#
# Input : artifacts/audit/cross_method_comparison.csv
#         artifacts/midwife_org_affiliations_candidate.csv
#         artifacts/open_payments_recent_address.csv
#         artifacts/midwife_practice_locations.csv
# Output: artifacts/audit/residual_disagreements_classified.csv
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
  library(stringr); library(tibble); library(tidyr)
})
source("R/lib/common_helpers.R")
source("link_open_payments_type2_bulk.R")   # op_norm_addr(), op_zip5()

source(file.path("R", "lib", "medicare_duckdb.R"))
DB <- resolve_midwifery_duckdb()

# norm_org() moved to R/lib/org_names.R when the affiliation resolver became a
# second caller. Defined once, so the two callers cannot drift apart on what
# counts as the same organization.
source(file.path("R", "lib", "org_names.R"))

# THE TWO PIPELINES DO NOT READ THE SAME OPEN PAYMENTS ADDRESS. The Python
# path takes it from CMS_Open_Payments_Profile_Supplement.csv (a profile
# address); this project's path takes the most recent
# Recipient_Primary_Business_Street_Address_Line1 from the yearly tables. Where
# those differ the methods were never answering the same question, and the
# disagreement is not a matching failure. This is tested FIRST because it
# subsumes the others.
th_src <- chr("artifacts/cohort_midwives_open_payments_type2_organizations_full.csv") %>%
  transmute(certification_number,
            th_op_addr = op_norm_addr(str_trim(
              str_split_fixed(open_payments_address, ",", 3)[, 1])))

cmp <- chr("artifacts/audit/cross_method_comparison.csv")
dis <- cmp %>% filter(!is.na(py_npi), !is.na(r_npis), agree == "FALSE")
cat(sprintf("residual disagreements to classify: %d\n", nrow(dis)))

mine <- chr("artifacts/midwife_org_affiliations_candidate.csv")
opa  <- chr("artifacts/open_payments_recent_address.csv")
locs <- chr("artifacts/midwife_practice_locations.csv")

con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
org <- dbGetQuery(con, "
  SELECT CAST(npi AS VARCHAR) AS npi, organization_name,
         practice_address_street AS addr, practice_address_zip AS zip,
         taxonomy_1 AS taxonomy
    FROM npi_org_all") %>%
  mutate(addr_norm = op_norm_addr(addr), z5 = op_zip5(zip),
         name_norm = norm_org(organization_name))

# One row per (midwife, R-assigned organization): a midwife may hold several.
r_long <- dis %>%
  select(certification_number, r_npis) %>%
  separate_rows(r_npis, sep = ";") %>%
  rename(r_npi = r_npis) %>%
  left_join(mine %>% select(certification_number, type2_npi,
                            r_method = resolution_method,
                            r_key = evidence_key,
                            r_conf = affiliation_confidence),
            by = c("certification_number", "r_npi" = "type2_npi"))

# An organization NPI can hold SEVERAL registered addresses in npi_org_all, so
# joining by NPI alone attaches one arbitrary address and then asks whether it
# equals the Open Payments address. That produced py_at_op_addr = FALSE for
# organizations the bulk matcher had matched ON that very address, and
# multiplied the row count. Collapse to one row per NPI, and test address
# agreement as SET MEMBERSHIP over all of that NPI's addresses.
org_addr_set <- org %>% filter(!is.na(addr_norm), !is.na(z5)) %>%
  distinct(npi, addr_norm, z5)
has_addr <- function(npi_vec, addr_vec, zip_vec) {
  key_have <- paste(org_addr_set$npi, org_addr_set$addr_norm, org_addr_set$z5)
  paste(npi_vec, addr_vec, zip_vec) %in% key_have
}
org_one <- org %>%
  group_by(npi) %>%
  summarise(organization_name = first(organization_name),
            name_norm = first(name_norm), taxonomy = first(taxonomy),
            addr_norm = paste(sort(unique(addr_norm[!is.na(addr_norm)])), collapse = " ;; "),
            z5 = paste(sort(unique(z5[!is.na(z5)])), collapse = ";"),
            .groups = "drop")

d <- dis %>%
  left_join(org_one %>% select(npi, py_name = organization_name,
                               py_addr = addr_norm, py_zip = z5,
                               py_name_norm = name_norm, py_tax = taxonomy),
            by = c("py_npi" = "npi")) %>%
  left_join(r_long, by = "certification_number", relationship = "one-to-many") %>%
  left_join(org_one %>% select(npi, r_name = organization_name,
                               r_addr = addr_norm, r_zip = z5,
                               r_name_norm = name_norm, r_tax = taxonomy),
            by = c("r_npi" = "npi")) %>%
  left_join(opa %>% transmute(certification_number,
                              op_addr = op_norm_addr(addr), op_zip = op_zip5(zip)),
            by = "certification_number")

# Did the R evidence come from a primary or a secondary NPPES location?
loc_type <- locs %>%
  mutate(addr_norm = op_norm_addr(addr)) %>%
  group_by(certification_number) %>%
  summarise(has_primary = any(loc_type == "primary"),
            has_secondary = any(loc_type == "secondary"),
            r_loc_addrs = paste(unique(addr_norm), collapse = " ;; "),
            .groups = "drop")
d <- d %>% left_join(loc_type, by = "certification_number") %>%
  left_join(th_src, by = "certification_number") %>%
  mutate(op_source_differs = !is.na(th_op_addr) & !is.na(op_addr) &
                               th_op_addr != op_addr)

d <- d %>%
  mutate(
    same_name       = !is.na(py_name_norm) & !is.na(r_name_norm) &
                        nzchar(py_name_norm) & py_name_norm == r_name_norm,
    # Set membership over every address the NPI registers, not equality
    # against one arbitrarily chosen address.
    same_address    = has_addr(py_npi, op_addr, op_zip) &
                        has_addr(r_npi, op_addr, op_zip),
    r_at_op_addr    = has_addr(r_npi, op_addr, op_zip),
    py_at_op_addr   = has_addr(py_npi, op_addr, op_zip),
    weak_r_key      = !is.na(r_key) & str_detect(r_key, "zip5"),
    r_from_secondary = coalesce(has_secondary, FALSE) & !r_at_op_addr)

# All matching causes, then the most specific one.
d <- d %>%
  mutate(causes = pmap_chr <- NA_character_) %>% select(-causes)
d$causes <- apply(d, 1, function(row) {
  cs <- character(0)
  if (isTRUE(as.logical(row[["op_source_differs"]]))) cs <- c(cs, "open_payments_address_source_difference")
  if (isTRUE(as.logical(row[["same_name"]])))    cs <- c(cs, "organization_name_normalization")
  if (isTRUE(as.logical(row[["same_address"]]))) cs <- c(cs, "same_address_collision")
  if (!isTRUE(as.logical(row[["r_at_op_addr"]]))) cs <- c(cs, "different_source_location")
  if (isTRUE(as.logical(row[["weak_r_key"]])))   cs <- c(cs, "evidence_key_strength")
  if (!length(cs)) cs <- "other"
  paste(cs, collapse = "+")
})
d <- d %>%
  mutate(primary_cause = case_when(
    op_source_differs ~ "open_payments_address_source_difference",
    same_name        ~ "organization_name_normalization",
    same_address     ~ "same_address_collision",
    !r_at_op_addr & coalesce(has_secondary, FALSE) ~ "different_source_location_secondary",
    !r_at_op_addr    ~ "different_source_location",
    weak_r_key       ~ "evidence_key_strength",
    TRUE             ~ "other"))

cat("\n=== PRIMARY CAUSE (one per midwife-pair) ===\n")
print(d %>% count(primary_cause, sort = TRUE) %>% as.data.frame())

cat("\n=== ALL MATCHING CAUSES (overlaps visible) ===\n")
print(d %>% count(causes, sort = TRUE) %>% as.data.frame())

cat("\n=== does either organization sit at the Open Payments address? ===\n")
print(d %>% count(py_at_op_addr, r_at_op_addr) %>% as.data.frame())

cat("\n=== sample cases ===\n")
print(d %>%
        transmute(cert = certification_number,
                  py = str_trunc(py_name, 34), r = str_trunc(r_name, 34),
                  r_key, cause = str_trunc(primary_cause, 34)) %>%
        head(12) %>% as.data.frame())

out <- d %>%
  select(certification_number, op_addr, op_zip,
         py_npi, py_name, py_addr, py_tax,
         r_npi, r_name, r_addr, r_tax, r_method, r_key, r_conf,
         th_op_addr, op_source_differs,
         same_name, same_address, py_at_op_addr, r_at_op_addr,
         has_primary, has_secondary, causes, primary_cause) %>%
  mutate(human_verdict = "", correct_method = "", review_notes = "")
write_csv(out, "artifacts/audit/residual_disagreements_classified.csv", na = "")
cat(sprintf("\nwritten: artifacts/audit/residual_disagreements_classified.csv (%d rows)\n",
            nrow(out)))
cat("human_verdict / correct_method / review_notes are blank for adjudication.\n")
