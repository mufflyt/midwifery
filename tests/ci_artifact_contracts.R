# =============================================================================
# Artifact contracts: the arithmetic that has to hold in what we publish
# =============================================================================
# These are not unit tests. They read COMMITTED artifacts and assert the
# properties a reader would assume without checking -- that a table's parts sum
# to its whole, that a suppressed cell is not a zero, that a published number
# can be traced to the run that produced it.
#
# Each one exists because the failure it catches has already happened here:
#
#   A1  Table 1 has twice been rebuilt half-way, publishing rows from two
#       different cohorts side by side. If the blocks sum to the cohort N, that
#       cannot be true silently.
#   A2  Cycles 3, 4 and 15 were all one bug -- a suppressed cell rendered as 0 --
#       and it published wrong numbers three times before anyone noticed. A
#       suppressed cell means "not published", and 0 means "none happened".
#   A3  write_with_provenance is described as wired across every pipeline write.
#       21 of 166 tracked artifacts have a sidecar. The ratchet holds that ratio
#       and lets it improve.
#
# Base R only. Runs in seconds.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

source(file.path(root, "tests", "ci_report.R"))


# -----------------------------------------------------------------------------
ci_section("A1 Table 1 blocks reconcile to the cohort")

t1_path <- file.path(root, "artifacts", "table1_midwives.csv")
if (!file.exists(t1_path)) {
  ci_skip("table1_midwives.csv absent; skipped")
} else {
  t1 <- read.csv(t1_path, check.names = FALSE, stringsAsFactors = FALSE)
  need <- c("characteristic", "n", "percent", "category")
  if (!all(need %in% names(t1))) {
    ci_fail("A1: table1_midwives.csv lost a required column; have [%s]", paste(names(t1), collapse = ", "))
  } else {
    N <- t1$n[t1$category == "Cohort"][1]
    if (is.na(N) || N <= 0) {
      ci_fail("A1: no usable cohort N in the Cohort row")
    } else {
      ci_ok("cohort N = %s", format(N, big.mark = ","))

      # RULING 2026-08-14: every block sums to the cohort, and each remainder
      # gets its own named row. No exemptions, no pinned shortfalls.
      #
      # This block previously carried a MULTI_SELECT exemption and three pinned
      # subset denominators (11,808 and 11,882) because the Healthgrades blocks
      # dropped 112 unattributable midwives and the ACOG block dropped 38 with
      # overseas-military or territory addresses. Both exclusions were correct
      # and both were invisible: the rows were individually right and the column
      # did not add up, so anyone reconciling Table 1 against the cohort found
      # 150 people missing with nothing to explain them. The remainders are now
      # rows, so the exemptions are gone and the assertion is the simple one.
      cats <- setdiff(unique(t1$category), "Cohort")
      offenders <- character(0)
      for (k in cats) {
        s_k <- sum(t1$n[t1$category == k], na.rm = TRUE)
        if (s_k != N) {
          offenders <- c(offenders, sprintf("%s sums to %s (cohort %s, difference %s)",
                                            k, format(s_k, big.mark = ","),
                                            format(N, big.mark = ","),
                                            format(s_k - N, big.mark = ",")))
        }
      }
      if (length(offenders)) {
        ci_fail("A1: %d block(s) do not sum to the cohort. Every remainder needs its own row -- an exclusion that is correct but invisible still leaves a reader unable to reconcile the table:\n%s",
                length(offenders), paste(sprintf("       %s", offenders), collapse = "\n"))
      } else {
        ci_ok("all %d blocks sum to the cohort", length(cats))
      }

      # Percentages must be percentages.
      bad_pct <- t1$characteristic[!is.na(t1$percent) & (t1$percent < 0 | t1$percent > 100)]
      if (length(bad_pct)) {
        ci_fail("A1: percent outside 0-100 in: %s", paste(bad_pct, collapse = ", "))
      } else {
        ci_ok("every percent is within 0-100")
      }

      # COUNTS must reconcile everywhere; PERCENTAGES need not. The Language
      # block reports a lower bound -- "at least this many speak a language
      # other than English" -- so its one percentage is 3.1 and nothing makes
      # it 100. That is the row being honest, not the table being wrong, and
      # the exemption belongs here and NOT on the count check above.
      PCT_EXEMPT <- c("Language (Healthgrades floor)")

      # Within a block, the percentages of the rows that HAVE one must close.
      # The rows without a percent are the absence rows -- "no geocoded practice
      # location" -- and excluding them from the sum is the whole point of
      # keeping absence separate from zero.
      for (k in setdiff(cats, PCT_EXEMPT)) {
        d <- t1[t1$category == k & !is.na(t1$percent), ]
        if (nrow(d) == 0) next
        s <- sum(d$percent)
        if (abs(s - 100) > 1.5) {
          ci_fail("A1: percentages in block '%s' sum to %.1f, not 100", k, s)
        }
      }
      ci_ok("percentages close to 100 within every block except the %d lower-bound one(s)", length(PCT_EXEMPT))

      # An n with no percent is an absence row; a percent with no n is a number
      # with nothing behind it.
      orphan <- t1$characteristic[!is.na(t1$percent) & is.na(t1$n)]
      if (length(orphan)) {
        ci_fail("A1: percent with no n in: %s", paste(orphan, collapse = ", "))
      } else {
        ci_ok("no percentage without a count behind it")
      }
    }
  }
}

# -----------------------------------------------------------------------------
ci_section("A2 suppressed is not zero")

cb_path <- file.path(root, "artifacts", "county_profiles", "county_cnm_births.csv")
if (!file.exists(cb_path)) {
  ci_skip("county_cnm_births.csv absent; skipped")
} else {
  cb <- read.csv(cb_path, stringsAsFactors = FALSE)
  need <- c("cnm_births_2016_2024", "suppressed", "wonder_county_reported")
  if (!all(need %in% names(cb))) {
    ci_fail("A2: county_cnm_births.csv is missing %s", paste(setdiff(need, names(cb)), collapse = ", "))
  } else {
    births <- suppressWarnings(as.numeric(cb$cnm_births_2016_2024))
    supp   <- as.logical(cb$suppressed)
    rep    <- as.logical(cb$wonder_county_reported)

    # A suppressed cell that arrives as 0 is the exact defect from cycles 3, 4
    # and 15: it turns "CDC does not publish this" into "no midwife attended a
    # birth here", which is a claim about maternity care that nobody made.
    v1 <- which(!is.na(supp) & supp & !is.na(births) & births == 0)
    if (length(v1)) {
      ci_fail("A2: %d suppressed count(y|ies) carry 0 instead of NA (rows: %s)",
           length(v1), paste(utils::head(v1, 5), collapse = ", "))
    } else {
      ci_ok("no suppressed county carries a zero (%d suppressed)", sum(supp, na.rm = TRUE))
    }

    # Counties WONDER does not report separately are pooled by state. They are
    # unpublished, not childless.
    v2 <- which(!is.na(rep) & !rep & !is.na(births) & births == 0)
    if (length(v2)) {
      ci_fail("A2: %d unreported count(y|ies) carry 0 instead of NA", length(v2))
    } else {
      ci_ok("no unreported county carries a zero (%d unreported)", sum(!rep, na.rm = TRUE))
    }

    # Anything derived from a missing count must itself be missing, or the
    # absence gets laundered into a rate.
    for (col in intersect(c("cnm_births_per_year", "cnm_share_of_births_pct"), names(cb))) {
      d <- suppressWarnings(as.numeric(cb[[col]]))
      v <- which(is.na(births) & !is.na(d))
      if (length(v)) {
        ci_fail("A2: %s is populated in %d row(s) where the underlying count is missing", col, length(v))
      }
    }
    ci_ok("derived rates are missing wherever the count is missing")
  }
}

# -----------------------------------------------------------------------------
ci_section("A3 provenance coverage does not regress")

# Pinned to what is true today, not to what we wish were true. The number may
# only go down: adding an artifact without a sidecar fails, adding one WITH a
# sidecar passes and lowers the pin for the next person.
# A NAMED LIST, not a number. The count said how much debt existed; it could not
# say which files, so a new uncovered artifact was invisible whenever an old one
# left, and recording a genuine reduction meant editing the number -- an edit
# indistinguishable from raising it to make CI pass.
#
# tests/ci_artifact_provenance_baseline.txt names every artifact that lacks a
# sidecar today. Adding one that is not on that list fails. Removing a line
# requires the artifact to gain a REAL sidecar: inputs and their SHA-256 as
# recorded when it was written, not reconstructed afterwards.
#
# The list may shrink and must never grow, which is the same rule the leak
# baseline runs on and, unlike a threshold, it cannot be quietly relaxed.
BASELINE <- file.path(root, "tests", "ci_artifact_provenance_baseline.txt")

arts <- suppressWarnings(system2("git", c("ls-files", shQuote("artifacts/*.csv")), stdout = TRUE, stderr = FALSE))
if (length(arts) == 0) {
  ci_skip("no tracked artifacts; skipped")
} else {
  sidecars <- suppressWarnings(system2("git", c("ls-files", shQuote("artifacts/*.provenance.json")), stdout = TRUE, stderr = FALSE))
  have <- sub("\\.provenance\\.json$", "", sidecars)
  uncovered <- setdiff(arts, have)

  grandfathered <- if (file.exists(BASELINE)) {
    x <- trimws(readLines(BASELINE, warn = FALSE))
    x[nzchar(x) & !startsWith(x, "#")]
  } else character(0)

  new_offenders <- setdiff(uncovered, grandfathered)
  fixed <- setdiff(grandfathered, uncovered)

  if (length(new_offenders)) {
    ci_fail("A3: %d tracked artifact(s) have no .provenance.json sidecar and are not on the baseline. Write them through write_with_provenance() (R) so the sidecar records the inputs and their SHA-256:\n       %s",
            length(new_offenders), paste(utils::head(new_offenders, 8), collapse = "\n       "))
  } else if (length(fixed)) {
    ci_ok("%d of %d artifacts lack a sidecar; %d gained one -- delete these line(s) from the baseline to hold the gain: %s",
          length(uncovered), length(arts), length(fixed),
          paste(utils::head(fixed, 5), collapse = ", "))
  } else {
    ci_ok("%d of %d tracked artifacts lack a sidecar; all are on the baseline, none new",
          length(uncovered), length(arts))
  }
}

# -----------------------------------------------------------------------------
ci_finish()
