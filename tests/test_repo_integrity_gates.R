#!/usr/bin/env Rscript
# =============================================================================
# The gates must FAIL on a planted defect
# =============================================================================
# tests/ci_repo_integrity.R passing tells you the repository is clean. It does
# NOT tell you the gates work -- a checker with an inverted condition, an
# over-broad allowance or a typo'd regex passes exactly the same way, and reads
# as coverage while asserting nothing. That failure mode is why
# test_healthgrades_integrity.R is excluded from CI, and it applies to gates
# more than to tests, because nobody watches a green checker.
#
# So: one planted defect per gate, each asserted to be detected. The forbidden
# strings are assembled at runtime rather than written literally, so this file
# does not trip the very gate it is testing.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "ci_repo_integrity_gates.R"))

fails <- 0L
report <- function(label, fired) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(fired)) "ok" else "FAIL", label))
  if (!isTRUE(fired)) fails <<- fails + 1L
}

TMP_LITERAL <- paste0("/", "tmp", "/planted.rds")

tmp <- file.path(tempdir(), "gatetest")
unlink(tmp, recursive = TRUE)
dir.create(file.path(tmp, "R"), recursive = TRUE)
dir.create(file.path(tmp, "tests"), recursive = TRUE)
dir.create(file.path(tmp, "artifacts"), recursive = TRUE)

# 1. absolute path
writeLines(paste0('x <- readRDS("', TMP_LITERAL, '")'),
           file.path(tmp, "R", "bad.R"))
report("absolute path /tmp is detected",
       nrow(repo_gate_find_absolute_paths(tmp)) > 0)

# 2. package reachable only through source(file.path(root, ...)) -- the
#    checkmate shape that a grep of the test file cannot see
writeLines(c('source(file.path(root, "R", "dep.R"))'),
           file.path(tmp, "tests", "test_x.R"))
writeLines('if (!requireNamespace("checkmate", quietly = TRUE)) stop("nope")',
           file.path(tmp, "R", "dep.R"))
miss <- repo_gate_check_packages(
  file.path("tests", "test_x.R"), c("dplyr"), tmp
)
report("package behind source(file.path(root, ...)) is detected",
       "checkmate" %in% miss$package)

# 3. vacuous suite
writeLines(c("# no assertions here", "cat('PASS\\n')"),
           file.path(tmp, "tests", "test_vacuous.R"))
report("suite with zero assertions is detected",
       nrow(repo_gate_check_vacuous_tests(
         file.path("tests", "test_vacuous.R"), tmp)) > 0)

# 4. missing input
writeLines('d <- read.csv("data/gone.csv")', file.path(tmp, "R", "reads.R"))
report("input that does not exist is detected",
       nrow(repo_gate_check_missing_inputs(tmp)) > 0)

# 5. artifact without accessed_utc
writeLines("a,b\n1,2", file.path(tmp, "artifacts", "new.csv"))
report("artifact without accessed_utc is detected",
       nrow(repo_gate_check_access_dates(tmp)) > 0)

# 5b. and accepts one WITH a valid accessed_utc
writeLines(
  '{"source_url":"https://x","accessed_utc":"2026-08-14T16:18:00Z"}',
  file.path(tmp, "artifacts", "new.csv.provenance.json")
)
report("artifact WITH accessed_utc is accepted",
       nrow(repo_gate_check_access_dates(tmp)) == 0)

# 6. safe_percent(default = 0)
writeLines(paste0("v <- ", "safe_percent(part, total, default = 0)"),
           file.path(tmp, "R", "pct.R"))
report("safe_percent(default = 0) is detected",
       nrow(repo_gate_scan_percent_zero_default(tmp)) > 0)

# 7. vendored drift, byte-for-byte
writeLines("f <- function() 1", file.path(tmp, "R", "canon.R"))
writeLines("f <- function() 1 # one comment", file.path(tmp, "R", "vend.R"))
d <- repo_gate_compare_vendored_files("R/canon.R", "R/vend.R", tmp)
report("a one-comment difference in a vendored copy is detected", !d$identical)

# 8. NPI in commit metadata
ev <- file.path(tmp, "event.json")
writeLines('{"head_commit":{"message":"spotlight CNM Jane Doe NPI 1306048970"}}', ev)
Sys.setenv(GITHUB_EVENT_PATH = ev)
report("10-digit NPI in commit metadata is detected",
       nrow(repo_gate_scan_identifiers(tmp)) > 0)
Sys.unsetenv("GITHUB_EVENT_PATH")

unlink(tmp, recursive = TRUE)

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
