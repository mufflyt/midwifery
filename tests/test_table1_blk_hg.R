#!/usr/bin/env Rscript
# =============================================================================
# Tests for blk_hg() -- the Healthgrades Table 1 row builder
# =============================================================================
# blk_hg() is defined in build_table1_midwives.R against global state (hg_link,
# N, hg_ambiguous). It is re-declared inline here with identical logic so it
# can be exercised against controlled inputs without loading the full pipeline.
#
# Run: Rscript tests/test_table1_blk_hg.R
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(tibble)
})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# ---------------------------------------------------------------------------
# Inline copy of blk_hg() from build_table1_midwives.R — any change there
# must be reflected here. The point is to test LOGIC, not to re-source a
# script that tries to open files.
# ---------------------------------------------------------------------------
make_blk_hg <- function(hg_link, N, hg_ambiguous) {
  function(col, category, lvls = NULL, binary_yes = NULL) {
    if (is.null(hg_link) || !col %in% names(hg_link)) {
      return(tibble(characteristic = "Healthgrades data not available",
                    n = NA_integer_, percent = NA_real_, category = category))
    }
    N_hg <- N - length(hg_ambiguous)
    v <- hg_link[[col]]
    if (!is.null(binary_yes))
      v <- dplyr::if_else(as.character(v) %in% as.character(binary_yes),
                          "Yes",
                          dplyr::if_else(is.na(v), NA_character_, "No"))
    known <- sum(!is.na(v))
    out <- tibble(characteristic = as.character(v)) %>%
      filter(!is.na(characteristic)) %>%
      count(characteristic, name = "n") %>%
      mutate(percent = round(100 * n / known, 1), category = category)
    if (!is.null(lvls))
      out <- out %>% arrange(match(characteristic, lvls))
    else
      out <- out %>% arrange(desc(n))
    miss <- N_hg - known
    bind_rows(out, tibble(characteristic = "Unknown / not recorded",
                          n = miss, percent = NA_real_, category = category))
  }
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# 10 eligible midwives (N=12, 2 ambiguous => N_hg=10).
# 4 have gender data; 6 are unknown.
N_fix   <- 12L
amb_fix <- c("C001", "C002")   # 2 shared-profile exclusions
hg_fix  <- tibble(
  certification_number = paste0("C", sprintf("%03d", 3:12)),  # C003–C012
  hg_gender = c("Female", "Female", "Female", "Male", NA, NA, NA, NA, NA, NA),
  hg_bool   = c(TRUE, TRUE, FALSE, NA, NA, NA, NA, NA, NA, NA)
)
blk_hg <- make_blk_hg(hg_fix, N_fix, amb_fix)

cat("\n-- NULL / missing column guards --\n")

# T1. NULL hg_link must return a single "not available" row, not crash.
blk_null <- make_blk_hg(NULL, N_fix, amb_fix)
r1 <- blk_null("hg_gender", "Sex (Healthgrades)")
chk(nrow(r1) == 1L && r1$characteristic == "Healthgrades data not available",
    "NULL hg_link returns 'not available' row")

# T2. A column that doesn't exist in hg_link must also return the guard row.
r2 <- blk_hg("hg_nonexistent", "Missing col")
chk(nrow(r2) == 1L && r2$characteristic == "Healthgrades data not available",
    "missing column name returns 'not available' row")

cat("\n-- denominator correctness --\n")

# T3. Unknown / not recorded n = N_hg - known (10 - 4 = 6 here).
# The denominator is N - ambiguous, NOT the full cohort N.
r3 <- blk_hg("hg_gender", "Sex (Healthgrades)")
unknown_row <- r3[r3$characteristic == "Unknown / not recorded", ]
chk(unknown_row$n == 6L,
    "Unknown row n = N_hg - known_profiles (uses eligible denominator, not N)")

# T4. percent is computed on the known denominator, not N_hg or N.
# 3 Female out of 4 known = 75%.
female_row <- r3[r3$characteristic == "Female", ]
chk(abs(female_row$percent - 75) < 0.1,
    "percent is computed on the non-missing denominator only")

cat("\n-- binary_yes coercion --\n")

# T5. Logical TRUE values are coerced to "Yes"; FALSE to "No"; NA stays NA.
# 2 TRUE, 1 FALSE, 7 NA => Yes=2, No=1, Unknown=7.
r5 <- blk_hg("hg_bool", "Accepts new patients",
              binary_yes = c("TRUE", TRUE))
yes_row  <- r5[r5$characteristic == "Yes",  ]
no_row   <- r5[r5$characteristic == "No",   ]
unk_row  <- r5[r5$characteristic == "Unknown / not recorded", ]
chk(yes_row$n == 2L && no_row$n == 1L && unk_row$n == 7L,
    "binary_yes coerces TRUE->Yes / FALSE->No / NA stays unknown")

# T6. percent within binary_yes sums to 100 across Yes + No rows.
pct_sum <- sum(r5$percent, na.rm = TRUE)
chk(abs(pct_sum - 100) < 0.2,
    "Yes + No percents sum to 100 (within rounding)")

cat("\n-- ordering --\n")

# T7. When lvls is supplied, rows appear in that order (Female before Male).
r7 <- blk_hg("hg_gender", "Sex (Healthgrades)", lvls = c("Female", "Male"))
value_rows <- r7[r7$characteristic != "Unknown / not recorded", ]
chk(value_rows$characteristic[1] == "Female" && value_rows$characteristic[2] == "Male",
    "lvls ordering is respected (Female before Male)")

# T8. Without lvls, rows are sorted descending by n (Female=3 before Male=1).
r8 <- blk_hg("hg_gender", "Sex (Healthgrades)")
value_rows8 <- r8[r8$characteristic != "Unknown / not recorded", ]
chk(value_rows8$n[1] >= value_rows8$n[2],
    "without lvls, rows are ordered descending by n")

# T9. Unknown / not recorded row is always last regardless of lvls.
chk(tail(r7$characteristic, 1) == "Unknown / not recorded" &&
      tail(r8$characteristic, 1) == "Unknown / not recorded",
    "Unknown row is always last")

cat("\n-- output schema --\n")

# T10. Output always has exactly the four required columns with correct types.
r10 <- blk_hg("hg_gender", "Sex (Healthgrades)")
chk(identical(names(r10), c("characteristic", "n", "percent", "category")) &&
      is.character(r10$characteristic) &&
      is.integer(r10$n) &&
      is.numeric(r10$percent) &&
      is.character(r10$category),
    "output has columns characteristic/n/percent/category with correct types")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
