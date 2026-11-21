# =============================================================================
# The harness every saboteur suite was writing out for itself
# =============================================================================
# WHY THIS EXISTS. A saboteur suite is four things: find the repo root, print a
# pass or count a failure, head each saboteur, and exit non-zero if any held.
# Those four were copied into every new suite -- the root-finding preamble
# alone appears byte-identical in 111 tracked files -- and the copies were
# harmless right up until they weren't: `sab`, `refused`, `restore_scene`,
# `says`, `write_manifest`, `write_year`, `year_path` and `snapshot` all ended
# up defined in two to six files at once, and tests/ci_hygiene.R's H4 gate
# ("no function defined at top level in two tracked files") went from passing
# at origin/main to failing, because nobody ran it while the suites were being
# written.
#
# WHAT IS SHARED AND WHAT IS NOT. Only the pieces that are genuinely identical
# live here. The fixture builders are NOT: `restore_scene` rebuilds a
# different sandbox in each of four suites, and two `says` implementations
# read different things (one a refusal's text, one a captured build log). Those
# keep per-suite names, which is what this repository already does elsewhere
# ("mn_prefixed: ci_hygiene H4 fails on a top-level function defined in two
# tracked files"). Merging functions that only share a NAME would be worse
# than the duplication: it hides that they do different work.
#
# `fails` is defined here and incremented with `<<-` from chk(), so sourcing
# this file into a suite's environment gives the suite the counter too. A
# suite that wants its own tally can still keep one; this one is the default.
# =============================================================================

#' The repository root, whether the suite was run by path or from the root
#'
#' `Rscript tests/test_x.R` passes `--file=`, so the root is the test file's
#' parent's parent. Sourced interactively there is no `--file=`, and the
#' working directory is the root by convention.
#' @return [character(1)] normalized absolute path.
test_repo_root <- function() {
  from_rscript <- grep("--file=", commandArgs(), value = TRUE)
  if (length(from_rscript))
    normalizePath(file.path(dirname(sub("--file=", "", from_rscript[1])), ".."))
  else normalizePath(".")
}


#' The repository root, resolved once when this harness is sourced
SAB_ROOT <- test_repo_root()

#' Read a repository-relative file as one string
#'
#' Lived in two saboteur suites at once, which is what ci_hygiene H4 forbids
#' and for the usual reason: the duplication is not the name but the work.
#' @param rel [character(1)] path relative to the repository root.
#' @param root [character(1)] the root; resolved once at source time.
#' @return [character(1)] the whole file, newline-joined.
slurp <- function(rel, root = SAB_ROOT)
  paste(readLines(file.path(root, rel), warn = FALSE), collapse = "\n")

#' Tracked paths, from git
#'
#' @param pattern [character(1)] a git pathspec. A DIRECTORY-QUALIFIED glob
#'   ("tests/*.R") or "." -- never a bare "*.R", which does not cross
#'   directory boundaries and reads only the repository root (267 of 647 files
#'   here). `tests/test_gate_integrity_saboteurs.R`'s Q2a refuses the bare
#'   form; this docstring is the other half of that fix.
#' @param root [character(1)] the repository root; resolved once at source time.
#' @return [character] tracked paths, or `character(0)`.
tracked <- function(pattern, root = SAB_ROOT) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(root), "ls-files", pattern),
                                  stdout = TRUE, stderr = FALSE))
  if (!length(out)) character(0) else out
}

#' Every tracked .R file, at any depth
#'
#' Lists once and filters in R, because a git pathspec does not recurse.
#' @return [character] repository-relative paths.
tracked_r <- function() grep("\\.R$", tracked("."), value = TRUE)

fails <- 0L

#' Assert, print, and count
#'
#' @param cond [logical(1)] the assertion. Anything but TRUE is a failure, so
#'   an NA or a zero-length result fails rather than passing quietly.
#' @param m [character(1)] what was being asserted, in words.
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

#' The letter each saboteur's label carries, set by the suite before use
#'
#' Six suites each defined their own one-line `sab()` differing only in this
#' letter (A for agreement, Z for ZIP, and so on), which is a variable, not a
#' function.
SAB_PREFIX <- "S"

#' Head a saboteur
#' @param n [character(1)|integer(1)] its number, or e.g. "10b" for a pair.
#' @param name [character(1)] what it sabotages.
sab <- function(n, name) cat(sprintf("\n%s%s %s\n", SAB_PREFIX, n, name))

#' Did the call under test refuse?
#'
#' The suites wrap the function under test so that a refusal comes back as a
#' value of class "refusal" carrying its message, rather than aborting the
#' run -- a saboteur has to keep going after the build says no.
#' @param x the wrapped result.
refused <- function(x) inherits(x, "refusal")

#' Print the tally and exit with the status a CI runner reads
#' @param n_saboteurs [character(1)|integer(1)] how many saboteurs ran.
saboteur_report <- function(n_saboteurs) {
  cat(sprintf("\n%s (%d failure(s) across %s saboteurs)\n",
              if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS",
              fails, n_saboteurs))
  quit(status = if (fails == 0L) 0L else 1L)
}
