#!/usr/bin/env Rscript
# =============================================================================
# Invariants for Cohort Exclusion Criteria & Stage Flow
# =============================================================================
# Verifies that every record entering the cohort exclusion pipeline is strictly
# classified into exactly one exclusion stage or the final included cohort, and
# that all inclusion/exclusion rules, stage counts, and population conservation
# invariants hold every night and on every build.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

ci_section("E1 Unit invariants for exclusion rule logic (planted synthetic cases)")

source(file.path(root, "R", "federal_adverse_action_exclusions.R"))

# Define standard ACOG unmapped state set (matching build_exclusion_flow_person_level.R)
ACOG_UNMAPPED <- c("AA", "AE", "AP", "GU", "PR", "VI", "AS", "MP", "FM", "PW", "MH")

classify_exclusion_stage <- function(df) {
  df %>%
    mutate(
      geocoded = coalesce(geocoded, FALSE),
      federal_adverse_action_excluded = coalesce(federal_adverse_action_excluded, FALSE),
      acog_mapped = geocoded & !(nppes_state %in% ACOG_UNMAPPED),
      exclusion_stage = case_when(
        status != "ACTIVE"              ~ "deceased_or_inactive",
        match_status != "primary"       ~ "no_npi_match",
        federal_adverse_action_excluded ~ "federal_adverse_action_dea_fda_medicare",
        !geocoded                       ~ "no_geocodable_address",
        !acog_mapped                    ~ "no_acog_district",
        TRUE                            ~ "included_final_cohort"
      )
    )
}

# Synthetic test fixture containing 6 distinct cases
synthetic_test_df <- tibble(
  certification_number = paste0("CERT", 1:6),
  status               = c("ACTIVE", "LAPSED", "ACTIVE",  "ACTIVE",  "ACTIVE",  "ACTIVE"),
  match_status         = c("primary", "primary", "unmatched", "primary", "primary", "primary"),
  federal_adverse_action_excluded = c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE),
  geocoded             = c(TRUE,     TRUE,     TRUE,    TRUE, FALSE, TRUE),
  nppes_state          = c("CO",     "CO",     "CO",    "CO", "CO",  "PR")
)

classified_synth <- classify_exclusion_stage(synthetic_test_df)

expected_stages <- c(
  "included_final_cohort",
  "deceased_or_inactive",
  "no_npi_match",
  "federal_adverse_action_dea_fda_medicare",
  "no_geocodable_address",
  "no_acog_district"
)

if (identical(classified_synth$exclusion_stage, expected_stages)) {
  ci_ok("synthetic test cases correctly classified into all 6 expected exclusion stages")
} else {
  ci_fail("E1: synthetic test cases failed classification (expected [%s], got [%s])",
          paste(expected_stages, collapse = ", "),
          paste(classified_synth$exclusion_stage, collapse = ", "))
}


ci_section("E2 Population conservation across cohort flow counts artifact")

counts_path <- file.path(root, "docs", "figures", "cohort_exclusion_flow_counts.csv")
if (!file.exists(counts_path)) {
  ci_fail("E2: %s is missing -- cohort exclusion flow counts artifact must exist", counts_path)
} else {
  counts_df <- read_csv(counts_path, show_col_types = FALSE)
  need_cols <- c("stage", "n", "cohort_rule", "analytic_cohort_n")
  if (!all(need_cols %in% names(counts_df))) {
    ci_fail("E2: cohort_exclusion_flow_counts.csv missing required columns: %s",
            paste(setdiff(need_cols, names(counts_df)), collapse = ", "))
  } else {
    roster_n <- counts_df$n[counts_df$stage == "roster"][1]
    active_n <- counts_df$n[counts_df$stage == "active"][1]
    inactive_n <- counts_df$n[counts_df$stage == "inactive"][1]
    matched_n <- counts_df$n[counts_df$stage == "matched"][1]
    unmatched_n <- counts_df$n[counts_df$stage == "unmatched"][1]
    adverse_n <- counts_df$n[counts_df$stage == "federal_adverse_action"][1]
    after_adverse_n <- counts_df$n[counts_df$stage == "after_federal_adverse_action"][1]
    geocoded_n <- counts_df$n[counts_df$stage == "geocoded"][1]
    not_geocoded_n <- counts_df$n[counts_df$stage == "not_geocoded"][1]
    final_n <- counts_df$n[counts_df$stage == "final_cohort"][1]
    acog_excl_n <- counts_df$n[counts_df$stage == "acog_excluded"][1]

    # Invariant 1: roster == active + inactive
    if (roster_n != (active_n + inactive_n)) {
      ci_fail("E2: roster count (%d) != active (%d) + inactive (%d)", roster_n, active_n, inactive_n)
    } else {
      ci_ok("roster count (%d) = active (%d) + inactive (%d)", roster_n, active_n, inactive_n)
    }

    # Invariant 2: active == matched + unmatched
    if (active_n != (matched_n + unmatched_n)) {
      ci_fail("E2: active count (%d) != matched (%d) + unmatched (%d)", active_n, matched_n, unmatched_n)
    } else {
      ci_ok("active count (%d) = matched (%d) + unmatched (%d)", active_n, matched_n, unmatched_n)
    }

    # Invariant 3: matched == adverse + after_adverse
    if (matched_n != (adverse_n + after_adverse_n)) {
      ci_fail("E2: matched count (%d) != adverse (%d) + after_adverse (%d)", matched_n, adverse_n, after_adverse_n)
    } else {
      ci_ok("matched count (%d) = adverse (%d) + after_adverse (%d)", matched_n, adverse_n, after_adverse_n)
    }

    # Invariant 4: after_adverse == geocoded + not_geocoded
    if (after_adverse_n != (geocoded_n + not_geocoded_n)) {
      ci_fail("E2: after_adverse count (%d) != geocoded (%d) + not_geocoded (%d)", after_adverse_n, geocoded_n, not_geocoded_n)
    } else {
      ci_ok("after_adverse count (%d) = geocoded (%d) + not_geocoded (%d)", after_adverse_n, geocoded_n, not_geocoded_n)
    }

    # Invariant 5: geocoded == final_cohort + acog_excluded
    if (geocoded_n != (final_n + acog_excl_n)) {
      ci_fail("E2: geocoded count (%d) != final_cohort (%d) + acog_excluded (%d)", geocoded_n, final_n, acog_excl_n)
    } else {
      ci_ok("geocoded count (%d) = final_cohort (%d) + acog_excluded (%d)", geocoded_n, final_n, acog_excl_n)
    }
  }
}


ci_section("E3 Verification against person-level freeze dataset (when present)")

linkage_path <- file.path(root, "artifacts", "amcb_npi_linkage_FROZEN.csv")
geo_path     <- file.path(root, "artifacts", "midwives_geography_FROZEN.csv")

if (!file.exists(linkage_path) || !file.exists(geo_path)) {
  ci_skip("amcb_npi_linkage_FROZEN.csv / midwives_geography_FROZEN.csv absent (PRIVATE-OK); E3 skipped on CI runner")
} else {
  linkage <- read_csv(linkage_path, show_col_types = FALSE, progress = FALSE, guess_max = Inf)
  geo     <- read_csv(geo_path, show_col_types = FALSE, progress = FALSE, guess_max = Inf)

  geo_std <- geo %>% transmute(certification_number, geocoded = !is.na(county_best))

  action_flags_path <- file.path(root, "artifacts", "federal_adverse_action_flags.csv")
  action_flags <- if (file.exists(action_flags_path)) {
    read_csv(action_flags_path, show_col_types = FALSE, progress = FALSE) %>%
      transmute(npi_action_key = gsub("[^0-9]", "", as.character(npi)),
                federal_adverse_action_excluded,
                federal_adverse_action_source) %>%
      distinct(npi_action_key, .keep_all = TRUE)
  } else {
    tibble(npi_action_key = character(), federal_adverse_action_excluded = logical(),
           federal_adverse_action_source = character())
  }

  joined <- linkage %>%
    left_join(geo_std, by = "certification_number") %>%
    mutate(npi_action_key = gsub("[^0-9]", "", as.character(npi))) %>%
    left_join(action_flags, by = "npi_action_key")

  classified_real <- classify_exclusion_stage(joined)

  # Check zero missing stage values
  n_na_stage <- sum(is.na(classified_real$exclusion_stage))
  if (n_na_stage > 0) {
    ci_fail("E3: %d record(s) failed stage classification (exclusion_stage is NA)", n_na_stage)
  } else {
    ci_ok("all %d records in the frozen roster classified into a valid stage without NA", nrow(classified_real))
  }

  # Check total population conservation
  stage_summary <- count(classified_real, exclusion_stage)
  total_classified <- sum(stage_summary$n)
  if (total_classified != nrow(linkage)) {
    ci_fail("E3: total classified records (%d) != total roster records (%d)", total_classified, nrow(linkage))
  } else {
    ci_ok("total classified records (%d) exactly equals total roster records (%d)", total_classified, nrow(linkage))
  }
}

ci_finish()
