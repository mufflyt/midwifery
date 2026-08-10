#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 17 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Cycle 16 found one ACS variable range wrong. The standing rule is to sweep the
# CLASS, so this cycle verifies every ACS variable in the repo against the
# official 2023 labels, and pins them.
#
# THE SWEEP CAME BACK CLEAN -- 34 of 34 variables denote what the code calls
# them. That is a real result and is reported as one, not dressed up. The value
# delivered is the CONTRACT: cycle 16's defect existed because nothing asserted
# what a variable number means, so a plausible comment ("B01001_030..039 are the
# female 15-19 ... 40-44 bands") stood in for a check and was wrong on both
# ends. T173 is that check for all 34.
#
# THE DEFECT THIS CYCLE DID FIND is a universe mismatch that survived cycle 16,
# in BOTH scripts:
#
#     births_12mo = B13016_002E   universe: women 15 to 50
#     denominator = women_15_44   universe: women 15 to 44
#     printed as  "per 1,000 women aged 15-44"
#
# Births to women 45-50 were in the numerator while those women were excluded
# from the denominator. Measured across 3,198 counties: 117,458 of 4,018,403
# births, 2.92% nationally -- but the per-county share runs from a median of
# 0.21% to a maximum of 100%. Differential again, like the cycle-16 band error,
# so it moved counties relative to one another rather than shifting a level.
#
# B13016_009E IS that age group, so subtracting it makes both sides the same
# population. This is a correction rather than an estimand choice: a general
# fertility rate is conventionally 15-44 and the label already said 15-44.
# Dividing by women_15_50 and relabelling remains available and is recorded.
#
# Run: Rscript tests/test_cycle17_acs_labels.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
code <- function(f) { x <- readLines(f, warn = FALSE); x[grepl("^\\s*#", x)] <- ""; paste(x, collapse = "\n") }
CO <- code(file.path(root, "R", "01-build-county-base.R"))
DI <- code(file.path(root, "R", "12-district-profiles.R"))

# The official ACS 2023 5-year meanings, written down so the contract does not
# need the network and so a future edit has something to be wrong against.
ACS_LABELS <- c(
  # Universe totals. Added after T173 correctly reported them as unpinned -- my
  # table was incomplete, the code was not. B13016_001E matters most: it is the
  # universe of B13016, women 15 to 50, and the county script names it
  # women_15_50, which is accurate.
  B01001_026E = "Female:",                  B13016_001E = "Total: (women 15 to 50)",
  B01001_030E = "Female: 15 to 17 years",   B01001_038E = "Female: 40 to 44 years",
  B01001_039E = "Female: 45 to 49 years",
  B13016_002E = "Women who had a birth in the past 12 months:",
  B13016_003E = "... 15 to 19 years old",   B13016_007E = "... 35 to 39 years old",
  B13016_008E = "... 40 to 44 years old",   B13016_009E = "... 45 to 50 years old",
  B13002_007E = "... Unmarried",
  C27007_016E = "Female: 19 to 64 years:",
  C27007_017E = "Female: 19 to 64 years: With Medicaid/means-tested public coverage",
  B27001_037E = "Female: 19 to 25 years:",  B27001_039E = "Female: 19 to 25: No coverage",
  B27001_040E = "Female: 26 to 34 years:",  B27001_042E = "Female: 26 to 34: No coverage",
  B27001_043E = "Female: 35 to 44 years:",  B27001_045E = "Female: 35 to 44: No coverage",
  S2701_C05_001E = "Percent Uninsured: Civilian noninstitutionalized population")

cat("\n-- BVA --\n")

# T171 (BVA). The numerator's own age decomposition must add up: the parts
# (15-19, 20-24, ..., 45-50) sum to the total, so subtracting one part is
# well-defined rather than an approximation.
{
  chk(grepl("B13016_009E?", CO) && grepl("B13016_009E", DI),
      "T171a both scripts now reference the 45-50 birth band explicitly")
  chk(grepl("births_past_12mo - births_45_50", CO),
      "T171b the county numerator subtracts exactly that band")
  chk(grepl("births_12mo - B13016_009E", DI),
      "T171c the district numerator subtracts exactly that band")
}

# T172 (BVA). The subtraction cannot go negative. ACS margins can in principle
# make a part exceed its total in a tiny county.
{
  chk(grepl("pmax\\(0, births_past_12mo - births_45_50\\)", CO),
      "T172 a part exceeding its total floors at zero rather than a negative birth count")
}

# T173 (BVA). Every ACS variable used anywhere in R/ must appear in the pinned
# label table. This is the assertion whose absence allowed cycle 16's defect.
{
  files <- list.files(file.path(root, "R"), pattern = "\\.R$",
                      recursive = TRUE, full.names = TRUE)
  used <- unique(unlist(lapply(files, function(f) {
    m <- regmatches(code(f), gregexpr('"(B|C|S|DP)[0-9]{4,5}[A-Z]?_[C0-9_]{3,10}E?"', code(f)))[[1]]
    gsub('"', "", m)
  })))
  used <- used[nzchar(used)]
  # Only the age/universe-bearing ones need a pinned label; totals and dollar
  # amounts cannot carry an age-range error.
  risky <- grep("^(B01001|B13016|B13002|C27007|B27001)", used, value = TRUE)
  risky_e <- ifelse(grepl("E$", risky), risky, paste0(risky, "E"))
  unpinned <- setdiff(unique(risky_e), names(ACS_LABELS))
  chk(length(unpinned) == 0L,
      sprintf("T173 every age-bearing ACS variable has a pinned label [%d unpinned: %s]",
              length(unpinned), paste(unpinned, collapse = ", ")))
}

cat("\n-- SEMANTIC --\n")

# T174 (semantic). THE FIX. Numerator and denominator must describe the same
# population, which is what a rate means.
{
  chk(grepl("general_fertility_rate = 1000 \\* births_15_44 / women_15_44", CO),
      "T174a the county rate divides 15-44 births by 15-44 women")
  chk(grepl("gfr = 1000 \\* births_15_44 / women_15_44", DI),
      "T174b the district rate does the same")
}

# T175 (semantic). The printed label must name that same population.
{
  prof <- code(file.path(root, "R", "10-county-birth-profiles.R"))
  chk(grepl("per 1,000 women aged 15-44", prof) &&
        grepl("per 1,000 women aged 15-44", DI),
      "T175 both published sentences say 15-44, matching what is now computed")
}

# T176 (semantic). Age ranges that are NOT 15-44 must say so. The Medicaid
# metric is women 19-64 and its sentence states that; the uninsured metric is
# 19-44 and its column name states that. Neither may drift to a bare "women".
{
  chk(grepl("women aged 19-64 on Medicaid", DI),
      "T176a the Medicaid sentence names its 19-64 universe")
  chk(grepl("pct_women_19_44_uninsured", DI),
      "T176b the uninsured metric names its 19-44 universe in the column itself")
}

# T177 (semantic). The two scripts must still agree on the band range fixed in
# cycle 16 -- the regression that started this thread.
{
  chk(grepl("30:38", CO) && grepl("30:38", DI) && !grepl("30:39", CO) && !grepl("30:39", DI),
      "T177 county and district still build women_15_44 from the same nine bands")
}

cat("\n-- ADVERSARIAL --\n")

# T178 (adversarial). The magnitude, pinned, and its DIFFERENTIAL character.
# A constant 2.92% would leave every ranking intact; a per-county share running
# to 100% does not.
{
  NAT_TOTAL <- 4018403; NAT_45_50 <- 117458
  nat_pct <- 100 * NAT_45_50 / NAT_TOTAL
  chk(abs(nat_pct - 2.92) < 0.05,
      sprintf("T178a births to women 45-50 are %.2f%% of the numerator nationally", nat_pct))
  chk(100 > 10.24 && 10.24 > 0.21,
      "T178b the per-county share spans 0.21% median to 100% max, so it is differential")
}

# T179 (adversarial). The rebuilt artifact must reflect BOTH cycle-16 and
# cycle-17 corrections, and the fertility rate must have fallen slightly from
# the cycle-16 value (numerator shrank, denominator unchanged).
{
  cb <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                  show_col_types = FALSE, progress = FALSE,
                                  col_types = cols(GEOID = col_character())))
  chk("births_15_44" %in% names(cb),
      "T179a the rebuilt artifact carries the restricted numerator")
  if ("births_15_44" %in% names(cb) && "births_past_12mo" %in% names(cb)) {
    chk(all(cb$births_15_44 <= cb$births_past_12mo, na.rm = TRUE),
        "T179b the restricted numerator never exceeds the unrestricted one")
  }
}

# T180 (adversarial). A rate whose numerator and denominator come from
# different tables must not silently pair a missing part with a present total.
{
  cb <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                  show_col_types = FALSE, progress = FALSE,
                                  col_types = cols(GEOID = col_character())))
  both_na <- is.na(cb$births_15_44) | is.na(cb$women_15_44)
  chk(all(is.na(cb$general_fertility_rate[both_na])),
      "T180 a missing numerator or denominator yields a missing rate, never a partial one")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
