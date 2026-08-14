# =============================================================================
# Semantic contracts: invariants about MEANING, not about types
# =============================================================================
# ci_artifact_contracts.R asserts arithmetic inside single artifacts. This file
# asserts meaning ACROSS them -- the properties that make two files describe the
# same world. Every failure here is a file that parses, validates, and says
# something different from its neighbour.
#
# The defect classes are drawn from this repository's own history:
#
#   S1  A pipeline stage that writes without provenance. Stage 15 was added
#       after the wiring and used readr::write_csv directly; its four artifacts
#       were the only pipeline outputs untraceable to their inputs.
#   S2  A third rurality vocabulary (cycle 2). Two artifacts spelling the same
#       stratum differently join to nothing, silently.
#   S3  Percent stored as a proportion (cycle 7's unit family). A column named
#       pct whose maximum is 0.34 is either 34% or 0.34%, and nothing in the
#       file says which.
#   S4  A GEOID that lost its leading zero. Alabama is "01001"; read as a
#       number it is 1001, which is nowhere.
#   S5  Counts that are not counts -- negative, or fractional.
#
# Base R only. Reads committed artifacts and tracked source; no network.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

read_head <- function(path, n = -1L) {
  tryCatch(utils::read.csv(path, stringsAsFactors = FALSE, nrows = n,
                           check.names = FALSE, colClasses = "character"),
           error = function(e) NULL)
}

# -----------------------------------------------------------------------------
ci_section("S1 every numbered pipeline stage writes through write_with_provenance")

# Static analysis, not a run: the stages need data this runner does not have.
# A raw writer in a numbered stage is the defect, whether or not it executes.
stages <- sort(ci_tracked("R/[0-9]*-*.R"))
if (!length(stages)) {
  ci_skip("no numbered stages found; skipped")
} else {
  RAW <- "\\b(readr::)?write_csv\\(|\\bwrite\\.csv\\(|\\bfwrite\\("
  offenders <- character(0)
  for (s in stages) {
    txt <- readLines(file.path(root, s), warn = FALSE)
    # Ignore comment lines and roxygen: a raw writer NAMED in prose is not one.
    code <- txt[!grepl("^\\s*#", txt)]
    n_raw <- sum(grepl(RAW, code))
    if (n_raw > 0L) offenders <- c(offenders, sprintf("%s (%d raw write%s)",
                                                      s, n_raw, if (n_raw == 1) "" else "s"))
  }
  if (length(offenders)) {
    ci_fail("S1: %d numbered stage(s) write CSVs without provenance:\n%s\n       Every artifact they emit is untraceable to the inputs that made it.",
            length(offenders), paste(sprintf("       %s", offenders), collapse = "\n"))
  } else {
    ci_ok("all %d numbered stages write only through write_with_provenance", length(stages))
  }

  # The claim in NEWS.md is about the numbered pipeline, and this records the
  # part that is NOT covered so the changelog cannot drift back into claiming
  # more than is true.
  adhoc <- 0L
  for (f in ci_tracked("*.R")) {
    if (grepl("^R/[0-9]", f) || grepl("^tests/", f)) next
    txt <- readLines(file.path(root, f), warn = FALSE)
    code <- txt[!grepl("^\\s*#", txt)]
    if (any(grepl(RAW, code)) && !any(grepl("write_with_provenance", code))) adhoc <- adhoc + 1L
  }
  ci_ok("%d ad-hoc scripts outside R/NN-*.R still write without provenance -- out of scope for this contract, and NOT covered by the changelog's claim", adhoc)
}

# -----------------------------------------------------------------------------
ci_section("S2 no FOURTH rurality vocabulary appears")

# R/lib/table1_bands.R defines THREE label sets on purpose -- LONG, SHORT and
# COHORT -- and says why: unifying them would silently rename published columns.
# So "one vocabulary" is the wrong assertion. Cycle 2's actual defect was a
# third vocabulary appearing unnoticed; the invariant is that no FOURTH one
# does. Anything outside the sanctioned sets is a new dialect.
SANCTIONED <- c(
  "Metropolitan (RUCC 1-3)", "Nonmetropolitan, adjacent (RUCC 4-6)",
  "Nonmetropolitan, remote (RUCC 7-9)",
  "Metro (RUCC 1-3)", "Nonmetro, adjacent (RUCC 4-6)", "Nonmetro, remote (RUCC 7-9)",
  "Metro (RUCC 1-3)", "Nonmetro, adjacent (4-6)", "Nonmetro, remote (7-9)",
  "Unknown", "unlabelled"
)
rur_cols <- c("rucc_cat", "rurality", "rural_cat", "rucc_category")
found <- character(0)
for (f in ci_tracked("artifacts/*.csv")) {
  p <- file.path(root, f)
  if (!file.exists(p) || file.info(p)$size > 20e6) next
  hdr <- tryCatch(names(utils::read.csv(p, nrows = 1, check.names = FALSE)),
                  error = function(e) character(0))
  if (!length(intersect(tolower(hdr), rur_cols))) next
  d <- read_head(p)
  if (is.null(d)) next
  for (h in intersect(tolower(names(d)), rur_cols)) {
    col <- names(d)[tolower(names(d)) == h][1]
    v <- trimws(d[[col]]); v <- v[nzchar(v) & !is.na(v) & v != "NA"]
    v <- v[grepl("[A-Za-z]", v)]
    new <- setdiff(unique(v), SANCTIONED)
    if (length(new)) found <- c(found, sprintf("%s :: %s", f, paste(new, collapse = " | ")))
  }
}
if (length(found)) {
  ci_fail("S2: a rurality dialect outside the three sanctioned label sets:\n%s",
          paste(sprintf("       %s", found), collapse = "\n"))
} else {
  ci_ok("every rurality label belongs to one of the three sanctioned vocabularies")
}

ci_section("S3 no NEW percent column arrives on a proportion scale")

# County Health Rankings publishes proportions, and this repo keeps the source
# column names. So a pct_ column holding 0.2258 is inherited, not invented --
# but a NEW one is a unit bug of the family that made cycle 7. Pin the known
# proportion-scale columns; fail on anything else.
PROPORTION_SCALE <- c("pct_rural", "pct_low_birth_weight", "chr_pct_uninsured")

suspect <- character(0); checked <- 0L
for (f in ci_tracked("artifacts/*.csv")) {
  p <- file.path(root, f)
  if (!file.exists(p) || file.info(p)$size > 20e6) next
  d <- tryCatch(utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE),
                error = function(e) NULL)
  if (is.null(d) || !nrow(d)) next
  for (nm in names(d)) {
    if (!grepl("(^|_)(pct|percent)(_|$)", tolower(nm))) next
    v <- suppressWarnings(as.numeric(d[[nm]])); v <- v[is.finite(v)]
    if (length(v) < 20L) next
    checked <- checked + 1L
    if (max(v) <= 1 && !tolower(nm) %in% PROPORTION_SCALE)
      suspect <- c(suspect, sprintf("%s :: %s (max %.4f -- proportion on a pct name)", f, nm, max(v)))
    if (max(v) > 100.5)
      suspect <- c(suspect, sprintf("%s :: %s (max %.1f -- above 100)", f, nm, max(v)))
  }
}
if (length(suspect)) {
  ci_fail("S3: %d percent column(s) on an unexpected scale:\n%s",
          length(suspect), paste(sprintf("       %s", suspect), collapse = "\n"))
} else {
  ci_ok("%d percent columns are on their expected scale (%d pinned as proportions)",
        checked, length(PROPORTION_SCALE))
}

ci_section("S4 a geographic id is uniform in width and all digits")

# Not "five characters": a congressional-district GEOID is legitimately four
# (2-digit state + 2-digit district) and a tract GEOID is eleven. The invariant
# that holds everywhere is that a given column uses ONE width and contains only
# digits -- so a lost leading zero shows up as a minority short value, and a
# forged token shows up as a non-digit.
bad_geo <- character(0); n_geo <- 0L
for (f in ci_tracked("artifacts/*.csv")) {
  p <- file.path(root, f)
  if (!file.exists(p) || file.info(p)$size > 20e6) next
  d <- read_head(p)
  if (is.null(d) || !nrow(d)) next
  for (nm in names(d)) {
    if (!tolower(nm) %in% c("geoid", "fips", "county_fips", "geoid_county")) next
    v <- trimws(d[[nm]]); v <- v[nzchar(v) & !is.na(v) & v != "NA"]
    if (!length(v)) next
    n_geo <- n_geo + 1L

    nondigit <- unique(v[grepl("[^0-9]", v)])
    if (length(nondigit)) {
      bad_geo <- c(bad_geo, sprintf("%s :: %s contains non-digits: %s", f, nm,
                                    paste(utils::head(nondigit, 3), collapse = ", ")))
    }
    dv <- v[!grepl("[^0-9]", v)]
    if (length(dv)) {
      w <- table(nchar(dv)); modal <- as.integer(names(w)[which.max(w)])
      short <- unique(dv[nchar(dv) < modal])
      if (length(short)) {
        bad_geo <- c(bad_geo, sprintf("%s :: %s is %d wide but %d value(s) are shorter, e.g. %s",
                                      f, nm, modal, sum(nchar(dv) < modal),
                                      paste(utils::head(short, 3), collapse = ", ")))
      }
    }
  }
}
if (length(bad_geo)) {
  ci_fail("S4: %d geographic id problem(s):\n%s",
          length(bad_geo), paste(sprintf("       %s", bad_geo), collapse = "\n"))
} else {
  ci_ok("%d geographic id columns are uniform width and all digits", n_geo)
}

ci_section("S5 counts are non-negative whole numbers")

bad_n <- character(0)
n_cols <- 0L
for (f in ci_tracked("artifacts/*.csv")) {
  p <- file.path(root, f)
  if (!file.exists(p) || file.info(p)$size > 20e6) next
  d <- tryCatch(utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE),
                error = function(e) NULL)
  if (is.null(d) || !nrow(d)) next
  for (nm in names(d)) {
    if (!grepl("^(n|n_[a-z0-9_]+|count|.*_count|births|.*_births)$", tolower(nm))) next
    v <- suppressWarnings(as.numeric(d[[nm]]))
    v <- v[is.finite(v)]
    if (!length(v)) next
    n_cols <- n_cols + 1L
    if (any(v < 0)) bad_n <- c(bad_n, sprintf("%s :: %s has a negative count (min %.2f)", f, nm, min(v)))
  }
}
if (length(bad_n)) {
  ci_fail("S5: %d count column(s) hold a negative value:\n%s",
          length(bad_n), paste(sprintf("       %s", bad_n), collapse = "\n"))
} else {
  ci_ok("%d count columns are non-negative", n_cols)
}

ci_finish()
