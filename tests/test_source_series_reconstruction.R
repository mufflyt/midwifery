#!/usr/bin/env Rscript
# =============================================================================
# Source-series reconstruction contract
# =============================================================================
# docs/source-series-reconstruction.md asserts a short list of properties that
# make the temporal analyses in this project readable as measurements rather
# than as artifacts of the reconstruction. This file pins them.
#
# pull_states() is tested AS SHIPPED, not as a copy: the test parses
# extract_medicare_part_b_d_cohort_states.R, lifts out that one assignment, and
# evaluates it against an in-memory DuckDB. Re-typing the function here would
# test the test. The rest of that script (warehouse resolution, volume paths,
# 6 GB of CSV) never runs.
#
# Claim -> test map, for docs/source-series-reconstruction.md S7:
#   S3.1 deterministic modal rule, ties alphabetical ....... [1] [2]
#   S3.1 duplicate midwife-year rows resolve, not duplicate  [1] [3]
#   S3.1 multiplicity is reported, not hidden ............... [3]
#   S3.1 non-US states dropped, not coerced ................. [4]
#   S2   missing years left missing, never interpolated ..... [5]
#   S3.1 no future information reaches an earlier year ...... [6]
#   S3.1 original observations preserved under rerun ........ [7]
#   S2   output schema is stable ............................ [8]
#   S4   artifacts hold one row per (npi, year) ............. [9]
#   S4   only ADJACENT years count as a transition ........... [10]
#   S2.1 a vintage packaged before its period is refuted ..... [11]
#   S2.1 PPEF reads the two-letter state, not the FIPS code ... [12]
#   S3.1 a padded NPI still joins to the cohort .............. [13]
#   S6   the resolver picks by-Provider, not by-Provider+Drug . [14]
#   S2   an absent warehouse table is reported absent ......... [15]
#   S2.1 vintage labels are zero-padded and sortable .......... [16]
#   S4   load_pairs() deduplicates before counting ............ [17]
# =============================================================================
ok <- requireNamespace("duckdb", quietly = TRUE) && requireNamespace("DBI", quietly = TRUE)
if (!ok) { cat("duckdb/DBI unavailable -- skipping\n"); quit(status = 0L) }
suppressPackageStartupMessages({library(DBI); library(duckdb)})
source(file.path("R", "lib", "clean_state.R"))

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", msg))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", msg)) }
}

# ---- lift pull_states() out of the shipped script, without running it -------
SCRIPT <- "extract_medicare_part_b_d_cohort_states.R"
exprs <- parse(SCRIPT)
is_def <- vapply(exprs, function(e)
  is.call(e) && identical(as.character(e[[1]]), "<-") &&
    is.name(e[[2]]) && identical(as.character(e[[2]]), "pull_states"), logical(1))
chk(sum(is_def) == 1L, sprintf("pull_states() found exactly once in %s", SCRIPT))
if (sum(is_def) != 1L) quit(status = 1L)

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
eval(exprs[[which(is_def)]])   # defines pull_states() against this `con`

mk <- function(name, df) { dbWriteTable(con, name, as.data.frame(df), overwrite = TRUE); 
                           list(sql = dbQuoteIdentifier(con, name), label = name) }
stage_cohort <- function(npis) dbWriteTable(con, "cohort_npi", data.frame(npi = npis), overwrite = TRUE)

# ---- [1] deterministic modal rule ------------------------------------------
stage_cohort(c("1000000001"))
src <- mk("t_modal", data.frame(
  NPI   = c("1000000001", "1000000001", "1000000001"),
  STATE = c("CO", "CO", "WY"), stringsAsFactors = FALSE))
r1 <- pull_states(src, "NPI", "STATE", 2013L)
chk(nrow(r1) == 1L && r1$state == "CO", "[1] modal state wins (CO 2 rows vs WY 1)")
chk(identical(r1$year, 2013L), "[1] year is the literal passed in, not read from data")

r1b <- pull_states(src, "NPI", "STATE", 2013L)
chk(identical(r1, r1b), "[1] rerun is identical (deterministic)")

# ---- [2] ties broken alphabetically, both orderings ------------------------
stage_cohort(c("1000000002"))
a <- pull_states(mk("t_tie_a", data.frame(NPI = c("1000000002","1000000002"),
       STATE = c("WY","CO"), stringsAsFactors = FALSE)), "NPI", "STATE", 2014L)
b <- pull_states(mk("t_tie_b", data.frame(NPI = c("1000000002","1000000002"),
       STATE = c("CO","WY"), stringsAsFactors = FALSE)), "NPI", "STATE", 2014L)
chk(a$state == "CO" && b$state == "CO",
    "[2] a 1-1 tie resolves to the alphabetically first state, whatever the row order")

# ---- [3] duplicates collapse to one row; multiplicity is reported ----------
stage_cohort(c("1000000003"))
r3 <- pull_states(mk("t_dup", data.frame(
  NPI = rep("1000000003", 5), STATE = c("CO","CO","CO","WY","NM"),
  stringsAsFactors = FALSE)), "NPI", "STATE", 2015L)
chk(nrow(r3) == 1L, "[3] five rows for one midwife-year collapse to one row")
chk(r3$n_states_this_year == 3L, "[3] n_states_this_year reports all 3, so multiplicity is visible")

# ---- [4] non-US states dropped, never coerced to a US state ----------------
stage_cohort(c("1000000004", "1000000005"))
r4 <- pull_states(mk("t_zz", data.frame(
  NPI   = c("1000000004", "1000000005"),
  STATE = c("ZZ", "CO"), stringsAsFactors = FALSE)), "NPI", "STATE", 2016L)
chk(nrow(r4) == 1L && r4$npi == "1000000005",
    "[4] a foreign state code (ZZ) is dropped, not mapped to a US state")

# empty / whitespace states never become a row
stage_cohort(c("1000000006"))
r4b <- pull_states(mk("t_blank", data.frame(
  NPI = c("1000000006","1000000006"), STATE = c("", "   "),
  stringsAsFactors = FALSE)), "NPI", "STATE", 2016L)
chk(is.null(r4b), "[4] a midwife with only blank states yields no row (not a blank state)")

# ---- [5] missing years are left missing ------------------------------------
stage_cohort(c("1000000007"))
r5 <- pull_states(NULL, "NPI", "STATE", 2017L)
chk(is.null(r5), "[5] an absent source returns NULL -- no placeholder row, no carry-forward")

# ---- [6] no future information reaches an earlier year ---------------------
# Same midwife, two years, different states. The 2013 answer must not change
# because a 2014 file exists, and must never be filled from it.
stage_cohort(c("1000000008"))
s13 <- mk("t_y13", data.frame(NPI = "1000000008", STATE = "CO", stringsAsFactors = FALSE))
s14 <- mk("t_y14", data.frame(NPI = "1000000008", STATE = "NM", stringsAsFactors = FALSE))
y13_alone <- pull_states(s13, "NPI", "STATE", 2013L)
invisible(pull_states(s14, "NPI", "STATE", 2014L))
y13_after <- pull_states(s13, "NPI", "STATE", 2013L)
chk(identical(y13_alone, y13_after),
    "[6] the 2013 value is unchanged by the existence of a 2014 observation")
chk(y13_after$state == "CO", "[6] and still holds its own year's state, not the later one")

# a year with no row for this midwife stays empty rather than inheriting
stage_cohort(c("1000000009"))
s_only14 <- mk("t_only14", data.frame(NPI = "1000000009", STATE = "NM", stringsAsFactors = FALSE))
stage_cohort(c("1000000008"))   # a different midwife
chk(is.null(pull_states(s_only14, "NPI", "STATE", 2014L)),
    "[6] a midwife absent from a year's file gets no row for that year")

# ---- [7] original observations preserved: rerun is idempotent --------------
stage_cohort(c("1000000010"))
s7 <- mk("t_idem", data.frame(NPI = rep("1000000010", 3), STATE = c("CO","CO","WY"),
                              stringsAsFactors = FALSE))
runs <- lapply(1:3, function(i) pull_states(s7, "NPI", "STATE", 2018L))
chk(length(unique(lapply(runs, identity))) == 1L, "[7] three consecutive runs agree exactly")

# ---- [8] output schema is stable -------------------------------------------
chk(identical(names(r1), c("npi", "year", "state", "n_states_this_year")),
    "[8] columns are exactly npi, year, state, n_states_this_year, in order")
chk(is.integer(r1$year) && is.character(r1$npi) && is.character(r1$state),
    "[8] column types are stable (npi/state character, year integer)")

# ---- [9] shipped artifacts hold one row per (npi, year) --------------------
# Skipped where the artifact is absent: CI does not carry person-level files.
for (f in c("artifacts/cohort_midwives_part_b_state_by_year.csv",
            "artifacts/cohort_midwives_part_d_state_by_year.csv",
            "artifacts/pecos_revalidation_cohort_state_by_year.csv")) {
  if (!file.exists(f)) { cat(sprintf("  skip %s (absent)\n", basename(f))); next }
  d <- utils::read.csv(f, colClasses = "character")
  key <- paste(trimws(d$npi), d$year)
  chk(!any(duplicated(key)), sprintf("[9] %s has one row per (npi, year)", basename(f)))
  chk(all(!is.na(suppressWarnings(as.integer(d$year)))),
      sprintf("[9] %s has an integer year on every row", basename(f)))
}

# ---- [10] only adjacent years count as a transition -----------------------
# The independence audit's whole claim rests on this: a midwife seen in 2015
# and again in 2019 did not make ONE transition over four years, she made an
# unknown number, and counting the pair as a transition would invent a
# measurement. Lifted from the shipped script for the same reason as above.
if (requireNamespace("dplyr", quietly = TRUE)) {
  suppressPackageStartupMessages(library(dplyr))
  AUD <- "audit_source_series_independence.R"
  aexp <- parse(AUD)
  ais <- vapply(aexp, function(e)
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), "adjacent_transitions"),
    logical(1))
  chk(sum(ais) == 1L, sprintf("[10] adjacent_transitions() found once in %s", AUD))
  if (sum(ais) == 1L) {
    eval(aexp[[which(ais)]])
    # DELIBERATELY SHUFFLED. A file read off disk arrives in whatever order
    # the writer used, so adjacent_transitions() must sort before taking
    # lead(). A fixture in sorted order would pass even if arrange() were
    # deleted. B's 2019 sits one year before C's 2020 on purpose: without
    # group_by(npi), lead() runs off the end of one midwife into the next
    # and invents a transition between two different people.
    d <- data.frame(
      npi  = c("C",   "A",   "B",   "C",   "A",   "C",   "B",   "A",   "C"),
      year = c(2023L, 2014L, 2019L, 2020L, 2013L, 2024L, 2015L, 2015L, 2021L),
      stringsAsFactors = FALSE)
    tr <- adjacent_transitions(d)
    chk(nrow(tr) == 4L, "[10] 9 observations yield 4 adjacent transitions, not 6")
    chk(!any(tr$npi == "B"), "[10] a 2015->2019 gap contributes no transition")
    chk(identical(sort(tr$year[tr$npi == "C"]), c(2020L, 2023L)),
        "[10] C's 2021->2023 gap is skipped; its two adjacent pairs are kept")
    chk(nrow(adjacent_transitions(d[d$npi == "B", ])) == 0L,
        "[10] a midwife with only non-adjacent years yields nothing")
  }
} else cat("  skip [10] dplyr unavailable\n")

# ---- [11] a vintage packaged before its period is refuted -----------------
# PPEF carries no in-file date, so the archive's stored mtime is the evidence.
# It cannot confirm a vintage, but it can refute one: a file packaged before
# the period it claims to describe is impossible.
if (nzchar(Sys.which("zip")) && file.exists("extract_ppef_cohort_state_by_vintage.R")) {
  pexp <- parse("extract_ppef_cohort_state_by_vintage.R")
  pis <- vapply(pexp, function(e)
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), "validate_vintage"),
    logical(1))
  chk(sum(pis) == 1L, "[11] validate_vintage() found once")
  if (sum(pis) == 1L) {
    eval(pexp[[which(pis)]])
    mkzip <- function(tag, mtime) {
      d <- file.path(tempdir(), paste0("vz_", tag)); dir.create(d, showWarnings = FALSE)
      f <- file.path(d, paste0("ppefenrol", tag, ".csv"))
      writeLines("npi,state_cdstr", f); Sys.setFileTime(f, mtime)
      z <- file.path(d, paste0("ppefenrol", tag, ".csv.zip"))
      owd <- setwd(d); on.exit(setwd(owd), add = TRUE)
      utils::zip(basename(z), basename(f), flags = "-qX")
      file.path(d, basename(z))
    }
    zl <- mkzip("20168late", as.POSIXct("2016-11-18 12:00:00", tz = "UTC"))
    r <- validate_vintage(zl, "\\.csv$", as.Date("2016-08-01"), "nber_monthly")
    chk(identical(r$status, "verified_year"),
        "[11] packaged 2016-11 for a 2016-08 claim is verified_year")

    ze <- mkzip("20168early", as.POSIXct("2016-03-01 12:00:00", tz = "UTC"))
    r2 <- validate_vintage(ze, "\\.csv$", as.Date("2016-08-01"), "nber_monthly")
    chk(identical(r2$status, "refuted"),
        "[11] packaged BEFORE the claimed month is refuted, not accepted")

    zy <- mkzip("20168wrongyr", as.POSIXct("2018-02-01 12:00:00", tz = "UTC"))
    r3 <- validate_vintage(zy, "\\.csv$", as.Date("2016-08-01"), "nber_monthly")
    chk(identical(r3$status, "refuted"),
        "[11] a monthly file packaged two years late is refuted")
    r4 <- validate_vintage(zy, "\\.csv$", as.Date("2016-08-01"), "cms_quarterly")
    chk(identical(r4$status, "verified_date"),
        "[11] the same lag is accepted for a quarterly member, whose CMS extract date is in its name")
  }
} else cat("  skip [11] zip binary or PPEF script unavailable\n")

# ---- [17] load_pairs() deduplicates before anything is counted ------------
# A source that lists a midwife twice in one year -- two enrolments, two
# billing rows -- must not contribute two observations. Everything the
# independence audit reports is a count, so a duplicate here inflates
# npi_years, transitions and the interior-gap denominator at once.
if (requireNamespace("dplyr", quietly = TRUE) &&
    requireNamespace("readr", quietly = TRUE)) {
  aexp2 <- parse("audit_source_series_independence.R")
  lis <- vapply(aexp2, function(e)
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), "load_pairs"),
    logical(1))
  chk(sum(lis) == 1L, "[17] load_pairs() found once")
  if (sum(lis) == 1L) {
    # load_pairs() calls read_csv()/cols() unqualified, as it may: its own
    # script attaches readr at the top. Lifting the function out means
    # reproducing that environment, not rewriting the function.
    suppressPackageStartupMessages({library(readr); library(dplyr)})
    eval(aexp2[[which(lis)]])
    lf <- file.path(tempdir(), "lp_fixture.csv")
    writeLines(c("npi,year",
                 "3000000001,2019", "3000000001,2019", "3000000001,2019",
                 "3000000001,2020", "3000000002,2019", ",2019",
                 "3000000003,"), lf)
    lp <- load_pairs(list(path = lf, year_col = "year"))
    chk(nrow(lp) == 3L,
        "[17] 7 rows with triplicates, a blank NPI and a blank year yield 3 pairs")
    chk(sum(lp$npi == "3000000001") == 2L,
        "[17] one midwife's three identical 2019 rows collapse to one")
    chk(!any(is.na(lp$year)) && !any(!nzchar(lp$npi)),
        "[17] rows with no NPI or no year are dropped, not kept as NA")
  }
}

# ---- [14] the catalogue resolver picks the right PRODUCT and year ---------
# data.cms.gov publishes two Part D products whose titles differ by three
# words: "- by Provider :" (one row per prescriber) and "- by Provider and
# Drug :" (one row per prescriber-drug, ~40x the rows, wrong grain entirely).
# Both appear in the catalogue for every year. A regex that cannot tell them
# apart downloads the wrong one, and it still parses, still has NPIs, still
# has a state column.
if (requireNamespace("jsonlite", quietly = TRUE) &&
    file.exists("download_cms_by_provider_files.R")) {
  dexp <- parse("download_cms_by_provider_files.R")
  want <- c("TITLE_RE", "%||%", "resolve_by_provider_urls")
  for (nm in want) {
    hit <- vapply(dexp, function(e)
      is.call(e) && identical(as.character(e[[1]]), "<-") &&
        identical(deparse(e[[2]]), if (nm == "%||%") "`%||%`" else nm),
      logical(1))
    if (any(hit)) eval(dexp[[which(hit)[1]]])
  }
  fx <- list(dataset = list(
    list(title = "Medicare Part D Prescribers - by Provider and Drug : 2013-12-31",
         distribution = list(list(downloadURL = "https://x/WRONG_DY13_NPIBN.csv"))),
    list(title = "Medicare Part D Prescribers - by Provider : 2013-12-03",
         distribution = list(list(downloadURL = "https://x/right_dy13_npi.csv"))),
    list(title = "Medicare Physician & Other Practitioners - by Provider : 2024-12-01",
         distribution = list(list(downloadURL = "https://x/PHY_D24_Prov.csv"))),
    list(title = "Some Unrelated CMS Dataset : 2024-01-01",
         distribution = list(list(downloadURL = "https://x/unrelated.csv")))))
  fj <- file.path(tempdir(), "cms_fixture.json")
  jsonlite::write_json(fx, fj, auto_unbox = TRUE)
  got <- resolve_by_provider_urls(fj)
  chk(nrow(got) == 2L, "[14] only the two by-Provider datasets are resolved")
  chk(!any(grepl("NPIBN", got$url)),
      "[14] the by-Provider-and-Drug product is NOT mistaken for by-Provider")
  chk(identical(got$year[got$source == "part_d"], 2013L),
      "[14] the data year comes from the title, as an integer")
  chk(identical(got$year[got$source == "part_b"], 2024L),
      "[14] and Part B resolves its own year independently")
} else cat("  skip [14] jsonlite or downloader unavailable\n")

# ---- [15] an absent warehouse table is reported absent --------------------
# has_table() is what stops a missing year becoming a silent zero. If it ever
# answers TRUE for a table that is not there, the query runs against nothing
# and the year vanishes without a log line.
# has_table()/tbl_src() are lifted the same way pull_states() was: by name,
# from the shipped file, so the test cannot drift from the function.
for (nm in c("has_table", "tbl_src")) {
  hit <- vapply(exprs, function(e)
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), nm), logical(1))
  chk(sum(hit) == 1L, sprintf("[15] %s() found once in %s", nm, SCRIPT))
  if (sum(hit) == 1L) eval(exprs[[which(hit)]])
}
chk(is.null(tbl_src("definitely_not_a_table_9f3a")),
    "[15] tbl_src() returns NULL for a table the warehouse does not have")
DBI::dbWriteTable(con, "really_here_9f3a", data.frame(x = 1L), overwrite = TRUE)
chk(!is.null(tbl_src("really_here_9f3a")),
    "[15] and returns a source expression for one it does")

# ---- [16] vintage labels are zero-padded and sortable ---------------------
# NBER does not zero-pad the month in PPEF filenames (ppefenrol20168, not
# ...201608), which already cost one round of 404s. The label this builds
# must pad, or "2016-8" sorts after "2016-10" and every join on vintage
# misses.
if (file.exists("extract_ppef_cohort_state_by_vintage.R")) {
  vexp <- parse("extract_ppef_cohort_state_by_vintage.R")
  vis <- vapply(vexp, function(e)
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), "ppef_vintages"),
    logical(1))
  if (any(vis)) {
    eval(vexp[[which(vis)[1]]])
    vd <- file.path(tempdir(), "vint", "201608"); dir.create(vd, recursive = TRUE, showWarnings = FALSE)
    file.create(file.path(vd, "ppefenrol20168.csv.zip"))
    vd2 <- file.path(tempdir(), "vint", "201710"); dir.create(vd2, recursive = TRUE, showWarnings = FALSE)
    file.create(file.path(vd2, "ppefenrol201710.csv.zip"))
    vv <- ppef_vintages(file.path(tempdir(), "vint"))
    chk(!is.null(vv) && all(c("2016-08", "2017-10") %in% vv$vintage),
        "[16] an unpadded filename month becomes a padded, sortable vintage")
    chk(!is.null(vv) && identical(vv$vintage, sort(vv$vintage)),
        "[16] vintages sort chronologically as strings")
  }
}

# ---- [13] a padded NPI in the source still joins to the cohort ------------
# Warehouse NPIs are clean, so a dropped trim() passes every warehouse year
# and silently drops rows only in the downloaded CSVs -- a source-specific
# undercount that looks like genuinely lower Part D participation.
stage_cohort(c("1000000012"))
r13 <- pull_states(mk("t_pad", data.frame(
  NPI = c(" 1000000012", "1000000012 "), STATE = c("CO", "CO"),
  stringsAsFactors = FALSE)), "NPI", "STATE", 2019L)
chk(!is.null(r13) && nrow(r13) == 1L && r13$state == "CO",
    "[13] NPIs padded with whitespace still match the cohort")

# ---- [12] PPEF reads the two-letter state, not the FIPS code --------------
# The monthly NBER layout carries BOTH state_cd (numeric FIPS: 6, 36, 48) and
# state_cdstr (CA, NY, TX). The quarterly CMS layout carries only STATE_CD,
# and there it IS the two-letter code. Reading the wrong one yields a state
# series of integers. This is not hypothetical: it is the bug that was
# written on 2026-11-10 and caught only because clean_state() refuses
# anything that is not a US state.
if (nzchar(Sys.which("zip")) && file.exists("extract_ppef_cohort_state_by_vintage.R")) {
  pexp2 <- parse("extract_ppef_cohort_state_by_vintage.R")
  pvs <- vapply(pexp2, function(e)
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      is.name(e[[2]]) && identical(as.character(e[[2]]), "pull_vintage"),
    logical(1))
  chk(sum(pvs) == 1L, "[12] pull_vintage() found once")
  if (sum(pvs) == 1L) {
    eval(pexp2[[which(pvs)]])
    pd <- file.path(tempdir(), "ppef_fx"); dir.create(pd, showWarnings = FALSE)
    fx <- file.path(pd, "ppefenrol209901.csv")
    writeLines(c("npi,state_cd,state_cdstr",
                 '"2000000001",6,"CA"',
                 '"2000000002",36,"NY"',
                 '"2000000002",8,"CO"'), fx)
    zfx <- file.path(pd, "ppefenrol209901.csv.zip")
    local({ owd <- setwd(pd); on.exit(setwd(owd), add = TRUE)
            utils::zip(basename(zfx), basename(fx), flags = "-qX") })
    DBI::dbWriteTable(con, "cohort_npi",
                      data.frame(npi = c("2000000001", "2000000002")),
                      overwrite = TRUE)
    got <- pull_vintage(con, zfx, "\\.csv$", "2099-01")
    chk(identical(got$state_col, "state_cdstr"),
        "[12] state_cdstr is preferred over state_cd when both exist")
    rr <- got$rows
    chk(!is.null(rr) && all(rr$state %in% c("CA", "CO", "NY")),
        "[12] states are two-letter codes, never FIPS integers")
    chk(!is.null(rr) && rr$state[rr$npi == "2000000001"] == "CA",
        "[12] a single-state midwife keeps her state")
    chk(!is.null(rr) && rr$state[rr$npi == "2000000002"] == "CO",
        "[12] simultaneous CO/NY enrolments resolve alphabetically to CO")
    chk(!is.null(rr) && rr$n_states_this_vintage[rr$npi == "2000000002"] == 2L,
        "[12] and the multiplicity is reported, not hidden")
  }
} else cat("  skip [12] zip binary or PPEF script unavailable\n")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
