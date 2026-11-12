#!/usr/bin/env Rscript
# =============================================================================
# OIG Remake Phase 2: Candidate-Location Cardinality & Source-Intersection
# Analysis (Implementation Specification Sections 4-5; execution order
# Section 15 "Phase 2 -- Candidate-set analysis")
# =============================================================================
# Builds on the already-completed six-priority audit
# (`remake_oig_07_09_00440_midwifery.R`, `artifacts/oig_remake/*.csv`) without
# modifying any of its files. Phase 1 reconciliation already confirmed that
# audit reproduces the spec's cited numbers (5,897 enrolled; 5,643 linked;
# 595/1,015/3,523/510/254 tier split; 168,917 clinician-ZIP5 pairs; 1,789
# three-source matches, 573 hospital-corroborated).
#
# What this script fixes relative to the existing audit:
#   1. The existing "PECOS candidate ZIP set" is a tier-PRIORITY PICK
#      (direct if present, else group) -- it drops group-reassignment ZIPs
#      for any clinician who has both. This script uses the UNION instead
#      (`union_zip5_sets()` in R/lib/oig_phase2_candidate_set.R).
#   2. The existing "1,789 three-source corroborated" count is a boolean
#      ANY-OVERLAP test against PECOS's full (possibly dozens-long)
#      candidate set. This script computes the actual three-way
#      intersection and classifies it into six explicit buckets
#      (`classify_intersection_cardinality()`), so "exactly one surviving
#      ZIP5" (uniquely resolved) is reported separately from "multiple
#      shared ZIP5s" (cross-source concordance only).
#
# Explicitly OUT OF SCOPE for this pass (deferred to Phase 3 / Phase 5 per
# the spec's own execution order, and the user's own scoping decision):
#   - Whether Physician Compare's ZIP claim is itself derived from PECOS
#     (source-dependence classification, spec Section 6 / Phase 3).
#   - Whether a uniquely-resolved ZIP5 corresponds to an independently
#     verified historical clinical site (spec Section 8 / Phase 5).
# Both are stubbed NA in the outputs below with a comment pointing to the
# phase that will fill them in -- never fabricated here.
#
# Outputs (all NEW filenames; no existing file in artifacts/oig_remake/ or
# remake_oig_07_09_00440_midwifery.R is read, written, or depended upon):
#   - artifacts/oig_remake/oig_phase2_candidate_cardinality_by_tier.csv (agg)
#   - artifacts/oig_remake/oig_phase2_source_intersections_summary.csv (agg)
#   - artifacts/oig_remake/oig_phase2_1789_reassessment.csv (agg)
#   - qa/oig_phase2_candidate_cardinality_per_clinician.csv (PERSON-LEVEL,
#     gitignored; never written anywhere else -- see the stop() guard below)
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(dplyr)
  library(readr)
  library(stringr)
  library(tibble)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "oig_phase2_candidate_set.R"))

OUT_DIR <- file.path("artifacts", "oig_remake")
QA_DIR <- "qa"
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(QA_DIR, recursive = TRUE, showWarnings = FALSE)

write_person_level <- function(x, filename) {
  out_path <- file.path(QA_DIR, filename)
  if (!identical(dirname(out_path), QA_DIR)) {
    stop(
      "Refusing to write person-level output outside qa/, which is ",
      "gitignored. qa/ is the only directory this script writes ",
      "person-level data to.", call. = FALSE
    )
  }
  readr::write_csv(x, out_path, na = "")
  base::message(sprintf("Wrote person-level file (qa/, gitignored): %s (%d rows)", out_path, nrow(x)))
  invisible(out_path)
}

FROZEN_PATH <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
stopifnot(file.exists(FROZEN_PATH))

# norm_pecos_bigint_zip5() and norm_str_zip5() now live in
# R/lib/oig_zip_normalizers.R, shared with remake_oig_07_09_00440_midwifery.R
# (both scripts are committed now, so the earlier ponytail note about
# deferring de-duplication no longer applies).
source(file.path("R", "lib", "oig_zip_normalizers.R"))

# =============================================================================
# 1. Cohort frame (same 5,897-enrolled PECOS frame as the existing audit)
# =============================================================================
lnk_raw <- read_csv(FROZEN_PATH, col_types = cols(.default = "c"), progress = FALSE)
cohort_active <- canonical_active_primary(lnk_raw) %>%
  mutate(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
assert_one_row_per_id(cohort_active, "npi", "canonical_active_primary() cohort")
base::message(sprintf("Canonical active primary-linked AMCB cohort: N = %d NPIs", nrow(cohort_active)))

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
    SELECT TRIM(e.enrlmt_id) FROM main.ppef_enrol_2019 e
    INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
    UNION
    SELECT TRIM(r.rcv_bnft_enrlmt_id) FROM main.ppef_enrol_2019 e
    INNER JOIN tmp_cohort_active c ON CAST(e.npi AS VARCHAR) = c.npi
    INNER JOIN main.ppef_reassign_2019 r ON TRIM(e.enrlmt_id) = TRIM(r.reasgn_bnft_enrlmt_id)
  )
")
base::message(sprintf(
  "Fetched PECOS 2019: enrl=%d rows, reassign=%d rows, addr=%d rows",
  nrow(pecos_enrl_2019), nrow(pecos_reassign_2019), nrow(pecos_addr_2019)
))

# main.ppef_addr_2019 has no street-level field (confirmed via DESCRIBE:
# enrlmt_id, city_name, zip_cd, state_cd/state_cdstr only) -- full-address
# cardinality (spec 4.2's "when those fields are available") is genuinely
# not computable from this source and is reported as NA, not fabricated.
HAS_STREET_ADDRESS_FIELD <- FALSE

nppes_2019_panel <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year == "2019") %>%
  mutate(npi = trimws(npi)) %>%
  semi_join(cohort_active, by = "npi")
assert_one_row_per_id(nppes_2019_panel, "npi", "midwife_panel.csv snapshot_year==2019")

nppes_2019_st_zip <- nppes_2019_panel %>%
  transmute(
    npi,
    nppes_state_2019 = clean_state(practice_state),
    nppes_zip5_2019 = norm_str_zip5(practice_zip)
  )
base::message(sprintf("Fetched 2019 NPPES panel: %d NPIs", nrow(nppes_2019_st_zip)))

pc_2019_sub <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(vintage %in% c("2019-06", "2019-12")) %>%
  transmute(npi = trimws(npi), pc_zip5 = norm_str_zip5(practice_zip)) %>%
  filter(npi %in% cohort_active$npi, !is.na(pc_zip5)) %>%
  distinct()
base::message(sprintf(
  "Fetched 2019 Physician Compare (vintages 2019-06/2019-12): %d NPIs with >=1 ZIP5",
  n_distinct(pc_2019_sub$npi)
))

# =============================================================================
# 2. Direct-enrollment and group-reassignment address joins
#    (same join shape as remake_oig_07_09_00440_midwifery.R:2161-2174)
# =============================================================================
enrl_dedup_2019 <- pecos_enrl_2019 %>% distinct(npi, enrlmt_id)
reass_dedup_2019 <- pecos_reassign_2019 %>% distinct(npi, reasgn_bnft_enrlmt_id, rcv_bnft_enrlmt_id)
pecos_addr_clean <- pecos_addr_2019 %>%
  mutate(
    zip5 = norm_pecos_bigint_zip5(zip_cd),
    state = clean_state(state_cdstr)
  )

direct_join_2019 <- enrl_dedup_2019 %>%
  inner_join(pecos_addr_clean, by = "enrlmt_id", relationship = "many-to-many") %>%
  filter(!is.na(zip5))

group_join_2019 <- enrl_dedup_2019 %>%
  inner_join(reass_dedup_2019, by = c("npi", "enrlmt_id" = "reasgn_bnft_enrlmt_id"), relationship = "many-to-many") %>%
  inner_join(pecos_addr_clean, by = c("rcv_bnft_enrlmt_id" = "enrlmt_id"), relationship = "many-to-many") %>%
  filter(!is.na(zip5))

direct_by_npi <- direct_join_2019 %>%
  group_by(npi) %>%
  summarise(
    has_direct = TRUE,
    n_individual_enrollment_ids = n_distinct(enrlmt_id),
    direct_zip5_list = list(sort(unique(zip5))),
    direct_state_list = list(sort(unique(state[!is.na(state)]))),
    .groups = "drop"
  )

group_by_npi <- group_join_2019 %>%
  group_by(npi) %>%
  summarise(
    has_group = TRUE,
    n_raw_group_rows = n(),
    n_billing_orgs = n_distinct(rcv_bnft_enrlmt_id),
    n_group_zip5 = n_distinct(zip5),
    n_group_states = n_distinct(state[!is.na(state)]),
    group_zip5_list = list(sort(unique(zip5))),
    group_state_list = list(sort(unique(state[!is.na(state)]))),
    .groups = "drop"
  )

# ZIP5 -> number of distinct billing orgs it appears under, per NPI (spec
# 4.3: "candidate ZIP5s associated with more than one billing organization")
zip5_multi_org_counts <- group_join_2019 %>%
  distinct(npi, rcv_bnft_enrlmt_id, zip5) %>%
  count(npi, zip5, name = "n_orgs_for_zip5") %>%
  group_by(npi) %>%
  summarise(n_zip5_with_multiple_billing_orgs = sum(n_orgs_for_zip5 > 1L), .groups = "drop")

pc_by_npi <- pc_2019_sub %>%
  group_by(npi) %>%
  summarise(pc_zip5_list = list(sort(unique(pc_zip5))), .groups = "drop")

# =============================================================================
# 3. Per-clinician candidate sets P_i (union, the Phase 2 fix), N_i, C_i
# =============================================================================
ENROLLED_FRAME <- tibble(npi = unique(enrl_dedup_2019$npi))
base::message(sprintf("2019 PECOS-enrolled frame: N = %d NPIs", nrow(ENROLLED_FRAME)))

candidate_sets <- ENROLLED_FRAME %>%
  left_join(nppes_2019_st_zip, by = "npi") %>%
  left_join(direct_by_npi, by = "npi") %>%
  left_join(group_by_npi, by = "npi") %>%
  left_join(zip5_multi_org_counts, by = "npi") %>%
  left_join(pc_by_npi, by = "npi") %>%
  mutate(
    has_direct = coalesce(has_direct, FALSE),
    has_group = coalesce(has_group, FALSE),
    n_individual_enrollment_ids = coalesce(n_individual_enrollment_ids, 0L),
    n_raw_group_rows = coalesce(n_raw_group_rows, 0L),
    n_billing_orgs = coalesce(n_billing_orgs, 0L),
    n_group_zip5 = coalesce(n_group_zip5, 0L),
    n_group_states = coalesce(n_group_states, 0L),
    n_zip5_with_multiple_billing_orgs = coalesce(n_zip5_with_multiple_billing_orgs, 0L)
  )
candidate_sets$direct_zip5_list[lengths(candidate_sets$direct_zip5_list) == 0L] <- list(character(0))
candidate_sets$group_zip5_list[lengths(candidate_sets$group_zip5_list) == 0L] <- list(character(0))
candidate_sets$direct_state_list[lengths(candidate_sets$direct_state_list) == 0L] <- list(character(0))
candidate_sets$group_state_list[lengths(candidate_sets$group_state_list) == 0L] <- list(character(0))
candidate_sets$pc_zip5_list[lengths(candidate_sets$pc_zip5_list) == 0L] <- list(character(0))

candidate_sets <- candidate_sets %>%
  mutate(
    # P_i -- THE FIX: union of direct + group ZIPs, not a tier-priority pick.
    p_zip5_list = Map(union_zip5_sets, direct_zip5_list, group_zip5_list),
    p_state_list = Map(union_zip5_sets, direct_state_list, group_state_list),
    n_distinct_zip5 = lengths(p_zip5_list),
    n_distinct_states = lengths(p_state_list),
    n_distinct_cities = n_individual_enrollment_ids, # no city list retained; see NOTE below
    n_distinct_full_address = NA_integer_,            # spec 4.2: not available, see header comment
    # N_i: NPPES 2019 is confirmed exactly one ZIP5 per NPI (verified during
    # planning: 257,869 rows == 257,869 distinct NPI for snapshot_year 2019).
    n_zip5_list = lapply(nppes_zip5_2019, function(z) if (is.na(z)) character(0) else z),
    n_out_of_state_zip5_vs_nppes = mapply(function(states, nppes_state) {
      if (length(states) == 0L || is.na(nppes_state)) return(NA_integer_)
      sum(states != nppes_state)
    }, p_state_list, nppes_state_2019),
    has_multiple_sites = n_distinct_zip5 > 1L
  )

# =============================================================================
# 4. Analysis 1 (spec Section 4) -- candidate-location cardinality by tier
# =============================================================================
hierarchy <- candidate_sets %>%
  mutate(
    specificity_tier = case_when(
      has_direct ~ "Tier 1: Direct Individual Practice Location (Attached to Individual Enrollment ID)",
      !has_direct & has_group & n_group_zip5 == 1L & n_group_states == 1L ~ "Tier 2: Unique Group-Associated Location (1 ZIP5 in 1 State via Billing Group)",
      !has_direct & has_group & n_group_zip5 >= 2L & n_group_zip5 <= 5L & n_group_states == 1L ~ "Tier 3: Small Intrastate Multi-Site Group (2-5 Unique ZIP5s in 1 State)",
      !has_direct & has_group & n_group_zip5 > 5L & n_group_states == 1L ~ "Tier 4: Large Intrastate Multi-Site Group (>5 Unique ZIP5s in 1 State)",
      !has_direct & has_group & n_group_states >= 2L ~ "Tier 5: Multi-State / Interstate Billing Group Locations (>=2 States)",
      TRUE ~ "Tier 6: No Practice Location Linked in PECOS (Neither Direct Nor Group)"
    ),
    has_any_location = has_direct | has_group,
    n_candidate_zip5_bucket = classify_zip5_count_bucket(n_distinct_zip5)
  )

N_ENROLLED <- nrow(hierarchy)
N_LINKED <- sum(hierarchy$has_any_location)

# The existing "595" and "168,917" figures use narrower definitions than a
# plain n_distinct_zip5==1 / total-pairs count over the union P_i:
#   - "595" = count of clinicians in Tier 1 + Tier 2 BY TIER LABEL (tier
#     assignment logic is unchanged by the union fix, so this reproduces
#     exactly).
#   - "168,917" = distinct (npi, zip5) pairs from GROUP-REASSIGNMENT rows
#     ONLY (confirmed by direct computation during planning: direct-address
#     ZIP5s were never part of that denominator at all).
# Both are reproduced exactly below. The union-based P_i then adds two NEW,
# correctly-broader metrics that are deliberately NOT expected to match the
# old narrower figures -- see the appendix for the explained effect size.
N_TIER1_TIER2_BY_LABEL <- sum(grepl("^Tier 1|^Tier 2", hierarchy$specificity_tier))
N_GROUP_ONLY_ZIP5_PAIRS <- group_join_2019 %>% distinct(npi, zip5) %>% nrow()
N_SINGLE_ZIP_UNION_BASED <- sum(hierarchy$n_distinct_zip5 == 1L)
N_UNION_ZIP5_PAIRS <- hierarchy %>%
  tidyr::unnest(p_zip5_list) %>%
  distinct(npi, p_zip5_list) %>%
  nrow()

base::message(sprintf(
  paste(
    "Section 4.4 validation: enrolled=%d (expect 5897), linked=%d (expect 5643),",
    "tier1_tier2_by_label=%d (expect 595), group_only_pairs=%d (expect 168917);",
    "union-based single_zip5=%d, union-based pairs=%d (new, broader metrics,",
    "not expected to equal the old narrower figures -- see appendix)"
  ),
  N_ENROLLED, N_LINKED, N_TIER1_TIER2_BY_LABEL, N_GROUP_ONLY_ZIP5_PAIRS,
  N_SINGLE_ZIP_UNION_BASED, N_UNION_ZIP5_PAIRS
))
section_4_4_validation <- tibble(
  check = c(
    "enrolled_clinicians", "linked_clinicians",
    "tier1_plus_tier2_by_label", "group_only_npi_zip5_pairs",
    "single_zip5_clinicians_union_based", "npi_zip5_pairs_union_based"
  ),
  expected_from_spec = c(5897L, 5643L, 595L, 168917L, NA_integer_, NA_integer_),
  observed_this_script = c(
    N_ENROLLED, N_LINKED, N_TIER1_TIER2_BY_LABEL, N_GROUP_ONLY_ZIP5_PAIRS,
    N_SINGLE_ZIP_UNION_BASED, N_UNION_ZIP5_PAIRS
  ),
  matches = c(expected_from_spec[1:4] == observed_this_script[1:4], NA, NA),
  note = c(
    NA_character_, NA_character_, NA_character_, NA_character_,
    sprintf(
      "New union-based metric; %d lower than 595 because the union correctly reclassifies clinicians whose group-reassignment addresses reveal additional candidate ZIPs beyond their one direct address",
      595L - N_SINGLE_ZIP_UNION_BASED
    ),
    sprintf(
      "New union-based metric; %d higher than the 168,917 group-only baseline, from direct-address ZIP5s (18 direct-only + partial overlap for the 8 both-direct-and-group clinicians) that baseline never counted",
      N_UNION_ZIP5_PAIRS - N_GROUP_ONLY_ZIP5_PAIRS
    )
  )
)
print(as.data.frame(section_4_4_validation), row.names = FALSE)

candidate_cardinality_by_tier <- hierarchy %>%
  group_by(specificity_tier) %>%
  summarise(
    n_clinicians = n(),
    pct_of_5897_enrolled = round(100 * n() / N_ENROLLED, 2),
    pct_of_5643_linked = if (grepl("^Tier 6", first(specificity_tier))) NA_real_ else round(100 * n() / N_LINKED, 2),
    mean_distinct_zip5 = round(mean(n_distinct_zip5), 2),
    sd_distinct_zip5 = round(sd(n_distinct_zip5), 2),
    median_distinct_zip5 = median(n_distinct_zip5),
    p25_distinct_zip5 = quantile(n_distinct_zip5, 0.25),
    p75_distinct_zip5 = quantile(n_distinct_zip5, 0.75),
    n_single_address = sum(n_distinct_zip5 == 1L),
    n_multiple_zip5 = sum(n_distinct_zip5 > 1L),
    n_interstate_candidates = sum(n_distinct_states > 1L),
    mean_billing_orgs = round(mean(n_billing_orgs), 2),
    mean_zip5_with_multiple_billing_orgs = round(mean(n_zip5_with_multiple_billing_orgs), 2),
    .groups = "drop"
  )

# =============================================================================
# 5. Analysis 2 (spec Section 5) -- source intersection & unique-location ID
# =============================================================================
intersections <- hierarchy %>%
  mutate(
    intersection_bucket = mapply(
      classify_intersection_cardinality, p_zip5_list, n_zip5_list, pc_zip5_list,
      SIMPLIFY = TRUE
    ),
    # IMPORTANT: NPPES contributes at most 1 ZIP5/clinician (verified during
    # planning), so this three-way intersection is structurally
    # empty-or-singleton -- "two"/"three_to_five"/"more_than_five" can never
    # occur here regardless of how large PECOS's or Physician Compare's own
    # sets are. The pairwise PECOS-vs-Physician-Compare intersection below
    # is where genuine multi-ZIP5 agreement (the "large billing group chance
    # agreement" question) can actually be observed.
    pairwise_pecos_pc_bucket = mapply(
      classify_intersection_cardinality, p_zip5_list, pc_zip5_list,
      SIMPLIFY = TRUE
    ),
    three_way_shared_zip5 = Map(function(p, n, c) intersect(intersect(p, n), c), p_zip5_list, n_zip5_list, pc_zip5_list),
    n_three_way_shared_zip5 = lengths(three_way_shared_zip5),
    # Reproduce the EXISTING audit's "1,789" definition exactly (any-overlap
    # against the full PECOS candidate set), for the Section 5.4 reassessment.
    pecos_matches_pc_any = lengths(Map(intersect, p_zip5_list, pc_zip5_list)) > 0L,
    nppes_matches_pc_any = lengths(Map(intersect, n_zip5_list, pc_zip5_list)) > 0L,
    all3_zip5_corroborated_existing_definition = pecos_matches_pc_any & nppes_matches_pc_any
  )

source_intersection_summary <- intersections %>%
  count(intersection_bucket, name = "n_clinicians") %>%
  mutate(pct_of_5897_enrolled = round(100 * n_clinicians / N_ENROLLED, 2))

pairwise_pecos_pc_summary <- intersections %>%
  count(pairwise_pecos_pc_bucket, name = "n_clinicians") %>%
  mutate(pct_of_5897_enrolled = round(100 * n_clinicians / N_ENROLLED, 2))

# Sequential resolution (spec 5.3): PECOS -> +NPPES -> +PhysCompare, and the
# reversed PECOS -> +PhysCompare -> +NPPES, to check order-dependence.
sequential <- intersections %>%
  mutate(
    step1_to_nppes = mapply(classify_sequential_transition, p_zip5_list, n_zip5_list),
    step2_pecos_nppes = Map(function(p, n) if (length(n) == 0L) p else intersect(p, n), p_zip5_list, n_zip5_list),
    step2_to_pc = mapply(classify_sequential_transition, step2_pecos_nppes, pc_zip5_list),
    step1_to_pc = mapply(classify_sequential_transition, p_zip5_list, pc_zip5_list),
    step2_pecos_pc = Map(function(p, c) if (length(c) == 0L) p else intersect(p, c), p_zip5_list, pc_zip5_list),
    step2_to_nppes = mapply(classify_sequential_transition, step2_pecos_pc, n_zip5_list)
  )

sequential_resolution_order_a <- bind_rows(
  sequential %>% count(transition = step1_to_nppes, name = "n_clinicians") %>% mutate(order = "pecos_then_nppes_then_physcompare", step = "1_add_nppes"),
  sequential %>% count(transition = step2_to_pc, name = "n_clinicians") %>% mutate(order = "pecos_then_nppes_then_physcompare", step = "2_add_physcompare")
)
sequential_resolution_order_b <- bind_rows(
  sequential %>% count(transition = step1_to_pc, name = "n_clinicians") %>% mutate(order = "pecos_then_physcompare_then_nppes", step = "1_add_physcompare"),
  sequential %>% count(transition = step2_to_nppes, name = "n_clinicians") %>% mutate(order = "pecos_then_physcompare_then_nppes", step = "2_add_nppes")
)
sequential_resolution_summary <- bind_rows(sequential_resolution_order_a, sequential_resolution_order_b) %>%
  select(order, step, transition, n_clinicians)

source_intersections_summary_tbl <- bind_rows(
  source_intersection_summary %>% mutate(table_section = "5.2_three_way_intersection_buckets"),
  pairwise_pecos_pc_summary %>%
    rename(intersection_bucket = pairwise_pecos_pc_bucket) %>%
    mutate(table_section = "5.2b_pairwise_pecos_vs_physician_compare_buckets"),
  sequential_resolution_summary %>%
    rename(n_count = n_clinicians) %>%
    mutate(table_section = "5.3_sequential_resolution_transitions", intersection_bucket = transition, n_clinicians = n_count) %>%
    select(table_section, order, step, intersection_bucket, n_clinicians)
)

# --- Section 5.4: reassess the existing 1,789 three-source matches --------
n_1789_reproduced <- sum(intersections$all3_zip5_corroborated_existing_definition)
base::message(sprintf("Section 5.4: reproduced existing all3_zip5_corroborated count = %d (expect 1789)", n_1789_reproduced))

reassessment_1789_by_bucket <- intersections %>%
  filter(all3_zip5_corroborated_existing_definition) %>%
  count(intersection_bucket, name = "n_clinicians") %>%
  mutate(
    pct_of_1789 = round(100 * n_clinicians / n_1789_reproduced, 2),
    interpretation = case_when(
      intersection_bucket == "exactly_one" ~ "Uniquely geographically resolved -- the ONLY group reportable as such per spec 5.4.",
      intersection_bucket == "two" ~ "Cross-source geographic concordance only; 2 ZIP5s remain plausible.",
      intersection_bucket == "three_to_five" ~ "Cross-source geographic concordance only; 3-5 ZIP5s remain plausible.",
      intersection_bucket == "more_than_five" ~ "Cross-source geographic concordance only; >5 ZIP5s remain plausible (large billing group).",
      intersection_bucket == "no_common_zip5" ~ "Inconsistent with the existing any-overlap definition; should not occur (QA check).",
      intersection_bucket == "source_unavailable" ~ "Inconsistent with the existing any-overlap definition; should not occur (QA check)."
    ),
    # Spec 5.4 sub-bullets explicitly deferred (NOT fabricated here):
    pc_derived_from_pecos = NA,          # Phase 3 (source-dependence audit)
    independently_supported_site = NA    # Phase 5 (historical verification)
  )

reassessment_1789_pairwise_pc_bucket <- intersections %>%
  filter(all3_zip5_corroborated_existing_definition) %>%
  count(pairwise_pecos_pc_bucket, name = "n_clinicians") %>%
  mutate(
    pct_of_1789 = round(100 * n_clinicians / n_1789_reproduced, 2),
    interpretation = case_when(
      pairwise_pecos_pc_bucket == "exactly_one" ~ "PECOS and Physician Compare agree on exactly one ZIP5 -- the strongest pairwise evidence available.",
      pairwise_pecos_pc_bucket %in% c("two", "three_to_five", "more_than_five") ~ "PECOS and Physician Compare share multiple ZIP5s -- consistent with chance agreement from a large billing-group address list, not a pinpointed site.",
      pairwise_pecos_pc_bucket == "no_common_zip5" ~ "Inconsistent with the existing any-overlap definition; should not occur (QA check).",
      pairwise_pecos_pc_bucket == "source_unavailable" ~ "Inconsistent with the existing any-overlap definition; should not occur (QA check)."
    ),
    pc_derived_from_pecos = NA,
    independently_supported_site = NA
  )

the_1789 <- intersections %>% filter(all3_zip5_corroborated_existing_definition)
reassessment_1789_summary <- tibble(
  metric = c(
    "original_1789_cross_source_geographic_concordance",
    "n_uniquely_resolved_exactly_one_zip5_three_way",
    "n_multiple_shared_zip5_two_or_more_three_way",
    "n_with_pecos_candidate_set_over_5_zip5_many_in_pecos_proxy",
    "n_pecos_vs_physcompare_pairwise_multi_zip5_chance_agreement"
  ),
  n_count = c(
    nrow(the_1789),
    sum(the_1789$intersection_bucket == "exactly_one"),
    sum(the_1789$intersection_bucket %in% c("two", "three_to_five", "more_than_five")),
    sum(the_1789$n_distinct_zip5 > 5L),
    sum(the_1789$pairwise_pecos_pc_bucket %in% c("two", "three_to_five", "more_than_five"))
  ),
  pct_of_1789 = round(100 * n_count / nrow(the_1789), 2),
  note = c(
    NA_character_,
    "Three-way (PECOS n NPPES n Physician Compare) intersection is structurally empty-or-singleton because NPPES contributes <=1 ZIP5/clinician -- see pairwise metric below for genuine multi-ZIP5 agreement.",
    "Mathematically near-impossible given a singleton NPPES set (see note above); near-zero is expected, not a bug.",
    NA_character_,
    "The honest answer to 'chance agreement from a large billing-group address list': PECOS and Physician Compare (both genuinely multi-valued) share >1 ZIP5 despite the existing any-overlap definition counting this clinician as corroborated."
  )
)

# --- Section 5.5: four separate, never-conflated evidence endpoints -------
endpoints_5_5 <- intersections %>%
  transmute(
    npi,
    unique_zip5_identified = intersection_bucket == "exactly_one",
    unique_street_address_identified = NA,   # not available; see HAS_STREET_ADDRESS_FIELD
    unique_facility_identified = NA,         # Phase 3 (CCN/facility linkage)
    independently_verified_clinician_facility_association = NA # Phase 5
  )

# =============================================================================
# 6. Write outputs
# =============================================================================
write_with_provenance(
  candidate_cardinality_by_tier,
  file.path(OUT_DIR, "oig_phase2_candidate_cardinality_by_tier.csv"),
  inputs = c(FROZEN_PATH, "midwife_panel.csv")
)
write_with_provenance(
  source_intersections_summary_tbl,
  file.path(OUT_DIR, "oig_phase2_source_intersections_summary.csv"),
  inputs = c(FROZEN_PATH, "midwife_panel.csv", "artifacts/physician_compare_historical_midwives.csv")
)
reassessment_1789_combined <- bind_rows(
  reassessment_1789_summary %>% mutate(table_section = "5.4_headline_metrics", .before = 1L),
  reassessment_1789_by_bucket %>%
    rename(n_count = n_clinicians) %>%
    mutate(
      table_section = "5.4_breakdown_by_three_way_intersection_bucket",
      metric = intersection_bucket,
      .before = 1L
    ) %>%
    select(table_section, metric, n_count, pct_of_1789, interpretation, pc_derived_from_pecos, independently_supported_site),
  reassessment_1789_pairwise_pc_bucket %>%
    rename(n_count = n_clinicians) %>%
    mutate(
      table_section = "5.4_breakdown_by_pairwise_pecos_vs_physcompare_bucket",
      metric = pairwise_pecos_pc_bucket,
      .before = 1L
    ) %>%
    select(table_section, metric, n_count, pct_of_1789, interpretation, pc_derived_from_pecos, independently_supported_site)
)
write_with_provenance(
  reassessment_1789_combined,
  file.path(OUT_DIR, "oig_phase2_1789_reassessment.csv"),
  inputs = c(FROZEN_PATH, "midwife_panel.csv", "artifacts/physician_compare_historical_midwives.csv")
)

person_level <- hierarchy %>%
  left_join(intersections %>% select(npi, intersection_bucket, pairwise_pecos_pc_bucket, n_three_way_shared_zip5, all3_zip5_corroborated_existing_definition), by = "npi") %>%
  left_join(endpoints_5_5, by = "npi") %>%
  select(
    npi, specificity_tier, has_direct, has_group, n_distinct_zip5,
    n_distinct_states, n_billing_orgs, n_individual_enrollment_ids,
    n_zip5_with_multiple_billing_orgs, n_out_of_state_zip5_vs_nppes,
    has_multiple_sites, intersection_bucket, pairwise_pecos_pc_bucket,
    n_three_way_shared_zip5,
    all3_zip5_corroborated_existing_definition, unique_zip5_identified,
    unique_street_address_identified, unique_facility_identified,
    independently_verified_clinician_facility_association
  )
write_person_level(person_level, "oig_phase2_candidate_cardinality_per_clinician.csv")

base::message("Phase 2 candidate-set and intersection analysis complete.")
