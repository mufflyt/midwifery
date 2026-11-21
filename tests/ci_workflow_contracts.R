#!/usr/bin/env Rscript
# =============================================================================
# A job cannot run a tool it never installed
# =============================================================================
# PR #100 failed with exit 127 and `Rscript: command not found`. Nothing was
# wrong with the tests. Two steps invoking Rscript had been added to the
# "Python syntax and address keys" job, which runs actions/setup-python and
# provisions no R at all. The Python unittest in the same step passed -- "Ran
# 11 tests ... OK" -- one line before the shell could not find Rscript.
#
# The placement reads well and is wrong. The R port's cross-implementation
# check was put beside the Python test it agrees with, which is where it
# belongs conceptually. It belongs in the job that has an R toolchain.
# PROXIMITY IN THE FILE IS NOT A RUNTIME, and nothing in the repository could
# say so until a red run said it.
#
# This is the cheapest possible guard on that: for every job, if any step
# invokes a tool, the job must declare the action that installs it. It costs
# no packages and runs in under a second, and it would have caught #100 at
# authoring time instead of after a full CI round trip.
#
# WHY NOT PARSE THE YAML. Neither CI job has a YAML library -- not the R jobs,
# not the Python one -- and adding a parser dependency to the workflow in order
# to check that same workflow declares its dependencies is a circle. The
# structure being read here is four lines deep and completely regular, so it is
# scanned directly, and the scan ASSERTS WHAT IT FOUND: if it stops finding
# jobs, or stops finding any tool invocation at all, that is a failure rather
# than a silent pass. A checker that quietly matches nothing is worse than no
# checker, because it reports success.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))

WORKFLOWS <- list.files(file.path(root, ".github", "workflows"),
                        pattern = "[.]ya?ml$", full.names = TRUE)

# What must be installed before what may be run. The action pattern is matched
# against `uses:` lines anywhere in the job.
TOOLS <- list(
  list(label = "Rscript", cmd = "(^|[;&|[:space:]])Rscript([[:space:]]|$)",
       action = "setup-r", advice = "r-lib/actions/setup-r@v2"),
  list(label = "python",  cmd = "(^|[;&|[:space:]])python3?([[:space:]]|$)",
       action = "setup-python", advice = "actions/setup-python@v5")
)

# scan_jobs() lives in a helper because a SECOND gate needs the same
# decomposition: test_claim_integrity_saboteurs.R's R1-R3 read the package
# install lists out of these same job blocks. Two copies of a workflow reader
# drift, and ci_hygiene.R's H4 forbids a top-level function in two tracked
# files for exactly that reason.
source(file.path(root, "tests", "helper-workflow-scan.R"))

ci_section("W1 a job may not invoke a tool it never installed")

n_jobs <- 0L; n_invocations <- 0L; bad <- character(0)
for (wf in WORKFLOWS) {
  rel <- sub(paste0("^", root, "/"), "", wf)
  for (j in scan_jobs(wf)) {
    n_jobs <- n_jobs + 1L
    for (t in TOOLS) {
      hits <- grep(t$cmd, j$cmds, value = TRUE)
      if (!length(hits)) next
      n_invocations <- n_invocations + length(hits)
      if (!any(grepl(t$action, j$uses, fixed = TRUE)))
        bad <- c(bad, sprintf(
          "%s job '%s' runs %s on %d line(s) but never uses %s\n              first: %s",
          rel, j$name, t$label, length(hits), t$advice, trimws(hits[1])))
    }
  }
}

# NON-VACUITY. A scan that matched nothing would report success, which is the
# failure mode this repository has already been bitten by twice.
if (n_jobs < 4L)
  ci_fail("W1: found only %d job(s) across %d workflow file(s). The scanner has\n       stopped understanding the file structure, which is a failure, not a pass.",
          n_jobs, length(WORKFLOWS))
if (n_invocations == 0L)
  ci_fail("W1: found no tool invocation in any job. Either every job stopped\n       running anything, or the command scan is broken. Both are failures.")

if (length(bad)) {
  ci_fail("W1: %d job(s) invoke a tool they do not install:\n%s\n       Proximity in the file is not a runtime. Move the step to the job that\n       provisions the tool; do not add a second toolchain to make it work here.",
          length(bad), paste(sprintf("       - %s", bad), collapse = "\n"))
} else {
  ci_ok("%d job(s) across %d workflow(s); all %d tool invocation(s) are in a job that installs the tool",
        n_jobs, length(WORKFLOWS), n_invocations)
}

# --- POSITIVE CONTROL --------------------------------------------------------
# Proof the detector responds. A gate with only a negative result has shown it
# did not fire; it has not shown it could.
local({
  tmp <- tempfile(fileext = ".yml")
  on.exit(unlink(tmp), add = TRUE)
  writeLines(c("jobs:", "  a-job:", "    name: Pretend Python job",
               "    steps:", "      - uses: actions/setup-python@v5",
               "      - name: Run something",
               "        run: |",
               "          python3 -m unittest x",
               "          Rscript tests/whatever.R",
               "  b-job:", "    name: Fine job", "    steps:",
               "      - uses: r-lib/actions/setup-r@v2",
               "      - run: Rscript tests/ok.R"), tmp)
  js <- scan_jobs(tmp)
  fires <- vapply(js, function(j)
    length(grep(TOOLS[[1]]$cmd, j$cmds)) > 0 &&
      !any(grepl("setup-r", j$uses, fixed = TRUE)), logical(1))
  if (sum(fires) == 1L && identical(js[[1]]$name, "Pretend Python job"))
    ci_ok("POSITIVE CONTROL: the planted Rscript-without-setup-r is detected, and the healthy job beside it is not")
  else
    ci_fail("W1: the positive control did not behave -- %d job(s) flagged, expected exactly the first.",
            sum(fires))
})

ci_finish()
