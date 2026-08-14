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

failures <- character(0)
fail <- function(...) failures <<- c(failures, sprintf(...))
ok   <- function(...) cat(sprintf("  ok   %s\n", sprintf(...)))
skip <- function(...) cat(sprintf("  --   %s\n", sprintf(...)))
sect <- function(s) cat(sprintf("\n-- %s --\n", s))

# -----------------------------------------------------------------------------
sect("A1 Table 1 blocks reconcile to the cohort")

t1_path <- file.path(root, "artifacts", "table1_midwives.csv")
if (!file.exists(t1_path)) {
  skip("table1_midwives.csv absent; skipped")
} else {
  t1 <- read.csv(t1_path, check.names = FALSE, stringsAsFactors = FALSE)
  need <- c("characteristic", "n", "percent", "category")
  if (!all(need %in% names(t1))) {
    fail("A1: table1_midwives.csv lost a required column; have [%s]", paste(names(t1), collapse = ", "))
  } else {
    N <- t1$n[t1$category == "Cohort"][1]
    if (is.na(N) || N <= 0) {
      fail("A1: no usable cohort N in the Cohort row")
    } else {
      ok("cohort N = %s", format(N, big.mark = ","))

      # A midwife may speak several languages, so this block counts people once
      # per language and cannot sum to N. It is exempt from the sum, not from
      # the bound: no single row may exceed the cohort.
      MULTI_SELECT <- c("Language (Healthgrades floor)")

      # Blocks whose denominator is a documented subset rather than the cohort.
      # The shortfall is pinned so that a CHANGE in it fails -- an unexplained
      # gap is the signal, a known one is not.
      KNOWN_SHORTFALL <- c(
        "Accepts new patients" = 11808L,
        "Offers telehealth"    = 11808L,
        "ACOG district"        = 11882L
      )

      cats <- setdiff(unique(t1$category), "Cohort")
      for (k in cats) {
        d <- t1[t1$category == k, ]
        s <- sum(d$n, na.rm = TRUE)
        if (k %in% MULTI_SELECT) {
          over <- d$characteristic[!is.na(d$n) & d$n > N]
          if (length(over)) {
            fail("A1: multi-select block '%s' has row(s) exceeding the cohort: %s", k, paste(over, collapse = ", "))
          }
        } else if (k %in% names(KNOWN_SHORTFALL)) {
          if (!identical(as.integer(s), unname(KNOWN_SHORTFALL[[k]]))) {
            fail("A1: block '%s' sums to %s; its pinned subset denominator is %s. If the denominator moved on purpose, update KNOWN_SHORTFALL and say why.",
                 k, format(s, big.mark = ","), format(KNOWN_SHORTFALL[[k]], big.mark = ","))
          }
        } else if (s != N) {
          fail("A1: block '%s' sums to %s, cohort is %s (difference %s)",
               k, format(s, big.mark = ","), format(N, big.mark = ","), format(s - N, big.mark = ","))
        }
      }
      ok("%d of %d blocks sum exactly to the cohort (%d multi-select, %d pinned subsets)",
         length(cats) - length(MULTI_SELECT) - length(KNOWN_SHORTFALL), length(cats),
         length(MULTI_SELECT), length(KNOWN_SHORTFALL))

      # Percentages must be percentages.
      bad_pct <- t1$characteristic[!is.na(t1$percent) & (t1$percent < 0 | t1$percent > 100)]
      if (length(bad_pct)) {
        fail("A1: percent outside 0-100 in: %s", paste(bad_pct, collapse = ", "))
      } else {
        ok("every percent is within 0-100")
      }

      # Within a block, the percentages of the rows that HAVE one must close.
      # The rows without a percent are the absence rows -- "no geocoded practice
      # location" -- and excluding them from the sum is the whole point of
      # keeping absence separate from zero.
      for (k in setdiff(cats, MULTI_SELECT)) {
        d <- t1[t1$category == k & !is.na(t1$percent), ]
        if (nrow(d) == 0) next
        s <- sum(d$percent)
        if (abs(s - 100) > 1.5) {
          fail("A1: percentages in block '%s' sum to %.1f, not 100", k, s)
        }
      }
      ok("percentages close to 100 within every non-multi-select block")

      # An n with no percent is an absence row; a percent with no n is a number
      # with nothing behind it.
      orphan <- t1$characteristic[!is.na(t1$percent) & is.na(t1$n)]
      if (length(orphan)) {
        fail("A1: percent with no n in: %s", paste(orphan, collapse = ", "))
      } else {
        ok("no percentage without a count behind it")
      }
    }
  }
}

# -----------------------------------------------------------------------------
sect("A2 suppressed is not zero")

cb_path <- file.path(root, "artifacts", "county_profiles", "county_cnm_births.csv")
if (!file.exists(cb_path)) {
  skip("county_cnm_births.csv absent; skipped")
} else {
  cb <- read.csv(cb_path, stringsAsFactors = FALSE)
  need <- c("cnm_births_2016_2024", "suppressed", "wonder_county_reported")
  if (!all(need %in% names(cb))) {
    fail("A2: county_cnm_births.csv is missing %s", paste(setdiff(need, names(cb)), collapse = ", "))
  } else {
    births <- suppressWarnings(as.numeric(cb$cnm_births_2016_2024))
    supp   <- as.logical(cb$suppressed)
    rep    <- as.logical(cb$wonder_county_reported)

    # A suppressed cell that arrives as 0 is the exact defect from cycles 3, 4
    # and 15: it turns "CDC does not publish this" into "no midwife attended a
    # birth here", which is a claim about maternity care that nobody made.
    v1 <- which(!is.na(supp) & supp & !is.na(births) & births == 0)
    if (length(v1)) {
      fail("A2: %d suppressed count(y|ies) carry 0 instead of NA (rows: %s)",
           length(v1), paste(utils::head(v1, 5), collapse = ", "))
    } else {
      ok("no suppressed county carries a zero (%d suppressed)", sum(supp, na.rm = TRUE))
    }

    # Counties WONDER does not report separately are pooled by state. They are
    # unpublished, not childless.
    v2 <- which(!is.na(rep) & !rep & !is.na(births) & births == 0)
    if (length(v2)) {
      fail("A2: %d unreported count(y|ies) carry 0 instead of NA", length(v2))
    } else {
      ok("no unreported county carries a zero (%d unreported)", sum(!rep, na.rm = TRUE))
    }

    # Anything derived from a missing count must itself be missing, or the
    # absence gets laundered into a rate.
    for (col in intersect(c("cnm_births_per_year", "cnm_share_of_births_pct"), names(cb))) {
      d <- suppressWarnings(as.numeric(cb[[col]]))
      v <- which(is.na(births) & !is.na(d))
      if (length(v)) {
        fail("A2: %s is populated in %d row(s) where the underlying count is missing", col, length(v))
      }
    }
    ok("derived rates are missing wherever the count is missing")
  }
}

# -----------------------------------------------------------------------------
sect("A3 provenance coverage does not regress")

# Pinned to what is true today, not to what we wish were true. The number may
# only go down: adding an artifact without a sidecar fails, adding one WITH a
# sidecar passes and lowers the pin for the next person.
MAX_UNCOVERED <- 145L

arts <- suppressWarnings(system2("git", c("ls-files", shQuote("artifacts/*.csv")), stdout = TRUE, stderr = FALSE))
if (length(arts) == 0) {
  skip("no tracked artifacts; skipped")
} else {
  sidecars <- suppressWarnings(system2("git", c("ls-files", shQuote("artifacts/*.provenance.json")), stdout = TRUE, stderr = FALSE))
  have <- sub("\\.provenance\\.json$", "", sidecars)
  uncovered <- setdiff(arts, have)
  n <- length(uncovered)

  if (n > MAX_UNCOVERED) {
    fail("A3: %d tracked artifacts have no .provenance.json sidecar, up from %d. New artifacts must be written through write_with_provenance().\n       newest offenders: %s",
         n, MAX_UNCOVERED, paste(utils::head(setdiff(uncovered, character(0)), 5), collapse = ", "))
  } else if (n < MAX_UNCOVERED) {
    ok("%d of %d artifacts lack a sidecar, DOWN from %d -- lower MAX_UNCOVERED to %d to hold the gain",
       n, length(arts), MAX_UNCOVERED, n)
  } else {
    ok("%d of %d artifacts lack a sidecar; no regression", n, length(arts))
  }
}

# -----------------------------------------------------------------------------
cat("\n")
if (length(failures)) {
  for (f in failures) cat(sprintf("FAIL %s\n", f))
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
