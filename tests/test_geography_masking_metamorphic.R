#!/usr/bin/env Rscript
# =============================================================================
# Counterfactual missingness: less evidence cannot yield more certainty
# =============================================================================
# THE LAW
#
#   Removing geographic evidence may turn a KNOWN geography into an UNKNOWN
#   one. It may never turn one known geography into a DIFFERENT known geography.
#
# Yukon-Koyukuk violated exactly this. A midwife with no practice ZIP did not
# become Unknown; she became Yukon-Koyukuk Census Area, Alaska, RUCC 8 -- a real
# county with a real rurality, because 903 ZCTA-less rows survived into the
# crosswalk, group_by() collapsed them into one NA-keyed row, and left_join()
# matches NA to NA. Absence of evidence became evidence.
#
# ci_science_laws.R L3 asserts the FIX: the canonical crosswalk filters those
# rows and refuses an NA key. This asserts the LAW, which is the more durable
# statement -- it holds for any resolver, any crosswalk, any future rewrite, and
# it would catch the same class of defect arriving through a different door.
#
# WHY THIS RUNS IN PUBLIC CI. It needs no person-level data. The resolution
# chain is zip5_key() -> ZIP-to-county crosswalk -> RUCC -> band, and every
# input is a tracked public file: data/zcta_county_2020.txt (Census),
# data/rucc_2023.xlsx (USDA). The subjects are real ZIPs drawn from the Census
# file itself, so no midwife is involved and nothing is synthetic except the
# masking.
#
# POSITIVE AND NEGATIVE CONTROLS, both required:
#
#   negative  the unmasked baseline must resolve to a known county. Without it
#             a resolver that returns NA for everything would pass every
#             assertion below and prove nothing.
#   positive  at least one mask must actually produce Unknown. Without it a
#             resolver that ignores masking entirely -- returning the baseline
#             regardless of input -- would also pass, and the test would be
#             asserting a tautology.
#
# HISTORICAL CONTROL. The final section rebuilds the crosswalk the defective way
# and asserts the law IS violated. A metamorphic test that cannot detect the
# defect it was written for is decoration; this proves it would have caught
# Yukon-Koyukuk before the artifact shipped.
# =============================================================================

EVIDENCE_SOURCE <- "tests/test_geography_masking_metamorphic.R"

# EVIDENCE CUSTODY. Stamps this run with what it is evidence FOR -- the file's
# own content hash, the registry's, and the commit -- so tests/ci_law_coverage.R
# can prove a replayed log belongs to the evaluation it is being used for
# instead of trusting its filename. The helper is sourced, never re-declared:
# two copies of a custody check are two things that can disagree.
local({
  r <- file.path(getwd(), "tests", "ci_report.R")
  if (file.exists(r)) {
    e <- new.env(); sys.source(r, envir = e)
    e$ci_law_evidence_header(EVIDENCE_SOURCE)
  }
})

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(readxl)
})

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "zip_county_crosswalk.R"))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }

XW   <- file.path("data", "zcta_county_2020.txt")
RUCC <- file.path("data", "rucc_2023.xlsx")

# A HARD FAILURE, not a skip. Both are TRACKED public files -- the Census
# ZCTA-county relationship file and the USDA rurality codes -- so on any
# checkout they are present. If one is renamed, deleted, or made unreachable by
# a change to how the runner checks out, the scientific law below stops being
# evaluated. Skipping there would let the law disappear while CI stays green,
# which is the precise failure this whole suite exists to prevent: a gate that
# reports success because it did not run.
#
# The PRIVATE frozen linkage further down may legitimately skip -- it is
# person-level and no public runner has it. A public input may not.
missing_public <- c(XW, RUCC)[!file.exists(c(XW, RUCC))]
if (length(missing_public)) {
  cat(sprintf("  FAIL required public input(s) absent: %s\n",
              paste(missing_public, collapse = ", ")))
  cat("       These are tracked files. Their absence means the geography law is\n")
  cat("       not being evaluated at all -- which is a failure, not a skip.\n\n")
  cat("FAILED (1)\n"); quit(status = 1)
}

# --- the resolver under test, mirroring the pipeline exactly -----------------
# zip5_key() then the canonical crosswalk then the canonical bander. Nothing is
# reimplemented: a private copy here would test the copy, not the pipeline.
xw_good <- zip_county_dominant(XW)
rucc_raw <- read_excel(RUCC)
rucc_lk  <- build_rucc_lookup(rucc_raw$FIPS, rucc_raw$RUCC_2023)

mask_resolve <- function(zip_raw, crosswalk = xw_good) {
  z <- zip5_key(zip_raw)
  g <- crosswalk$GEOID[match(z, crosswalk$zip5)]
  r <- rucc_lk$rucc[match(substr(g, 1, 5), rucc_lk$county)]
  data.frame(zip5 = z, county = g,
             band = band_rurality(r, RURALITY_LABELS_COHORT),
             stringsAsFactors = FALSE)
}

# --- subjects: real ZIPs that resolve, drawn from the Census file ------------
set.seed(20260824)
subjects <- xw_good %>% filter(!is.na(GEOID)) %>% slice_sample(n = 400) %>% pull(zip5)
base <- mask_resolve(subjects)

cat("\n-- negative control: the chain resolves before anything is masked --\n")
chk(nrow(base) == length(subjects), "every subject produced a row")
chk(all(!is.na(base$county)), sprintf("all %d subjects resolve to a county", length(subjects)))
chk(sum(!is.na(base$band)) > 0.9 * length(subjects),
    sprintf("%d of %d resolve to a rurality band", sum(!is.na(base$band)), length(subjects)))
chk(length(unique(na.omit(base$county))) > 50,
    sprintf("subjects span %d distinct counties, not one", length(unique(na.omit(base$county)))))

# --- the maskings ------------------------------------------------------------
# Each turns a valid ZIP into something carrying LESS information. None adds
# information, so none may produce a geography the original did not have.
# ABSENT evidence: the value carries no ZIP at all. These are the maskings the
# law governs, and every one must erase rather than replace.
mask_of <- list(
  "NA"                  = function(z) rep(NA_character_, length(z)),
  "empty string"        = function(z) rep("", length(z)),
  "whitespace only"     = function(z) rep("   ", length(z)),
  "literal 'NA'"        = function(z) rep("NA", length(z)),
  "literal 'N/A'"       = function(z) rep("N/A", length(z)),
  "literal 'UNKNOWN'"   = function(z) rep("UNKNOWN", length(z)),
  "literal 'None'"      = function(z) rep("None", length(z)),
  "a dash"              = function(z) rep("-", length(z)),
  "truncated to 1"      = function(z) substr(z, 1, 1),
  "letters"             = function(z) rep("ABCDE", length(z)),
  "punctuation"         = function(z) rep("#####", length(z)),
  "all zeros"           = function(z) rep("00000", length(z)),
  "impossible 99999"    = function(z) rep("99999", length(z)),
  "over-long"           = function(z) paste0(z, "0000"),
  "ZIP+4 suffix only"   = function(z) rep("1234", length(z)),
  "NA then blank"       = function(z) ifelse(seq_along(z) %% 2 == 0, NA_character_, "")
)

# DEGRADED evidence: a ZIP that has lost digits but still looks like one. Held
# apart from the law deliberately, and asserted separately below, because the
# pipeline CANNOT satisfy the law for these and the reason is structural rather
# than a defect -- see the section at the end.
mask_degraded <- list(
  "truncated to 3"      = function(z) substr(z, 1, 3),
  "truncated to 4"      = function(z) substr(z, 1, 4),
  "zero-prefixed"       = function(z) paste0("0", z)
)

cat("\n-- the law: masking may erase a geography, never replace it --\n")
n_unknown_producing <- 0L
for (nm in names(mask_of)) {
  got <- mask_resolve(mask_of[[nm]](subjects))
  # A row is legal if it resolves to the SAME county, or to nothing at all.
  same    <- !is.na(got$county) & !is.na(base$county) & got$county == base$county
  erased  <- is.na(got$county)
  invented <- !same & !erased
  if (any(erased)) n_unknown_producing <- n_unknown_producing + 1L

  chk(!any(invented),
      sprintf("%-20s produced no new geography (%d erased, %d unchanged)",
              nm, sum(erased), sum(same)))
  if (any(invented)) {
    i <- which(invented)[1]
    cat(sprintf("       row %d: %s -> %s (was %s)\n", i,
                base$county[i], got$county[i], base$county[i]))
  }
  # The band must follow the county: no new rurality either.
  band_invented <- !is.na(got$band) & !is.na(base$band) & got$band != base$band
  chk(!any(band_invented),
      sprintf("%-20s produced no new rurality band", nm))
}

# -----------------------------------------------------------------------------
cat("\n-- DEGRADED evidence: a documented limitation, not a passing law --\n")
# pad5() left-pads to five digits, and it must: a ZIP stored as the integer 1234
# is 01234, and New England, Puerto Rico and the Virgin Islands would all be
# unresolvable without that repair. But "1234" as a TRUNCATION of 12345 is the
# same four characters, and no function can tell the two apart from the value
# alone.
#
# So a truncated ZIP does not become Unknown. It becomes a different, real,
# confidently-resolved county -- 48245 truncated to "482" resolves to 00482,
# which is in Puerto Rico. That is the Yukon-Koyukuk failure mode arriving
# through a door the crosswalk fix does not close.
#
# Asserted rather than fixed, because the fix is upstream: a ZIP field that can
# be truncated should be caught where it is read, not repaired where it is used.
# Recorded here so the behaviour is visible, bounded, and cannot change without
# this test saying so.
for (nm in names(mask_degraded)) {
  got <- mask_resolve(mask_degraded[[nm]](subjects))
  changed <- !is.na(got$county) & !is.na(base$county) & got$county != base$county
  cat(sprintf("  note %-18s resolves %d of %d subjects to a DIFFERENT county\n",
              nm, sum(changed), length(subjects)))
}
deg <- mask_resolve(mask_degraded[["truncated to 3"]](subjects))
chk(any(!is.na(deg$county) & deg$county != base$county),
    "truncation is confirmed to produce a different known county (the limitation is real)")
chk(all(nchar(na.omit(zip5_key(substr(subjects, 1, 3)))) == 5L),
    "and it does so by left-padding, which is pad5()'s necessary behaviour")

# How much of this limitation is LIVE rather than theoretical. The frozen
# linkage is person-level and gitignored, so this resolves through the file when
# it is present and SKIPS loudly when it is not -- the `external-private` class
# tests/ci_nightly_exceptions.txt already registers four suites under. On a
# public runner the law above still runs in full; only this bound is deferred.
cat("\n-- how much of the limitation is live --\n")
FROZEN <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
SHORT_ZIP_BASELINE <- 2L    # observed 2026-08-24: one 2-digit, one 4-digit, of 17,062
if (!file.exists(FROZEN)) {
  cat(sprintf("  SKIP %s is gitignored and absent; the short-ZIP bound is not checked\n", FROZEN))
  cat("       (set MIDWIFERY_TEST_DATA_DIR or run locally to exercise it)\n")
} else {
  fz <- suppressWarnings(read_csv(FROZEN, show_col_types = FALSE, progress = FALSE))
  # NAMED, not matched. This was grep("zip", names(fz))[1], which silently takes
  # whichever ZIP-ish column sorts first. The frozen linkage carries exactly one
  # today -- nppes_zip, the practice ZIP -- but a mailing_zip or home_zip added
  # later could capture that position and the gate would go on reporting a
  # confident result about the wrong variable. A scientific gate does not get to
  # choose its own subject.
  PRACTICE_ZIP <- "nppes_zip"
  zc <- PRACTICE_ZIP
  if (!(PRACTICE_ZIP %in% names(fz))) {
    fails <- fails + 1L
    cat(sprintf("  FAIL the frozen linkage is present but has no `%s` column.\n", PRACTICE_ZIP))
    cat("       The practice-ZIP field was renamed or removed. Point this at the\n")
    cat("       new name deliberately -- do not let the gate pick one.\n")
  } else {
    v <- as.character(fz[[zc]]); v <- v[!is.na(v) & nzchar(v)]
    ndig <- nchar(gsub("[^0-9]", "", v))
    short <- sum(ndig > 0L & ndig < 5L)
    cat(sprintf("  note %d of %s records carry a ZIP shorter than five digits\n",
                short, format(length(v), big.mark = ",")))
    chk(short <= SHORT_ZIP_BASELINE,
        sprintf("short ZIPs are within the baseline of %d (found %d)",
                SHORT_ZIP_BASELINE, short))
    if (short > SHORT_ZIP_BASELINE)
      cat("       Each of these silently left-pads to a real ZIP in another state.\n",
          "      Catch them where the field is read, not where it is used.\n", sep = "")
  }
}

cat("\n-- positive control: masking is not a no-op --\n")
chk(n_unknown_producing >= length(mask_of) - 1L,
    sprintf("%d of %d maskings actually erase geography", n_unknown_producing, length(mask_of)))
allna <- mask_resolve(rep(NA_character_, length(subjects)))
chk(all(is.na(allna$county)), "a fully NA ZIP resolves to no county at all")
chk(all(is.na(allna$band)),   "and to no rurality band")

# --- historical control ------------------------------------------------------
cat("\n-- historical control: the defective crosswalk must FAIL this law --\n")
# The crosswalk as it was before R/lib/zip_county_crosswalk.R existed: no
# !is.na(GEOID_ZCTA5_20) filter, so the 903 ZCTA-less rows survive, group_by()
# collapses them to one NA-keyed row, and match() on NA finds it.
xw_broken <- read_delim(XW, delim = "|", show_col_types = FALSE, progress = FALSE) %>%
  transmute(zip5 = pad5(GEOID_ZCTA5_20), GEOID = pad5(GEOID_COUNTY_20),
            land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
  group_by(zip5) %>% slice_max(land, n = 1, with_ties = FALSE) %>%
  ungroup() %>% select(zip5, GEOID)

na_row <- xw_broken$GEOID[is.na(xw_broken$zip5)]
chk(length(na_row) == 1L,
    sprintf("the defective crosswalk carries an NA-keyed row (-> county %s)",
            paste(na_row, collapse = ",")))

broke <- mask_resolve(rep(NA_character_, length(subjects)), crosswalk = xw_broken)
invented_by_defect <- sum(!is.na(broke$county))
chk(invented_by_defect > 0L,
    sprintf("under the defect, %d masked subjects gain a county they never had", invented_by_defect))
chk(length(unique(na.omit(broke$county))) == 1L,
    sprintf("and all of them gain the SAME county (%s) -- the collapsed NA key",
            paste(unique(na.omit(broke$county)), collapse = ",")))
brk_band <- unique(na.omit(broke$band))
chk(length(brk_band) == 1L && !is.na(brk_band[1]),
    sprintf("which carries a real rurality band: %s", paste(brk_band, collapse = ",")))

# Evidence for tests/ci_law_coverage.R. Emitted at the end so it reflects what
# actually ran: the subject count is the number of ZIPs masked, and the positive
# control is the historical one -- this file plants its own defect by rebuilding
# the crosswalk the broken way, so it is both the law and its own mutation.
cat("\n")
cat(sprintf("[LAW] L6 EXERCISED\n"))
cat(sprintf("[CONTROL] L6 negative n=%d\n", length(subjects)))
# POSITIVE: the historical control proved the defective crosswalk DOES
# invent geography, so the law demonstrably fires.
cat(sprintf("[CONTROL] L6 positive n=%d\n", as.integer(invented_by_defect > 0L)))
cat(sprintf("[MUTATION] L6 historical-crosswalk %s\n",
            if (invented_by_defect > 0L) "DETECTED" else "SURVIVED"))

if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
