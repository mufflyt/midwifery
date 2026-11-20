#!/usr/bin/env Rscript
# =============================================================================
# Exercise every mysteryroster "no gold standard" comparison-toolkit function
# that has never yet run on real midwifery data, against real data.
# =============================================================================
# Scope: the 15 functions added in mysteryroster PR #37 (location
# specificity, spatial concordance, hierarchical fusion, mover/stayer,
# enumeration lifecycle, verification sample design, OIG HTML, audit diff,
# normalization, vintage audit) plus 8 pre-existing functions that had only
# ever run on synthetic examples (agreement_add_ci, agreement_by_covariate,
# catch_up_curve_prose, consensus_tier_flow, claims_collapse_lineage,
# truth_fusion_prose, format_proportion_comparison_prose, format_ranking_prose).
#
# All real data: the canonical AMCB-linked midwife cohort, 2019 relational
# PECOS (ppef_enrol/ppef_reassign/ppef_addr_2019, same tables and
# construction as remake_oig_07_09_00440_midwifery.R), 2019 NPPES
# (midwife_panel.csv), DAC historical (physician_compare_historical_midwives.csv),
# PECOS revalidation state-by-year, T-MSIS Medicaid enrollment state-by-year,
# and the geocoded frozen cohort.
#
# Outputs: artifacts/no_gold_standard_run/*.csv (+ .provenance.json sidecars)
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
  library(tibble)
  library(mysteryroster)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "oig_zip_normalizers.R"))

OUT_DIR <- file.path("artifacts", "no_gold_standard_run")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
out <- function(name) file.path(OUT_DIR, name)

FROZEN_PATH <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
stopifnot(file.exists(FROZEN_PATH))
verify_linkage_freeze(FROZEN_PATH)

# =============================================================================
# 0. Cohort and real source tables
# =============================================================================
lnk_raw <- read_csv(FROZEN_PATH, col_types = cols(.default = "c"), progress = FALSE)
cohort_active <- canonical_active_primary(lnk_raw) %>%
  mutate(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
stopifnot(!anyDuplicated(cohort_active$npi))
cat(sprintf("Canonical active primary-linked AMCB cohort: N = %d unique NPIs\n", nrow(cohort_active)))

con <- open_medicare_duckdb(read_only = TRUE)
on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
DBI::dbWriteTable(con, "tmp_cohort_active", tibble(npi = cohort_active$npi), temporary = TRUE, overwrite = TRUE)

pecos_enrl_2019 <- DBI::dbGetQuery(con, "
  SELECT CAST(e.npi AS VARCHAR) AS npi, TRIM(e.enrlmt_id) AS enrlmt_id
  FROM main.ppef_enrol_2019 e
  INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
")
pecos_reassign_2019 <- DBI::dbGetQuery(con, "
  SELECT DISTINCT CAST(e.npi AS VARCHAR) AS npi,
    TRIM(r.reasgn_bnft_enrlmt_id) AS reasgn_bnft_enrlmt_id,
    TRIM(r.rcv_bnft_enrlmt_id) AS rcv_bnft_enrlmt_id
  FROM main.ppef_enrol_2019 e
  INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
  INNER JOIN main.ppef_reassign_2019 r ON TRIM(e.enrlmt_id) = TRIM(r.reasgn_bnft_enrlmt_id)
")
pecos_addr_2019 <- DBI::dbGetQuery(con, "
  SELECT TRIM(a.enrlmt_id) AS enrlmt_id, TRIM(a.city_name) AS city_name,
    a.zip_cd AS zip_cd, TRIM(a.state_cdstr) AS state_cdstr
  FROM main.ppef_addr_2019 a
  WHERE TRIM(a.enrlmt_id) IN (
    SELECT TRIM(e.enrlmt_id) FROM main.ppef_enrol_2019 e INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
    UNION
    SELECT TRIM(r.rcv_bnft_enrlmt_id)
    FROM main.ppef_enrol_2019 e
    INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
    INNER JOIN main.ppef_reassign_2019 r ON TRIM(e.enrlmt_id) = TRIM(r.reasgn_bnft_enrlmt_id)
  )
")
cat(sprintf("Real PECOS 2019 (cohort-filtered): %d enrollment edges, %d reassignment edges, %d raw address rows\n",
            nrow(pecos_enrl_2019), nrow(pecos_reassign_2019), nrow(pecos_addr_2019)))

nppes_2019_panel <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year == "2019") %>%
  mutate(npi = trimws(npi)) %>%
  semi_join(cohort_active, by = "npi")
stopifnot(!anyDuplicated(nppes_2019_panel$npi))
cat(sprintf("Real NPPES 2019 panel (cohort-filtered): %d rows\n", nrow(nppes_2019_panel)))

indiv_edges_2019 <- pecos_enrl_2019 %>%
  transmute(npi = trimws(npi), year = 2019L, enrollment_id = trimws(enrlmt_id)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(enrollment_id), nzchar(enrollment_id)) %>%
  distinct()
reassign_edges_2019 <- pecos_reassign_2019 %>%
  transmute(npi = trimws(npi), year = 2019L, enrollment_id = trimws(rcv_bnft_enrlmt_id)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(enrollment_id), nzchar(enrollment_id)) %>%
  distinct()
loc_2019 <- pecos_addr_2019 %>%
  mutate(
    year = 2019L,
    enrollment_id = trimws(enrlmt_id),
    practice_zip5 = norm_pecos_bigint_zip5(zip_cd),
    practice_state = clean_state(state_cdstr),
    practice_city = toupper(trimws(city_name))
  ) %>%
  filter(!is.na(enrollment_id), nzchar(enrollment_id)) %>%
  distinct(year, enrollment_id, practice_zip5, practice_state, practice_city) %>%
  mutate(location_id = sprintf("LOC2019_%06d", row_number()))

pecos_linkage_2019 <- attribute_enrollment_locations(
  individual_enrollments = indiv_edges_2019,
  reassignments = reassign_edges_2019,
  locations = loc_2019
)
cat("Built real attribute_enrollment_locations() linkage for 2019.\n")

# =============================================================================
# 1. normalize_directory_attribute() -- real messy directory strings
# =============================================================================
cat("\n--- 1. normalize_directory_attribute() ---\n")
raw_zip_sample <- nppes_2019_panel$practice_zip
norm_zip_real <- normalize_directory_attribute(raw_zip_sample, normalizer = "zip5")
n_restored <- sum(nchar(trimws(raw_zip_sample)) < 5 & norm_zip_real$format_valid, na.rm = TRUE)
cat(sprintf("Real ZIP5 normalization (cohort, 2019): %d raw values, %d required leading-zero restoration, %d failed format validation\n",
            length(raw_zip_sample), n_restored, sum(!norm_zip_real$format_valid, na.rm = TRUE)))

raw_credential_sample <- nppes_2019_panel$credential
norm_cred_real <- normalize_directory_attribute(raw_credential_sample, normalizer = "credential_token")
cred_tbl <- tibble(raw = raw_credential_sample,
                    normalized = norm_cred_real$normalized_value,
                    format_valid = norm_cred_real$format_valid) %>%
  count(raw, normalized, format_valid, sort = TRUE)
write_with_provenance(cred_tbl, out("normalize_credential_real_2019.csv"),
                       inputs = "midwife_panel.csv")
cat(sprintf("Real credential normalization: %d distinct raw strings -> %d distinct normalized tokens\n",
            n_distinct(raw_credential_sample), n_distinct(norm_cred_real$normalized_value, na.rm = TRUE)))

norm_npi_real <- normalize_directory_attribute(nppes_2019_panel$npi, normalizer = "npi10")
cat(sprintf("Real NPI10 Luhn check: %d of %d real NPIs pass check digit validation\n",
            sum(norm_npi_real$format_valid, na.rm = TRUE), length(norm_npi_real$format_valid)))

# =============================================================================
# 2. attribute_source_vintage_audit() -- real DAC vs PECOS sub-feed coverage
# =============================================================================
cat("\n--- 2. attribute_source_vintage_audit() ---\n")
dac_hist <- read_csv("artifacts/physician_compare_historical_midwives.csv",
                      col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4))) %>%
  semi_join(cohort_active, by = "npi") %>%
  filter(!is.na(year)) %>%
  distinct(npi, year)
pecos_reval <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv",
                         col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi), year = as.integer(year)) %>%
  semi_join(cohort_active, by = "npi") %>%
  distinct(npi, year)
vintage_population <- expand_grid(npi = cohort_active$npi,
                                   year = sort(union(dac_hist$year, pecos_reval$year)))
vintage_res_real <- attribute_source_vintage_audit(
  population = vintage_population,
  sources = list(dac = dac_hist, pecos_reval = pecos_reval),
  source_families = list(medicare_combined = c("dac", "pecos_reval")),
  jump_threshold_pct = 15.0
)
write_with_provenance(vintage_res_real$family_decomposition, out("source_vintage_audit_real.csv"),
                       inputs = c("artifacts/physician_compare_historical_midwives.csv",
                                  "artifacts/pecos_revalidation_cohort_state_by_year.csv"))
print(vintage_res_real$flagged_discontinuities)

# =============================================================================
# 3-5. Enrollment linkage trio (cardinality, specificity, topology) -- real 2019 PECOS
# =============================================================================
cat("\n--- 3. attribute_enrollment_cardinality_audit() ---\n")
# raw_suite_rows must represent a layer MORE raw than
# attribute_enrollment_locations()'s own linked-rows output -- a would-be
# suite/floor-level join row count before any collapse. nrow(pecos_addr_2019)
# is the wrong layer entirely: it's the raw *location table* row count
# (45,637), which is smaller than the linked edge x location join (184,694)
# because the real fan-out here is edges-per-enrollment-id x
# locations-per-enrollment-id, not suite/floor duplication within one
# location. Passing the location-table count as raw_suite_rows produced an
# impossible negative "removed" count at step 2 (caught by this repo's own
# CI semantic-contract check, S5). Omit it and let the function use its
# correct internal default (nrow(sub), the linked-rows table itself) as
# step 1 -- guaranteed non-increasing by construction.
nppes_ref_state_real <- nppes_2019_panel %>%
  transmute(id = npi, year = 2019L, practice_state = clean_state(practice_state))
card_audit_real <- attribute_enrollment_cardinality_audit(
  pecos_linkage_2019$links,
  reference_state = nppes_ref_state_real
)
write_with_provenance(card_audit_real, out("enrollment_cardinality_audit_real_2019.csv"),
                       inputs = "artifacts/amcb_npi_linkage_FROZEN.csv")
print(card_audit_real)

cat("\n--- 4. attribute_location_specificity() ---\n")
dac_2019_vintage <- read_csv("artifacts/physician_compare_historical_midwives.csv",
                              col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4))) %>%
  filter(year == 2019) %>%
  semi_join(cohort_active, by = "npi") %>%
  arrange(npi, desc(vintage)) %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>%
  transmute(id = npi, year = 2019L, practice_zip5 = str_pad(practice_zip, 5, pad = "0"))
stopifnot(!anyDuplicated(dac_2019_vintage[, c("id", "year")]))
corrob_sources_real <- list(
  nppes = nppes_2019_panel %>% transmute(id = npi, year = 2019L,
                                          practice_zip5 = str_pad(practice_zip, 5, pad = "0")),
  dac = dac_2019_vintage
)
spec_audit_real <- attribute_location_specificity(
  pecos_linkage_2019$links,
  corroboration_sources = corrob_sources_real,
  provider_plural = "midwives"
)
write_with_provenance(spec_audit_real$tiers, out("location_specificity_tiers_real_2019.csv"),
                       inputs = c("midwife_panel.csv", "artifacts/physician_compare_historical_midwives.csv"))
write_with_provenance(spec_audit_real$funnel, out("location_specificity_funnel_real_2019.csv"),
                       inputs = c("midwife_panel.csv", "artifacts/physician_compare_historical_midwives.csv"))
print(spec_audit_real$tiers)
cat(spec_audit_real$plain_english_summary, "\n")

cat("\n--- 5. attribute_billing_group_topology() ---\n")
billing_topo_real <- attribute_billing_group_topology(pecos_linkage_2019$links)
write_with_provenance(billing_topo_real$archetype_summary, out("billing_group_topology_real_2019.csv"),
                       inputs = "artifacts/amcb_npi_linkage_FROZEN.csv")
print(billing_topo_real$archetype_summary)

cat("\n--- 23. attribute_audit_diff() vs. remake_oig_07_09_00440's hand-rolled cardinality numbers ---\n")
old_card_path <- "artifacts/oig_remake/oig_pecos_2019_join_cardinality_audit.csv"
if (file.exists(old_card_path)) {
  old_card <- read_csv(old_card_path, col_types = cols(.default = "c"), progress = FALSE)
  # The old script's step 1 ("raw relational join rows") and the new
  # function's raw_suite_rows count different things by definition (full
  # relational multiplication vs. distinct address rows pulled), so they are
  # not comparable. Steps 7/8 of the old script ("distinct clinician x
  # state pairs" and "distinct clinician x billing-org pairs"), however, are
  # exactly the same real-world quantities as the new function's
  # distinct_id_state/distinct_id_group_enrollment steps -- genuinely
  # comparable, and a meaningful regression check that the new helper
  # reproduces the hand-rolled logic exactly.
  old_n <- function(step_prefix) {
    as.numeric(old_card$n_count[startsWith(old_card$decomposition_step, step_prefix)])
  }
  new_n <- function(level) {
    card_audit_real$n_rows_or_pairs[card_audit_real$aggregation_level == level]
  }
  baseline_card <- c(
    distinct_npi_state_pairs = old_n("7. Distinct clinician x state pairs"),
    distinct_npi_group_pairs = old_n("8. Distinct clinician x billing organization pairs")
  )
  revised_card <- c(
    distinct_npi_state_pairs = new_n("distinct_id_state"),
    distinct_npi_group_pairs = new_n("distinct_id_group_enrollment")
  )
  diff_real <- attribute_audit_diff(
    baseline = baseline_card, revised = revised_card,
    reasons = c(
      distinct_npi_state_pairs = "Validation only: attribute_enrollment_cardinality_audit() recomputing the same real quantity as the script's hand-rolled Step 7, not a correction.",
      distinct_npi_group_pairs = "Validation only: attribute_enrollment_cardinality_audit() recomputing the same real quantity as the script's hand-rolled Step 8, not a correction."
    )
  )
  write_with_provenance(diff_real$diff_table, out("audit_diff_cardinality_vs_handrolled.csv"),
                         inputs = old_card_path)
  print(diff_real$diff_table)
} else {
  cat("Skipped: ", old_card_path, " not found (remake_oig_07_09_00440_midwifery.R has not been (re)run).\n")
}

# =============================================================================
# 6. attribute_geographic_concordance() -- real NPPES vs DAC ZIP concordance
# =============================================================================
cat("\n--- 6. attribute_geographic_concordance() ---\n")
dir_addr_real <- nppes_2019_panel %>%
  transmute(npi, year = 2019L, practice_zip5 = str_pad(practice_zip, 5, pad = "0"))
ref_addr_real <- dac_2019_vintage %>% transmute(npi = id, year, reference_zip5 = practice_zip5)
geo_conc_real <- attribute_geographic_concordance(dir_addr_real, ref_addr_real)
write_with_provenance(geo_conc_real$mutually_exclusive, out("geographic_concordance_real_nppes_vs_dac_2019.csv"),
                       inputs = c("midwife_panel.csv", "artifacts/physician_compare_historical_midwives.csv"))
print(geo_conc_real$mutually_exclusive)

# =============================================================================
# 7. attribute_spatial_distance() -- real geocoded address vs NPPES ZIP centroid
# =============================================================================
cat("\n--- 7. attribute_spatial_distance() ---\n")
geo_guarded <- read_csv("artifacts/frozen_cohort/midwives_geography_guarded.csv",
                         col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi), latitude = as.numeric(latitude), longitude = as.numeric(longitude)) %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  semi_join(cohort_active, by = "npi")
stopifnot(!anyDuplicated(geo_guarded$npi))
dir_coords_real <- geo_guarded %>% transmute(npi, year = 2019L, lat = latitude, lon = longitude)
ref_zip_real <- nppes_2019_panel %>%
  semi_join(geo_guarded, by = "npi") %>%
  transmute(npi, year = 2019L, reference_zip5 = str_pad(practice_zip, 5, pad = "0"))
sp_dist_real <- tryCatch(
  attribute_spatial_distance(dir_coords_real, ref_zip_real,
                              dir_lat_col = "lat", dir_lon_col = "lon"),
  error = function(e) { cat("attribute_spatial_distance() error:", conditionMessage(e), "\n"); NULL }
)
if (!is.null(sp_dist_real)) {
  write_with_provenance(sp_dist_real$band_summary, out("spatial_distance_bands_real.csv"),
                         inputs = c("artifacts/frozen_cohort/midwives_geography_guarded.csv", "midwife_panel.csv"))
  print(sp_dist_real$band_summary)
}

# =============================================================================
# 8. Real multi-year, multi-source panels (NPPES state, PECOS reval state, TMSIS state)
# =============================================================================
cat("\n--- Building real multi-year state panels (NPPES / PECOS-reval / T-MSIS) ---\n")
nppes_state_panel <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi), year = as.integer(snapshot_year)) %>%
  semi_join(cohort_active, by = "npi") %>%
  transmute(npi, year, state = clean_state(practice_state))
stopifnot(!anyDuplicated(nppes_state_panel[, c("npi", "year")]))

# T-MSIS is a genuinely multi-state source: 12,159 real (npi, year) pairs in
# this cohort report more than one distinct state in the same year (true
# concurrent Medicaid enrollment, not duplicate noise -- verified directly).
# Collapsing that to one row per (npi, year) before calling
# attribute_mover_stayer_transition_matrix() would silently discard exactly
# the concurrency signal concurrent_source exists to capture. Keep the full
# raw set for concurrent_source, and derive a single deterministic (not
# fabricated -- always one of the real reported states) primary state per
# (npi, year) only for the panel argument, which requires exactly one row.
tmsis_raw_real <- read_csv("artifacts/tmsis_medicaid_enrollment_state_by_year.csv",
                            col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi), year = as.integer(year)) %>%
  semi_join(cohort_active, by = "npi") %>%
  transmute(npi, year, state = clean_state(state)) %>%
  filter(!is.na(state))
tmsis_panel <- tmsis_raw_real %>%
  arrange(npi, year, state) %>%
  group_by(npi, year) %>% slice(1) %>% ungroup()
stopifnot(!anyDuplicated(tmsis_panel[, c("npi", "year")]))

pecos_reval_panel <- pecos_reval %>%
  inner_join(
    read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv",
             col_types = cols(.default = "c"), progress = FALSE) %>%
      mutate(npi = trimws(npi), year = as.integer(year)),
    by = c("npi", "year")
  ) %>%
  transmute(npi, year, state = clean_state(pecos_state))
stopifnot(!anyDuplicated(pecos_reval_panel[, c("npi", "year")]))
cat(sprintf("Real panels: NPPES %d rows (%d NPIs, years %d-%d); PECOS-reval %d rows; T-MSIS %d rows\n",
            nrow(nppes_state_panel), n_distinct(nppes_state_panel$npi),
            min(nppes_state_panel$year), max(nppes_state_panel$year),
            nrow(pecos_reval_panel), nrow(tmsis_panel)))

# =============================================================================
# 9. attribute_inconsistency_table() -- real NPPES vs PECOS multi-attribute (2019)
# =============================================================================
cat("\n--- 9. attribute_inconsistency_table() ---\n")
# PECOS is a genuinely multi-valued source here (group-reassignment links one
# physician to every location her billing group operates, often 10-30+ real
# ZIPs) -- collapsing it to one arbitrary row before comparing is exactly the
# any_shared-vs-same_set conflation attribute_set_agreement()/
# attribute_inconsistency_table() exist to avoid. Keep the FULL linked set and
# let the set-aware functions handle it the way they're designed to.
pecos_linked_set_2019 <- pecos_linkage_2019$links %>%
  filter(location_linked, !is.na(practice_zip5)) %>%
  transmute(npi = id, year, practice_zip5, state = practice_state)
nppes_multi_2019 <- nppes_2019_panel %>%
  transmute(npi, year = 2019L, practice_zip5 = str_pad(practice_zip, 5, pad = "0"),
            state = clean_state(practice_state)) %>%
  semi_join(pecos_linked_set_2019, by = "npi")
pecos_multi_2019 <- pecos_linked_set_2019 %>% semi_join(nppes_multi_2019, by = "npi")
inconsist_real <- attribute_inconsistency_table(
  nppes_multi_2019, pecos_multi_2019,
  attributes = c("practice_zip5", "state"),
  attribute_labels = c(practice_zip5 = "Practice 5-Digit ZIP", state = "Practice State"),
  source_a_label = "nppes", source_b_label = "pecos"
)
write_with_provenance(inconsist_real$table4_summary, out("inconsistency_table_real_nppes_vs_pecos_2019.csv"),
                       inputs = "midwife_panel.csv")
print(inconsist_real$table4_summary[, c("attribute", "n_compared", "n_disjoint_inconsistent", "pct_disjoint_inconsistent")])

# =============================================================================
# 10. attribute_hierarchical_truth_fusion() -- real NPPES + PECOS, state/zip5
# =============================================================================
# Unlike attribute_set_agreement(), hierarchical fusion needs exactly one
# claimed value per source per entity -- PECOS structurally cannot offer a
# single honest ZIP-level claim for a physician linked to a 23-site billing
# group, and picking one arbitrarily would be the same error as above. Restrict
# this specific comparison to physicians where PECOS actually resolves to a
# single, unambiguous ZIP (location_specificity Tier 1/2 -- direct or a
# single-ZIP group), where a flat one-value-per-source claim is honest.
cat("\n--- 10. attribute_hierarchical_truth_fusion() ---\n")
pecos_unambiguous_npis <- pecos_linked_set_2019 %>%
  group_by(npi) %>% filter(n_distinct(practice_zip5) == 1L) %>% ungroup() %>%
  distinct(npi, practice_zip5, state)
cat(sprintf("%d of %d PECOS-linked midwives resolve to a single unambiguous ZIP; restricting the flat (one-value) comparisons below to those.\n",
            n_distinct(pecos_unambiguous_npis$npi), n_distinct(pecos_linked_set_2019$npi)))
hf_nppes <- nppes_multi_2019 %>% semi_join(pecos_unambiguous_npis, by = "npi") %>%
  transmute(npi, year, state, zip5 = practice_zip5)
hf_pecos <- pecos_unambiguous_npis %>% transmute(npi, year = 2019L, state, zip5 = practice_zip5)
hf_real <- attribute_hierarchical_truth_fusion(list(nppes = hf_nppes, pecos = hf_pecos))
write_with_provenance(hf_real$resolution_summary, out("hierarchical_truth_fusion_real_2019.csv"),
                       inputs = "midwife_panel.csv")
print(hf_real$resolution_summary)

# =============================================================================
# 11. attribute_disagreement_trajectories() -- real NPPES vs PECOS-reval state, 2021-2026
# =============================================================================
cat("\n--- 11. attribute_disagreement_trajectories() ---\n")
traj_real <- attribute_disagreement_trajectories(
  nppes_state_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, attr_val = state),
  pecos_reval_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, attr_val = state),
  attribute = "attr_val", base_year = 2021L, max_panel_year = 2026L,
  source_a_label = "NPPES", source_b_label = "PECOS_revalidation"
)
write_with_provenance(traj_real$summary, out("disagreement_trajectories_real_nppes_vs_pecos.csv"),
                       inputs = c("midwife_panel.csv", "artifacts/pecos_revalidation_cohort_state_by_year.csv"))
print(traj_real$summary[, c("trajectory_code", "n", "pct", "median_years_to_resolution")])
cat(strwrap(traj_real$prose, width = 78), sep = "\n")

# =============================================================================
# 12. attribute_mover_stayer_transition_matrix() -- real T-MSIS state panel
# =============================================================================
cat("\n--- 12. attribute_mover_stayer_transition_matrix() ---\n")
tmsis_multi_year <- tmsis_panel %>%
  group_by(npi) %>% filter(n_distinct(year) >= 2L) %>% ungroup() %>%
  filter(!is.na(state))
markov_real <- attribute_mover_stayer_transition_matrix(
  tmsis_multi_year %>% transmute(npi, year, state),
  concurrent_source = tmsis_raw_real %>% semi_join(tmsis_multi_year, by = "npi")
)
write_with_provenance(markov_real$regime_summary, out("mover_stayer_transition_real_tmsis.csv"),
                       inputs = "artifacts/tmsis_medicaid_enrollment_state_by_year.csv")
print(markov_real$regime_summary[, c("mobility_regime", "n", "pct", "pct_with_contiguous_border_move")])

# =============================================================================
# 13. attribute_enumeration_lifecycle() -- real AMCB DECEASED vs NPPES vs downstream panels
# =============================================================================
cat("\n--- 13. attribute_enumeration_lifecycle() ---\n")
cert_roster_real <- lnk_raw %>%
  mutate(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  transmute(npi, cert_status = toupper(status))
stopifnot(!anyDuplicated(cert_roster_real$npi))
active_nppes_real <- nppes_2019_panel %>% filter(is.na(deactivation_date) | !nzchar(deactivation_date)) %>%
  distinct(npi)
# midwife_panel.csv carries one row per NPPES snapshot year, so a deactivated
# NPI's deactivation_date is repeated across every later snapshot year it
# still appears in -- real duplication, not noise, but almost always the
# same date repeated. Checked directly: of 47 NPIs with >1 row here, all but
# 2 report one single, consistent deactivation_date across every snapshot.
# Use the earliest reported date per NPI (when NPPES first recorded the
# deactivation) and flag the 2 genuinely inconsistent NPIs rather than
# silently picking whichever snapshot year happened to sort first.
deact_nppes_raw_real <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(npi = trimws(npi)) %>%
  filter(!is.na(deactivation_date), nzchar(deactivation_date)) %>%
  semi_join(cohort_active, by = "npi")
deact_inconsistent_real <- deact_nppes_raw_real %>%
  group_by(npi) %>% summarise(n_distinct_dates = n_distinct(deactivation_date), .groups = "drop") %>%
  filter(n_distinct_dates > 1L)
if (nrow(deact_inconsistent_real) > 0L) {
  cat(sprintf("NOTE: %d NPI(s) report inconsistent deactivation_date across NPPES snapshot years (using the earliest reported date for each): %s\n",
              nrow(deact_inconsistent_real), paste(deact_inconsistent_real$npi, collapse = ", ")))
}
deact_nppes_real <- deact_nppes_raw_real %>%
  arrange(npi, deactivation_date) %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>%
  transmute(npi, deactivation_date)
stopifnot(!anyDuplicated(deact_nppes_real$npi))
downstream_panels_real <- list(
  pecos_reval = pecos_reval_panel %>% transmute(npi, year),
  tmsis = tmsis_panel %>% transmute(npi, year)
)
life_real <- attribute_enumeration_lifecycle(
  cert_roster_real,
  active_enumeration = active_nppes_real,
  deactivated_enumeration = deact_nppes_real,
  activity_panels = downstream_panels_real
)
write_with_provenance(life_real$matrix_summary, out("enumeration_lifecycle_real.csv"),
                       inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "midwife_panel.csv"))
print(life_real$matrix_summary[, c("lifecycle_status", "npi_enumeration_status", "n", "pct", "n_post_event_downstream")])
print(life_real$deceased_audit)

# =============================================================================
# 14. design_verification_sample() -- real stratification from location_specificity tiers
# =============================================================================
cat("\n--- 14. design_verification_sample() ---\n")
tier_strata_real <- spec_audit_real$clinicians %>%
  mutate(stratum = dplyr::case_when(
    specificity_tier %in% c("Tier 1: Direct Individual Location", "Tier 2: Unique Group Location (1 ZIP5, 1 State)") ~ "pinpoint_concordant",
    specificity_tier %in% c("Tier 3: Small Intrastate Group (2-5 ZIP5s, 1 State)", "Tier 4: Large Intrastate Group (>5 ZIP5s, 1 State)") ~ "multisite_group",
    TRUE ~ "discordant_or_unlinked"
  )) %>%
  transmute(npi = id, stratum)
strata_tab_real <- table(tier_strata_real$stratum)
cat("Real stratum sizes:\n"); print(strata_tab_real)
sample_plan_real <- design_verification_sample(
  tier_strata_real,
  allocation_method = "cost_optimal",
  target_moe = 0.04,
  prior_p = c(pinpoint_concordant = 0.85, multisite_group = 0.55, discordant_or_unlinked = 0.30),
  unit_cost = c(pinpoint_concordant = 1.0, multisite_group = 2.0, discordant_or_unlinked = 3.5),
  response_rate = 0.80
)
write_with_provenance(sample_plan_real$strata, out("design_verification_sample_real.csv"),
                       inputs = c("midwife_panel.csv", "artifacts/physician_compare_historical_midwives.csv"))
print(sample_plan_real$strata[, c("stratum", "pop_N", "n_complete", "n_fielded", "stratum_moe")])
print(sample_plan_real$design_summary)

# =============================================================================
# 15. attribute_oig_audit_html() -- real self-contained HTML report
# =============================================================================
cat("\n--- 15. attribute_oig_audit_html() ---\n")
rp_real <- bind_rows(
  nppes_multi_2019 %>% transmute(id = npi, year, source = "nppes", attribute = "practice_zip5",
                                  record_present = TRUE, field_status = "populated"),
  pecos_multi_2019 %>% distinct(npi, year) %>%
    transmute(id = npi, year, source = "pecos", attribute = "practice_zip5",
              record_present = TRUE, field_status = "populated")
)
set_ag_real <- attribute_set_agreement(
  list(nppes = nppes_multi_2019 %>% transmute(npi, year, practice_zip5),
       pecos = pecos_multi_2019 %>% transmute(npi, year, practice_zip5)),
  attribute = "practice_zip5"
)
set_sum_real <- attribute_set_agreement_summary(set_ag_real)
oig_html_real <- attribute_oig_audit_html(
  record_presence = rp_real, set_agreement_summary = set_sum_real, year = 2019L,
  source_a = "nppes", source_b = "pecos", attribute = "practice_zip5",
  attribute_label = "practice ZIP codes", linkage = pecos_linkage_2019$links,
  provider_noun = "midwife", location_specificity = spec_audit_real
)
writeLines(oig_html_real, out("oig_audit_report_real_2019.html"))
cat(sprintf("Real OIG HTML report written (%d bytes), includes Appendix A2: %s\n",
            nchar(oig_html_real), grepl("Appendix A2", oig_html_real, fixed = TRUE)))

cat("\n=== Real-data run of PR #37 functions complete. Continuing with the 8 previously-synthetic-only functions. ===\n")

# =============================================================================
# 16. attribute_agreement_by_covariate() -- real NPPES vs PECOS ZIP agreement by credential
# =============================================================================
cat("\n--- 16. attribute_agreement_by_covariate() ---\n")
# Flat (one-value-per-source) comparison, same restriction as section 10:
# only physicians where PECOS resolves to a single unambiguous ZIP.
nppes_unambig_2019 <- nppes_multi_2019 %>% semi_join(pecos_unambiguous_npis, by = "npi")
covariate_real <- nppes_2019_panel %>%
  semi_join(nppes_unambig_2019, by = "npi") %>%
  transmute(npi, credential_group = ifelse(grepl("CNM", toupper(credential)), "CNM", "other_or_blank"))
by_cov_real <- attribute_agreement_by_covariate(
  nppes_unambig_2019 %>% transmute(npi, year, practice_zip5),
  pecos_unambiguous_npis %>% transmute(npi, year = 2019L, practice_zip5),
  covariate_df = covariate_real,
  attribute = "practice_zip5", covariate = "credential_group",
  comparison_label = "NPPES vs PECOS (2019 practice ZIP5, PECOS-unambiguous subset)"
)
write_with_provenance(by_cov_real, out("agreement_by_covariate_real_credential.csv"),
                       inputs = "midwife_panel.csv")
print(by_cov_real)

# =============================================================================
# 17. attribute_agreement_add_ci() -- real NPPES vs PECOS state agreement, with Wilson CI
# =============================================================================
cat("\n--- 17. attribute_agreement_add_ci() ---\n")
# A flat state-level comparison only needs PECOS to resolve to one
# unambiguous STATE (a looser bar than the ZIP-level restriction above --
# many physicians have one state but several in-state billing addresses).
pecos_unambig_state_npis <- pecos_linked_set_2019 %>%
  group_by(npi) %>% filter(n_distinct(state) == 1L) %>% ungroup() %>%
  distinct(npi, state)
nppes_unambig_state_2019 <- nppes_multi_2019 %>% semi_join(pecos_unambig_state_npis, by = "npi")
cat(sprintf("%d of %d PECOS-linked midwives resolve to a single unambiguous state.\n",
            n_distinct(pecos_unambig_state_npis$npi), n_distinct(pecos_linked_set_2019$npi)))
ag_state_2019 <- attribute_agreement(
  list(nppes = nppes_unambig_state_2019 %>% transmute(npi, year, state),
       pecos = pecos_unambig_state_npis %>% transmute(npi, year = 2019L, state)),
  attribute = "state"
)
ag_state_summary_2019 <- attribute_agreement_summary(ag_state_2019)
ag_with_ci_real <- attribute_agreement_add_ci(ag_state_summary_2019)
write_with_provenance(ag_with_ci_real, out("agreement_add_ci_real_state_2019.csv"),
                       inputs = "midwife_panel.csv")
print(ag_with_ci_real)

# =============================================================================
# 18. attribute_catch_up_curve_prose() -- real NPPES vs PECOS-reval state catch-up, 2021-2026
# =============================================================================
cat("\n--- 18. attribute_catch_up_curve_prose() ---\n")
cu_real <- attribute_catch_up_curve(
  list(nppes = nppes_state_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, state),
       pecos_reval = pecos_reval_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, state)),
  attribute = "state"
)
cu_prose_result_real <- attribute_catch_up_curve_prose(cu_real, display_label = c(nppes = "NPPES", pecos_reval = "PECOS revalidation"))
cat(strwrap(cu_prose_result_real$sentence, width = 78), sep = "\n")
writeLines(cu_prose_result_real$sentence, out("catch_up_curve_prose_real.txt"))

# =============================================================================
# 19. attribute_consensus_tier_flow() -- real 3-source (NPPES/PECOS-reval/T-MSIS) state consensus
# =============================================================================
cat("\n--- 19. attribute_consensus_tier_flow() ---\n")
three_src_real <- list(
  nppes = nppes_state_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, state),
  pecos_reval = pecos_reval_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, state),
  tmsis = tmsis_panel %>% filter(year %in% 2021:2026) %>% transmute(npi, year, state)
)
tiers_real <- attribute_consensus_tier(three_src_real, attribute = "state")
flow_real <- attribute_consensus_tier_flow(tiers_real, require_all_years = FALSE)
write_with_provenance(flow_real, out("consensus_tier_flow_real.csv"),
                       inputs = c("midwife_panel.csv", "artifacts/pecos_revalidation_cohort_state_by_year.csv",
                                  "artifacts/tmsis_medicaid_enrollment_state_by_year.csv"))
print(flow_real)

# =============================================================================
# 20-21. attribute_claims_collapse_lineage() & attribute_truth_fusion_prose()
#         -- real 3-source state claims, 2021 (first full overlap year)
# =============================================================================
cat("\n--- 20. attribute_claims_collapse_lineage() ---\n")
to_state_fusion_claims <- function(df, src) {
  tibble(entity_id = df$npi, attribute = "practice_state", source_id = src,
         claimed_value = df$state, reference_year = df$year)
}
claims_2021_real <- bind_rows(
  to_state_fusion_claims(nppes_state_panel %>% filter(year == 2021), "nppes"),
  to_state_fusion_claims(pecos_reval_panel %>% filter(year == 2021), "pecos_reval"),
  to_state_fusion_claims(tmsis_panel %>% filter(year == 2021), "tmsis")
) %>% filter(!is.na(claimed_value))
collapsed_real <- attribute_claims_collapse_lineage(
  claims_2021_real,
  lineage_groups = list(cms_administrative = c("pecos_reval", "tmsis"))
)
write_with_provenance(collapsed_real, out("claims_collapse_lineage_real_2021.csv"),
                       inputs = c("artifacts/pecos_revalidation_cohort_state_by_year.csv",
                                  "artifacts/tmsis_medicaid_enrollment_state_by_year.csv"))
cat(sprintf("Real claims: %d raw -> %d after collapsing PECOS-reval+T-MSIS (shared CMS lineage) to one vote\n",
            nrow(claims_2021_real), nrow(collapsed_real)))

cat("\n--- 21. attribute_truth_fusion_prose() ---\n")
fusion_real <- attribute_truth_fusion(collapsed_real, method = "majority", attribute_name = "practice_state")
fusion_prose_real <- attribute_truth_fusion_prose(fusion_real, result_label = "2021 practice-state majority vote")
cat(strwrap(fusion_prose_real$combined_text, width = 78), sep = "\n")
writeLines(fusion_prose_real$combined_text, out("truth_fusion_prose_real_2021.txt"))

# =============================================================================
# 22. format_proportion_comparison_prose() -- real multi-state fan-out, two angles
# =============================================================================
cat("\n--- 22. format_proportion_comparison_prose() ---\n")
multistate_group_n <- billing_topo_real$archetype_summary$n_clinician_links[5]
multistate_group_total <- sum(billing_topo_real$archetype_summary$n_clinician_links)
multistate_mover_n <- markov_real$regime_summary$n[markov_real$regime_summary$mobility_regime ==
                                                       "5. Multi-State Serial Mover / Traveler (>=3 Primary States)"]
multistate_mover_total <- markov_real$regime_summary$n[markov_real$regime_summary$mobility_regime == "Total"]
prop_prose_real <- format_proportion_comparison_prose(
  n_a = multistate_group_n, n_total_a = multistate_group_total,
  n_b = multistate_mover_n, n_total_b = multistate_mover_total,
  label_a = "clinicians linked to a multi-state billing group (PECOS 2019)",
  label_b = "clinicians classified as multi-state serial movers (T-MSIS panel)",
  unit_label = "midwives", condition_label = "showed multi-state administrative fan-out"
)
cat(strwrap(prop_prose_real$combined_text, width = 78), sep = "\n")
writeLines(prop_prose_real$combined_text, out("proportion_comparison_prose_real.txt"))

# =============================================================================
# 23b. format_ranking_prose() -- real mobility regimes ranked by frequency
# =============================================================================
cat("\n--- format_ranking_prose() ---\n")
regime_rank_df <- markov_real$regime_summary %>% filter(mobility_regime != "Total")
rank_prose_real <- format_ranking_prose(
  group = sub("^[0-9]+\\.\\s*", "", regime_rank_df$mobility_regime),
  value = regime_rank_df$pct, value_label = "share of the T-MSIS panel", fmt = "%.1f", suffix = "%"
)
cat(strwrap(rank_prose_real$sentence, width = 78), sep = "\n")
writeLines(rank_prose_real$sentence, out("ranking_prose_real_mobility_regimes.txt"))

cat("\n=== All gap functions exercised on real midwifery data. ===\n")

cat("\n=== Real-data run of PR #37 functions complete. ===\n")

