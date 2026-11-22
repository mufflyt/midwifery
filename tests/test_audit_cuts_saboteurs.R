#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-22 over-engineering cuts
# =============================================================================
# Three cuts, and the two gates that stop them growing back:
#
#   A1 Four `%||%` definitions coexisted with FOUR different meanings, each
#      shadowing base R's at its own call sites. ci_hygiene H4 is the gate
#      against a name defined twice, and it could not see any of them: its
#      pattern started at [.A-Za-z_], so a backtick could not match.
#   A2 Sixteen library() calls attached packages that no call in the file --
#      or in anything it source()s -- ever used. Nothing connects an
#      attachment to its use, so the two drift apart silently.
#   A3 Four functions with no caller anywhere were deleted. The interesting
#      part is what was NOT deleted: six more looked dead by the same first
#      measurement and were not, because they are called from inside their own
#      file. That near miss is pinned below, because the measurement that
#      produced it is the obvious one to reach for again.
#
# Each saboteur reintroduces the defect and requires the guard to fire, so a
# guard that has stopped being able to fail reports as a failure of the guard.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
SAB_PREFIX <- "A"

# A throwaway git repo is the only way to run a gate against planted source:
# both gates ask git which files are tracked, so an untracked fixture is
# invisible to them and every case would pass vacuously.
scaffold_repo <- function(dir, gate) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "R", "lib"), recursive = TRUE, showWarnings = FALSE)
  file.copy(file.path(root, "tests", gate), file.path(dir, "tests", gate))
  file.copy(file.path(root, "tests", "ci_report.R"),
            file.path(dir, "tests", "ci_report.R"))
  # A .gitignore, because ci_hygiene's H3 reads one and dies on its absence --
  # which made the FIRST version of these cases "pass" without ever reaching
  # H4. A saboteur that is satisfied by an unrelated error is not testing the
  # guard it names; see docs/APPENDIX_checks_that_cannot_fail_2026-11-20.md.
  writeLines(c("*.tmp"), file.path(dir, ".gitignore"))
  system2("git", c("-C", dir, "init", "-q"), stdout = FALSE, stderr = FALSE)
}

# A scaffold that is CLEAN must pass, or every rejection below could be the
# scaffold's own fault rather than the planted defect's.
control_is_clean <- function(gate, plant) {
  dir <- file.path(tempdir(), paste0("ctl", sample.int(1e6, 1)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scaffold_repo(dir, gate)
  plant(dir)
  !gate_rejects(dir, gate)
}

write_lines_to <- function(dir, rel, lines) {
  p <- file.path(dir, rel)
  dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, p)
}

# Tracked .R/.qmd paths, asked of git with no shell in the way.
ci_tracked_files <- function(root) {
  out <- suppressWarnings(system2("git",
    c("-C", shQuote(root), "ls-files", shQuote("*.R"), shQuote("*.qmd")),
    stdout = TRUE, stderr = FALSE))
  if (!length(out)) character(0) else out
}

gate_rejects <- function(dir, gate) {
  system2("git", c("-C", dir, "add", "-A"), stdout = FALSE, stderr = FALSE)
  st <- suppressWarnings(system2("sh", c("-c",
    shQuote(sprintf("cd %s && Rscript tests/%s", shQuote(dir), gate))),
    stdout = NULL, stderr = NULL))
  !identical(as.integer(st), 0L)
}

audit_case <- function(label, gate, plant, expect_reject = TRUE) {
  dir <- file.path(tempdir(), paste0("aud", sample.int(1e6, 1)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scaffold_repo(dir, gate)
  plant(dir)
  chk(identical(gate_rejects(dir, gate), expect_reject), label)
}

# --- A1 a second definition of an operator ------------------------------------
sab(1, "H4 sees a function defined twice even when its name is an operator")

chk(control_is_clean("ci_hygiene.R", function(d) {
      write_lines_to(d, "a.R", c("z <- 1"))
      write_lines_to(d, "b.R", c("q <- 2"))
    }), "A1-control an empty scaffold passes ci_hygiene, so a rejection below means the planted defect")

audit_case("A1a KILLED: the same `%||%` defined in two files is caught",
         "ci_hygiene.R",
         function(d) {
           write_lines_to(d, "a.R", c('`%||%` <- function(x, y) if (is.null(x)) y else x',
                                      'z <- 1'))
           write_lines_to(d, "b.R", c('`%||%` <- function(a, b) if (length(a)) a else b',
                                      'q <- 2'))
         })

audit_case("A1b near miss: two DIFFERENTLY named operators are not a duplicate",
         "ci_hygiene.R",
         function(d) {
           write_lines_to(d, "a.R", c('`%|na|%` <- function(a, b) if (all(is.na(a))) b else a',
                                      'z <- 1'))
           write_lines_to(d, "b.R", c('`%|blank|%` <- function(a, b) if (!length(a)) b else a',
                                      'q <- 2'))
         }, expect_reject = FALSE)

# The fix itself: no hand-rolled %||% survives, and base R supplies one.
defs <- unlist(lapply(
  list.files(root, pattern = "\\.R$", recursive = TRUE, full.names = TRUE),
  function(f) grep("^`%\\|\\|%` *<- *function",
                   tryCatch(readLines(f, warn = FALSE), error = function(e) character(0)),
                   value = TRUE)))
chk(length(defs) == 0L, "A1c no hand-rolled `%||%` is left in the tree")
chk(exists("%||%", envir = baseenv()),
    "A1d ... because base R supplies one, which is why the copies could go")

# --- A2 an attached package nothing uses --------------------------------------
sab(2, "an attachment with no use is caught, and a used one is not")

audit_case("A2a KILLED: library() for a package the file never calls is caught",
         "ci_unused_dependencies.R",
         function(d) write_lines_to(d, "s.R", c("library(tools)", "x <- 1 + 1")))

audit_case("A2b near miss: a package the file DOES call is not flagged",
         "ci_unused_dependencies.R",
         function(d) write_lines_to(d, "s.R",
           c("library(tools)", 'x <- toTitleCase("a b")')),
         expect_reject = FALSE)

audit_case("A2c near miss: use via pkg:: counts, with no call token at all",
         "ci_unused_dependencies.R",
         function(d) write_lines_to(d, "s.R",
           c("library(tools)", 'x <- tools::toTitleCase("a b")')),
         expect_reject = FALSE)

# THE FALSE POSITIVE THAT WOULD HAVE BROKEN 29 SCRIPTS. Six R/lib files call
# read_csv() and friends unqualified, so a script that source()s one must
# attach readr for code it never names. Judging the file alone reported all of
# them as carrying an unused readr.
audit_case("A2d near miss: a package used only by a source()d file is not flagged",
         "ci_unused_dependencies.R",
         function(d) {
           write_lines_to(d, "R/lib/helper.R", c('reader <- function(p) toTitleCase(p)'))
           write_lines_to(d, "s.R", c("library(tools)",
                                      'source(file.path("R", "lib", "helper.R"))',
                                      'x <- reader("a b")'))
         }, expect_reject = FALSE)

# --- A3 the deleted functions, and the ones that only looked deleted ----------
sab(3, "dead functions are gone; functions used inside their own file are not")

gone <- c("wonder_request_xml", "wonder_post", "load_mysterymaps",
          "source_coverage_columns")

# READ THE FILES, DO NOT SHELL OUT. system2() pastes its arguments into a
# shell command, so `*.R` was glob-expanded by the shell against the top-level
# directory before git ever saw it -- git grep then searched root-level files
# only, never R/lib/, and this check could not fail. It reported "all 4 stay
# gone" while three references to wonder_post() sat in
# R/lib/wonder_natality.R. Reading tracked files directly has no quoting
# layer to get wrong.
tracked <- ci_tracked_files(root)
tracked <- tracked[!grepl("test_audit_cuts_saboteurs\\.R$", tracked)]
still <- vapply(gone, function(fn) {
  any(vapply(tracked, function(f) {
    txt <- tryCatch(readLines(file.path(root, f), warn = FALSE),
                    error = function(e) character(0))
    any(grepl(sprintf("\\b%s\\b", fn), txt))
  }, logical(1)))
}, logical(1))
chk(!any(still), sprintf("A3a all %d deleted functions stay gone (%s)",
                         length(gone), paste(names(which(still)), collapse = ", ")))

# THE MISTAKE, PINNED. These six were reported dead by a grep that excluded the
# file defining them, which hides every caller inside the same module. They are
# live and must stay. A measurement that cannot tell this apart from real death
# is not good enough to delete on.
kept <- c("digest_file_sha256" = "R/lib/source_coverage.R",
          "pct_or_na"          = "R/lib/geographic_persistence_stats.R",
          "git_commit_date"    = "R/lib/source_vintage.R",
          "freeze_running_script" = "R/lib/cohort_definitions.R",
          "ensure_file_exists" = "R/lib/match_npi_to_hospitals.R",
          "build_ob_hospitals_artifact" = "R/lib/match_npi_to_hospitals.R")
alive <- vapply(seq_along(kept), function(i) {
  fn <- names(kept)[i]
  txt <- readLines(file.path(root, kept[[i]]), warn = FALSE)
  code <- txt[!grepl("^\\s*#", txt)]
  # a call, not the definition line
  any(grepl(sprintf("\\b%s\\s*\\(", fn), code) & !grepl(sprintf("^%s\\s*<-", fn), code))
}, logical(1))
chk(all(alive),
    sprintf("A3b the %d functions called only from inside their own file are still present (%s)",
            length(kept), paste(names(kept)[!alive], collapse = ", ")))

saboteur_report(3)
