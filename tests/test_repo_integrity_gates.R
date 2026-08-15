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

# 5. a downloaded source file with no accessed_utc / source_url
dir.create(file.path(tmp, "data"), recursive = TRUE, showWarnings = FALSE)
writeLines("a,b\n1,2", file.path(tmp, "data", "downloaded.csv"))
report("downloaded file without accessed_utc is detected",
       nrow(repo_gate_check_access_dates(tmp)) > 0)

# 5b. accepted once it carries BOTH fields
writeLines(
  '{"source_url":"https://example.org/x.csv","accessed_utc":"2026-08-14T16:18:00Z"}',
  file.path(tmp, "data", "downloaded.csv.provenance.json")
)
report("downloaded file WITH accessed_utc + source_url is accepted",
       nrow(repo_gate_check_access_dates(tmp)) == 0)

# 5c. a date alone is not enough -- without source_url you cannot tell what was
#     fetched, only when
writeLines('{"accessed_utc":"2026-08-14T16:18:00Z"}',
           file.path(tmp, "data", "downloaded.csv.provenance.json"))
report("accessed_utc without source_url is still detected",
       nrow(repo_gate_check_access_dates(tmp)) > 0)
unlink(file.path(tmp, "data", "downloaded.csv"))
unlink(file.path(tmp, "data", "downloaded.csv.provenance.json"))

# 5d. THE RULE THE RE-SCOPE RESTS ON. A file WE built carries inputs+sha256 and
#     has no download date; demanding one is a category error. data/county_base.csv
#     is exactly this -- it lives under data/ but R/01-build-county-base.R makes it.
writeLines("a,b\n1,2", file.path(tmp, "data", "derived.csv"))
writeLines(
  '{"artifact":"derived.csv","written_utc":"2026-08-14 00:00:00 UTC","inputs":[{"path":"data/x.csv","sha256":"deadbeef"}]}',
  file.path(tmp, "data", "derived.csv.provenance.json")
)
report("a DERIVED file (inputs sidecar) is exempt from the download date",
       nrow(repo_gate_check_access_dates(tmp)) == 0)

# 5e. a .json payload is not a sidecar for itself
writeLines('[{"x":1}]', file.path(tmp, "data", "api_response.json"))
report("a .json payload is checked, not mistaken for its own sidecar",
       nrow(repo_gate_check_access_dates(tmp)) > 0)
unlink(file.path(tmp, "data", "api_response.json"))
unlink(file.path(tmp, "data", "derived.csv"))
unlink(file.path(tmp, "data", "derived.csv.provenance.json"))

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
report("a real NPI in commit metadata is detected",
       nrow(repo_gate_scan_identifiers(tmp)) > 0)

# A SHA-256 prefix is not an NPI. This repository's commit messages are full of
# hashes, and the naive "any ten digits" rule flagged 9455138198 -- the first
# ten digits of 9455138198e4d347 -- in a commit that was discussing artifact
# hashes. A gate that cries wolf on hashes here would be switched off in a week.
writeLines('{"head_commit":{"message":"geography artifact 9455138198e4d347 unchanged"}}', ev)
report("a SHA-256 prefix is NOT reported as an NPI",
       nrow(repo_gate_scan_identifiers(tmp)) == 0)

# Ten digits alone are not enough: a real NPI satisfies Luhn over 80840 + its
# first nine digits, and an arbitrary run does so about one time in ten.
writeLines('{"head_commit":{"message":"see record 1234567890 for details"}}', ev)
report("a 10-digit run failing the check digit is not reported",
       nrow(repo_gate_scan_identifiers(tmp)) == 0)
Sys.unsetenv("GITHUB_EVENT_PATH")

unlink(tmp, recursive = TRUE)

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
