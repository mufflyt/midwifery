#!/usr/bin/env Rscript
# =============================================================================
# The volume's name must never be able to change a scientific result
# =============================================================================
# macOS leaves a stale mount point in /Volumes after an unclean unmount and
# remounts the real disk as "<name> 1". The repo hardcoded "<name>". DuckDB
# CREATES a database when the path does not exist, so the mismatch produced a
# 12 KB empty warehouse, zero rows from every query, and a run that reported
# success having measured nothing. Both files are on the volume right now:
#
#   .../MufflySamsung 1/DuckDB/nber_my_duckdb.duckdb   84.3 GB, 454 tables
#   .../MufflySamsung 1/nber_my_duckdb.duckdb           12 KB,   0 tables
#
# THE CENTRAL CASE, and the one that nearly bit the project: given a tiny fake
# database under one spelling and the real one under another, the resolver must
# choose the real one and must not create or modify EITHER during discovery.
#
# Hermetic: fixtures in a temp directory, no /Volumes access, no network, no
# database is ever opened. Discovery is filesystem-only by design, which is
# what makes it testable without the drive mounted.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
# Named for this file: tests/test_cycle11_spatial.R already defines a bare
# raises(), and ci_hygiene.R H4 refuses a second top-level definition of the
# same verb -- two files that look identical are how they quietly diverge.
raises <- function(expr) inherits(try(expr, silent = TRUE), "try-error")
emsg <- function(expr) {
  e <- try(expr, silent = TRUE)
  if (inherits(e, "try-error")) as.character(e) else ""
}

# --- fixtures: two "volumes", one real-sized file, one decoy -----------------
tmp <- file.path(tempdir(), paste0("volfix-", as.integer(Sys.time())))
# Fixtures are written at a SCALED size with a scaled threshold (MINB below).
# The invariant under test is "a size floor separates the real warehouse from a
# newly-created stub", which holds at any scale; writing multi-GB fixtures would
# only test the filesystem. D1 separately asserts the SHIPPED threshold is a
# realistic one.
MINB <- 1000
mkfile <- function(dir, vol, bytes) {
  d <- file.path(dir, vol, "DuckDB"); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  p <- file.path(d, "nber_my_duckdb.duckdb")
  con <- file(p, "wb"); writeBin(as.raw(rep(0L, bytes)), con); close(con)
  p
}
mk <- function(vol, bytes) mkfile(tmp, vol, bytes)
GLOB <- file.path(tmp, "MufflySamsung*", "DuckDB", "nber_my_duckdb.duckdb")
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

# =============================================================================
cat("\n-- V: the decoy must never win --\n")
# =============================================================================
{
  real  <- mk("MufflySamsung 1", 5000)  # the drive, remounted with " 1"
  decoy <- mk("MufflySamsung",    100)  # the wreckage of the original bug
  before <- file.info(c(real, decoy))[, c("size", "mtime")]

  got <- resolve_midwifery_duckdb(glob = GLOB, env_var = "", min_bytes = MINB, quiet = TRUE)
  chk(identical(normalizePath(got), normalizePath(real)),
      "V1 the real warehouse is chosen over the tiny decoy")
  chk(!grepl("MufflySamsung/DuckDB", got, fixed = TRUE),
      "V2 and the decoy path is not returned")

  # DISCOVERY MUST NOT TOUCH THE CANDIDATES. If resolution could create or
  # modify a file, running the resolver would itself manufacture the decoy.
  after <- file.info(c(real, decoy))[, c("size", "mtime")]
  chk(identical(before, after),
      "V3 discovery created and modified NOTHING -- sizes and mtimes unchanged")
  chk(file.exists(decoy),
      "V4 the decoy is left in place, not silently deleted")
}

# =============================================================================
cat("\n-- N: name-agnostic --\n")
# =============================================================================
{
  t2 <- file.path(tempdir(), paste0("volfix2-", as.integer(Sys.time())))
  mk2 <- function(vol, bytes) mkfile(t2, vol, bytes)
  g2 <- file.path(t2, "MufflySamsung*", "DuckDB", "nber_my_duckdb.duckdb")
  on.exit(unlink(t2, recursive = TRUE), add = TRUE)

  # Whatever macOS appends, the same drive must resolve.
  for (nm in c("MufflySamsung", "MufflySamsung 1", "MufflySamsung 2")) {
    unlink(file.path(t2), recursive = TRUE)
    p <- mk2(nm, 5000)
    got <- resolve_midwifery_duckdb(glob = g2, env_var = "", min_bytes = MINB, quiet = TRUE)
    chk(identical(normalizePath(got), normalizePath(p)),
        sprintf("N1 resolves when the volume is called %s", nm))
  }
}

# =============================================================================
cat("\n-- A: ambiguity and absence stop LOUDLY --\n")
# =============================================================================
{
  t3 <- file.path(tempdir(), paste0("volfix3-", as.integer(Sys.time())))
  mk3 <- function(vol, bytes) mkfile(t3, vol, bytes)
  g3 <- file.path(t3, "MufflySamsung*", "DuckDB", "nber_my_duckdb.duckdb")
  on.exit(unlink(t3, recursive = TRUE), add = TRUE)

  chk(raises(resolve_midwifery_duckdb(glob = g3, env_var = "", min_bytes = MINB, quiet = TRUE)),
      "A1 no candidate at all -> error, never a hardcoded fallback")

  mk3("MufflySamsung", 100); mk3("MufflySamsung 1", 200)
  chk(raises(resolve_midwifery_duckdb(glob = g3, env_var = "", min_bytes = MINB, quiet = TRUE)),
      "A2 only implausible candidates -> error, never 'use the biggest'")

  # TWO plausible warehouses is genuinely ambiguous. Picking one would be a
  # coin flip that decides which data the analysis ran on.
  mk3("MufflySamsung 2", 5000); mk3("MufflySamsung 3", 6000)
  m <- emsg(resolve_midwifery_duckdb(glob = g3, env_var = "", min_bytes = MINB, quiet = TRUE))
  chk(nzchar(m), "A3 two plausible warehouses -> error, not a silent choice")
  chk(grepl("exactly ONE", m), "A4 and the error says what was expected")
}

# =============================================================================
cat("\n-- D: the SHIPPED threshold is realistic --\n")
{
  # The scaled fixtures above prove the logic. This proves the default that
  # actually ships would reject the real 12 KB decoy on the real volume.
  chk(DUCKDB_MIN_BYTES >= 1e9,
      sprintf("D1 the shipped size floor is >= 1 GB [%.0e]", DUCKDB_MIN_BYTES))
  chk(12288 < DUCKDB_MIN_BYTES,
      "D2 and the real 12 KB decoy on the volume falls below it")
  chk(grepl("MufflySamsung\\*", DUCKDB_GLOB_DEFAULT),
      "D3 discovery globs the volume name rather than hardcoding a spelling")
}

cat("\n-- E: an explicit override is still checked --\n")
# =============================================================================
{
  chk(raises(resolve_midwifery_duckdb(glob = "/nonexistent/*", env_var = "",
                                    quiet = TRUE)),
      "E1 a glob matching nothing errors")
  Sys.setenv(TESTVOL_DB = file.path(tempdir(), "definitely-not-here.duckdb"))
  on.exit(Sys.unsetenv("TESTVOL_DB"), add = TRUE)
  m <- emsg(resolve_midwifery_duckdb(env_var = "TESTVOL_DB", quiet = TRUE))
  chk(nzchar(m), "E2 an override pointing at a missing file errors")
  chk(grepl("CREATE", m), "E3 and the error explains WHY: dbConnect would create it")
}

# =============================================================================
cat("\n-- H: NO executable source hardcodes the volume, in any language --\n")
{
  # Scanning only *.R would let the same failure return through a Python
  # scraper, a shell wrapper or a workflow env: line. The literal is the bug,
  # whatever file it lives in.
  tracked <- system2("git", c("ls-files",
                              "*.R", "*.py", "*.sh", "*.yml", "*.yaml", "*.Rmd"),
                     stdout = TRUE)
  tracked <- tracked[file.exists(tracked)]
  allowed <- c("R/lib/medicare_duckdb.R", "tests/test_duckdb_volume_resolution.R")
  # Comment lines are exempt: a comment cannot open a database, and the history
  # of WHY this rule exists is worth keeping legible.
  comment_re <- "^\\s*(#|//|--)"
  offenders <- character(0)
  for (f in setdiff(tracked, allowed)) {
    ln <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    ln <- ln[!grepl(comment_re, ln)]
    if (any(grepl("/Volumes/MufflySamsung", ln, fixed = TRUE)))
      offenders <- c(offenders, f)
  }
  chk(length(offenders) == 0L,
      sprintf("H1 no executable source hardcodes the volume [%d file(s) scanned; offenders: %s]",
              length(tracked),
              if (length(offenders)) paste(basename(offenders), collapse = ", ") else "none"))

  # And the specific spellings that caused the incident, called out by name so a
  # future reader knows what is being defended against.
  for (lit in c("/Volumes/MufflySamsung", "MufflySamsung/DuckDB", "MufflySamsung 1/DuckDB")) {
    bad <- character(0)
    for (f in setdiff(tracked, allowed)) {
      ln <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
      ln <- ln[!grepl(comment_re, ln)]
      if (any(grepl(lit, ln, fixed = TRUE))) bad <- c(bad, f)
    }
    chk(length(bad) == 0L, sprintf("H2 no executable source contains %s", lit))
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
