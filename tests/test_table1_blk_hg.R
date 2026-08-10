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
    miss <- max(0L, N_hg - known)
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

# T10b. category is propagated to EVERY row, including Unknown. A join on
# category downstream would silently drop the unknown count if it is blank.
chk(all(r10$category == "Sex (Healthgrades)"),
    "category is propagated to every row including Unknown / not recorded")

# T10c. Unknown row has NA percent, not 0. Reporting 0% for the unknown count
# would imply the unknown fraction is zero, which contradicts its own n.
unknown_pct <- r10$percent[r10$characteristic == "Unknown / not recorded"]
chk(is.na(unknown_pct),
    "Unknown / not recorded row has NA percent, not 0")

cat("\n-- BVA: denominator edge cases --\n")

# T11. All values NA (known = 0). Must produce only the Unknown row with
# n = N_hg and no value rows -- not a division-by-zero crash, not a row for NA.
hg_allna <- tibble(certification_number = paste0("C", 3:12),
                   hg_x = rep(NA_character_, 10))
blk_allna <- make_blk_hg(hg_allna, N_fix, amb_fix)
r11 <- blk_allna("hg_x", "Test")
chk(nrow(r11) == 1L && r11$characteristic == "Unknown / not recorded" &&
      r11$n == 10L,
    "all-NA column: only Unknown row with n = N_hg, no crash")

# T12. All values known (known = N_hg). Unknown row must still appear with n = 0,
# not be silently dropped. Dropping it hides the fact that the denominator
# changed relative to registry-sourced rows above it.
hg_allknown <- tibble(certification_number = paste0("C", 3:12),
                      hg_x = rep("Female", 10))
blk_allknown <- make_blk_hg(hg_allknown, N_fix, amb_fix)
r12 <- blk_allknown("hg_x", "Test")
unknown12 <- r12[r12$characteristic == "Unknown / not recorded", ]
chk(nrow(unknown12) == 1L && unknown12$n == 0L,
    "all-known column: Unknown row present with n = 0 (denominator still visible)")

# T13. Zero-row hg_link (scrape ran but matched nobody). Known = 0, miss = N_hg.
# Must not crash; must not report negative unknowns.
hg_empty <- tibble(certification_number = character(0), hg_x = character(0))
blk_empty <- make_blk_hg(hg_empty, N_fix, amb_fix)
r13 <- blk_empty("hg_x", "Test")
chk(nrow(r13) == 1L && r13$n == 10L && r13$characteristic == "Unknown / not recorded",
    "zero-row hg_link: Unknown row n = N_hg, no crash")

cat("\n-- BVA: binary_yes edge cases --\n")

# T14. binary_yes with no matching values (all FALSE). The Yes row must be
# absent or n=0; the No row must carry all known n. A missing Yes row is fine
# as long as percent is correct -- but a present Yes row with n=0 that still
# gets 0% is also acceptable. Either way No must hold all known counts.
hg_allno <- tibble(certification_number = paste0("C", 3:12),
                   hg_b = c(FALSE, FALSE, FALSE, NA, NA, NA, NA, NA, NA, NA))
blk_allno <- make_blk_hg(hg_allno, N_fix, amb_fix)
r14 <- blk_allno("hg_b", "Test", binary_yes = c("TRUE", TRUE))
no_row14 <- r14[r14$characteristic == "No", ]
chk(nrow(no_row14) == 1L && no_row14$n == 3L,
    "binary_yes with no True values: No row holds all known n")

# T15. binary_yes percent sums to 100 across Yes + No even when one side is
# absent. This guards against percent being computed on N_hg instead of known.
hg_mix <- tibble(certification_number = paste0("C", 3:12),
                 hg_b = c(TRUE, TRUE, FALSE, FALSE, FALSE, NA, NA, NA, NA, NA))
blk_mix <- make_blk_hg(hg_mix, N_fix, amb_fix)
r15 <- blk_mix("hg_b", "Test", binary_yes = c("TRUE", TRUE))
value_rows15 <- r15[r15$characteristic %in% c("Yes", "No"), ]
chk(abs(sum(value_rows15$percent, na.rm = TRUE) - 100) < 0.2,
    "binary_yes Yes + No percents sum to 100 regardless of split")

cat("\n-- ADVERSARIAL --\n")

# T16. Duplicate certification_numbers in hg_link inflate row counts. If the
# same person appears twice (e.g., two practice sites joined in), blk_hg()
# will count them as two people. This is a KNOWN HAZARD: blk_hg() trusts its
# caller to deduplicate on certification_number before passing hg_link in.
# The test documents the defect rather than hiding it.
hg_dup <- tibble(certification_number = c("C003", "C003", paste0("C", 4:12)),
                 hg_gender = c("Female", "Female", "Female", "Male",
                               rep(NA_character_, 7)))
blk_dup <- make_blk_hg(hg_dup, N_fix, amb_fix)
r16 <- blk_dup("hg_gender", "Sex (Healthgrades)")
female16 <- r16$n[r16$characteristic == "Female"]
chk(female16 == 3L,
    paste0("DOCUMENTED HAZARD: duplicate rows in hg_link inflate counts ",
           sprintf("[Female n=%d, expected 2 unique people but caller sent 3 rows]",
                   female16)))

# T17. N_hg - known goes negative when hg_link has more rows than eligible
# midwives (possible with the duplicate defect above or a join explosion).
# The Unknown row must not carry a negative n, which would be published as-is.
hg_excess <- tibble(
  certification_number = paste0("C", 3:22),   # 20 rows, N_hg is only 10
  hg_gender = rep("Female", 20))
blk_excess <- make_blk_hg(hg_excess, N_fix, amb_fix)
r17 <- blk_excess("hg_gender", "Sex (Healthgrades)")
miss17 <- r17$n[r17$characteristic == "Unknown / not recorded"]
chk(miss17 >= 0L,
    paste0("DOCUMENTED HAZARD: N_hg - known is negative when hg_link has more rows ",
           sprintf("than eligible midwives [Unknown n=%d] -- caller must deduplicate",
                   miss17)))

# T18. Category string containing special characters (spaces, slashes) must
# propagate intact to every row. A downstream regex or split on "/" would
# corrupt a multi-word category name but that is the caller's problem;
# blk_hg()'s contract is to pass it through unchanged.
r18 <- blk_hg("hg_gender", "Sex / gender (HG)")
chk(all(r18$category == "Sex / gender (HG)"),
    "category with special characters propagates intact to every row")

# T19. The percent on value rows must be computed on the non-missing denominator
# within the hg_link rows, NOT on N_hg. If computed on N_hg, female_pct would
# be 3/10 = 30%; if computed on known (4), it is 75%. A Table 1 that uses N_hg
# as the percent denominator understates prevalence by up to 4x at 25% fill.
r19 <- blk_hg("hg_gender", "Sex (Healthgrades)")
female_pct19 <- r19$percent[r19$characteristic == "Female"]
chk(abs(female_pct19 - 75.0) < 0.1,
    sprintf("percent uses non-missing denominator (75%%), not N_hg (30%%) [got %.1f%%]",
            female_pct19))

# T20. lvls that include a value not present in the data must not crash or
# produce a phantom row. If "X (other)" is in lvls but no midwife has it,
# the output must simply omit that level silently.
r20 <- blk_hg("hg_gender", "Sex (Healthgrades)",
               lvls = c("Female", "Male", "X (other)"))
chk(!"X (other)" %in% r20$characteristic,
    "lvls value absent from data does not produce a phantom row")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
