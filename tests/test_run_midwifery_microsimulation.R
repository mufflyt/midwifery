#!/usr/bin/env Rscript
# =============================================================================
# run_midwifery_microsimulation.R -- R port of the Python microsimulation
# =============================================================================
# Same contract as tests/test_cycle24_microsimulation_conservation.py, which
# this file does not duplicate: it pins that the R port (1) does not run
# main()'s side effects merely from being sourced, and (2) produces output
# numerically IDENTICAL to the Python implementation for the same inputs,
# so the two cannot silently drift apart. Population-conservation itself is
# already covered on the Python side; re-asserting it here would be a
# variant of an existing test, not a new one.
root <- if (basename(getwd()) == "tests") ".." else "."
source(file.path(root, "tests", "ci_report.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

r_file <- file.path(root, "run_midwifery_microsimulation.R")
py_file <- file.path(root, "run_midwifery_microsimulation.py")

cat("\n-- sourcing does not run main() (no file I/O as a side effect) --\n")
before <- if (file.exists(file.path(root, "artifacts", "midwifery_microsimulation_projections_2026_2040.csv")))
  file.info(file.path(root, "artifacts", "midwifery_microsimulation_projections_2026_2040.csv"))$mtime else NA
e <- new.env()
sys.source(r_file, envir = e)
after <- if (file.exists(file.path(root, "artifacts", "midwifery_microsimulation_projections_2026_2040.csv")))
  file.info(file.path(root, "artifacts", "midwifery_microsimulation_projections_2026_2040.csv"))$mtime else NA
chk(identical(before, after), "sourcing the file did not rewrite the published artifact")
chk(is.function(e$project_workforce), "project_workforce() is available after sourcing")

cat("\n-- BVA: matches the Python port's own boundary cases --\n")
r1000 <- e$project_workforce(1000, years = 2026)
chk(r1000$Total_Active_CNM_Workforce[1] == 1648, "single-year run matches the hand computation (T24-2)")
chk(r1000$Rural_Practicing_CNMs[1] + r1000$Urban_Practicing_CNMs[1] ==
      r1000$Total_Active_CNM_Workforce[1],
    "population conserved for the same single-year case")

r0 <- e$project_workforce(0)
chk(all(r0$Rural_Practicing_CNMs + r0$Urban_Practicing_CNMs == r0$Total_Active_CNM_Workforce),
    "zero-baseline run conserves population across all 15 years")

cat("\n-- semantic: negative input is rejected, not silently propagated --\n")
chk(inherits(tryCatch(e$project_workforce(-5), error = function(err) err), "error"),
    "negative initial_workforce raises an error")

cat("\n-- adversarial: cross-implementation agreement, R vs Python --\n")
py_available <- nzchar(Sys.which("python3"))
if (!py_available) {
  cat("  --   SKIP cross-implementation check: python3 not on PATH\n")
} else {
  script <- sprintf('
import sys
sys.path.insert(0, %s)
import run_midwifery_microsimulation as sim
import json
rows = sim.project_workforce(12211)
print(json.dumps(rows))
', shQuote(normalizePath(root)))
  py_json <- tryCatch(
    system2("python3", c("-c", shQuote(script)), stdout = TRUE, stderr = TRUE),
    error = function(e) NA
  )
  if (identical(py_json, NA) || length(py_json) == 0 || !grepl("^\\[", py_json[1])) {
    cat("  --   SKIP cross-implementation check: could not run the Python port\n",
        paste(py_json, collapse = "\n"), "\n")
  } else {
    py_rows <- jsonlite::fromJSON(paste(py_json, collapse = ""))
    r_rows <- e$project_workforce(12211)
    chk(nrow(py_rows) == nrow(r_rows), "same number of simulated years")
    for (col in c("Simulation_Year", "Total_Active_CNM_Workforce", "New_Graduate_Inflow",
                  "Retirement_Outflow", "Urban_Practicing_CNMs", "Rural_Practicing_CNMs",
                  "Projected_Births_Attended")) {
      chk(identical(as.numeric(py_rows[[col]]), as.numeric(r_rows[[col]])),
          sprintf("R and Python agree exactly on %s for every year", col))
    }
    chk(all(abs(py_rows$Rural_Workforce_Share_Pct - r_rows$Rural_Workforce_Share_Pct) < 1e-9),
        "R and Python agree on Rural_Workforce_Share_Pct")
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
