# =============================================================================
# Reading a GitHub Actions workflow without a YAML parser
# =============================================================================
# WHY THIS EXISTS. `scan_jobs()` was written for ci_workflow_contracts.R's W1
# gate ("a job may not invoke a tool it never installed"). A second gate --
# test_claim_integrity_saboteurs.R's R1-R3, on package install lists -- needs
# exactly the same decomposition: a workflow into jobs, a job into the shell
# lines it actually runs. Copying it into the second gate would have put a
# top-level function in two tracked files, which is precisely what
# tests/ci_hygiene.R's H4 forbids and for the reason H4 exists: the two copies
# drift and the gates then disagree about what a workflow says.
#
# WHY NOT PARSE THE YAML. Unchanged from W1's own note: neither CI job has a
# YAML library, and adding a parser dependency to the workflow in order to
# check that same workflow declares its dependencies is a circle. The structure
# read here is four lines deep and completely regular.
# =============================================================================

#' Split one workflow into jobs, and each job into its shell command lines
#'
#' Jobs are the two-space keys under `jobs:`. Command lines are the inline form
#' `run: <cmd>` and the bodies of `run: |` block scalars -- NOT arbitrary text,
#' because a step called "Run the Rscript suite" is a name, not an invocation,
#' and a gate that cannot tell those apart fires on comments and gets disabled.
#' @param path [character(1)] workflow file.
#' @return [list] one entry per job: `key`, `name`, `uses`, `cmds`.
scan_jobs <- function(path) {
  ln <- readLines(path, warn = FALSE)
  jobs_at <- grep("^jobs:[[:space:]]*$", ln)
  if (!length(jobs_at)) return(list())
  starts <- grep("^  [A-Za-z0-9_-]+:[[:space:]]*$", ln)
  starts <- starts[starts > jobs_at[1]]
  if (!length(starts)) return(list())
  ends <- c(starts[-1] - 1L, length(ln))

  lapply(seq_along(starts), function(i) {
    block <- ln[starts[i]:ends[i]]
    key <- sub("^  ([A-Za-z0-9_-]+):.*$", "\\1", ln[starts[i]])
    nm <- grep("^    name:", block, value = TRUE)
    cmds <- character(0)
    in_block <- FALSE; block_indent <- NA_integer_
    for (l in block) {
      indent <- nchar(sub("^([[:space:]]*).*$", "\\1", l))
      if (in_block) {
        if (nzchar(trimws(l)) && indent <= block_indent) in_block <- FALSE
        else { cmds <- c(cmds, l); next }
      }
      m <- regmatches(l, regexec("^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*(.*)$", l))[[1]]
      if (length(m) == 3) {
        rest <- trimws(m[3])
        if (rest %in% c("|", ">", "|-", ">-", "")) {
          in_block <- TRUE; block_indent <- indent
        } else {
          cmds <- c(cmds, rest)
        }
      }
    }
    # Shell comments are not invocations. This matters: the fix for #100 left a
    # comment in the Python job explaining why Rscript is absent from it, and a
    # naive scan flags that comment as the very defect it documents.
    cmds <- cmds[!grepl("^[[:space:]]*#", cmds)]
    list(key = key,
         name = if (length(nm)) trimws(sub("^    name:[[:space:]]*", "", nm[1])) else key,
         uses = grep("uses:", block, value = TRUE),
         cmds = cmds)
  })
}
