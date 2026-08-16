#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 22 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: RE-RUN SAFETY. Twenty-one cycles have tested what the pipeline
# computes; none has asked whether running a step TWICE gives the same answer as
# running it once. That is a different axis, and it caught a script that worked
# exactly once.
#
# THE FINDING: R/10 and R/11 consume each other's output.
#
#   R/10 reads county_cnm_births.csv   (R/11's output) and merges
#        cnm_births_2016_2024, suppressed, ct_apportioned into the profile
#   R/11 reads county_birth_profiles.csv (R/10's output) and left-joins the
#        same three columns back
#
# On a FIRST run the profile lacks those columns and the join is clean. On every
# run after, dplyr suffixes both copies to .x/.y and the next
# `mutate(ct_apportioned = ...)` dies with "object 'ct_apportioned' not found".
#
# So R/11 ran once, wrote an artifact containing 9 apportioned Connecticut
# planning regions, and could never run again -- which is exactly the state
# found on disk: a good artifact beside a script that cannot reproduce it. The
# failure was invisible because nobody re-ran the step, and cycle 18 established
# that a stage which aborts leaves its previous output in place.
#
# A SECOND LATENT BREAK on the same line: `ct_apportioned` is only created
# inside the CT branch, so a WONDER export with no Connecticut legacy counties
# -- all suppressed, or a different geography -- skips the branch and hits the
# same opaque error from the opposite direction.
#
# Class swept: R/10 <-> R/11 is the ONLY read/write cycle in the pipeline
# (T227).
#
# Run: Rscript tests/test_cycle22_idempotence.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "tests", "helper-optional-inputs.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
ING <- paste(readLines("R/11-wonder-county-ingest.R", warn = FALSE), collapse = "\n")
OUTP <- "artifacts/county_profiles/county_cnm_births.csv"
rd <- function(p) suppressWarnings(read_csv(p, show_col_types = FALSE, progress = FALSE,
                                            col_types = cols(GEOID = col_character())))

cat("\n-- BVA --\n")

# T221 (BVA). The stale-column drop at its three cardinalities: none present,
# some present, all present. Dropping a column that is not there must not error.
{
  ct_cols <- c("cnm_births_2016_2024", "suppressed", "ct_apportioned")
  none <- data.frame(GEOID = "01001")
  some <- data.frame(GEOID = "01001", suppressed = FALSE)
  all3 <- data.frame(GEOID = "01001", cnm_births_2016_2024 = 1,
                     suppressed = FALSE, ct_apportioned = FALSE)
  drop <- function(d) dplyr::select(d, -dplyr::any_of(ct_cols))
  chk(ncol(drop(none)) == 1L, "T221a dropping absent columns is a no-op, not an error")
  chk(ncol(drop(some)) == 1L, "T221b a partially-stale profile drops only what it has")
  chk(ncol(drop(all3)) == 1L, "T221c a fully-stale profile is reduced to its key")
}

# T222 (BVA). The drop list must cover every column this script derives. One
# omission and the collision returns for that column alone.
{
  derived <- c("cnm_births_2016_2024", "suppressed", "ct_apportioned",
               "cnm_births_per_year", "cnm_share_of_births_pct",
               "wonder_county_reported")
  # The first version tried to isolate the ct_cols vector with a pair of sub()
  # calls and isolated nothing, so every column looked missing. Read the
  # declaration directly instead.
  decl <- regmatches(ING, regexpr("ct_cols <- c\\((?:[^)]|\\n)*\\)", ING))
  missing <- derived[!vapply(derived, function(k)
    length(decl) == 1L && grepl(sprintf('"%s"', k), decl), logical(1))]
  chk(length(missing) == 0L,
      sprintf("T222 every derived column is on the drop list [missing: %s]",
              if (length(missing)) paste(missing, collapse = ", ") else "none"))
}

# T223 (BVA). The empty-CT boundary. No Connecticut legacy county in the export
# is a legitimate state -- full suppression, or a differently-shaped pull.
{
  chk(grepl('if \\(!"ct_apportioned" %in% names\\(ident\\)\\) ident\\$ct_apportioned <- FALSE', ING),
      "T223a the column is guaranteed before use, so an empty CT branch cannot crash")
  ident <- data.frame(GEOID = "01001")            # no CT rows at all
  if (!"ct_apportioned" %in% names(ident)) ident$ct_apportioned <- FALSE
  out <- ident %>% mutate(ct_apportioned = coalesce(ct_apportioned, FALSE))
  chk(nrow(out) == 1L && identical(out$ct_apportioned, FALSE),
      "T223b with no CT rows the flag is FALSE, not missing")
}

# T224 (BVA). A profile that already carries suffixed remnants of a previous
# collision must still be usable -- the repair has to survive its own aftermath.
{
  poisoned <- data.frame(GEOID = "01001", ct_apportioned.x = TRUE,
                         ct_apportioned.y = FALSE, suppressed = NA)
  cleaned <- poisoned %>% select(-any_of(c("cnm_births_2016_2024", "suppressed",
                                           "ct_apportioned")))
  chk(!"suppressed" %in% names(cleaned) && ncol(cleaned) == 3L,
      "T224 a profile bearing .x/.y remnants still loses its stale un-suffixed columns")
}

cat("\n-- SEMANTIC --\n")

# T225 (semantic). THE CONTRACT. Running the step twice must produce the same
# artifact as running it once. This is what "re-runnable analysis" means.
{
  if (!file.exists(OUTP)) chk(FALSE, "T225 output exists") else {
    before <- rd(OUTP)
    chk(nrow(before) > 0L && "ct_apportioned" %in% names(before),
        sprintf("T225a the artifact carries its derived columns [%d rows]", nrow(before)))
    chk(sum(before$ct_apportioned %in% c(TRUE, "TRUE")) == 9L,
        sprintf("T225b nine Connecticut planning regions are apportioned [%d]",
                sum(before$ct_apportioned %in% c(TRUE, "TRUE"))))
  }
}

# T226 (semantic). This script is the AUTHORITY for the WONDER columns. A stale
# copy arriving on the profile must be re-derived, never preserved, or the
# artifact silently reports last week's births.
{
  chk(grepl("dropping \\{length\\(dropped\\)\\} stale WONDER column", ING),
      "T226a a stale copy is reported when dropped, not removed silently")
  chk(grepl("select\\(prof, -any_of\\(ct_cols\\)\\)", ING),
      "T226b the profile's copies are dropped before the join, not suffixed")
}

# T227 (semantic). CLASS SWEEP, measured rather than inferred.
#
# A static detector matching shared BASENAMES reported six "cycles" among
# scripts 02, 03, 05 and 07. Running each of them twice shows they complete
# cleanly both times: they share INPUT filenames, not a producer/consumer loop.
# Reporting those six would have been a false-positive list of the same shape as
# the Michigan water mask and the naive longitude test.
#
# The property actually worth asserting is not "no shared filenames" but "a
# second run behaves like the first". That is measured directly for the script
# where it genuinely failed (T228), and pinned here as a per-script contract for
# the ones cheap to verify.
{
  # "Cheaply runnable" also means "has something to run ON". Both of these read
  # person-level spines that are gitignored, so on a runner they exit non-zero
  # for want of input and the assertion reported an idempotence defect that was
  # never demonstrated. Attempt only the scripts whose inputs are present.
  candidates <- list(
    "R/02-geocoding-completeness.R" = c("midwives_geocoded.csv",
                                        "data/county_base.csv"),
    "R/04-diagnose-cross-state.R"   = c("midwives_geography.csv",
                                        "midwives_with_nppes.csv"))
  runnable <- names(candidates)[vapply(names(candidates), function(s)
    have_inputs(candidates[[s]], sprintf("T227 idempotence of %s", basename(s))),
    logical(1))]

  if (!length(runnable)) {
    cat("  --   SKIP T227: no cheaply-runnable script has its inputs present\n")
  } else {
    twice_ok <- vapply(runnable, function(s) {
      a <- system2("Rscript", s, stdout = FALSE, stderr = FALSE)
      b <- system2("Rscript", s, stdout = FALSE, stderr = FALSE)
      a == 0L && b == 0L
    }, logical(1))
    chk(all(twice_ok),
        sprintf("T227 every cheaply-runnable script completes on a second run [%s]",
                paste(basename(runnable), ifelse(twice_ok, "ok", "FAILED"),
                      collapse = ", ")))
  }
}

cat("\n-- ADVERSARIAL --\n")

# T228 (adversarial). The real proof: run the script twice and compare bytes.
# Anything less is an argument that it is idempotent rather than a measurement.
{
  if (!file.exists(OUTP)) chk(FALSE, "T228 output exists") else {
    first <- readBin(OUTP, "raw", file.info(OUTP)$size)
    ok <- system2("Rscript", "R/11-wonder-county-ingest.R",
                  stdout = FALSE, stderr = FALSE) == 0L
    second <- readBin(OUTP, "raw", file.info(OUTP)$size)
    chk(ok, "T228a a second run completes rather than aborting")
    chk(identical(first, second),
        "T228b the artifact is byte-identical after re-running")
  }
}

# T229 (adversarial). Suppression must survive the round trip. A county WONDER
# suppressed must not come back as an observed zero after a re-run -- the
# suppressed-is-not-zero principle, applied across an execution boundary.
{
  if (!file.exists(OUTP)) chk(FALSE, "T229 output exists") else {
    d <- rd(OUTP)
    if (!"suppressed" %in% names(d)) chk(FALSE, "T229 suppressed column present") else {
      sup <- d[d$suppressed %in% c(TRUE, "TRUE"), , drop = FALSE]
      chk(nrow(sup) > 0L && !any(sup$cnm_births_2016_2024 %in% 0),
          sprintf("T229 no suppressed county carries a zero birth count [%d suppressed]",
                  nrow(sup)))
    }
  }
}

# T230 (adversarial). The apportioned CT rows must be flagged as estimates in
# the artifact, not merely inside the function that made them.
{
  if (!file.exists(OUTP)) chk(FALSE, "T230 output exists") else {
    d <- rd(OUTP)
    ct <- d[grepl("^091", d$GEOID), , drop = FALSE]
    chk(nrow(ct) == 9L && all(ct$ct_apportioned %in% c(TRUE, "TRUE")),
        sprintf("T230 all %d Connecticut planning regions are flagged apportioned", nrow(ct)))
  }
}

optional_inputs_summary()
cat(sprintf("\n%s (%d failures, %d skipped)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, optional_skip_count()))
quit(status = if (fails == 0L) 0L else 1L)
