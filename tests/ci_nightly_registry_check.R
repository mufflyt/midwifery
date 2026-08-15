#!/usr/bin/env Rscript
# =============================================================================
# The nightly exception registry is itself under test
# =============================================================================
# tests/ci_nightly_exceptions.txt is the single mechanism by which a discovered
# test is treated as non-blocking. That makes it the one file where a quiet
# mistake buys silence, so it gets its own gate:
#
#   N1  every entry names a file that still exists
#   N2  every entry declares a known class
#   N3  no entry is listed twice
#   N4  the registry stays SMALL relative to the suite -- if exceptions ever
#       outnumber a tenth of the tests, discovery has stopped meaning anything
#
# N1 is the one that matters most. A test can be renamed or deleted while its
# exception stays behind; the line then excuses nothing, and the next reader
# reasonably assumes some real test is still being handled.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

REGISTRY <- file.path(root, "tests", "ci_nightly_exceptions.txt")
KNOWN_CLASSES <- c("external-private", "external-network")

ci_section("N0 the registry exists and parses")

if (!file.exists(REGISTRY)) {
  ci_fail("N0: %s is missing. The nightly reads it; an absent registry silently
       turns every exception into a blocking test.", REGISTRY)
  ci_finish()
}

raw <- readLines(REGISTRY, warn = FALSE)
lines <- trimws(raw)
lines <- lines[nzchar(lines) & !startsWith(lines, "#")]

parse_entry <- function(x) {
  x <- sub("#.*$", "", x)                       # strip trailing reason comment
  parts <- strsplit(trimws(x), "[[:space:]]+")[[1]]
  list(path = parts[1], class = if (length(parts) > 1) parts[2] else NA_character_)
}
entries <- lapply(lines, parse_entry)
ci_ok("%d exception(s) declared", length(entries))

# -----------------------------------------------------------------------------
ci_section("N1 every exception names a file that still exists")

missing <- vapply(entries, function(e) !file.exists(file.path(root, e$path)), logical(1))
if (any(missing)) {
  ci_fail("N1: %d exception(s) name a file that does not exist. Delete the line
       or fix the path -- an exception for a deleted test excuses nothing:\n%s",
       sum(missing),
       paste(sprintf("       %s", vapply(entries[missing], `[[`, character(1), "path")),
             collapse = "\n"))
} else {
  ci_ok("all %d exception path(s) resolve", length(entries))
}

# -----------------------------------------------------------------------------
ci_section("N2 every exception declares a known class")

bad_class <- vapply(entries, function(e) is.na(e$class) || !e$class %in% KNOWN_CLASSES,
                    logical(1))
if (any(bad_class)) {
  ci_fail("N2: %d entr%s an unknown class (known: %s):\n%s",
       sum(bad_class), if (sum(bad_class) == 1) "y declares" else "ies declare",
       paste(KNOWN_CLASSES, collapse = ", "),
       paste(sprintf("       %s  [%s]",
                     vapply(entries[bad_class], `[[`, character(1), "path"),
                     vapply(entries[bad_class], function(e) as.character(e$class), character(1))),
             collapse = "\n"))
} else {
  ci_ok("all classes are known")
}

# -----------------------------------------------------------------------------
ci_section("N3 no test is excepted twice")

paths <- vapply(entries, `[[`, character(1), "path")
dups <- unique(paths[duplicated(paths)])
if (length(dups)) {
  ci_fail("N3: %d path(s) listed more than once:\n%s", length(dups),
       paste(sprintf("       %s", dups), collapse = "\n"))
} else {
  ci_ok("no duplicate entries")
}

# -----------------------------------------------------------------------------
ci_section("N4 exceptions stay a small minority of the suite")

all_tests <- list.files(file.path(root, "tests"), pattern = "^test.*\\.(R|py)$")
all_tests <- all_tests[!startsWith(all_tests, "helper-")]
limit <- max(5L, as.integer(ceiling(length(all_tests) * 0.10)))

if (length(entries) > limit) {
  ci_fail("N4: %d exceptions against %d tests exceeds the %d allowed (10%%).
       Exceptions are for things this CI genuinely cannot do, not for tests
       that are inconvenient. Fix the dependency or delete the test.",
       length(entries), length(all_tests), limit)
} else {
  ci_ok("%d exception(s) of %d tests, limit %d", length(entries), length(all_tests), limit)
}

ci_finish()
