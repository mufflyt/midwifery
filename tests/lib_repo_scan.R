# =============================================================================
# Reading the repository as git sees it, once
# =============================================================================
# WHY THIS EXISTS. Three primitives were written for
# test_claim_integrity_saboteurs.R and are needed verbatim by
# test_doc_integrity_saboteurs.R: the tracked-file listing, the
# "tracked or deliberately ignored" predicate, and the markdown link reader.
# Copying them would put three top-level functions in two tracked files, which
# tests/ci_hygiene.R's H4 forbids, and for the reason H4 exists: the copies
# drift and the two gates then disagree about what the tree contains.
#
# ORDERING. `SAB_ROOT` comes from tests/helper-saboteur.R, so source that
# first. These functions close over it rather than taking a root argument,
# because every caller in this repository means the same root.
#
# WHY `lib_`, NOT `helper-`. testthat sources every tests/helper-*.R
# ALPHABETICALLY before it runs any test file in the directory. Named
# helper-repo-scan.R, this file sorted before helper-saboteur.R, read
# `SAB_ROOT` at load time, errored with "object 'SAB_ROOT' not found", and
# took down all 16 testthat files in the directory -- which surfaced not as an
# error anyone read but as ci_skip_budget.R reporting 16 gates that "produced
# no testthat summary line". tests/lib_manuscript_numbers.R already set the
# convention: a file that suites source explicitly is `lib_`. The alternative,
# making this file self-sufficient, would run `git ls-files` once per testthat
# file -- 213 subprocesses to serve two callers that source it directly.
# =============================================================================

#' Lines of a git command's stdout, empty on failure
#'
#' @param ... arguments after `-C <root>`.
#' @return [character] stdout lines, `character(0)` if git said nothing.
git_lines <- function(...) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(SAB_ROOT), ...),
                                  stdout = TRUE, stderr = FALSE))
  if (!length(out)) character(0) else out
}

#' Every path git tracks, resolved once when this helper is sourced
TRACKED <- git_lines("ls-files")

#' Is each path one the repository knows about?
#'
#' Tracked, or matched by a `.gitignore` rule. The second half matters: most
#' of what this repository's prose cites under `artifacts/` is a build output
#' that is deliberately not committed, and a gate that called those paths dead
#' produced 25 false alarms on its first run.
#'
#' ONE GIT CALL, NOT ONE PER PATH. The first version shelled out twice per
#' entry -- `ls-files --error-unmatch` and `check-ignore -q` -- which is 748
#' processes for 374 entries and 72 of that gate's 82 seconds, all of it
#' spawning. Tracked is answered from the `git ls-files` listing already in
#' memory, and every remaining path goes to `check-ignore --stdin` together.
#' @param paths [character] repository-relative paths.
#' @return [logical] one per path.
known_paths <- function(paths) {
  known <- paths %in% TRACKED
  rest <- unique(paths[!known])
  if (length(rest)) {
    ignored <- suppressWarnings(system2(
      "git", c("-C", shQuote(SAB_ROOT), "check-ignore", "--stdin"),
      input = rest, stdout = TRUE, stderr = FALSE))
    known <- known | paths %in% ignored
  }
  known
}

#' Relative repository paths linked from markdown
#'
#' Takes the path out of `](path)` and not the words around it. Anchors
#' (`](#section)`) and absolute URLs are excluded by the character class.
#' @param ln [character] markdown lines.
#' @return [character] unique link targets, as written.
link_paths <- function(ln) {
  pat <- "\\]\\([A-Za-z0-9_./-]+[.](R|py|csv|md|tsv|txt|json|qmd|ya?ml|sh)\\)"
  m <- regmatches(ln, gregexpr(pat, ln))
  unique(sub("\\)$", "", sub("^\\]\\(", "", unlist(m))))
}
