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

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
