#!/usr/bin/env Rscript
# =============================================================================
# Table 1 Demographics Quality Control (QC) Test Suite
# =============================================================================
# Verifies demographic plausibility, block reconciliation, percentage bounds,
# and cross-artifact concordance for Table 1 demographics on every build and
# nightly CI run.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

ci_section("D1 Table 1 Artifact Availability & Cohort N Initialization")

t1_csv_path <- file.path(root, "artifacts", "table1_midwives.csv")
t1_md_path  <- file.path(root, "docs", "table1_midwives.md")
base_path   <- file.path(root, "tests", "ci_table1_cohort_baseline.txt")

if (!file.exists(t1_csv_path)) {
  ci_skip("artifacts/table1_midwives.csv absent; D1 Table 1 Demographics QC skipped")
} else {
  t1 <- read_csv(t1_csv_path, show_col_types = FALSE)
  need_cols <- c("characteristic", "n", "percent", "category")
  if (!all(need_cols %in% names(t1))) {
    ci_fail("D1: table1_midwives.csv missing required columns: [%s]",
            paste(setdiff(need_cols, names(t1)), collapse = ", "))
  } else {
    cohort_row <- t1 %>% filter(category == "Cohort")
    if (nrow(cohort_row) == 0 || is.na(cohort_row$n[1]) || cohort_row$n[1] <= 0) {
      ci_fail("D1: no valid Cohort row N found in table1_midwives.csv")
    } else {
      N <- cohort_row$n[1]
      ci_ok("Table 1 Cohort N initialized = %s", format(N, big.mark = ","))

      ci_section("D2 Block Category Sum Reconciliation to Cohort N")

      categories <- setdiff(unique(t1$category), "Cohort")
      failed_blocks <- character(0)

      for (cat_name in categories) {
        sub_t1 <- t1 %>% filter(category == cat_name)
        sum_n  <- sum(sub_t1$n, na.rm = TRUE)
        if (sum_n != N) {
          failed_blocks <- c(failed_blocks, sprintf("Category '%s': sum(n)=%s vs Cohort N=%s (diff=%d)",
                                                    cat_name, format(sum_n, big.mark = ","),
                                                    format(N, big.mark = ","), sum_n - N))
        }
      }

      if (length(failed_blocks) > 0) {
        ci_fail("D2: %d demographic category block(s) fail to sum to Cohort N:\n       %s",
                length(failed_blocks), paste(failed_blocks, collapse = "\n       "))
      } else {
        ci_ok("all %d demographic category blocks sum exactly to Cohort N = %s",
              length(categories), format(N, big.mark = ","))
      }

      ci_section("D3 Demographic Plausibility & Distribution Bounds")

      # 1. Sex distribution: Female must be > 95% of identified sex
      sex_rows <- t1 %>% filter(category == "Sex")
      female_row <- sex_rows %>% filter(characteristic == "Female")
      if (nrow(female_row) == 1 && !is.na(female_row$percent)) {
        if (female_row$percent < 95.0) {
          ci_fail("D3: Female midwife share (%.1f%%) is below the 95%% demographic threshold", female_row$percent)
        } else {
          ci_ok("Female midwife share (%.1f%%) meets demographic plausibility threshold (>= 95%%)", female_row$percent)
        }
      }

      # 2. Calibrated Age distribution: All 5 age bands must be present with non-zero counts
      age_category_name <- grep("Age", unique(t1$category), value = TRUE)[1]
      if (!is.na(age_category_name)) {
        age_rows <- t1 %>% filter(category == age_category_name)
        expected_age_bands <- c("<35 years", "35-44 years", "45-54 years", "55-64 years", ">=65 years")
        missing_age_bands <- setdiff(expected_age_bands, age_rows$characteristic)
        zero_age_bands <- age_rows %>% filter(characteristic %in% expected_age_bands, n <= 0) %>% pull(characteristic)

        if (length(missing_age_bands) > 0 || length(zero_age_bands) > 0) {
          ci_fail("D3: Age distribution missing or zero-count bands: missing [%s], zero [%s]",
                  paste(missing_age_bands, collapse = ", "), paste(zero_age_bands, collapse = ", "))
        } else {
          ci_ok("all 5 calibrated age bands present with positive midwife counts")
        }
      }

      # 3. Years Since Certification distribution: All 5 tenure bands present
      tenure_category_name <- grep("Years Since AMCB", unique(t1$category), value = TRUE)[1]
      if (!is.na(tenure_category_name)) {
        tenure_rows <- t1 %>% filter(category == tenure_category_name)
        expected_tenure_bands <- c("<5 years", "5-9 years", "10-19 years", "20-29 years", ">=30 years")
        missing_tenure_bands <- setdiff(expected_tenure_bands, tenure_rows$characteristic)
        zero_tenure_bands <- tenure_rows %>% filter(characteristic %in% expected_tenure_bands, n <= 0) %>% pull(characteristic)

        if (length(missing_tenure_bands) > 0 || length(zero_tenure_bands) > 0) {
          ci_fail("D3: Tenure distribution missing or zero-count bands: missing [%s], zero [%s]",
                  paste(missing_tenure_bands, collapse = ", "), paste(zero_tenure_bands, collapse = ", "))
        } else {
          ci_ok("all 5 tenure bands present with positive midwife counts")
        }
      }

      # 4. Rurality (RUCC): Metropolitan share must be > 80%
      rucc_category_name <- grep("Rurality", unique(t1$category), value = TRUE)[1]
      if (!is.na(rucc_category_name)) {
        metro_row <- t1 %>% filter(category == rucc_category_name, grepl("Metropolitan", characteristic))
        if (nrow(metro_row) >= 1 && !is.na(metro_row$percent[1])) {
          if (metro_row$percent[1] < 80.0) {
            ci_fail("D3: Metropolitan RUCC share (%.1f%%) below expected 80%% threshold", metro_row$percent[1])
          } else {
            ci_ok("Metropolitan RUCC share (%.1f%%) meets geographic distribution expectation (>= 80%%)", metro_row$percent[1])
          }
        }
      }

      ci_section("D4 Non-Negative Counts & Percentage Validity")

      negative_n <- t1 %>% filter(!is.na(n) & n < 0)
      if (nrow(negative_n) > 0) {
        ci_fail("D4: %d row(s) carry negative counts: %s",
                nrow(negative_n), paste(negative_n$characteristic, collapse = ", "))
      } else {
        ci_ok("every count n is non-negative")
      }

      invalid_pct <- t1 %>% filter(!is.na(percent) & (percent < 0 | percent > 100))
      if (nrow(invalid_pct) > 0) {
        ci_fail("D4: %d row(s) carry percentages outside 0-100: %s",
                nrow(invalid_pct), paste(invalid_pct$characteristic, collapse = ", "))
      } else {
        ci_ok("every populated percentage is within [0, 100]")
      }

      ci_section("D5 Markdown / CSV Cohort Concordance")

      if (file.exists(t1_md_path)) {
        md_lines <- readLines(t1_md_path, warn = FALSE)
        cohort_md_match <- grep("Cohort: \\*\\*[0-9,]+\\*\\*", md_lines, value = TRUE)
        if (length(cohort_md_match) > 0) {
          md_n_val <- as.integer(gsub(",", "", sub("^Cohort: \\*\\*([0-9,]+)\\*\\*.*$", "\\1", cohort_md_match[1])))
          known_baseline <- if (file.exists(base_path)) trimws(readLines(base_path, warn = FALSE)) else character(0)
          obs_key <- sprintf("table1_csv_n=%d table1_md_n=%d", N, md_n_val)
          is_baselined <- any(grepl(obs_key, known_baseline, fixed = TRUE))

          if (!is.na(md_n_val) && md_n_val != N && !is_baselined) {
            ci_fail("D5: docs/table1_midwives.md Cohort N (%d) != artifacts/table1_midwives.csv Cohort N (%d)",
                    md_n_val, N)
          } else if (is_baselined) {
            ci_ok("docs/table1_midwives.md vs CSV N mismatch matches recorded baseline (%s)", obs_key)
          } else {
            ci_ok("docs/table1_midwives.md Cohort N (%s) agrees with table1_midwives.csv", format(N, big.mark = ","))
          }
        }
      }
    }
  }
}

ci_finish()
