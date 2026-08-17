# =============================================================================
# Does ci_science_contracts.R actually detect anything?
# =============================================================================
# A gate with an inverted condition, an over-broad allowance or a regex that
# matches nothing passes exactly like a clean repository, and nobody watches a
# green checker. This plants one defect per gate in a scratch copy of the repo
# and asserts each is caught.
#
# It also asserts the converse for the two gates that produced false positives
# on their first run: a NEAR-MISS -- text that resembles a violation but is not
# one -- must NOT fail. Those were `resolution_method = first(resolution_method)`
# carrying a label through a group, and `fl_voter_path <- ...` matching "vote"
# inside "voter". Both are pinned here so the precision cannot regress.
#
# Runs the real gate script in a temporary git repository, so it exercises
# ci_tracked() -- which shells out to `git ls-files` -- rather than a stub.
# Base R only.
# =============================================================================

root <- normalizePath(".")
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git"))
  root <- normalizePath("..")

GATE <- file.path(root, "tests", "ci_science_contracts.R")
REPORT <- file.path(root, "tests", "ci_report.R")
stopifnot(file.exists(GATE), file.exists(REPORT))

failures <- character(0)
chk <- function(ok, msg) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else failures <<- c(failures, msg)
}

# Build a minimal repo that PASSES the gate, then perturb one file per case.
# Minimal on purpose: a copy of the real repo would carry the three baselined
# SCI2 sites and every planted defect would be indistinguishable from them.
scaffold <- function(dir) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "R", "lib"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "artifacts"), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE, file.path(dir, "tests", "ci_science_contracts.R"))
  file.copy(REPORT, file.path(dir, "tests", "ci_report.R"))

  # The delegating wrapper SCI5 requires, reduced to the two lines it checks.
  writeLines(c("norm_addr_canonical <- function(x) {",
               "  e$normalize_addresses_canonical(x)",
               "}"),
             file.path(dir, "R", "lib", "address_parser_canonical.R"))

  # A clean analysis script.
  writeLines(c("suppressPackageStartupMessages(library(dplyr))",
               "organization_affiliation <- pairs %>% filter(n_orgs == 1L)"),
             file.path(dir, "clean_analysis.R"))

  # The coverage matrix SCI3b reads.
  writeLines(c("npi,pecos_reassignment,any_strong_arm",
               "1234567893,1,TRUE"),
             file.path(dir, "artifacts", "affiliation_coverage_matrix.csv"))

  # git init + add, because ci_tracked() asks git, not the filesystem.
  system2("git", c("-C", shQuote(dir), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
}

# Returns TRUE when the gate FAILED (exit status non-zero).
#
# The `cd` is load-bearing and was missing in the first version of this file.
# The gate resolves its own root as `getwd()`, and `system2("Rscript", <path>)`
# leaves the working directory at the CALLER's -- so every case ran the gate
# against the real repository instead of the scaffold, all seven planted
# defects went undetected, and the four near-miss cases passed vacuously.
# Invoke through a shell that changes directory first.
gate_fails <- function(dir) {
  st <- suppressWarnings(system2(
    "sh", c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_science_contracts.R",
                                  shQuote(dir)))),
    stdout = NULL, stderr = NULL))
  !identical(as.integer(st), 0L)
}

# Writes `lines` to `rel` in a fresh scaffold, re-adds to git, runs the gate.
with_planted <- function(rel, lines) {
  dir <- file.path(tempdir(), paste0("sci_", as.integer(runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scaffold(dir)
  target <- file.path(dir, rel)
  dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, target)
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
  gate_fails(dir)
}

cat("\n-- the scaffold itself is clean --\n")
{
  dir <- file.path(tempdir(), "sci_clean")
  unlink(dir, recursive = TRUE); dir.create(dir, recursive = TRUE)
  scaffold(dir)
  chk(!gate_fails(dir),
      "a clean repository passes (otherwise every case below is vacuous)")
  unlink(dir, recursive = TRUE)
}

cat("\n-- planted defects, one per gate --\n")

chk(with_planted("bad_employer.R",
                 "employer <- org_name[match(npi, roster$npi)]"),
    "SCI1 detects an affiliation assigned to a variable named `employer`")

chk(with_planted("bad_pick.R",
                 c("person <- long %>% arrange(npi, rank) %>% group_by(npi) %>%",
                   "  summarise(organization_name = first(organization_name))")),
    "SCI2 detects an organization chosen with first() from several")

chk(with_planted("bad_absence.R",
                 c("# dac facility affiliation",
                   "x <- dac %>% mutate(billed = case_when(is.na(ccn) ~ \"No\", TRUE ~ \"Yes\"))")),
    "SCI3 detects a partial-coverage source coded absence-as-negative")

chk(with_planted("experiment_planted_cut.R",
                 c("threshold <- 5",
                   "hits <- cand %>% filter(n_clin > 5)")),
    "SCI4 detects an experiment with a numeric cut and no exploratory flag")

chk(with_planted("R/lib/address_parser_canonical.R",
                 c("norm <- function(x) {",
                   "  x <- gsub(\"AVENUE\", \"AVE\", x)",
                   "  gsub(\"BOULEVARD\", \"BLVD\", x)",
                   "}")),
    "SCI5 detects a street-suffix table inside the delegating wrapper")

chk(with_planted("bad_second_parser.R",
                 "normalize_address_local <- function(x) toupper(x)"),
    "SCI5b detects a second address normaliser defined elsewhere")

# The source must be named in CODE, not in a comment: code_lines() strips
# comments, so an earlier version of this plant mentioned healthgrades only in
# a `#` line and SCI6's source-guard never engaged.
chk(with_planted("bad_pool.R",
                 c("src <- bind_rows(healthgrades, doximity, open_payments)",
                   "consensus <- sum(src$agree_flags) >= 2")),
    "SCI6 detects a majority vote pooled across external sources")

cat("\n-- near misses that must NOT fail --\n")
# Both of these DID fail on the gate's first run. They are the precision half:
# without them, tightening a regex to silence a false positive can silently
# widen it back later and nothing notices.

chk(!with_planted("ok_label_carry.R",
                  c("person <- long %>% group_by(npi) %>%",
                    "  summarise(resolution_method = first(resolution_method))")),
    "SCI2 does NOT flag a method LABEL carried through a group")

chk(!with_planted("ok_voter_file.R",
                  c("# healthgrades",
                    "fl_voter_path <- \"artifacts/florida_voter_license_ages.csv\"")),
    "SCI6 does NOT flag `voter` as a vote")

chk(!with_planted("ok_prose.R",
                  c("#' This does not compute an employer. Never label it employer.",
                    "#' A consensus <- across sources would be wrong here.",
                    "x <- 1")),
    "the gates do NOT flag the rules NAMED in comments and roxygen")

chk(!with_planted("experiment_exact_keys.R",
                  c("hits <- ep %>% filter(!is.na(affil_name))",
                    "res <- hits %>% count(npi)")),
    "SCI4 does NOT demand an exploratory flag from an experiment with no cut")

cat("\n")
if (length(failures)) {
  for (f in failures) cat(sprintf("FAIL %s\n", f))
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
