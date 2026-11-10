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
cohort <- function(npis) dbWriteTable(con, "cohort_npi", data.frame(npi = npis), overwrite = TRUE)

# ---- [1] deterministic modal rule ------------------------------------------
cohort(c("1000000001"))
src <- mk("t_modal", data.frame(
  NPI   = c("1000000001", "1000000001", "1000000001"),
  STATE = c("CO", "CO", "WY"), stringsAsFactors = FALSE))
r1 <- pull_states(src, "NPI", "STATE", 2013L)
chk(nrow(r1) == 1L && r1$state == "CO", "[1] modal state wins (CO 2 rows vs WY 1)")
chk(identical(r1$year, 2013L), "[1] year is the literal passed in, not read from data")

r1b <- pull_states(src, "NPI", "STATE", 2013L)
chk(identical(r1, r1b), "[1] rerun is identical (deterministic)")

# ---- [2] ties broken alphabetically, both orderings ------------------------
cohort(c("1000000002"))
a <- pull_states(mk("t_tie_a", data.frame(NPI = c("1000000002","1000000002"),
       STATE = c("WY","CO"), stringsAsFactors = FALSE)), "NPI", "STATE", 2014L)
b <- pull_states(mk("t_tie_b", data.frame(NPI = c("1000000002","1000000002"),
       STATE = c("CO","WY"), stringsAsFactors = FALSE)), "NPI", "STATE", 2014L)
chk(a$state == "CO" && b$state == "CO",
    "[2] a 1-1 tie resolves to the alphabetically first state, whatever the row order")

# ---- [3] duplicates collapse to one row; multiplicity is reported ----------
cohort(c("1000000003"))
r3 <- pull_states(mk("t_dup", data.frame(
  NPI = rep("1000000003", 5), STATE = c("CO","CO","CO","WY","NM"),
  stringsAsFactors = FALSE)), "NPI", "STATE", 2015L)
chk(nrow(r3) == 1L, "[3] five rows for one midwife-year collapse to one row")
chk(r3$n_states_this_year == 3L, "[3] n_states_this_year reports all 3, so multiplicity is visible")

# ---- [4] non-US states dropped, never coerced to a US state ----------------
cohort(c("1000000004", "1000000005"))
r4 <- pull_states(mk("t_zz", data.frame(
  NPI   = c("1000000004", "1000000005"),
  STATE = c("ZZ", "CO"), stringsAsFactors = FALSE)), "NPI", "STATE", 2016L)
chk(nrow(r4) == 1L && r4$npi == "1000000005",
    "[4] a foreign state code (ZZ) is dropped, not mapped to a US state")

# empty / whitespace states never become a row
cohort(c("1000000006"))
r4b <- pull_states(mk("t_blank", data.frame(
  NPI = c("1000000006","1000000006"), STATE = c("", "   "),
  stringsAsFactors = FALSE)), "NPI", "STATE", 2016L)
chk(is.null(r4b), "[4] a midwife with only blank states yields no row (not a blank state)")

# ---- [5] missing years are left missing ------------------------------------
cohort(c("1000000007"))
r5 <- pull_states(NULL, "NPI", "STATE", 2017L)
chk(is.null(r5), "[5] an absent source returns NULL -- no placeholder row, no carry-forward")

# ---- [6] no future information reaches an earlier year ---------------------
# Same midwife, two years, different states. The 2013 answer must not change
# because a 2014 file exists, and must never be filled from it.
cohort(c("1000000008"))
s13 <- mk("t_y13", data.frame(NPI = "1000000008", STATE = "CO", stringsAsFactors = FALSE))
s14 <- mk("t_y14", data.frame(NPI = "1000000008", STATE = "NM", stringsAsFactors = FALSE))
y13_alone <- pull_states(s13, "NPI", "STATE", 2013L)
invisible(pull_states(s14, "NPI", "STATE", 2014L))
y13_after <- pull_states(s13, "NPI", "STATE", 2013L)
chk(identical(y13_alone, y13_after),
    "[6] the 2013 value is unchanged by the existence of a 2014 observation")
chk(y13_after$state == "CO", "[6] and still holds its own year's state, not the later one")

# a year with no row for this midwife stays empty rather than inheriting
cohort(c("1000000009"))
s_only14 <- mk("t_only14", data.frame(NPI = "1000000009", STATE = "NM", stringsAsFactors = FALSE))
cohort(c("1000000008"))   # a different midwife
chk(is.null(pull_states(s_only14, "NPI", "STATE", 2014L)),
    "[6] a midwife absent from a year's file gets no row for that year")

# ---- [7] original observations preserved: rerun is idempotent --------------
cohort(c("1000000010"))
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

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
