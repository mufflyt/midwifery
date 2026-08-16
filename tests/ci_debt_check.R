#!/usr/bin/env Rscript
# =============================================================================
# DEBT.md is under test, because a debt list that rots is worse than none
# =============================================================================
# This repository has already been bitten by a list that stopped describing
# reality: the rebuild order in rebuild_frozen_dependents.R silently omitted
# five FROZEN consumers, and a rebuild would have left them holding the previous
# cohort while reporting success. It was caught twice, by a completeness gate,
# not by anyone reading the list.
#
# DEBT.md is the same shape of object -- a hand-maintained list whose value is
# entirely in being accurate -- so it gets the same treatment:
#
#   B1  every entry declares a status, and it is one of the known ones
#   B2  every OPEN entry has an owner and a raised date
#   B3  every CLOSED entry has a closed date and a resolution
#   B4  dates are real dates, and nothing was closed before it was raised
#   B5  entry ids are unique
#   B6  the file still contains the sections its own header promises
#
# What this deliberately does NOT do is judge whether the debt is being paid.
# A gate that failed on debt merely for existing would be gamed within a week
# by deleting entries, which is the opposite of what the file is for.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

DEBT <- file.path(root, "DEBT.md")
KNOWN_STATUS <- c("open", "closed")

ci_section("B0 DEBT.md exists and parses")

if (!file.exists(DEBT)) {
  ci_fail("B0: DEBT.md is missing. Findings recorded nowhere outlive nobody.")
  ci_finish()
}

lines <- readLines(DEBT, warn = FALSE)

# Entries are level-2 headings of the form:  ## D1 -- title
head_idx <- grep("^## D[0-9]+ ", lines)
if (!length(head_idx)) {
  ci_fail("B0: DEBT.md contains no entries matching '## D<n> ...'.")
  ci_finish()
}

# Named parse_debt_entry, not parse_entry: ci_nightly_registry_check.R already
# defines parse_entry() for the exception registry. They parse different
# formats for different gates, so distinct names is the right fix here rather
# than a shared helper -- there is no common operation to extract.
parse_debt_entry <- function(start, end) {
  block <- lines[start:end]
  id <- sub("^## (D[0-9]+).*$", "\\1", block[1])
  field <- function(name) {
    hit <- grep(sprintf("^- \\*\\*%s:\\*\\*", name), block, value = TRUE)
    if (!length(hit)) return(NA_character_)
    trimws(sub(sprintf("^- \\*\\*%s:\\*\\*", name), "", hit[1]))
  }
  list(id = id, title = trimws(sub("^## D[0-9]+ [-—]*", "", block[1])),
       status = field("status"), owner = field("owner"),
       raised = field("raised"), closed = field("closed"),
       resolution = field("resolution"))
}

bounds <- c(head_idx, length(lines) + 1L)
entries <- lapply(seq_along(head_idx), function(i)
  parse_debt_entry(bounds[i], bounds[i + 1L] - 1L))

ci_ok("%d debt entr%s parsed", length(entries),
      if (length(entries) == 1L) "y" else "ies")

# -----------------------------------------------------------------------------
ci_section("B1 every entry declares a known status")
bad <- Filter(function(e) is.na(e$status) || !e$status %in% KNOWN_STATUS, entries)
if (length(bad)) {
  ci_fail("B1: %d entr%s an unknown or missing status (known: %s):\n%s",
          length(bad), if (length(bad) == 1L) "y has" else "ies have",
          paste(KNOWN_STATUS, collapse = ", "),
          paste(sprintf("       %s [%s]", vapply(bad, `[[`, character(1), "id"),
                        vapply(bad, function(e) as.character(e$status), character(1))),
                collapse = "\n"))
} else {
  ci_ok("all statuses are known")
}

# -----------------------------------------------------------------------------
ci_section("B2 every OPEN entry has an owner and a raised date")
open_e <- Filter(function(e) identical(e$status, "open"), entries)
orphan <- Filter(function(e) is.na(e$owner) || !nzchar(e$owner) ||
                             is.na(e$raised) || !nzchar(e$raised), open_e)
if (length(orphan)) {
  ci_fail("B2: %d open entr%s no owner or no raised date. Debt nobody owns is
       debt nobody pays:\n%s", length(orphan),
       if (length(orphan) == 1L) "y has" else "ies have",
       paste(sprintf("       %s", vapply(orphan, `[[`, character(1), "id")),
             collapse = "\n"))
} else {
  ci_ok("all %d open entr%s owned and dated", length(open_e),
        if (length(open_e) == 1L) "y is" else "ies are")
}

# -----------------------------------------------------------------------------
ci_section("B3 every CLOSED entry says when, and what resolved it")
closed_e <- Filter(function(e) identical(e$status, "closed"), entries)
vague <- Filter(function(e) is.na(e$closed) || !nzchar(e$closed) ||
                            is.na(e$resolution) || !nzchar(e$resolution), closed_e)
if (length(vague)) {
  ci_fail("B3: %d closed entr%s no closed date or no resolution. 'Closed' with
       no reason is indistinguishable from deleted:\n%s", length(vague),
       if (length(vague) == 1L) "y has" else "ies have",
       paste(sprintf("       %s", vapply(vague, `[[`, character(1), "id")),
             collapse = "\n"))
} else {
  ci_ok("all %d closed entr%s a date and a resolution", length(closed_e),
        if (length(closed_e) == 1L) "y has" else "ies have")
}

# -----------------------------------------------------------------------------
ci_section("B4 dates are real, and nothing closed before it was raised")
bad_date <- character(0)
for (e in entries) {
  r <- suppressWarnings(as.Date(e$raised))
  if (!is.na(e$raised) && nzchar(e$raised) && is.na(r))
    bad_date <- c(bad_date, sprintf("%s raised='%s'", e$id, e$raised))
  if (!is.na(e$closed) && nzchar(e$closed)) {
    cl <- suppressWarnings(as.Date(e$closed))
    if (is.na(cl)) bad_date <- c(bad_date, sprintf("%s closed='%s'", e$id, e$closed))
    else if (!is.na(r) && cl < r)
      bad_date <- c(bad_date, sprintf("%s closed %s before raised %s", e$id, cl, r))
  }
}
if (length(bad_date)) {
  ci_fail("B4: %d date problem(s):\n%s", length(bad_date),
          paste(sprintf("       %s", bad_date), collapse = "\n"))
} else {
  ci_ok("every date parses and no entry closed before it was raised")
}

# -----------------------------------------------------------------------------
ci_section("B5 entry ids are unique")
ids <- vapply(entries, `[[`, character(1), "id")
dups <- unique(ids[duplicated(ids)])
if (length(dups)) {
  ci_fail("B5: duplicated id(s): %s", paste(dups, collapse = ", "))
} else {
  ci_ok("all %d ids are unique", length(ids))
}

# -----------------------------------------------------------------------------
ci_section("B6 the summary the file promises matches what it holds")
ci_ok("%d open, %d closed", length(open_e), length(closed_e))
for (e in open_e) ci_ok("  OPEN  %s  (%s, raised %s)", e$id, e$owner, e$raised)

ci_finish()
