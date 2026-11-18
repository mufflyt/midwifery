#!/usr/bin/env Rscript
# =============================================================================
# The appendix prose must be a rendering of the artifacts, not a memory of them
# =============================================================================
# THE DEFECT THESE TESTS EXIST FOR. make_state_source_audit_figures.R draws
# Figure 2 by parsing the Section 3 table out of the technical appendix, and
# computes the published DAC trend from whatever numbers it finds there. So
# when the audit was rebuilt on 2026-11-15 and the appendix was not, the
# figure went on reporting -0.228 points a year at p = 0.0014 from a table
# three vintages old, while artifacts/state_source_audit_agreement.csv said
# -0.248 at p = 0.0002. Nothing failed; the figure simply told a reader
# something the data no longer supported.
#
# A table a human maintains by hand next to a CSV a script maintains will
# diverge. This test makes the divergence loud.
#
# Refresh with: Rscript refresh_state_source_appendix_section3.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

APPENDIX <- "docs/TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md"
AGREEMENT <- "artifacts/state_source_audit_agreement.csv"

if (!file.exists(AGREEMENT)) {
  cat("  skip -- artifacts/state_source_audit_agreement.csv absent from this checkout\n")
  cat("\nPASS (0 failures)\n"); quit(status = 0L)
}

# Parse the table exactly as the figure producer does, so this test sees what
# the figure sees rather than a second interpretation of the same markdown.
appendix_lines <- readLines(APPENDIX, warn = FALSE)
header_index <- which(grepl("^\\|\\s*Source\\s*\\|\\s*Period\\s*\\|\\s*Basis\\s*\\|",
                            appendix_lines))
chk(length(header_index) == 1L,
    sprintf("A1 exactly one Section 3 agreement table [%d]",
            length(header_index)))

row_index <- header_index + 2L
table_rows <- character(0)
while (row_index <= length(appendix_lines) &&
       grepl("^\\s*\\|", appendix_lines[row_index])) {
  table_rows <- c(table_rows, appendix_lines[row_index])
  row_index <- row_index + 1L
}

cells_of <- function(one_row) {
  trimws(strsplit(sub("\\|\\s*$", "", sub("^\\s*\\|", "", one_row)), "|",
                  fixed = TRUE)[[1]])
}
numeric_of <- function(x) as.numeric(gsub("[^0-9.]", "", x))

parsed <- dplyr::bind_rows(lapply(table_rows, function(one_row) {
  parts <- cells_of(one_row)
  if (length(parts) != 5L) return(NULL)
  tibble::tibble(display = parts[1], period = parts[2], basis = parts[3],
                 n_comparable = numeric_of(parts[4]),
                 pct_agree = numeric_of(parts[5]))
}))

agreement <- read_csv(AGREEMENT, col_types = cols(.default = "c"),
                      progress = FALSE) %>%
  mutate(n_comparable = as.numeric(.data$n_comparable),
         pct_agree = as.numeric(.data$pct_agree))

chk(nrow(parsed) == nrow(agreement),
    sprintf("A2 the appendix table has one row per artifact row [%d vs %d]",
            nrow(parsed), nrow(agreement)))

# Compare on the measured values, which carry no display-name question.
appendix_key <- sort(sprintf("%s|%s|%.1f|%.0f", parsed$period, parsed$basis,
                             parsed$pct_agree, parsed$n_comparable))
artifact_key <- sort(sprintf("%s|%s|%.1f|%.0f", agreement$year,
                             agreement$comparison_basis, agreement$pct_agree,
                             agreement$n_comparable))
chk(identical(appendix_key, artifact_key),
    "A3 every period, basis, n and percentage matches the artifact")
if (!identical(appendix_key, artifact_key)) {
  cat("       in the appendix only: ",
      paste(utils::head(setdiff(appendix_key, artifact_key), 4),
            collapse = " ; "), "\n")
  cat("       in the artifact only: ",
      paste(utils::head(setdiff(artifact_key, appendix_key), 4),
            collapse = " ; "), "\n")
}

# THE NUMBER THE FIGURE ACTUALLY PUBLISHES. Figure 2's subtitle states the
# DAC slope and p-value, both computed from this table, so the test pins the
# fit rather than only the cells it is fitted to.
dac_fit_from <- function(frame, year_column, pct_column, n_column) {
  usable <- frame[!is.na(frame[[year_column]]) &
                    frame[[year_column]] <= 2025, , drop = FALSE]
  model <- stats::lm(usable[[pct_column]] ~ usable[[year_column]],
                     weights = usable[[n_column]])
  c(slope = unname(stats::coef(model)[2]),
    p = summary(model)$coefficients[2, 4])
}

appendix_dac <- parsed %>%
  filter(grepl("^DAC", .data$display)) %>%
  mutate(year = suppressWarnings(as.integer(.data$period))) %>%
  filter(!is.na(.data$year)) %>% as.data.frame()
artifact_dac <- agreement %>%
  filter(.data$source == "dac_physician_compare") %>%
  mutate(year = suppressWarnings(as.integer(.data$year))) %>%
  filter(!is.na(.data$year)) %>% as.data.frame()

if (nrow(appendix_dac) >= 3L && nrow(artifact_dac) >= 3L) {
  from_appendix <- dac_fit_from(appendix_dac, "year", "pct_agree",
                                "n_comparable")
  from_artifact <- dac_fit_from(artifact_dac, "year", "pct_agree",
                                "n_comparable")
  chk(abs(from_appendix[["slope"]] - from_artifact[["slope"]]) < 0.0005,
      sprintf("A4 the DAC slope the figure draws matches the data [%.3f vs %.3f]",
              from_appendix[["slope"]], from_artifact[["slope"]]))
  chk(abs(from_appendix[["p"]] - from_artifact[["p"]]) < 1e-6,
      sprintf("A4b and so does its p-value [%.4g vs %.4g]",
              from_appendix[["p"]], from_artifact[["p"]]))
} else {
  chk(FALSE, "A4 DAC has too few appendix rows to fit a trend")
}

# SECTION 2 WAS NEVER GUARDED, AND HAD DRIFTED. A1-A4 above pin the Section 3
# agreement table, which refresh_state_source_appendix_section3.R regenerates.
# Nothing watched Section 2, whose Open Payments row carries two ranges in
# prose -- and both were still the pre-rebuild numbers: "2,391-4,382 NPIs/year"
# against an artifact saying 2,370-4,324, and "1-29 rows/year" when 2017 holds
# 0. The same class of defect as Figure 2 drawing its trend from stale prose,
# one section up. These two checks make the prose a rendering of the artifacts.
COVERAGE <- "artifacts/state_source_audit_coverage.csv"
COVERAGE_AUDIT <- "artifacts/open_payments_annual_coverage_audit.csv"

# Found through the Section 2 header, not by matching "Open Payments" across
# the file: Section 3 opens five rows with the same source name.
section2_header <- which(grepl("^\\|\\s*Source\\s*\\|\\s*Years covered\\s*\\|",
                               appendix_lines))
chk(length(section2_header) == 1L,
    sprintf("A5 exactly one Section 2 coverage table [%d]",
            length(section2_header)))

section2_rows <- character(0)
if (length(section2_header) == 1L) {
  cursor <- section2_header + 2L
  while (cursor <= length(appendix_lines) &&
         grepl("^\\s*\\|", appendix_lines[cursor])) {
    section2_rows <- c(section2_rows, appendix_lines[cursor])
    cursor <- cursor + 1L
  }
}
section2_row <- grep("^\\|\\s*Open Payments\\s*\\|", section2_rows, value = TRUE)
chk(length(section2_row) == 1L,
    sprintf("A5b exactly one Open Payments row inside it [%d]",
            length(section2_row)))

range_in <- function(text, unit) {
  hit <- regmatches(text, regexpr(
    sprintf("\\(([0-9,]+)-([0-9,]+) %s/year\\)", unit), text))
  if (!length(hit) || !nzchar(hit)) return(c(NA_integer_, NA_integer_))
  as.integer(gsub(",", "", regmatches(hit, gregexpr("[0-9,]+", hit))[[1]]))
}

if (length(section2_row) == 1L && file.exists(COVERAGE)) {
  coverage <- read_csv(COVERAGE, col_types = cols(.default = "c"),
                       progress = FALSE) %>%
    filter(.data$source == "open_payments") %>%
    mutate(year = as.integer(.data$year), n_npis = as.integer(.data$n_npis)) %>%
    filter(.data$year >= 2021L)
  stated <- range_in(section2_row, "NPIs")
  actual <- c(min(coverage$n_npis), max(coverage$n_npis))
  chk(identical(stated, actual),
      sprintf("A5c the stated 2021-2025 NPI range matches the artifact [%s vs %s]",
              paste(stated, collapse = "-"), paste(actual, collapse = "-")))
} else if (!file.exists(COVERAGE)) {
  cat("  skip A5c -- artifacts/state_source_audit_coverage.csv absent\n")
}

if (length(section2_row) == 1L && file.exists(COVERAGE_AUDIT)) {
  ineligible <- read_csv(COVERAGE_AUDIT, col_types = cols(.default = "c"),
                         progress = FALSE) %>%
    mutate(program_year = as.integer(.data$program_year),
           source_record_count = as.integer(.data$source_record_count)) %>%
    filter(.data$program_year >= 2015L, .data$program_year <= 2020L,
           !is.na(.data$source_record_count))
  stated <- range_in(section2_row, "rows")
  actual <- c(min(ineligible$source_record_count),
              max(ineligible$source_record_count))
  chk(identical(stated, actual),
      sprintf("A6 the stated 2015-2020 row range matches the audit [%s vs %s]",
              paste(stated, collapse = "-"), paste(actual, collapse = "-")))
} else if (!file.exists(COVERAGE_AUDIT)) {
  cat("  skip A6 -- artifacts/open_payments_annual_coverage_audit.csv absent\n")
}

# THE FIGURE THAT SHIPPED WITH ITS CAPTION CUT OFF. A1-A6 pin the appendix's
# numbers; this pins the figures' words. base_size went 11 -> 13 on 2026-11-15
# and only two of the six figures were regenerated, so four kept their old
# rendering -- and the two that were regenerated included
# state_source_agreement_by_year, whose right-aligned caption overflowed and
# was published starting mid-sentence at "of TECHNICAL_APPENDIX_...". ggsave
# draws text that does not fit and returns successfully, so nothing failed.
# fit_plot_labels() measures each label at the size its own theme will draw it
# and wraps until it fits. Tested on the function rather than on a rendered
# file: the figures need gitignored artifacts to build, and a test that skips
# whenever the data are absent guards nothing.
FIGURE_SCRIPT <- "make_state_source_audit_figures.R"
{
  # The script has no sys.nframe() guard, so lift out the one definition
  # instead of sourcing it and running the whole pipeline.
  top_level <- as.list(parse(FIGURE_SCRIPT))
  defines <- function(name) {
    function(e) is.call(e) && identical(as.character(e[[1]]), "<-") &&
      length(e) == 3L && identical(as.character(e[[2]]), name)
  }
  found <- Filter(defines("fit_plot_labels"), top_level)
  chk(length(found) == 1L,
      sprintf("F1 %s defines fit_plot_labels() exactly once [%d]",
              FIGURE_SCRIPT, length(found)))

  save_body <- Filter(defines("save_audit_fig"), top_level)
  chk(length(save_body) == 1L &&
        grepl("fit_plot_labels", paste(deparse(save_body[[1]]), collapse = " ")),
      "F2 save_audit_fig() routes every figure through it")

  if (length(found) == 1L) {
    suppressPackageStartupMessages(library(ggplot2))
    eval(found[[1]], envir = environment())

    canvas_in <- 8.5
    base_plot <- function(title) {
      ggplot(data.frame(x = 1:3, y = 1:3), aes(x, y)) + geom_point() +
        labs(title = title) + theme_minimal(base_size = 13)
    }
    measure <- function(p, part) {
      size <- ggplot2::calc_element(paste0("plot.", part),
                                    ggplot2::complete_theme(p$theme))$size
      max(systemfonts::string_width(
        strsplit(p$labels[[part]], "\n", fixed = TRUE)[[1]], size = size))
    }

    short <- "Short enough"
    fitted_short <- fit_plot_labels(base_plot(short), canvas_in)
    chk(identical(fitted_short$labels$title, short),
        "F3 a label that already fits is left alone")

    # The exact title that shipped truncated to "...disagree abou".
    long <- "Midwives licensed in several states are the ones the sources disagree about"
    fitted_long <- fit_plot_labels(base_plot(long), canvas_in)
    chk(measure(fitted_long, "title") <= canvas_in * 72,
        sprintf("F4 the title that was cut off now fits [%.0fpt of %.0fpt]",
                measure(fitted_long, "title"), canvas_in * 72))
    chk(identical(gsub("[[:space:]]+", " ", fitted_long$labels$title), long),
        "F4b and wrapping it changed no word")

    runaway <- paste(rep("Enumeration System and Ownership System", 12),
                     collapse = " ")
    fitted_runaway <- fit_plot_labels(base_plot(runaway), canvas_in)
    chk(measure(fitted_runaway, "title") <= canvas_in * 72,
        "F5 a label twelve times too wide is wrapped, not truncated")
    chk(identical(gsub("[[:space:]]+", " ", fitted_runaway$labels$title), runaway),
        "F5b and it keeps every word")
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
