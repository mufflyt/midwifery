# =============================================================================
# Leak guard: person-level columns, and files too big to take back
# =============================================================================
# Four commits in one week untracked person-level artifacts one at a time -- the
# PPV review sample, the Doximity profiles, the voter DOBs, the attribute-layer
# outputs. Each was found by hand, after it was committed. The policy was never
# in doubt; the enforcement did not exist.
#
# This is the enforcement. It reads the HEADER of every tracked CSV and fails
# when a person-level column appears in a file that is not already known.
# New leaks are blocked today. "Known" is the union of two separate lists,
# kept apart deliberately:
#
#   ci_leak_baseline.txt            false positives ONLY -- the guard is
#                                    wrong about these. May only shrink.
#   ci_leak_reviewed_exceptions.txt genuinely person-level files someone with
#                                    authority reviewed and accepted, in the
#                                    open, for a stated reason. Also may only
#                                    shrink, but for a different cause: an
#                                    entry leaves this list when the file is
#                                    untracked, not when the guard turns out
#                                    to have been wrong about it.
#
# Blending them into one list would let a real, reviewed exception hide under
# the same "just a false positive" cover as the other 67 -- reading either
# file alone should give an honest answer about which kind of entry it holds.
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
  "license_number", "home_address", "residential_address",
  # Matching-evidence artifacts name the same people with a side prefix rather
  # than the plain column: artifacts/ab_middle_name/evidence_top2.csv carries
  # roster_first/roster_last for 14,852 AMCB certificants, and
  # artifacts/bc_resolver/contested_evidence.csv carries them for 8,645. Both
  # sat tracked and undetected because the guard only knew "first_name". A
  # roster surname beside a candidate NPI is exactly the pairing this file
  # exists to keep out of a public repository.
  "roster_first", "roster_last", "roster_middle", "roster_name",
  "cand_first", "cand_last", "cand_middle", "candidate_npi",
  "nppes_matched_first", "nppes_matched_last"
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

read_path_list <- function(p) {
  if (!file.exists(p)) return(character(0))
  b <- readLines(p, warn = FALSE)
  b <- trimws(b)
  b <- b[nzchar(b) & !startsWith(b, "#")]
  sub("\\s+#.*$", "", b)
}

# TWO SEPARATE LISTS, deliberately not merged into one on disk. baseline is
# false positives only -- the guard is wrong about these, and the list may
# only shrink. reviewed_exceptions is genuinely person-level files someone
# with authority reviewed and accepted in the open, for a stated reason (see
# that file's own header). Blending them would let a real exception get
# waved through under cover of "it's probably just a false positive like the
# others" -- the whole point of keeping them apart is that a reader checking
# either file gets an honest answer about which kind of entry it's looking at.
baseline_path <- file.path(root, "tests", "ci_leak_baseline.txt")
exceptions_path <- file.path(root, "tests", "ci_leak_reviewed_exceptions.txt")
baseline <- read_path_list(baseline_path)
reviewed_exceptions <- read_path_list(exceptions_path)
known <- union(baseline, reviewed_exceptions)

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

new_hits <- setdiff(hits, known)
if (length(new_hits)) {
  ci_fail("L1: %d tracked file(s) carry a person-level column and are neither a documented false positive (ci_leak_baseline.txt) nor a reviewed exception (ci_leak_reviewed_exceptions.txt):\n%s",
       length(new_hits),
       paste(sprintf("       %s  [%s]", new_hits,
                     vapply(new_hits, function(f) {
                       paste(intersect(header_cols(file.path(root, f)), PERSON_COLS), collapse = ", ")
                     }, character(1))), collapse = "\n"))
} else {
  ci_ok("no new person-level file (%d known: %d false positive(s) in ci_leak_baseline.txt, %d reviewed exception(s) in ci_leak_reviewed_exceptions.txt)",
     length(hits), length(intersect(hits, baseline)), length(intersect(hits, reviewed_exceptions)))
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
named_new <- setdiff(named_all, known)

if (length(named_new)) {
  ci_fail("L2: %d tracked file(s) named like a person-level artifact, neither a documented false positive nor a reviewed exception:\n%s",
       length(named_new), paste(sprintf("       %s", named_new), collapse = "\n"))
} else {
  ci_ok("no newly tracked FROZEN / review-sample / voter file")
}

# The ratchet, reported once both detectors have run. Retiring an entry from
# either list must be a passing change, so a shrinking list is fine and a
# growing one is not. Checked separately per file so a note about a stale
# reviewed exception can never be mistaken for a stale false positive, or
# vice versa -- they get fixed by editing different files for different
# reasons. STALE is a note, not a failure: nobody should have to edit either
# file to make a green build green again.
present <- union(hits, named_all)
stale_baseline <- setdiff(baseline, present)
stale_exceptions <- setdiff(reviewed_exceptions, present)
if (length(stale_baseline)) {
  ci_ok("%d ci_leak_baseline.txt entr%s now clean -- delete from ci_leak_baseline.txt:\n%s",
     length(stale_baseline), if (length(stale_baseline) == 1) "y is" else "ies are",
     paste(sprintf("       %s", stale_baseline), collapse = "\n"))
}
if (length(stale_exceptions)) {
  ci_ok("%d ci_leak_reviewed_exceptions.txt entr%s now clean -- delete from ci_leak_reviewed_exceptions.txt:\n%s",
     length(stale_exceptions), if (length(stale_exceptions) == 1) "y is" else "ies are",
     paste(sprintf("       %s", stale_exceptions), collapse = "\n"))
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
