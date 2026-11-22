#!/usr/bin/env Rscript
# =============================================================================
# Refresh Section 3's agreement table from the artifact that produced it
# =============================================================================
# WHY THIS EXISTS. make_state_source_audit_figures.R draws Figure 2 by PARSING
# the Section 3 table out of the technical appendix, and computes the DAC
# trend from the numbers it finds there. So the appendix prose -- not
# artifacts/state_source_audit_agreement.csv -- was the de facto input to a
# published figure. When the audit was rebuilt and the appendix was not, the
# figure kept reporting a slope of -0.228 points a year at p = 0.0014 from a
# table three vintages old, while the data said -0.248 at p = 0.0002.
#
# Rather than have the figure read the CSV and leave the prose to drift
# separately -- which would put two different numbers in front of a reader,
# one in the appendix and one in the figure -- this script makes the prose a
# rendering of the artifact. The appendix stays the single thing a human
# reads, and it can no longer say something the data does not.
#
# tests/test_appendix_matches_artifacts.R fails if the two ever diverge
# again, so running the audit without running this is caught rather than
# published.
#
# Usage: Rscript refresh_state_source_appendix_section3.R
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

APPENDIX <- "docs/TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md"
AGREEMENT <- "artifacts/state_source_audit_agreement.csv"

# The appendix's display names. Kept here rather than in the audit because
# they are typography, not data -- the artifact carries stable source ids.
DISPLAY_NAME <- c(
  dac_physician_compare   = "DAC / Physician Compare",
  open_payments           = "Open Payments",
  pecos_revalidation      = "PECOS revalidation",
  medicare_claims         = "Medicare claims (Parts B and D)",
  facility_affiliation_ccn = "Facility Affiliation (CCN)",
  healthgrades            = "Healthgrades",
  doximity                = "Doximity",
  state_boards_of_nursing = "State Boards of Nursing",
  cms_ndh_fhir            = "CMS NDH (FHIR)")

stopifnot(file.exists(APPENDIX), file.exists(AGREEMENT))

agreement <- read_csv(AGREEMENT, col_types = cols(.default = "c"),
                      progress = FALSE)
unknown <- setdiff(unique(agreement$source), names(DISPLAY_NAME))
if (length(unknown)) {
  stop("refresh_state_source_appendix_section3(): no display name for ",
       paste(unknown, collapse = ", "),
       " -- add it rather than letting the row drop out of the appendix",
       call. = FALSE)
}

# Order: multi-year sources first in their declared order, then the current-
# only snapshots, matching how the table has always read.
SOURCE_ORDER <- names(DISPLAY_NAME)
rendered <- agreement %>%
  mutate(display = DISPLAY_NAME[.data$source],
         source_rank = match(.data$source, SOURCE_ORDER),
         year_sortable = suppressWarnings(as.integer(.data$year)),
         n_comparable_num = as.integer(.data$n_comparable),
         pct_num = as.numeric(.data$pct_agree)) %>%
  arrange(.data$source_rank, is.na(.data$year_sortable),
          .data$year_sortable, .data$year) %>%
  transmute(row = sprintf("| %s | %s | %s | %s | %s |",
                          .data$display, .data$year, .data$comparison_basis,
                          format(.data$n_comparable_num, big.mark = ",",
                                 trim = TRUE),
                          sprintf("%.1f%%", .data$pct_num)))

appendix_lines <- readLines(APPENDIX, warn = FALSE)

# Locate the table the same way make_state_source_audit_figures.R::md_table()
# does -- by its header, not a line number -- so inserting a paragraph above
# it cannot make this script rewrite the wrong table.
header_pattern <- "^\\|\\s*Source\\s*\\|\\s*Period\\s*\\|\\s*Basis\\s*\\|"
header_index <- which(grepl(header_pattern, appendix_lines))
if (length(header_index) != 1L) {
  stop("refresh_state_source_appendix_section3(): expected exactly one ",
       "'| Source | Period | Basis |' header in the appendix, found ",
       length(header_index), call. = FALSE)
}
separator_index <- header_index + 1L
row_index <- separator_index + 1L
while (row_index <= length(appendix_lines) &&
       grepl("^\\s*\\|", appendix_lines[row_index])) {
  row_index <- row_index + 1L
}
old_rows <- appendix_lines[seq(separator_index + 1L, row_index - 1L)]

base::message(sprintf(
  "  Section 3 table: %d rows on disk -> %d rows from %s",
  length(old_rows), nrow(rendered), basename(AGREEMENT)))

refreshed <- c(appendix_lines[seq_len(separator_index)],
               rendered$row,
               appendix_lines[seq(row_index, length(appendix_lines))])
writeLines(refreshed, APPENDIX)
base::message(sprintf("  rewrote %s", APPENDIX))

# Report the DAC trend the figure will now draw, so a run that moves it says
# so out loud instead of only showing up in a regenerated PNG.
dac_trend <- agreement %>%
  filter(.data$source == "dac_physician_compare") %>%
  mutate(year_int = suppressWarnings(as.integer(.data$year)),
         pct = as.numeric(.data$pct_agree),
         n = as.integer(.data$n_comparable)) %>%
  filter(!is.na(.data$year_int), .data$year_int <= 2025)
if (nrow(dac_trend) >= 3L) {
  dac_model <- stats::lm(pct ~ year_int, data = dac_trend,
                         weights = dac_trend$n)
  base::message(sprintf(
    "  DAC trend through 2025: %.3f points/year, p = %.4f (n = %d years)",
    stats::coef(dac_model)[2],
    summary(dac_model)$coefficients[2, 4], nrow(dac_trend)))
}
