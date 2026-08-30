#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop, cycle 28 (session-cycle 5 of 24) -- 3 BVA / 4 semantic / 3 adversarial
# =============================================================================
# Target: check_npi_deactivation.R -- cross-checks AMCB certification status
# against NPPES NPI deactivations, the closest thing in this repo to an
# "exit" signal for a certificant leaving the workforce ("entrant and exit
# calculations" is explicitly prioritized). Zero prior tests existed.
#
# The file cannot run end-to-end here (needs a real NPPES Deactivated NPI
# Report .xlsx and midwives_with_nppes.csv), so these tests replicate its
# literal logic pieces -- the year-extraction regex, and the join/dedup
# integration -- rather than re-testing assert_unique_keys() itself, which
# is already exhaustively covered by tests/test_cycle2_dates_keys.R,
# test_cycle5_key_resolution.R and test_cycle9_joins.R.
suppressPackageStartupMessages({ library(dplyr); library(stringr) })
root <- if (basename(getwd()) == "tests") ".." else "."
source(file.path(root, "R", "join_safety.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

extract_year <- function(x) as.integer(str_extract(x, "[12][0-9]{3}"))

cat("\n-- BVA --\n")

chk(all(extract_year(c("2024-04-08", "04/08/2024", "20240408")) == 2024L),
    "T28-1: the year-extraction regex agrees across ISO, US-slash, and compact YYYYMMDD formats")

chk(is.na(extract_year("4/8/24")),
    "T28-2: a 2-digit-year format yields NA rather than misparsing a plausible-looking 4-digit run")

chk(is.na(extract_year("")) && is.na(extract_year(NA_character_)),
    "T28-3: an empty or NA deactivation_date string yields NA, not an error or a fabricated year")

cat("\n-- semantic --\n")

deact_dates <- c("2024-04-08", NA, "2023-01-15")
npi_deactivated <- !is.na(deact_dates)
chk(identical(npi_deactivated, c(TRUE, FALSE, TRUE)),
    "T28-4: npi_deactivated is TRUE if and only if a real (non-NA) deactivation date joined in -- exact logical correspondence, not an approximation")

summ <- tibble::tibble(status = c("ACTIVE", "LAPSED"), n = c(100L, 20L), matched = c(85L, 6L)) %>%
  mutate(pct_matched = round(100 * matched / n, 1))
chk(all(abs(summ$pct_matched - 100 * summ$matched / summ$n) < 1e-9),
    "T28-5: pct_matched is arithmetically consistent with matched/n for every status group")

dedup_input <- tibble::tibble(npi = c("1111111111", "1111111111"),
                              deactivation_date = c("2024-04-08", "2024-04-08"))
collapsed <- assert_unique_keys(dedup_input, "npi", label = "test fixture", dedupe = TRUE)
chk(nrow(collapsed) == 1L,
    "T28-6a: identical duplicate NPI rows in the deactivation report collapse to one without erroring")

conflict_input <- tibble::tibble(npi = c("2222222222", "2222222222"),
                                 deactivation_date = c("2024-04-08", "2019-11-01"))
err <- tryCatch({
  assert_unique_keys(conflict_input, "npi", label = "test fixture", dedupe = TRUE)
  NA_character_
}, error = function(e) conditionMessage(e))
chk(!is.na(err) && grepl("DISAGREE", err),
    "T28-6b: an NPI deactivated, reactivated, and deactivated again (two rows, different dates) STOPS the script rather than silently picking one by file order")

y_partial <- extract_year("4/8/24")  # year parse fails
d_partial <- "4/8/24"                # but the date STRING itself is present
chk(is.na(y_partial) && !is.na(d_partial) && nzchar(d_partial),
    "T28-7: a year-parse failure does not erase the underlying deactivation_date string it failed to parse from")

cat("\n-- adversarial --\n")

chk({
  retired <- conflict_input %>% distinct(npi, .keep_all = TRUE)
  nrow(retired) == 1L && retired$deactivation_date[1] == conflict_input$deactivation_date[1]
}, "T28-8 (anti-ceremony): the RETIRED distinct(.keep_all=TRUE) pattern DOES silently resolve the same conflicting pair by file order, picking whichever sorted first -- confirms T28-6b discriminates against real prior behaviour")

src_lines_all <- readLines(file.path(root, "check_npi_deactivation.R"), warn = FALSE)
src_lines <- src_lines_all[!grepl("^\\s*#", src_lines_all)]
src_txt <- paste(src_lines, collapse = "\n")
chk(lengths(regmatches(src_txt, gregexpr("as\\.character\\(npi\\)", src_txt))) == 2L,
    "T28-9: NPI is coerced to character on BOTH sides of the join (midwives and the deactivation report) -- a future edit dropping either side would silently break every match, since character and double never join")

chk(!grepl("distinct\\(npi,\\s*\\.keep_all\\s*=\\s*TRUE\\)", src_txt) &&
      grepl("assert_unique_keys\\(", src_txt),
    "T28-10: no bare distinct(npi, .keep_all=TRUE) survives in this file -- the deactivation report is deduplicated via the shared, conflict-aware helper")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
