#!/usr/bin/env Rscript
# =============================================================================
# Positive predictive value of each organization-resolution rule
# =============================================================================
# Reads the adjudicated review sample and reports PPV OVERALL and, more
# importantly, SEPARATELY BY RULE.
#
# A SINGLE OVERALL PPV IS NOT ACCEPTED AS AN ANSWER. Evidence strength was
# preserved through the whole pipeline precisely so this question could be
# asked per rule: telephone matches may be near-perfect while
# taxonomy-exclusion matches are not, and a pooled figure would hide exactly
# that. Rules are promoted or rejected individually.
#
# UNREVIEWED IS NOT CORRECT. Rows with a blank human_verdict are excluded from
# the denominator and reported separately, never counted as correct.
# "indeterminate" is also excluded from PPV but reported, because treating an
# uncertain call as a success inflates every rule.
#
# WIDE INTERVALS ARE THE POINT. 25 rows per stratum gives a Wilson interval
# roughly +/-15 points. A rule whose LOWER bound sits below the prespecified
# threshold has not been shown to meet it, however good the point estimate.
#
# Input : artifacts/org_resolution_review_sample.csv  (human_verdict filled in)
# Output: artifacts/org_resolution_ppv.csv
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr); library(stringr) })

F <- Sys.getenv("REVIEW_FILE", "artifacts/org_resolution_review_sample.csv")
THRESHOLD <- suppressWarnings(as.numeric(Sys.getenv("PPV_THRESHOLD", "0.90")))
if (!file.exists(F)) stop(sprintf("Review file not found: %s", F), call. = FALSE)

s <- read_csv(F, show_col_types = FALSE, progress = FALSE,
              col_types = cols(.default = col_character()))
for (cc in c("human_verdict", "review_stratum", "resolution_method"))
  if (!cc %in% names(s))
    stop(sprintf("Review file lacks required column '%s'", cc), call. = FALSE)

s <- s %>% mutate(v = tolower(str_trim(replace(human_verdict, is.na(human_verdict), ""))))
ok <- c("correct", "incorrect", "indeterminate")
bad <- setdiff(unique(s$v[nzchar(s$v)]), ok)
if (length(bad))
  stop(sprintf("Unrecognised human_verdict value(s): %s. Allowed: %s",
               paste(bad, collapse = ", "), paste(ok, collapse = ", ")), call. = FALSE)

n_blank <- sum(!nzchar(s$v))
cat(sprintf("review rows: %d | adjudicated: %d | UNREVIEWED: %d\n",
            nrow(s), sum(nzchar(s$v)), n_blank))
if (n_blank == nrow(s))
  stop("No rows adjudicated yet. Fill human_verdict before running this.",
       call. = FALSE)
if (n_blank > 0)
  cat(sprintf("  %d unreviewed rows are EXCLUDED from every denominator below.\n", n_blank))

# Wilson score interval: the normal approximation is not usable at n=25.
wilson <- function(x, n, conf = 0.95) {
  if (n == 0) return(c(NA_real_, NA_real_))
  z <- qnorm(1 - (1 - conf) / 2); p <- x / n
  d <- 1 + z^2 / n; c((p + z^2/(2*n) - z*sqrt((p*(1-p) + z^2/(4*n))/n))/d,
                      (p + z^2/(2*n) + z*sqrt((p*(1-p) + z^2/(4*n))/n))/d)
}

ppv_by <- function(d, grp) {
  d %>% filter(v %in% c("correct", "incorrect")) %>%
    group_by(across(all_of(grp))) %>%
    summarise(n_adjudicated = n(),
              n_correct = sum(v == "correct"),
              .groups = "drop") %>%
    rowwise() %>%
    mutate(ppv = n_correct / n_adjudicated,
           lo = wilson(n_correct, n_adjudicated)[1],
           hi = wilson(n_correct, n_adjudicated)[2],
           meets_threshold = !is.na(lo) & lo >= THRESHOLD) %>%
    ungroup()
}

# The left-ambiguous stratum has no assignment to be right or wrong about; it
# is reviewed to see whether we WITHHELD a resolution that was in fact
# knowable, which is a different question from PPV.
assigned <- s %>% filter(review_stratum != "left_ambiguous")

cat(sprintf("\n=== PPV BY RESOLUTION RULE (threshold: lower bound >= %.2f) ===\n", THRESHOLD))
by_rule <- ppv_by(assigned, "review_stratum")
print(by_rule %>% mutate(across(c(ppv, lo, hi), ~ round(.x, 3))) %>% as.data.frame())

cat("\n=== PPV BY resolution_method ===\n")
print(ppv_by(assigned, "resolution_method") %>%
        mutate(across(c(ppv, lo, hi), ~ round(.x, 3))) %>% as.data.frame())

cat("\n=== PPV BY confidence tier ===\n")
if ("affiliation_confidence" %in% names(s))
  print(ppv_by(assigned, "affiliation_confidence") %>%
          mutate(across(c(ppv, lo, hi), ~ round(.x, 3))) %>% as.data.frame())

pooled <- assigned %>% filter(v %in% c("correct", "incorrect"))
if (nrow(pooled)) {
  ci <- wilson(sum(pooled$v == "correct"), nrow(pooled))
  cat(sprintf("\npooled PPV: %.3f (95%% CI %.3f-%.3f, n=%d)  -- REPORTED FOR REFERENCE ONLY;\n",
              mean(pooled$v == "correct"), ci[1], ci[2], nrow(pooled)))
  cat("promote or reject rules individually, not on this number.\n")
}

if ("error_type" %in% names(s)) {
  e <- s %>% filter(v == "incorrect", nzchar(replace(error_type, is.na(error_type), "")))
  if (nrow(e)) { cat("\n=== why matches failed ===\n")
    print(e %>% count(review_stratum, error_type, sort = TRUE) %>% as.data.frame()) }
}

ind <- assigned %>% filter(v == "indeterminate")
if (nrow(ind))
  cat(sprintf("\nindeterminate (excluded from PPV, not counted as correct): %d\n", nrow(ind)))

la <- s %>% filter(review_stratum == "left_ambiguous", nzchar(v))
if (nrow(la)) {
  cat("\n=== deliberately-withheld cases: was withholding right? ===\n")
  print(la %>% count(v) %>% as.data.frame())
  cat("  'correct' here means the case genuinely could not be resolved.\n")
}

write_csv(by_rule, "artifacts/org_resolution_ppv.csv")
cat("\nwritten: artifacts/org_resolution_ppv.csv\n")

fails <- by_rule %>% filter(!meets_threshold)
if (nrow(fails))
  cat(sprintf("\nDO NOT PROMOTE: %s (lower bound below %.2f)\n",
              paste(fails$review_stratum, collapse = ", "), THRESHOLD))
