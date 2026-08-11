# =============================================================================
# Which scripts depend on the frozen cohort, and what do they produce?
# =============================================================================
#
# WHY THIS EXISTS. A re-freeze is only safe if every artifact derived from the
# old cohort is rebuilt from the new one. There is no pipeline runner in this
# repo -- 14 numbered stages plus a layer of root scripts, with no 00-master,
# no Makefile, no _targets.R, and nothing that sources two or more stages. The
# execution order lives in an operator's head. Rebuilding "everything
# downstream" by hand, in the wrong order, produces artifacts built from a
# HALF-UPDATED cohort, which is precisely the failure a freeze exists to
# prevent -- and it would look like success.
#
# So the dependency set is DISCOVERED here rather than remembered, and the
# runner fails if the discovered set and the declared set disagree.
#
# WHAT THIS CANNOT DO, stated plainly. Static analysis cannot resolve every
# output path: scripts build paths with file.path(), sprintf() and variables.
# Those are reported as UNRESOLVED rather than silently omitted, because an
# output this cannot see is exactly an output the rebuild would miss.
# =============================================================================

FROZEN_PATH <- "artifacts/amcb_npi_linkage_FROZEN.csv"

#' Source files in scope: repo root and R/, excluding tests, libs and archives.
frozen_scan_files <- function(root = ".") {
  f <- c(list.files(root, "\\.R$", full.names = FALSE),
         list.files(file.path(root, "R"), "\\.R$", recursive = TRUE,
                    full.names = TRUE))
  f <- unique(f[!grepl("^tests/|/lib/|@archive|@deprecated|_trash|R_temp_backup", f)])
  # THE SCANNER MUST NOT SCAN ITSELF. This file names the frozen artifact and
  # contains the network regex as string literals, so a naive sweep classified
  # it as a network-dependent consumer of the cohort. A tool that appears in
  # its own inventory inflates the rebuild set and, worse, makes the
  # completeness check fail for a reason that has nothing to do with the data.
  f <- f[!basename(f) %in% c("frozen_dependency_graph.R",
                             "rebuild_frozen_dependents.R")]
  # Normalise "./x.R" and "x.R" to one form, or the declared set and the
  # discovered set compare unequal on identical scripts.
  f <- sub("^\\./", "", f)
  f[file.exists(f)]
}

#' Strip comments before scanning: a script that only MENTIONS the frozen file
#' in a comment is not a consumer, and counting it would inflate the rebuild.
.code_only <- function(path) {
  ln <- readLines(path, warn = FALSE)
  paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
}

#' Discover every script that reads the frozen cohort, with its properties.
#'
#' @return data.frame: script, reads_frozen, network, writes, outputs (|-joined),
#'   n_unresolved_writes.
frozen_consumers <- function(root = ".") {
  files <- frozen_scan_files(root)
  rows <- lapply(files, function(f) {
    code <- .code_only(f)
    # Literal output paths we can actually see.
    outs <- unlist(regmatches(code, gregexpr(
      '(write_csv|write\\.csv|saveRDS|write_json|write_with_provenance|ggsave)\\s*\\([^\\n]*?"([^"]+\\.(csv|rds|json|png|html))"',
      code, perl = TRUE)))
    outs <- unique(unlist(regmatches(outs, gregexpr('"[^"]+\\.(csv|rds|json|png|html)"', outs))))
    outs <- gsub('"', '', outs)
    # Writes whose destination is computed rather than literal.
    n_write_calls <- length(unlist(regmatches(code, gregexpr(
      '(write_csv|write\\.csv|saveRDS|write_json|write_with_provenance|ggsave)\\s*\\(', code))))
    data.frame(
      script = sub("^\\./", "", f),
      reads_frozen = grepl("amcb_npi_linkage_FROZEN", code, fixed = TRUE),
      network = grepl("httr|curl|GET\\(|POST\\(|read_html|RSelenium|chromote|download\\.file|rvest",
                      code),
      n_write_calls = n_write_calls,
      outputs = paste(outs, collapse = "|"),
      n_unresolved_writes = max(0L, n_write_calls - length(outs)),
      stringsAsFactors = FALSE)
  })
  d <- do.call(rbind, rows)
  d[d$reads_frozen, , drop = FALSE]
}

#' Scripts that can be rebuilt deterministically.
#'
#' Network/scraping scripts are EXCLUDED and reported. They re-acquire data from
#' the outside world, so re-running them is not a rebuild -- it is a new
#' observation, and it would change inputs the freeze is meant to hold still.
frozen_rebuildable <- function(consumers = frozen_consumers()) {
  consumers[!consumers$network, , drop = FALSE]
}

#' Coverage report: what the rebuild can and cannot guarantee.
frozen_dependency_report <- function(root = ".") {
  cons <- frozen_consumers(root)
  reb <- frozen_rebuildable(cons)
  list(
    n_consumers = nrow(cons),
    n_network_excluded = sum(cons$network),
    n_rebuildable = nrow(reb),
    n_with_resolved_outputs = sum(nzchar(reb$outputs)),
    n_with_unresolved_writes = sum(reb$n_unresolved_writes > 0),
    unresolved = reb$script[reb$n_unresolved_writes > 0],
    network_excluded = cons$script[cons$network],
    consumers = cons)
}
