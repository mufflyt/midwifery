#' @title One call-tree walker
#'
#' @description
#' `walk_call_tree(node, visit)` calls `visit()` on every call node in an R
#' parse tree, pre-order, and recurses into the arguments.
#'
#' @details
#' WHY THIS FILE EXISTS. Two walkers were written independently for the same
#' job, both reachable from the same pipeline script, each carrying its own
#' paragraph about the same R language quirk:
#'
#'   - `walk()` inside `.code_closure()`, `R/lib/artifact_provenance.R` --
#'     looking for `source()` / `sys.source()` targets.
#'   - `walk_calls()` inside `duckdb_scan_for_raw_connections()`, then in
#'     `R/lib/medicare_duckdb.R`, now in `tests/duckdb_architecture_scan.R` --
#'     looking for raw DuckDB connection construction.
#'
#' Their traversal was identical (visit the call, recurse into arguments 2..n,
#' descend a pairlist or list); they differed only in how each coped with
#' nodes that cannot be walked. One skipped the empty symbol explicitly, the
#' other wrapped every recursive step in `tryCatch`. This file does both, so
#' it is a superset of each one's robustness with neither one's traversal
#' changed -- the 2026-11-20 complexity audit's fourth finding.
#'
#' THE HEAD IS NOT VISITED, DELIBERATELY. Both originals recursed into
#' `as.list(node)[-1L]` / `2:n`, skipping the callee itself, and the DuckDB
#' scanner's mutation suite (M1-M17) is calibrated against exactly the set of
#' sites that traversal reaches. Visiting heads too would be more thorough and
#' would change what that gate counts, which is a decision for whoever owns
#' the gate, not a side effect of removing a duplicate.
#'
#' Searched before writing: this repository has no other walker (`git grep
#' walk_call_tree`), and `~/isochrones/R/utils/inspect_r_code.R` --
#' `inspect_r_source()` -- is a different abstraction: it returns collected
#' calls, assignments and formals rather than taking a visitor, and a CI gate
#' here cannot depend on a sibling project being checked out anyway.
#'
#' @family ast
#'
#' @author Tyler Muffly, MD + Claude Code
#' @name ast_walk
NULL

#' Visit every call node in a parse tree
#'
#' @param node a language object: a call, a pairlist, an expression, or a
#'   list of any of those. Anything else is a leaf and is ignored.
#' @param visit [function] called once per call node, with the node. Its
#'   return value is discarded; collect with `<<-`.
#' @return `invisible(NULL)`. Called for its side effects.
#'
#' @section Nodes that cannot be walked:
#' R's call trees carry a special "empty symbol" for omitted arguments -- the
#' blank in `df[, "col"]`, or an `alist()`-style formal. It is not safely
#' indexable or bindable: even a `for` loop's own element-binding step can
#' raise "argument is missing" on it before any check in the loop body runs.
#' It is therefore tested for by comparing a one-element SUBLIST (which never
#' forces it), and every recursive step is additionally guarded, so a node
#' this walker cannot descend into is skipped rather than fatal. That trades a
#' theoretical blind spot -- a call nested inside a construct so unusual it
#' cannot be walked -- for working on arbitrary real-world R source.
walk_call_tree <- function(node, visit) {
  tryCatch({
    if (is.call(node)) {
      visit(node)
      kids <- as.list(node)[-1L]
    } else if (is.pairlist(node) || is.expression(node) || is.list(node)) {
      kids <- as.list(node)
    } else {
      return(invisible(NULL))
    }
    for (i in seq_along(kids)) {
      if (identical(kids[i], list(quote(expr = )))) next
      tryCatch(walk_call_tree(kids[[i]], visit), error = function(e) invisible(NULL))
    }
  }, error = function(e) invisible(NULL))
  invisible(NULL)
}
