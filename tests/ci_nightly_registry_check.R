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

ci_section("N5 every exception's stated reason is still true")

# N1 checks the exception's FILE still exists. Nothing checked that its REASON
# does -- which is the half that rots. An exception is a promise that this CI
# genuinely cannot run the test; when the dependency behind it goes away, the
# promise becomes false and the test stops being run for no reason at all. That
# is the failure the nightly's "no test file goes unrun" job exists to prevent,
# arriving through the one mechanism that job is told to respect.
#
# EVIDENCE IS TRANSITIVE, and it has to be: the dependency is usually not in the
# test file. test_amcb_name_normalization.R names nothing external and reaches
# mysterynpi through R/amcb_name_keys.R, a shim over that package;
# test_match_npi_to_hospitals.R reaches data.cms.gov through
# R/lib/match_npi_to_hospitals.R. A single-file grep calls both of those stale,
# which is how a correct exception gets deleted and a passing nightly starts
# failing. So the search follows source() to a depth of 3.
#
# A MISS IS A FAILURE, NOT A WARNING. If the scan cannot find the dependency,
# either the exception is stale -- delete it, the test can run here -- or the
# dependency is reached some way this cannot see, in which case the way it is
# reached should be made visible rather than left for the next reader to
# rediscover.
EVIDENCE <- list(
  "external-private" = "isochrones_dep|ISOCHRONES_HOME|ISOCHRONES_R|load_isochrones|mysterynpi",
  "external-network" = "https?://|data\\.cms\\.gov|download\\.file|curl::|httr::|GET\\(")

n5_source_targets <- function(txt) {
  out <- character(0)
  for (ln in grep("source\\s*\\(", txt, value = TRUE)) {
    q <- gsub('"', "", regmatches(ln, gregexpr('"[^"]+"', ln))[[1]])
    q <- q[!q %in% "root"]
    if (!length(q)) next
    out <- c(out, if (grepl("file\\.path", ln)) do.call(file.path, as.list(q)) else q)
  }
  unique(out)
}

n5_closure <- function(f, depth = 3L) {
  seen <- character(0); frontier <- f
  while (depth > 0L && length(frontier)) {
    frontier <- setdiff(frontier, seen); seen <- c(seen, frontier)
    nxt <- character(0)
    for (g in frontier) {
      fp <- file.path(root, g)
      if (file.exists(fp))
        nxt <- c(nxt, n5_source_targets(readLines(fp, warn = FALSE)))
    }
    frontier <- nxt; depth <- depth - 1L
  }
  seen
}

unsupported <- character(0); supported <- 0L; skipped_class <- 0L
for (e in entries) {
  pat <- EVIDENCE[[e$class]]
  if (is.null(pat)) { skipped_class <- skipped_class + 1L; next }  # N2 failed on the class
  found <- NA_character_
  for (g in n5_closure(e$path)) {
    fp <- file.path(root, g)
    if (!file.exists(fp)) next
    if (any(grepl(pat, readLines(fp, warn = FALSE)))) { found <- g; break }
  }
  if (is.na(found))
    unsupported <- c(unsupported, sprintf("%s (%s)", e$path, e$class))
  else supported <- supported + 1L
}

# THIS GATE MAY NOT PASS VACUOUSLY, and it did on its first run: the loop read
# e$file where parse_entry() provides e$path, sprintf() on a NULL returned
# character(0) rather than erroring, every append was a silent no-op, and the
# section reported "all 0 exception(s) still reach the dependency they claim"
# -- a clean green tick over nothing examined. The same shape ci_law_coverage.R
# rejects by requiring n > 0. Every declared exception must be accounted for.
if (supported + length(unsupported) + skipped_class != length(entries)) {
  ci_fail("N5: accounted for %d of %d exception(s) (%d supported, %d unsupported, %d bad class).\n       A coverage check that examines fewer entries than exist reports a\n       result about nothing.",
          supported + length(unsupported) + skipped_class, length(entries),
          supported, length(unsupported), skipped_class)
} else if (length(unsupported)) {
  ci_fail("N5: %d exception(s) whose stated reason cannot be found:\n       %s\n       Either the dependency is gone -- delete the line, the test can run here\n       now -- or it is reached in a way this scan cannot follow, which is worth\n       making visible. Do not widen EVIDENCE to make this pass.",
          length(unsupported), paste(unsupported, collapse = "\n       "))
} else {
  ci_ok("all %d exception(s) still reach the dependency they claim", supported)
}

ci_finish()
