#!/usr/bin/env Rscript
# =============================================================================
# Does the aggregate gate actually refuse?
# =============================================================================
# tests/ci_aggregate_gate.sh exists to say that a required component RAN and
# succeeded. A gate that says so only when everything is fine has proved it does
# not fire; it has not proved it could. So each way of not-passing is planted
# here and the gate must reject it BY KIND -- a cancelled dependency and a
# failed one are both refusals, but reporting one as the other sends whoever
# reads it to the wrong place.
#
# The last block is the one that matters most. Every scenario above it is a
# fixture, and a fixture proves the logic, not the wiring. The gate is only
# worth anything if its REQUIRED list actually names the jobs this repository
# runs, so the real ci.yml is parsed and compared against it. A job added
# without being required is the quiet way to lose coverage, and no synthetic
# JSON can catch it.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))

GATE <- file.path(root, "tests", "ci_aggregate_gate.sh")
CI   <- file.path(root, ".github", "workflows", "ci.yml")
stopifnot(file.exists(GATE), file.exists(CI))

REQ <- "r-checks python-checks r-unit-tests science-law-coverage"

#' Run the gate over a synthetic needs object
#' @keywords internal
#' @noRd
run_gate <- function(needs_json, required = REQ) {
  # Sys.setenv rather than system2(env=): that argument is pasted in front of
  # the command as `VAR=value cmd`, so a REQUIRED list with spaces in it -- which
  # is every real one -- is split by the shell and its second word is run as a
  # command. The first version of this file reported `sh: python-checks: command
  # not found` for all six scenarios.
  old <- Sys.getenv(c("NEEDS_JSON", "REQUIRED"), names = TRUE, unset = NA)
  Sys.setenv(NEEDS_JSON = needs_json, REQUIRED = required)
  on.exit({
    for (k in names(old)) if (is.na(old[[k]])) Sys.unsetenv(k) else
      do.call(Sys.setenv, setNames(list(old[[k]]), k))
  }, add = TRUE)
  out <- tempfile(); on.exit(unlink(out), add = TRUE)
  code <- suppressWarnings(system2("bash", c(GATE), stdout = out, stderr = out))
  list(code = code, text = paste(readLines(out, warn = FALSE), collapse = "\n"))
}

#' A needs object with every job successful, then whatever is overridden
#' @keywords internal
#' @noRd
needs_with <- function(...) {
  ov <- list(...)
  base <- list("r-checks" = "success", "python-checks" = "success",
               "r-unit-tests" = "success", "science-law-coverage" = "success")
  parts <- vapply(names(base), function(j) {
    res <- if (!is.null(ov[[j]])) ov[[j]] else base[[j]]
    # science-law-coverage is the one job that declares whether it did the work.
    exec <- if (identical(j, "science-law-coverage")) {
      e <- if (!is.null(ov[["..executed"]])) ov[["..executed"]] else "true"
      sprintf(',"outputs":{"executed":"%s"}', e)
    } else ""
    sprintf('"%s":{"result":"%s"%s}', j, res, exec)
  }, character(1))
  sprintf("{%s}", paste(parts, collapse = ","))
}

ci_section("the gate accepts a run in which everything ran and passed")
r <- run_gate(needs_with())
if (r$code == 0 && grepl("all 4 required component(s) ran and succeeded", r$text, fixed = TRUE)) {
  ci_ok("all-success passes")
} else {
  ci_fail("all-success did not pass (exit %d):\n%s", r$code, r$text)
}

ci_section("and refuses every way of not-passing, by kind")

cases <- list(
  list(lab = "one skipped dependency",   args = list("r-unit-tests" = "skipped"),
       kind = "NOT RUN", needle = "skipped by a conditional"),
  list(lab = "one cancelled dependency", args = list("python-checks" = "cancelled"),
       kind = "NOT RUN", needle = "cancelled"),
  list(lab = "one failed dependency",    args = list("r-checks" = "failure"),
       kind = "FAILED",  needle = "the job ran and failed"),
  # THE ONE THAT ACTUALLY HAPPENED. Exit zero, nothing evaluated.
  list(lab = "coverage exited zero having run no laws",
       args = list("..executed" = "false"),
       kind = "NOT RUN", needle = "exited zero but reported executed=false")
)
for (cs in cases) {
  r <- do.call(run_gate, list(do.call(needs_with, cs$args)))
  right_kind <- grepl(cs$kind, r$text, fixed = TRUE) && grepl(cs$needle, r$text, fixed = TRUE)
  if (r$code != 0 && right_kind) {
    ci_ok("%s -> refused as %s", cs$lab, cs$kind)
  } else {
    ci_fail("%s: expected a non-zero exit reported as %s (exit %d):\n%s",
            cs$lab, cs$kind, r$code, r$text)
  }
}

ci_section("a missing dependency is not a silent pass")
r <- run_gate('{"r-checks":{"result":"success"}}')
if (r$code != 0 && grepl("absent from the dependency graph", r$text, fixed = TRUE)) {
  ci_ok("three jobs absent from the graph -> refused as NOT RUN")
} else {
  ci_fail("a missing dependency did not refuse (exit %d):\n%s", r$code, r$text)
}

r <- run_gate(needs_with(), required = "")
if (r$code != 0) {
  ci_ok("an empty REQUIRED list refuses rather than passing vacuously")
} else {
  ci_fail("an empty REQUIRED list passed. A gate over nothing reported success.")
}

ci_section("and it is wired to the jobs this repository actually runs")
# THE FIXTURES ABOVE PROVE THE LOGIC, NOT THE WIRING. Parsed from the real file:
# every job in ci.yml except the gate itself must appear in both the needs: list
# and REQUIRED, or a job has been added that nothing requires.
ln <- readLines(CI, warn = FALSE)
jobs_at <- grep("^jobs:[[:space:]]*$", ln)[1]
all_jobs <- sub("^  ([A-Za-z0-9_-]+):.*$", "\\1",
                grep("^  [A-Za-z0-9_-]+:[[:space:]]*$", ln[seq(jobs_at, length(ln))], value = TRUE))
GATE_JOB <- "scientific-gate"
expected <- setdiff(all_jobs, GATE_JOB)

needs_line <- grep("^    needs:", ln, value = TRUE)
req_line   <- grep("^          REQUIRED:", ln, value = TRUE)
if (!length(needs_line) || !length(req_line)) {
  ci_fail("could not find the gate's needs: or REQUIRED: line in ci.yml.")
} else {
  declared_needs <- trimws(strsplit(gsub("[][]", "", sub("^    needs:", "", needs_line[1])), ",")[[1]])
  declared_req   <- trimws(strsplit(gsub('"', "", sub("^          REQUIRED:", "", req_line[1])), "[[:space:]]+")[[1]])
  declared_req   <- declared_req[nzchar(declared_req)]

  miss_n <- setdiff(expected, declared_needs); miss_r <- setdiff(expected, declared_req)
  extra  <- setdiff(union(declared_needs, declared_req), expected)
  if (length(expected) < 2)
    ci_fail("parsed only %d job(s) from ci.yml. The parse is broken, which is a failure, not a pass.",
            length(expected))
  if (length(miss_n))
    ci_fail("job(s) exist that the gate does not depend on: %s", paste(miss_n, collapse = ", "))
  if (length(miss_r))
    ci_fail("job(s) exist that REQUIRED does not name: %s", paste(miss_r, collapse = ", "))
  if (length(extra))
    ci_fail("the gate names job(s) that do not exist: %s", paste(extra, collapse = ", "))
  if (!length(miss_n) && !length(miss_r) && !length(extra)) {
    ci_ok("all %d job(s) in ci.yml are both depended on and required: %s",
          length(expected), paste(expected, collapse = ", "))
  }
}

# The gate must not be able to skip itself out of existence.
gate_at <- grep(sprintf("^  %s:[[:space:]]*$", GATE_JOB), ln)
if (!length(gate_at)) {
  ci_fail("the %s job is not in ci.yml at all.", GATE_JOB)
} else {
  blk <- ln[gate_at[1]:min(gate_at[1] + 12L, length(ln))]
  if (any(grepl("^    if:[[:space:]]*always\\(\\)", blk))) {
    ci_ok("the gate runs with if: always(), so a skipped dependency still reaches it")
  } else {
    ci_fail("the gate does not declare if: always(). A gate that is skipped when its\n       subject is skipped protects nothing.")
  }
}

ci_finish()
