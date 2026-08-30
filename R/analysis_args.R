# =============================================================================
# Argument and path resolution for the ad-hoc audits in analysis/
# =============================================================================
#
# ONE definition, sourced by all four. The first cut inlined this helper into
# each script and tests/ci_hygiene.R rejected it: "no NEW duplicate
# definitions". That gate is right, and it is the same rule R/amcb_name_keys.R
# states about name normalisation -- a second copy is how two callers quietly
# disagree. The scripts in analysis/ are throwaway in intent but they produce
# numbers quoted in docs/TECHNICAL_APPENDIX_*.md, so they get the same standard.
# =============================================================================

#' Positional argument, then environment variable, then default.
#'
#' Paths are ARGUMENTS, not constants. These audits were written against two
#' worktrees on one machine; hardcoding those makes them unrunnable anywhere
#' else and trips the non-hermetic-path gate in tests/ci_repo_integrity.R.
#'
#' @param i integer: position in commandArgs(TRUE).
#' @param env character: environment variable consulted when the argument is
#'   absent.
#' @param default character: used when both are absent. When NULL, absence is
#'   an error rather than a guess -- a wrong default here silently compares the
#'   wrong two artifacts and reports a clean-looking answer.
arg_or <- function(i, env, default = NULL) {
  a <- commandArgs(TRUE)
  if (length(a) >= i && nzchar(a[i])) return(a[i])
  v <- Sys.getenv(env, "")
  if (nzchar(v)) return(v)
  if (!is.null(default)) return(default)
  stop(sprintf("supply argument %d or set %s", i, env), call. = FALSE)
}
