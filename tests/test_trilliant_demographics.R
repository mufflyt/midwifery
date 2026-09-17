#!/usr/bin/env Rscript
# =============================================================================
# Trilliant's directory as a backup demographic source: R/lib/trilliant_demographics.R
# =============================================================================
# The ways this goes wrong quietly: an "UNSPECIFIED/OTHER" becomes somebody's
# recorded sex; the directory's "Other" becomes a school; a school cleans to a
# different string than DAC's, so one institution is counted twice; and, the
# one that matters most, an age computed from graduation year is admitted as if
# it were a second measurement and overwrites a calibrated age with a worse one.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "training_institution.R"))
source(file.path(root, "R", "lib", "trilliant_demographics.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

cat("\n-- SEX --\n")
chk(identical(trl_sex_code(c("FEMALE", "MALE", "female ")), c("F", "M", "F")), "T1 FEMALE/MALE map to F/M, case and spacing aside")
chk(all(is.na(trl_sex_code(c("UNSPECIFIED/OTHER", "", NA)))),
    "T2 UNSPECIFIED/OTHER, blank and NA are not a sex (NPPES tells X from U; the directory does not)")

cat("\n-- SCHOOL --\n")
chk(identical(trl_school_clean("Georgetown University School of Medicine"),
              strip_med_suffix("GEORGETOWN UNIVERSITY SCHOOL OF MEDICINE")),
    "T3 a directory name cleans to exactly what DAC's upper-case raw string cleans to")
chk(identical(trl_school_clean("Georgetown University School of Medicine"), "GEORGETOWN UNIVERSITY"),
    "T4 the medical-school unit is removed and the university kept")
chk(all(is.na(trl_school_clean(c("Other", "OTHER", " ", NA)))), "T5 the directory's 'Other' placeholder is not a school")
chk(identical(trl_school_clean("Medical University of South Carolina College of Medicine"),
              "MEDICAL UNIVERSITY OF SOUTH CAROLINA"),
    "T6 a university whose NAME starts with 'Medical' survives the cleaning")

cat("\n-- IS THE AGE DERIVED FROM GRADUATION YEAR? --\n")
gy <- c(1990, 2000, 2010, 2015, NA)
d1 <- trl_age_derivation(2052 - gy, gy)
chk(isTRUE(d1$derived) && d1$modal_sum == 2052 && d1$n_both == 4L, "T7 age = constant - graduation year is flagged as derived")
set.seed(1)
real_gy <- sample(1985:2020, 400, replace = TRUE)
d2 <- trl_age_derivation(2026 - real_gy + sample(24:40, 400, replace = TRUE), real_gy)
chk(isFALSE(d2$derived), "T8 an age that varies independently of graduation year is not flagged")
d3 <- trl_age_derivation(c(NA, NA), c(2000, NA))
chk(d3$n_both == 0L && is.na(d3$derived), "T9 with nothing to compare, the answer is NA, not FALSE")
chk(trl_age_derivation(c(50, 60), c(2002, 1992))$modal_sum == 2052 &&
      trl_age_derivation(c(60, 50), c(1992, 2002))$modal_sum == 2052, "T10 the mode does not depend on row order")

cat("\n-- MUST A TRILLIANT AGE BE ADMITTED? --\n")
n <- 300
truth <- round(runif(n, 30, 65))
fitted <- truth + rnorm(n, 0, 6)                      # a calibration off by ~5 years
grad <- sample(1985:2020, n, replace = TRUE)
derived_age <- 2052 - grad                            # the directory's actual construction
a1 <- trl_age_admission(derived_age, grad, truth, fitted, rep(TRUE, n))
chk(!a1$admitted && isTRUE(a1$derived), "T11 a derived age is refused even before its error is looked at")
good <- truth + sample(c(-1, 0, 1), n, replace = TRUE)
a2 <- trl_age_admission(good, grad, truth, fitted, rep(TRUE, n))
chk(a2$admitted && a2$trl_mae < a2$ols_mae, "T12 an independent age closer to the truth than the calibration is admitted")
worse <- truth + rnorm(n, -8, 3)
a3 <- trl_age_admission(worse, grad, truth, fitted, rep(TRUE, n))
chk(!a3$admitted && isFALSE(a3$derived), "T13 an independent age worse than the calibration is refused")
a4 <- trl_age_admission(good, grad, truth, fitted, c(rep(TRUE, 50), rep(FALSE, n - 50)))
chk(!a4$admitted && a4$n_compared == 50L, "T14 fewer than 100 measured ages to compare against is not enough to admit")
a5 <- trl_age_admission(good, grad, replace(truth, 1:10, 99), fitted, rep(TRUE, n))
chk(a5$n_compared == n - 10L, "T15 measured ages outside 21-85 are not used as truth")

cat("\n-- PATIENT PANEL --\n")
p <- data.frame(panel_median_age = c(32, 30, NA, 40),
                panel_percent_age_0_19 = c(0.02, 0.5, NA, 0.1),
                panel_percent_age_20_44 = c(0.90, 0.2, NA, 0.1),
                panel_percent_age_45_64 = c(0.05, 0, NA, 0.1),
                panel_percent_age_65_84 = c(0.03, 0, NA, 0.1),
                panel_percent_age_85_plus = c(0, 0, NA, 0.1))
chk(identical(trl_panel_ok(p), c(TRUE, FALSE, FALSE, FALSE)),
    "T16 a panel is usable only if it exists and its age bands sum to one")
chk(inherits(try(trl_panel_ok(p[, 1:3]), silent = TRUE), "try-error"), "T17 a panel missing an age band is an error, not FALSE")

cat("\n-- THE SCHOOL BACKUP IS LAST --\n")
tmp <- tempfile(fileext = ".csv")
write.csv(data.frame(certification_number = c("A", "B", "C"),
                     trl_school_clean = c("YALE UNIVERSITY", "EMORY UNIVERSITY", NA)), tmp, row.names = FALSE)
coh <- data.frame(certification_number = c("A", "B", "C"), npi = c("1", "2", "3"))
old <- setwd(tempdir())          # no DAC, Healthgrades or repository files here
res <- training_attach(coh, title_case = function(x) x, verbose = FALSE, trilliant_path = tmp)
setwd(old)
chk(identical(res$training_institution, c("YALE UNIVERSITY", "EMORY UNIVERSITY", NA)) &&
      identical(res$training_institution_source, c("Trilliant provider directory", "Trilliant provider directory", NA)),
    "T18 with no other source, the directory names the school and says so")
chk(!"trl_school" %in% names(res), "T19 the working column does not leak into the cohort")
write.csv(data.frame(certification_number = c("A", "A"), trl_school_clean = c("X", "Y")), tmp, row.names = FALSE)
chk(inherits(try(training_source_trilliant(tmp), silent = TRUE), "try-error"),
    "T20 a directory file that repeats a certificant is refused")

cat(if (fails) sprintf("\nFAILURES (%d)\n", fails) else "\nPASS (0 failures)\n")
quit(status = if (fails) 1L else 0L)
