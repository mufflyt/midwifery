#!/usr/bin/env Rscript
# =============================================================================
# Case-library runner for run_midwifery_microsimulation.R
# =============================================================================
# Reads tests/microsimulation_case_library.tsv and, for each row, calls
# project_workforce() with that row's parameters and checks its declared
# invariants generically. See the TSV's own header for the schema.
#
# This is deliberately data-driven rather than one hand-written test per
# case: the point of a case library is that adding a hard case is adding a
# row, not writing and wiring up a new R function each time.
suppressPackageStartupMessages(library(readr))

root <- if (basename(getwd()) == "tests") ".." else "."
e <- new.env()
sys.source(file.path(root, "run_midwifery_microsimulation.R"), envir = e)

lib <- read_tsv(
  file.path(root, "tests", "microsimulation_case_library.tsv"),
  comment = "#", show_col_types = FALSE,
  col_types = cols(
    initial_workforce      = col_double(),
    annual_new_graduates   = col_double(),
    annual_retire_rate     = col_double(),
    annual_rural_drift     = col_double(),
    rural_baseline_pct     = col_double(),
    rural_grad_share       = col_double(),
    expect_error           = col_logical(),
    expected_nrow          = col_integer(),
    require_conservation   = col_logical(),
    require_nonnegative    = col_logical(),
    require_integer_counts = col_logical(),
    .default               = col_character()
  )
)

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

parse_years <- function(spec) {
  if (is.na(spec) || !nzchar(spec)) return(integer(0))
  if (grepl(":", spec, fixed = TRUE)) {
    parts <- as.integer(strsplit(spec, ":", fixed = TRUE)[[1]])
    return(parts[1]:parts[2])
  }
  as.integer(strsplit(spec, ",", fixed = TRUE)[[1]])
}

# Default parameter values, read off the function itself rather than
# duplicated as literals here -- if the defaults ever change, this stays
# correct without editing.
defaults <- formals(e$project_workforce)

stopifnot("case_id column must have no duplicates" = !anyDuplicated(lib$case_id))

for (i in seq_len(nrow(lib))) {
  row <- lib[i, ]
  cat(sprintf("\n-- %s [%s]: %s --\n", row$case_id, row$category, row$description))

  args <- list(
    initial_workforce = row$initial_workforce,
    years = parse_years(row$years_spec)
  )
  for (nm in c("annual_new_graduates", "annual_retire_rate", "annual_rural_drift",
               "rural_baseline_pct", "rural_grad_share")) {
    if (!is.na(row[[nm]])) args[[nm]] <- row[[nm]]
  }

  result <- tryCatch(do.call(e$project_workforce, args), error = function(err) err)
  errored <- inherits(result, "error")

  if (isTRUE(row$expect_error)) {
    chk(errored, sprintf("%s: project_workforce() raises an error", row$case_id))
    if (errored && !is.na(row$error_pattern)) {
      chk(grepl(row$error_pattern, conditionMessage(result)),
          sprintf("%s: error message matches /%s/ (got: %s)",
                  row$case_id, row$error_pattern, conditionMessage(result)))
    }
    next
  }

  chk(!errored,
      sprintf("%s: project_workforce() does not error (%s)",
              row$case_id, if (errored) conditionMessage(result) else "ok"))
  if (errored) next

  chk(is.data.frame(result), sprintf("%s: result is a data.frame", row$case_id))

  if (!is.na(row$expected_nrow)) {
    chk(nrow(result) == row$expected_nrow,
        sprintf("%s: nrow == %d (got %d)", row$case_id, row$expected_nrow, nrow(result)))
  }

  if (isTRUE(row$require_conservation) && nrow(result) > 0) {
    chk(all(result$Rural_Practicing_CNMs + result$Urban_Practicing_CNMs ==
              result$Total_Active_CNM_Workforce),
        sprintf("%s: Rural + Urban == Total for every row", row$case_id))
  }

  if (isTRUE(row$require_nonnegative) && nrow(result) > 0) {
    count_cols <- c("Total_Active_CNM_Workforce", "Rural_Practicing_CNMs",
                     "Urban_Practicing_CNMs", "New_Graduate_Inflow", "Retirement_Outflow")
    chk(all(sapply(result[count_cols], function(col) all(col >= 0))),
        sprintf("%s: no count column ever goes negative", row$case_id))
  }

  if (isTRUE(row$require_integer_counts) && nrow(result) > 0) {
    count_cols <- c("Total_Active_CNM_Workforce", "Rural_Practicing_CNMs",
                     "Urban_Practicing_CNMs")
    chk(all(sapply(result[count_cols], function(col) all(abs(col - round(col)) < 1e-9))),
        sprintf("%s: every headcount column is a whole number", row$case_id))
  }
}

cat(sprintf("\n%s (%d failures, %d cases)\n", if (fails == 0L) "PASS" else "FAIL",
            fails, nrow(lib)))
quit(status = if (fails == 0L) 0L else 1L)
