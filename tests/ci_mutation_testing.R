#!/usr/bin/env Rscript
# =============================================================================
# Mutation testing: does this suite actually detect anything?
# =============================================================================
# Introduces a plausible bug, runs the tests that ought to catch it, and
# records whether any of them turned red.
#
#   KILLED    at least one declared killer failed. The suite works.
#   SURVIVED  every killer still passed. That is a HOLE IN THE TESTS, not a
#             bug in the code, and it is reported as a failure here.
#
# THE CONTROL RUN COMES FIRST AND IS NOT OPTIONAL. Before any mutation, the
# killers are run unmutated and must ALL PASS. Without that, a suite that is
# already broken would "kill" every mutation and this file would report perfect
# confidence while measuring nothing. That failure mode is the entire reason
# mutation testing exists, so it would be absurd to be vulnerable to it.
#
# SAFETY. Source files are mutated IN PLACE and restored from an in-memory copy
# taken beforehand. Restoration runs from on.exit(), so it survives an error, an
# interrupt, or a killer test calling quit(). A final verification re-reads every
# touched file and hard-fails if a single byte differs from the original -- a
# mutation runner that leaves a mutation behind is the worst possible outcome,
# far worse than not running at all.
#
# Usage
#   Rscript tests/ci_mutation_testing.R           # rotating slice (nightly)
#   MUTATION_ALL=1 Rscript tests/ci_mutation_testing.R    # whole catalogue
#   MUTATION_ID=membership-and-to-or Rscript ...          # one mutation
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "tests", "mutation_catalogue.R"))

RUN_ALL <- identical(Sys.getenv("MUTATION_ALL", "0"), "1")
ONE_ID  <- Sys.getenv("MUTATION_ID", "")
# Rotating slice so a nightly stays minutes rather than an hour, while the whole
# catalogue still cycles. Derived from the date so it advances without state.
SLICE   <- as.integer(Sys.getenv("MUTATION_SLICE", "3"))

fails <- 0L
# Prefixed because `say` and `bad` are already defined at top level in
# sweep_healthgrades_enrichment.R and test_healthgrades_integrity.R. The
# hygiene gate H4 caught this file doing exactly what it exists to warn about.
mut_say  <- function(...) cat(sprintf(...))
mut_fail <- function(...) { fails <<- fails + 1L; cat(sprintf(...)) }

# -----------------------------------------------------------------------------
# File custody. Everything below depends on this being airtight.
# -----------------------------------------------------------------------------
ORIGINALS <- new.env(parent = emptyenv())

snapshot <- function(path) {
  if (is.null(ORIGINALS[[path]])) {
    ORIGINALS[[path]] <- readLines(path, warn = FALSE)
  }
  invisible(TRUE)
}

restore_all <- function() {
  for (p in ls(ORIGINALS)) {
    writeLines(ORIGINALS[[p]], p)
  }
  invisible(TRUE)
}
# Registered IMMEDIATELY, before any mutation can be applied.
on.exit(restore_all(), add = TRUE)

verify_clean <- function() {
  dirty <- character(0)
  for (p in ls(ORIGINALS)) {
    now <- readLines(p, warn = FALSE)
    if (!identical(now, ORIGINALS[[p]])) dirty <- c(dirty, p)
  }
  dirty
}

apply_mutation <- function(m) {
  snapshot(m$file)
  s <- paste(readLines(m$file, warn = FALSE), collapse = "\n")
  hits <- gregexpr(m$find, s, fixed = TRUE)[[1]]
  if (hits[1] == -1L) return("absent")
  if (length(hits) > 1L) return("ambiguous")
  writeLines(strsplit(sub(m$find, m$repl, s, fixed = TRUE), "\n", fixed = TRUE)[[1]],
             m$file)
  "ok"
}

run_test <- function(path) {
  if (!file.exists(path)) return(NA)          # unknown, not passed
  cmd <- if (any(grepl("test_that(", readLines(path, warn = FALSE), fixed = TRUE))) {
    sprintf("Rscript -e \"testthat::test_file('%s',stop_on_failure=TRUE)\"", path)
  } else {
    sprintf("Rscript %s", path)
  }
  system(paste(cmd, "> /dev/null 2>&1")) == 0L
}

# -----------------------------------------------------------------------------
# Select the mutations for this run
# -----------------------------------------------------------------------------
sel <- MUTATIONS
if (nzchar(ONE_ID)) {
  sel <- Filter(function(m) identical(m$id, ONE_ID), MUTATIONS)
  if (!length(sel)) { mut_fail("no mutation with id '%s'\n", ONE_ID); quit(status = 1) }
} else if (!RUN_ALL) {
  n <- length(MUTATIONS)
  day <- as.integer(format(Sys.Date(), "%j"))
  idx <- ((day * SLICE + seq_len(min(SLICE, n)) - 1L) %% n) + 1L
  sel <- MUTATIONS[unique(idx)]
}

mut_say("\n================ MUTATION TESTING ================\n")
mut_say("catalogue: %d mutations; this run: %d (%s)\n\n", length(MUTATIONS), length(sel),
    if (nzchar(ONE_ID)) "single" else if (RUN_ALL) "full" else "rotating slice")

# -----------------------------------------------------------------------------
# CONTROL. Unmutated, every killer must pass. If not, nothing below means
# anything and the run stops rather than reporting confidence it has not earned.
# -----------------------------------------------------------------------------
# A mutation whose only killer cannot run here is NOT killed -- it is
# unmeasured. Saying so is the difference between "9/9 killed" and the truth.
IN_CI <- nzchar(Sys.getenv("GITHUB_ACTIONS"))
unreachable <- Filter(function(m) IN_CI && identical(m$ci_reachable, FALSE), sel)
if (length(unreachable)) {
  mut_say("-- coverage limit --\n")
  for (m in unreachable) {
    mut_say("  --   UNMEASURED %s: its killer (%s) cannot run here\n",
        m$id, paste(basename(m$killers), collapse = ", "))
  }
  mut_say("       %d of %d mutations are unmeasured in this environment.\n\n",
      length(unreachable), length(sel))
  sel <- Filter(function(m) !(IN_CI && identical(m$ci_reachable, FALSE)), sel)
}
if (!length(sel)) {
  mut_say("no measurable mutations in this environment\n")
  mut_say("\nPASS (0 failures)\n"); quit(status = 0)
}

mut_say("-- control: killers must pass BEFORE any mutation --\n")
killers <- unique(unlist(lapply(sel, `[[`, "killers")))
control <- vapply(killers, run_test, logical(1))

for (k in names(control)) {
  if (isTRUE(control[[k]])) mut_say("  ok   %s passes unmutated\n", basename(k))
  else mut_fail("  FAIL %s does not pass UNMUTATED -- every mutation it guards would look 'killed' for the wrong reason\n",
           basename(k))
}
if (any(!control %in% TRUE)) {
  mut_fail("\nCONTROL FAILED. Refusing to report mutation results built on a broken baseline.\n")
  mut_say("\nFAILED (%d)\n", fails)
  quit(status = 1)
}

# -----------------------------------------------------------------------------
# The mutations
# -----------------------------------------------------------------------------
results <- list()
for (m in sel) {
  mut_say("\n-- %s --\n", m$id)
  mut_say("   %s\n", paste(strwrap(m$why, width = 74, prefix = "   "), collapse = "\n"))

  st <- apply_mutation(m)
  if (!identical(st, "ok")) {
    mut_fail("  FAIL mutation could not be applied (%s): the catalogue entry has rotted and was testing nothing\n", st)
    results[[m$id]] <- "BROKEN"
    restore_all()
    next
  }

  verdicts <- vapply(m$killers, run_test, logical(1))
  restore_all()

  killed_by <- names(verdicts)[verdicts %in% FALSE]
  if (length(killed_by)) {
    mut_say("  ok   KILLED by %s\n", paste(basename(killed_by), collapse = ", "))
    results[[m$id]] <- "KILLED"
  } else {
    mut_fail("  FAIL SURVIVED -- %s still pass with this bug present.\n",
        paste(basename(m$killers), collapse = ", "))
    mut_fail("       This is a hole in the TESTS, not a bug in the code.\n")
    results[[m$id]] <- "SURVIVED"
  }
}

# -----------------------------------------------------------------------------
# Custody check. Non-negotiable.
# -----------------------------------------------------------------------------
mut_say("\n-- file custody --\n")
dirty <- verify_clean()
if (length(dirty)) {
  mut_fail("  FAIL %d file(s) left MUTATED: %s\n", length(dirty), paste(dirty, collapse = ", "))
  mut_fail("       Restore them from git before doing anything else.\n")
} else {
  mut_say("  ok   all %d mutated file(s) restored byte-for-byte\n", length(ls(ORIGINALS)))
}

# -----------------------------------------------------------------------------
mut_say("\n================ RESULT ================\n")
tab <- table(unlist(results))
for (k in names(tab)) mut_say("  %-9s %d\n", k, tab[[k]])
if (length(results)) {
  mut_say("  mutation score: %d/%d killed\n",
      sum(unlist(results) == "KILLED"), length(results))
}
if (length(unreachable)) {
  mut_say("  UNMEASURED:    %d (killer not runnable here, NOT counted as killed)\n",
      length(unreachable))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAILED", fails))
quit(status = if (fails == 0L) 0L else 1L)
