#!/usr/bin/env Rscript
# =============================================================================
# Build the canonical 13-field long-format source-record table
# =============================================================================
# Schema: docs/canonical-source-record-schema.md. Each longitudinal source is
# read from its existing per-source artifact and mapped onto the shared shape;
# fields a source does not publish are NA, never invented. Rows are tagged
# `reconstruction_version = "canonical_v1"` so no future rebuild under
# different rules can be pooled silently with this one.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (npi -> amcb_id)
#          midwife_panel.csv                      (nppes)
#          artifacts/pecos_revalidation_cohort_state_by_year.csv
#          artifacts/cohort_midwives_medicare_claims_state_by_year.csv
#          artifacts/open_payments_midwife_presence_by_year.csv
#          artifacts/medicaid_enrollment_cohort_state_by_year.csv
# Output : artifacts/canonical_source_records.csv
#          artifacts/canonical_source_records_field_coverage.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

OUT <- "artifacts/canonical_source_records.csv"
COV <- "artifacts/canonical_source_records_field_coverage.csv"
VERSION <- "canonical_v1"

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                 col_select = c(npi, amcb_id, cohort_member),
                 col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>%
  transmute(npi = trimws(npi), amcb_id) %>%
  distinct()

# Every per-source block reshapes its own file to at least npi/year/state;
# optional: source_record_id, evidence_type, snapshot_date, effective_date,
# vintage, usable_for_trend. canon() supplies the remaining defaults.
canon <- function(df, source, evidence_type = "observed",
                  vintage = NA_character_, usable = TRUE) {
  n <- nrow(df)
  tibble(
    amcb_id = NA_character_,
    npi = trimws(df$npi),
    source = source,
    source_record_id = if ("source_record_id" %in% names(df)) df$source_record_id else NA_character_,
    year = as.integer(df$year),
    state = clean_state(df$state),
    evidence_type = if ("evidence_type" %in% names(df)) df$evidence_type else evidence_type,
    snapshot_date = if ("snapshot_date" %in% names(df)) df$snapshot_date else NA_character_,
    effective_date = if ("effective_date" %in% names(df)) df$effective_date else NA_character_,
    vintage = if ("vintage" %in% names(df)) df$vintage else vintage,
    usable_for_trend = if ("usable_for_trend" %in% names(df)) df$usable_for_trend else usable,
    source_hash = NA_character_,
    reconstruction_version = VERSION
  ) %>% filter(!is.na(state), !is.na(year))
}

parts <- list()

parts$nppes <- read_csv("midwife_panel.csv",
                        col_select = c(npi, snapshot_year, snapshot_date, practice_state),
                        col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, year = snapshot_year, state = practice_state,
            snapshot_date = substr(snapshot_date, 1, 10)) %>%
  canon("nppes", vintage = "NPPES annual dissemination")

parts$pecos_revalidation <- read_csv(
  "artifacts/pecos_revalidation_cohort_state_by_year.csv",
  col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, year, state = pecos_state, vintage) %>%
  canon("pecos_revalidation", evidence_type = "administrative")

parts$medicare_claims <- read_csv(
  "artifacts/cohort_midwives_medicare_claims_state_by_year.csv",
  col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, year, state) %>%
  canon("medicare_claims", evidence_type = "derived",
        vintage = "CMS by-provider claims files, lineage-collapsed")

parts$open_payments <- read_csv(
  "artifacts/open_payments_midwife_presence_by_year.csv",
  col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, year = program_year, state, evidence_type,
            usable_for_trend = usable_for_trend == "TRUE") %>%
  canon("open_payments", vintage = "CMS Open Payments general payments")

parts$medicaid_enrollment <- read_csv(
  "artifacts/medicaid_enrollment_cohort_state_by_year.csv",
  col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, year, state, evidence_type,
            usable_for_trend = left_censored == "FALSE") %>%
  canon("medicaid_enrollment", vintage = "T-MSIS enrollment segments 2026-07-24")

records <- bind_rows(parts) %>%
  # The canonical table is defined ON the frozen cohort, like every other
  # analysis here; midwife_panel.csv covers a far wider NPI universe.
  semi_join(link %>% select(npi), by = "npi") %>%
  left_join(link, by = "npi") %>%
  mutate(amcb_id = dplyr::coalesce(amcb_id.y, amcb_id.x)) %>%
  select(amcb_id, npi, source, source_record_id, year, state, evidence_type,
         snapshot_date, effective_date, vintage, usable_for_trend,
         source_hash, reconstruction_version)

coverage <- records %>%
  group_by(source) %>%
  summarise(
    n_rows = dplyr::n(),
    n_npis = dplyr::n_distinct(npi),
    pct_amcb_id = round(100 * mean(!is.na(amcb_id)), 1),
    pct_snapshot_date = round(100 * mean(!is.na(snapshot_date)), 1),
    pct_effective_date = round(100 * mean(!is.na(effective_date)), 1),
    pct_usable_for_trend = round(100 * mean(usable_for_trend), 1),
    .groups = "drop")

write_with_provenance(records %>% arrange(source, npi, year), OUT,
                      inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv"), na = "")
write_with_provenance(coverage, COV, na = "")
print(as.data.frame(coverage), row.names = FALSE)
cat(sprintf("canonical_source_records: %s rows, %s NPIs, %d sources\n",
            format(nrow(records), big.mark = ","),
            format(dplyr::n_distinct(records$npi), big.mark = ","),
            dplyr::n_distinct(records$source)))
