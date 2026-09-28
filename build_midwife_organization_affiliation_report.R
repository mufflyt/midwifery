#!/usr/bin/env Rscript
# =============================================================================
# Person-level reported organization affiliations
# =============================================================================
# These are organization relationships reported by source systems, not verified
# employment relationships. Multiple rows per midwife and source are retained.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
art <- file.path(root, "artifacts")
out <- file.path(art, "midwife_organization_affiliation_report.csv")

work_raw <- read_csv(file.path(art, "midwife_work_sites_summary.csv"),
                     show_col_types = FALSE, progress = FALSE)

cohort <- work_raw %>%
  transmute(certification_number, npi, first_name, last_name,
            nppes_state)

work <- work_raw %>%
  transmute(
    certification_number,
    npi,
    first_name,
    last_name,
    nppes_state,
    organization_npi = NA_character_,
    organization_name = na_if(trimws(trilliant_primary_org), ""),
    source = "Trilliant provider directory",
    relationship = "Claims-associated primary organization",
    evidence = "Trilliant claims-derived organization field") %>%
  filter(!is.na(organization_name))

nppes <- read_csv(file.path(art, "midwife_org_person.csv"),
                  show_col_types = FALSE, progress = FALSE) %>%
  transmute(
    certification_number,
    npi,
    first_name = NA_character_,
    last_name = NA_character_,
    nppes_state = NA_character_,
    organization_npi = as.character(org_npi),
    organization_name = na_if(trimws(organization_name), ""),
    source = "NPPES Type-2 organization match",
    relationship = "Organization sharing the midwife's registered practice contact",
    evidence = paste0("NPPES ", loc_type, " location / telephone match")) %>%
  filter(!is.na(organization_name))

report <- bind_rows(work, nppes) %>%
  distinct(certification_number, organization_npi, organization_name, source,
           relationship, evidence, .keep_all = TRUE) %>%
  arrange(certification_number, source, organization_name)

missing <- cohort %>%
  anti_join(distinct(report, certification_number), by = "certification_number") %>%
  mutate(organization_npi = NA_character_, organization_name = NA_character_,
         source = "No reported organization",
         relationship = "No organization signal available in the included sources",
         evidence = NA_character_)
report <- bind_rows(report, missing) %>%
  arrange(certification_number, source, organization_name)

if (!nrow(report)) stop("No organization rows were available; refusing to write an empty report.", call. = FALSE)
write_csv(report, out, na = "")
cat(sprintf("wrote %s (%s rows; %s midwives)\n", out, nrow(report),
            dplyr::n_distinct(report$certification_number)))
