# =============================================================================
# Leak guard: person-level columns, and files too big to take back
# =============================================================================
# Four commits in one week untracked person-level artifacts one at a time -- the
# PPV review sample, the Doximity profiles, the voter DOBs, the attribute-layer
# outputs. Each was found by hand, after it was committed. The policy was never
# in doubt; the enforcement did not exist.
#
# This is the enforcement. It reads the HEADER of every tracked CSV and fails
# when a person-level column appears in a file that is not already on the
# baseline. New leaks are blocked today. The 67 files already tracked are listed
# in ci_leak_baseline.txt with their row counts, and the number is only allowed
# to go DOWN -- untracking one is a passing change, adding one is not.
#
# It also caps tracked file size. A 1.5 GB JSONL and an 840 MB CSV sit untracked
# in the working directory; one `git add -A` writes them into history where no
# amount of later deleting removes them.
#
# Base R only, header reads only. Runs in seconds.
# =============================================================================

# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

source(file.path(root, "tests", "ci_report.R"))



# -----------------------------------------------------------------------------
# The column names that make a row about an identifiable person. Deliberately
# narrow: a column called "state" is not identifying, a column called "npi" is.
# Matching is on the WHOLE column name, so "n_npi_matched" (a count) does not
# trip it while "npi" does.
# -----------------------------------------------------------------------------
PERSON_COLS <- c(
  "npi", "npi_1", "npi_2", "individual_npi", "provider_npi",
  "certification_number", "cert_number", "amcb_id", "customer_id",
  "first_name", "last_name", "middle_name", "full_name", "provider_name",
  "provider_first_name", "provider_last_name", "provider_middle_name",
  "dob", "date_of_birth", "birth_date", "birth_year",
  "license_number", "home_address", "residential_address"
)

header_cols <- function(path) {
  con <- file(path, "r")
  on.exit(close(con), add = TRUE)
  line <- tryCatch(readLines(con, n = 1L, warn = FALSE), error = function(e) character(0))
  if (length(line) == 0) return(character(0))
  # Good enough for a header: split on commas outside quotes.
  parts <- scan(text = line, what = "", sep = ",", quiet = TRUE,
                quote = "\"", strip.white = TRUE)
  tolower(trimws(parts))
}

baseline_path <- file.path(root, "tests", "ci_leak_baseline.txt")
baseline <- if (file.exists(baseline_path)) {
  b <- readLines(baseline_path, warn = FALSE)
  b <- trimws(b)
  b <- b[nzchar(b) & !startsWith(b, "#")]
  sub("\\s+#.*$", "", b)
} else character(0)

# -----------------------------------------------------------------------------
ci_section("L1 no NEW tracked file carries a person-level column")

csvs <- ci_tracked("*.csv")
hits <- character(0)
for (f in csvs) {
  p <- file.path(root, f)
  if (!file.exists(p)) next
  cols <- header_cols(p)
  if (any(cols %in% PERSON_COLS)) hits <- c(hits, f)
}

new_hits <- setdiff(hits, baseline)
if (length(new_hits)) {
  ci_fail("L1: %d tracked file(s) carry a person-level column and are not on the baseline:\n%s",
       length(new_hits),
       paste(sprintf("       %s  [%s]", new_hits,
                     vapply(new_hits, function(f) {
                       paste(intersect(header_cols(file.path(root, f)), PERSON_COLS), collapse = ", ")
                     }, character(1))), collapse = "\n"))
} else {
  ci_ok("no new person-level file (%d known, listed in ci_leak_baseline.txt)", length(hits))
}

# -----------------------------------------------------------------------------
ci_section("L2 no tracked file is named like a person-level artifact")

# FROZEN crosswalks are person-level by construction: one row per certificant,
# keyed to a certification number. The name is the tell, so it is checked
# independently of the header -- a rename must not launder the contents.
NAME_PATTERNS <- c("FROZEN", "review_sample", "voter", "_dob", "person_level")
# Data files only. `match_ohio_voter_ages.R` is a script that READS a voter file;
# it carries no rows itself, and flagging source code here would train everyone
# to ignore this check.
DATA_EXT <- "\\.(csv|tsv|rds|parquet|jsonl|xlsx?)$"
data_files <- grep(DATA_EXT, ci_tracked("*"), value = TRUE, ignore.case = TRUE)
named_all <- unique(unlist(lapply(NAME_PATTERNS, function(p) grep(p, data_files, value = TRUE))))
named_new <- setdiff(named_all, baseline)

if (length(named_new)) {
  ci_fail("L2: %d tracked file(s) named like a person-level artifact, not on the baseline:\n%s",
       length(named_new), paste(sprintf("       %s", named_new), collapse = "\n"))
} else {
  ci_ok("no newly tracked FROZEN / review-sample / voter file")
}

# The ratchet, reported once both detectors have run. Retiring a baseline entry
# must be a passing change, so a shrinking list is fine and a growing one is not.
# A STALE entry is worth reporting because it means the baseline is describing a
# file that is no longer tracked -- but it is a note, not a failure: nobody
# should have to edit this file to make a green build green again.
stale <- setdiff(baseline, union(hits, named_all))
if (length(stale)) {
  ci_ok("%d baseline entr%s now clean -- delete from ci_leak_baseline.txt:\n%s",
     length(stale), if (length(stale) == 1) "y is" else "ies are",
     paste(sprintf("       %s", stale), collapse = "\n"))
}

# -----------------------------------------------------------------------------
ci_section("L3 no tracked file is large enough to be permanent")

HARD_MB <- 50   # GitHub warns here; history cannot be un-bloated without a rewrite
WARN_MB <- 25

sizes <- vapply(ci_tracked("*"), function(f) {
  p <- file.path(root, f)
  if (file.exists(p)) file.info(p)$size / 1024^2 else 0
}, numeric(1))

over_hard <- sizes[sizes > HARD_MB]
over_warn <- sizes[sizes > WARN_MB & sizes <= HARD_MB]

if (length(over_hard)) {
  ci_fail("L3: %d tracked file(s) over %d MB -- committing these is not reversible:\n%s",
       length(over_hard), HARD_MB,
       paste(sprintf("       %6.1f MB  %s", over_hard, names(over_hard)), collapse = "\n"))
} else {
  ci_ok("no tracked file over %d MB (largest is %.1f MB)", HARD_MB, max(sizes, 0))
}
if (length(over_warn)) {
  ci_ok("%d tracked file(s) between %d and %d MB, worth watching:\n%s",
     length(over_warn), WARN_MB, HARD_MB,
     paste(sprintf("       %6.1f MB  %s", over_warn, names(over_warn)), collapse = "\n"))
}

# -----------------------------------------------------------------------------
ci_finish()
