#!/usr/bin/env Rscript
# =============================================================================
# Fourteen saboteurs: the Open Payments practice-state op_series
# =============================================================================
# read_open_payments_state_series() produces the 94,167-row, 2021-2025 op_series
# behind Figures 2, 4 and 5 and the Open Payments agreement percentage. It
# exists because three producers each discovered their input with Sys.glob()
# and took the program year from the filename, so a machine holding only the
# 2024 file published a five-year op_series as one year and nothing failed
# (docs/state-source-audit-coverage-defect.md).
#
# The window is now declared and the year comes from CMS's own Program_Year
# column. What was still unguarded is everything BETWEEN those two checks:
# the rows themselves. A row leaves this function for one of three reasons --
# no npi, no parseable year, or a year nobody declared -- and they are not
# interchangeable. One trailing filter made all three invisible.
#
# The standard every saboteur is held to:
#
#   A row that cannot be used must be COUNTED, and a malformed year must FAIL
#   LOUDLY: a partial loss leaves every declared year in the window, so the
#   window check cannot see it.
#   A declared year that is present, complete and EMPTY must PASS -- it is
#   valid evidence of absence, which is the whole distinction the coverage
#   contract draws.
#   A year declared ineligible or unavailable must stay out of the window
#   whether or not a file for it turns up.
#
# S1, S7, S9, S10 and S12 are inverted on purpose: they sabotage this code
# into being too strict, and pass only if valid absence and declared
# exclusion still survive. Without them a later "fix" could satisfy the rest
# by refusing every input.
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr)})
.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
source(file.path(root, "R", "lib", "source_year.R"))
source(file.path(root, "R", "lib", "source_coverage.R"))
source(file.path(root, "R", "lib", "clean_state.R"))
source(file.path(root, "R", "lib", "open_payments_state_series.R"))


# --- the crime scene ---------------------------------------------------------
# Three declared years standing in for the real five, three payment rows each,
# with each year's NPIs distinct so a double-read shows up as a row count.
sandbox <- file.path(tempdir(), "op_saboteurs")
DECLARED_YEARS <- 2021:2023

op_year_path <- function(program_year)
  file.path("artifacts",
            sprintf("cohort_midwives_open_payments_general_%d.csv",
                    program_year))

op_write_year <- function(program_year, n_rows = 3L, years_written = program_year,
                       npis = NULL, states = c("CO", "NM", "AZ"),
                       drop_columns = character(0)) {
  npi_base <- 1L + 100L * (program_year - 2020L)
  annual_rows <- tibble::tibble(
    npi = npis %||% sprintf("1%09d", npi_base + seq_len(3L) - 1L),
    certification_number = sprintf("CNM%05d", seq_len(3L)),
    program_year = rep(as.character(years_written), length.out = 3L),
    recipient_state = rep(states, length.out = 3L))
  for (dropped in drop_columns) annual_rows[[dropped]] <- NULL
  readr::write_csv(annual_rows[seq_len(n_rows), , drop = FALSE],
                   file.path(sandbox, op_year_path(program_year)))
}

# `statuses` and `requireds` are named by year so a saboteur can declare one
# year ineligible or unavailable without restating the rest.
op_write_manifest <- function(years = DECLARED_YEARS, statuses = NULL,
                           requireds = NULL, extra_year_for = NULL) {
  status_for <- function(y) if (!is.null(statuses) && as.character(y) %in%
                                names(statuses))
    statuses[[as.character(y)]] else "available"
  required_for <- function(y) if (!is.null(requireds) && as.character(y) %in%
                                  names(requireds))
    requireds[[as.character(y)]] else TRUE
  declared <- tibble::tibble(
    source_id = "open_payments", source_name = "saboteur fixture",
    expected_year = years, required = vapply(years, required_for, logical(1)),
    source_type = "annual", input_path = op_year_path(years), producer = "fixture",
    date_field = "program_year", state_field = "recipient_state",
    validation_method = "in_file_date", source_vintage = "fixture",
    artifact_sha256 = NA_character_, cnm_reportable = NA_character_,
    availability_status = vapply(years, status_for, character(1)),
    notes = "saboteur fixture")
  if (!is.null(extra_year_for)) {
    # The manifest's duplicate check keys on source_id + expected_year +
    # input_path, so the SAME path under a different declared year passes it.
    twice <- declared %>%
      dplyr::filter(.data$expected_year == extra_year_for)
    twice$expected_year <- 2020L
    declared <- dplyr::bind_rows(declared, twice)
  }
  readr::write_csv(declared, file.path(sandbox, "config",
                                       "state_source_audit_sources.csv"))
}

op_restore_scene <- function(...) {
  unlink(sandbox, recursive = TRUE)
  dir.create(file.path(sandbox, "artifacts"), recursive = TRUE,
             showWarnings = FALSE)
  dir.create(file.path(sandbox, "config"), recursive = TRUE,
             showWarnings = FALSE)
  for (program_year in DECLARED_YEARS) op_write_year(program_year)
  op_write_manifest(...)
}

# Captures both the verdict and the build log, so a saboteur can assert that
# a loss was REPORTED rather than merely survived.
op_series <- function(publication_mode = TRUE) {
  owd <- setwd(sandbox); on.exit(setwd(owd), add = TRUE)
  logged <- character(0)
  result <- withCallingHandlers(
    tryCatch(read_open_payments_state_series(publication_mode),
             error = function(e) structure(conditionMessage(e),
                                           class = "refusal")),
    message = function(m) {
      logged <<- c(logged, conditionMessage(m)); invokeRestart("muffleMessage")
    })
  if (!inherits(result, "refusal")) result$log <- paste(logged, collapse = "")
  result
}
op_says <- function(x, ...) {
  text <- if (refused(x)) as.character(x) else x$log
  all(vapply(c(...), function(needle) grepl(needle, text, fixed = TRUE),
             logical(1)))
}

cat("\n=== baseline ===\n")
op_restore_scene()
baseline <- op_series()
chk(!refused(baseline), "B1 an intact scene publishes")
chk(!refused(baseline) && nrow(baseline$rows) == 9L,
    "B2 all nine payment rows across all three declared years")
chk(!refused(baseline) && identical(baseline$years, 2021:2023),
    "B3 the analysed window is the declared window")

# --- S1 (INVERTED): the defect -- valid absence read as a contradiction ------
cat("\n=== S1 a declared year is present, complete and empty ===\n")
op_restore_scene()
op_write_year(2022, n_rows = 0L)
s1 <- op_series()
chk(!refused(s1), "S1 a zero-record declared year does NOT fail the build")
chk(!refused(s1) && nrow(s1$rows) == 6L,
    "S1 the other two years contribute all their rows")
chk(!refused(s1) && identical(s1$years_empty, 2022L),
    "S1 2022 is reported as an empty year, not as a missing one")
# "not a gap" is this function's own words; the coverage contract logs its
# own valid-absence line for the same year, so asserting on that text would
# have passed whatever this function said.
chk(op_says(s1, "zero qualifying records", "not a gap"),
    "S1 the build log names it as evidence of absence rather than a gap")
chk(!refused(s1) && identical(s1$declared_years, 2021:2023),
    "S1 the declared window still reads 2021-2023")

# --- S2: a partial year loss the window check cannot see --------------------
cat("\n=== S2 one row carries program_year '2,022' ===\n")
op_restore_scene()
op_write_year(2022, years_written = c("2022", "2,022", "2022"))
s2 <- op_series()
chk(op_says(s2, "not a four-digit year", "general_2022.csv"),
    "S2 refuses, naming the file and the malformed count")
chk(refused(s2) || nrow(s2$rows) != 8L,
    "S2 does not publish an eight-row op_series as if nine had been read")

# --- S3: every row in one file malformed ------------------------------------
cat("\n=== S3 every row in the 2023 file carries 'PY2023' ===\n")
op_restore_scene()
op_write_year(2023, years_written = "PY2023")
s3 <- op_series()
# When EVERY row is malformed the coverage contract gets there first and op_says
# something more precise than this function could: the year could not be
# established at all. That is the right layer and the right verdict. It is
# also why S2 exists -- a PARTIAL malformation leaves the majority of rows
# carrying the declared year, so assert_source_year() verifies it happily and
# only the per-file loss count can see the rows that left.
chk(op_says(s3, "year_unverified", "cannot establish the program year"),
    "S3 the coverage contract refuses a wholly unreadable year first")

# --- S4: a file carrying a year nobody declared ------------------------------
cat("\n=== S4 the 2022 file is full of 2019 rows ===\n")
op_restore_scene()
op_write_year(2022, years_written = 2019L)
s4 <- op_series()
chk(refused(s4), "S4 refuses a file whose rows carry an undeclared year")
chk(op_says(s4, "year_refuted", "contradicts declared year 2022"),
    "S4 the refusal op_says the in-file year contradicts the declared one")

# --- S5: a year with records that contributes none ---------------------------
cat("\n=== S5 every row in the 2022 file has a blank npi ===\n")
op_restore_scene()
op_write_year(2022, npis = rep(NA_character_, 3L))
s5 <- op_series()
chk(op_says(s5, "have records but contributed none", "2022"),
    "S5 a year whose rows are all unusable fails rather than becoming empty")

# --- S6: a declared required year simply absent ------------------------------
cat("\n=== S6 the 2022 file is missing ===\n")
op_restore_scene()
unlink(file.path(sandbox, op_year_path(2022)))
s6 <- op_series()
chk(refused(s6), "S6 publication mode refuses a missing required year")
chk(op_says(s6, "general_2022.csv"), "S6 the refusal names the absent file")

# --- S7 (INVERTED): an unattributable row is counted, not fatal --------------
cat("\n=== S7 one 2022 row has no npi, the other two are usable ===\n")
op_restore_scene()
op_write_year(2022, npis = c("1000000201", NA_character_, "1000000203"))
s7 <- op_series()
chk(!refused(s7), "S7 one unattributable row does not fail the build")
chk(!refused(s7) && nrow(s7$rows) == 8L, "S7 the eight usable rows survive")
chk(op_says(s7, "carry no npi and cannot be attributed"),
    "S7 the dropped row is a number in the log, not a silent subtraction")
chk(!refused(s7) &&
      s7$file_losses$n_npi_missing[s7$file_losses$declared_year == 2022L] == 1L,
    "S7 the loss is attributed to the year it came from")

# --- S8: the declared state column goes missing ------------------------------
cat("\n=== S8 the 2021 file loses its recipient_state column ===\n")
op_restore_scene()
op_write_year(2021, drop_columns = "recipient_state")
s8 <- op_series()
chk(refused(s8), "S8 refuses a file missing the declared state column")

# --- S9 (INVERTED): an ineligible year stays out, file or no file ------------
# 2015-2020 are declared ineligible because certified nurse-midwives were not
# reportable covered recipients before program year 2021. Those files EXIST
# and hold a few incidental rows. A declared scientific exclusion must not be
# undone by the file being readable.
cat("\n=== S9 2021 is declared ineligible but its file is full ===\n")
op_restore_scene(statuses = list("2021" = "ineligible"),
              requireds = list("2021" = FALSE))
s9 <- op_series()
chk(!refused(s9), "S9 an ineligible year does not fail the build")
chk(!refused(s9) && identical(s9$years, 2022:2023),
    "S9 the ineligible year is excluded from the analysed window")
chk(!refused(s9) && nrow(s9$rows) == 6L,
    "S9 none of its readable rows reaches the op_series")

# --- S10 (INVERTED): an unavailable year stays out too -----------------------
# 2013 and 2014 are declared unavailable because the CMS file carries no NPI
# column at all. The reason differs from ineligibility; the consequence must
# not. A stub file appearing for such a year may not widen the published
# window.
cat("\n=== S10 2021 is declared unavailable but a full file appears ===\n")
op_restore_scene(statuses = list("2021" = "unavailable"),
              requireds = list("2021" = FALSE))
s10 <- op_series()
chk(!refused(s10), "S10 an unavailable year does not fail the build")
chk(!refused(s10) && identical(s10$years, 2022:2023),
    "S10 a year declared unavailable stays out of the analysed window")
chk(!refused(s10) && nrow(s10$rows) == 6L,
    "S10 none of its rows reaches the op_series")

# --- S11: the in-file year contradicts the declared year --------------------
cat("\n=== S11 the 2022 file holds 2023 rows ===\n")
op_restore_scene()
op_write_year(2022, years_written = 2023L)
s11 <- op_series()
chk(refused(s11),
    "S11 refuses when a file's rows carry a different declared year's data")

# --- S12 (INVERTED): every declared year present and empty ------------------
cat("\n=== S12 every declared year is present and holds zero records ===\n")
op_restore_scene()
for (program_year in DECLARED_YEARS) op_write_year(program_year, n_rows = 0L)
s12 <- op_series()
chk(!refused(s12), "S12 an all-empty window returns a verdict, not an error")
chk(!refused(s12) && nrow(s12$rows) == 0L, "S12 zero rows, reported as zero")
chk(!refused(s12) && identical(s12$declared_years, 2021:2023),
    "S12 the declared window is still reported in full")

# --- S13: the same file declared under two years ----------------------------
cat("\n=== S13 the 2021 file is also declared as 2020 ===\n")
op_restore_scene(extra_year_for = 2021L)
s13 <- op_series()
chk(refused(s13) || nrow(s13$rows) == 9L,
    "S13 a twice-declared file is not read twice into the op_series")

# --- S14: an undeclared year hidden past the year-verifier's sample ---------
# source_year_from_columns() reads the first 50,000 rows and, for a file over
# 100,000 lines, the last 50,000. Every real Open Payments annual file is
# 14,000-22,000 rows, so the verifier sees all of it and a stray year is
# refuted upstream -- which is why S4 is caught there rather than here. A
# larger file has a blind middle, and for a row hiding in it this function's
# undeclared-year check is the only thing between a year nobody declared and
# the published window. 120,000 rows, one of them 2019, at row 60,000.
cat("\n=== S14 a 2019 row at row 60,000 of a 120,000-row 2022 file ===\n")
op_restore_scene()
HIDDEN_ROW <- 60000L
BIG_ROWS <- 120000L
big_years <- rep("2022", BIG_ROWS)
big_years[HIDDEN_ROW] <- "2019"
readr::write_csv(tibble::tibble(
  npi = sprintf("1%09d", 200000L + seq_len(BIG_ROWS)),
  certification_number = sprintf("CNM%06d", seq_len(BIG_ROWS)),
  program_year = big_years,
  recipient_state = rep(c("CO", "NM", "AZ"), length.out = BIG_ROWS)),
  file.path(sandbox, op_year_path(2022)))
s14 <- op_series()
chk(op_says(s14, "year_refuted") || op_says(s14, "undeclared year"),
    "S14 the hidden undeclared year is refused by one layer or the other")
chk(refused(s14) || !(2019L %in% s14$years),
    "S14 2019 never appears in the published window")

cat(sprintf("\n%s  %d failure(s)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS",
            fails))
quit(status = if (fails == 0L) 0L else 1L)
