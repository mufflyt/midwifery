#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 1 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Targets: the banding and parsing rules behind Table 1. Rurality is the
# stratifier for the access findings and the enumeration year drives two of
# the six characteristic blocks, so a silent misclassification here changes a
# published table rather than a log line.
#
# Run: Rscript tests/test_table1_bands.R
# =============================================================================

src <- file.path(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)[1])),
                 "..", "R", "lib", "table1_bands.R")
source(if (file.exists(src)) src else "R/lib/table1_bands.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- BVA --\n")

# T1. Band edges are closed on the left. An off-by-one here moves people
# between published rows, and 5/10/15/20 are exactly where a `<=` typo hides.
e <- band_years_since_enum(c(0, 4, 5, 9, 10, 14, 15, 19, 20, 25))
chk(identical(e, c("<5 years", "<5 years", "5-9 years", "5-9 years",
                   "10-14 years", "10-14 years", "15-19 years", "15-19 years",
                   ">=20 years", ">=20 years")),
    "enumeration bands are closed on the left at 5/10/15/20")

# T2. One appearance in the panel is ONE year, not zero: the span is
# inclusive. A first==last person banded as 0 would be dropped from the
# denominator entirely.
chk(identical(band_years_observed(c(1, 4, 5, 9, 10, 14, 15, 19)),
              c("<5 years", "<5 years", "5-9 years", "5-9 years",
                "10-14 years", "10-14 years", ">=15 years", ">=15 years")),
    "observed-years bands treat a single appearance as 1 year")

# T3. RUCC edges, including the codes just outside the valid range. 0 and 10
# must be NA, never the terminal band.
chk(identical(band_rurality(c(1, 3, 4, 6, 7, 9, 0, 10, 99, NA)),
              c("Metropolitan (RUCC 1-3)", "Metropolitan (RUCC 1-3)",
                "Nonmetropolitan, adjacent (RUCC 4-6)",
                "Nonmetropolitan, adjacent (RUCC 4-6)",
                "Nonmetropolitan, remote (RUCC 7-9)",
                "Nonmetropolitan, remote (RUCC 7-9)",
                NA_character_, NA_character_, NA_character_, NA_character_)),
    "RUCC 0, 10, 99 and NA are unclassifiable, not 'remote'")

# T4. Degenerate numerics must not reach a band. Inf passing a `< 5` test or
# a negative year landing in "<5 years" both fabricate members.
chk(all(is.na(band_years_since_enum(c(NA, Inf, -Inf, -1, NaN, 26)))) &&
      all(is.na(band_years_observed(c(NA, Inf, -1, 0, NaN)))),
    "NA, Inf, NaN, negative and out-of-window values band to NA")

cat("\n-- SEMANTIC --\n")

# T5. Equivalent inputs must give equivalent answers. The same date in ISO and
# US form is the same date; a positional parser returns 0512 for the ISO form,
# which fails the plausibility window and becomes NA -- the variable is lost
# for every row while looking merely missing.
chk(identical(parse_enum_year(c("05/12/2007", "2007-05-12", "12-05-2007")),
              c(2007L, 2007L, 2007L)),
    "the same date parses to the same year in ISO and US formats")

# T6. Labels must describe the quantity actually computed: every value banded
# "5-9 years" lies in [5, 9]. Checked exhaustively rather than by example.
v <- seq(0, 25, by = 0.5)
b <- band_years_since_enum(v)
rng_ok <- all(v[b == "<5 years"] < 5, na.rm = TRUE) &&
  all(v[b == "5-9 years"] >= 5 & v[b == "5-9 years"] < 10, na.rm = TRUE) &&
  all(v[b == "10-14 years"] >= 10 & v[b == "10-14 years"] < 15, na.rm = TRUE) &&
  all(v[b == "15-19 years"] >= 15 & v[b == "15-19 years"] < 20, na.rm = TRUE) &&
  all(v[b == ">=20 years"] >= 20, na.rm = TRUE)
chk(rng_ok, "every band label bounds the values assigned to it")

# T7. The bands partition the domain: exhaustive and mutually exclusive. A gap
# silently drops people from the table; an overlap double-counts them.
chk(!any(is.na(b)) && length(unique(b)) == 5,
    "bands are exhaustive and mutually exclusive over the plausible domain")

cat("\n-- ADVERSARIAL --\n")

# T8. A county FIPS carrying two DIFFERENT RUCC codes must stop the run.
# distinct(.keep_all = TRUE) resolves such a conflict by row order, so the
# same county is metropolitan or remote depending on how the file was sorted.
dup_ok <- tryCatch({
  build_rucc_lookup(c("01001", "01001"), c(1, 8)); FALSE
}, error = function(e) grepl("conflicting", e$message))
chk(dup_ok, "conflicting duplicate FIPS raise an error instead of picking one")

# Identical duplicates carry no conflict and must collapse quietly.
chk(nrow(build_rucc_lookup(c("01001", "01001"), c(1, 1))) == 1L,
    "identical duplicate FIPS collapse without error")

# T9. Row order must not change any result. Banding is a row-wise map, so a
# reordered input must produce the correspondingly reordered output.
set.seed(1)
x9 <- c(2, 7, 12, 17, 22, NA, 30)
p  <- sample(seq_along(x9))
chk(identical(band_years_since_enum(x9)[p], band_years_since_enum(x9[p])),
    "banding is invariant to row order")

# T10. Types that arrive from readr/readxl without warning -- character,
# factor -- must not silently misclassify. A factor passed to as.integer()
# yields its LEVEL INDEX, so factor("7") can become 1 and a remote county
# reads as metropolitan.
chk(identical(band_rurality(c("7", "1")), band_rurality(c(7, 1))) &&
      identical(band_rurality(factor(c("7", "1"))), band_rurality(c(7, 1))),
    "character and factor RUCC codes band identically to numeric")

cat("\n-- band_hg_age: BVA --\n")

# T11. Band edges are closed on the left at 35/45/55/65. Off-by-one here
# shifts a midwife's decade in a published demographic row.
a <- band_hg_age(c(34, 35, 44, 45, 54, 55, 64, 65, 100))
chk(identical(a, c("<35 years", "35-44 years", "35-44 years", "45-54 years",
                   "45-54 years", "55-64 years", "55-64 years",
                   ">=65 years", ">=65 years")),
    "hg_age bands are closed on the left at 35/45/55/65")

# T12. Ages outside the plausible window (< 18 or > 120) must be NA, not
# absorbed into the terminal bands.
chk(all(is.na(band_hg_age(c(NA, 17, 0, -1, 121, Inf, -Inf, NaN)))),
    "implausible ages (< 18, > 120, Inf, NaN, NA) band to NA")

cat("\n-- band_hg_age: SEMANTIC --\n")

# T13. Every value assigned to a band label actually falls within that band's
# stated range — labels must not lie about who they contain.
ages <- seq(18, 120, by = 1)
ba   <- band_hg_age(ages)
rng_ok_hg <-
  all(ages[!is.na(ba) & ba == "<35 years"]  < 35) &&
  all(ages[!is.na(ba) & ba == "35-44 years"] >= 35 & ages[!is.na(ba) & ba == "35-44 years"] < 45) &&
  all(ages[!is.na(ba) & ba == "45-54 years"] >= 45 & ages[!is.na(ba) & ba == "45-54 years"] < 55) &&
  all(ages[!is.na(ba) & ba == "55-64 years"] >= 55 & ages[!is.na(ba) & ba == "55-64 years"] < 65) &&
  all(ages[!is.na(ba) & ba == ">=65 years"]  >= 65)
chk(rng_ok_hg, "every hg_age band label bounds the values assigned to it")

# T14. Bands are exhaustive over the plausible domain and mutually exclusive.
chk(!any(is.na(ba)) && length(unique(ba)) == 5L,
    "hg_age bands are exhaustive and mutually exclusive over ages 18-120")

cat("\n-- band_hg_age: ADVERSARIAL --\n")

# T15. Character and factor inputs (as Healthgrades data often arrives) must
# band identically to numeric.
chk(identical(band_hg_age(c("34", "35", "65")), band_hg_age(c(34, 35, 65))) &&
      identical(band_hg_age(factor(c("34", "35", "65"))), band_hg_age(c(34, 35, 65))),
    "character and factor ages band identically to numeric")

# T16. Row order must not change any result.
set.seed(2)
x16 <- c(25, 40, 50, 60, 70, NA, 18)
p16 <- sample(seq_along(x16))
chk(identical(band_hg_age(x16)[p16], band_hg_age(x16[p16])),
    "hg_age banding is invariant to row order")

# T17. Zero-length input must return zero-length character, not crash and not
# logical(0). A logical(0) in a downstream bind_rows() poisons the column type
# and produces NA in every row — the same defect fixed for band_cert_decade().
chk(identical(band_hg_age(numeric(0)), character(0)),
    "zero-length input returns zero-length character (not logical(0))")

# T18. Decimal boundary values. The bands are right-closed on integers, but
# Healthgrades sometimes returns fractional ages. 34.9 must stay in "<35" and
# 35.0 must enter "35-44"; a >= vs > confusion at the boundary moves everyone
# who is exactly 35, 45, 55, or 65 into the wrong decade.
chk(identical(band_hg_age(c(34.9, 35.0, 44.9, 45.0, 54.9, 55.0, 64.9, 65.0)),
              c("<35 years", "35-44 years", "35-44 years", "45-54 years",
                "45-54 years", "55-64 years", "55-64 years", ">=65 years")),
    "decimal boundary values (34.9/35.0, 44.9/45.0, ...) land in the correct band")

# T19. Exact plausibility fence. 17 is out; 18 is in. 120 is in; 121 is out.
# The terminal exclusions guard against Healthgrades returning placeholder ages
# (999, 0) being absorbed into the "<35" or ">=65" band as real data.
chk(is.na(band_hg_age(17)) && band_hg_age(18) == "<35 years" &&
      band_hg_age(120) == ">=65 years" && is.na(band_hg_age(121)),
    "plausibility fence: 17 and 121 are NA; 18 and 120 are classified")

# T20. A vector of all-NA input must return all-NA, not error, not produce a
# band label. If the scrape returns no ages the function must not fabricate any.
chk(all(is.na(band_hg_age(c(NA_real_, NA_real_, NA_integer_)))),
    "all-NA input returns all-NA output")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
