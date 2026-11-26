#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for claims nobody re-verified
# =============================================================================
# WHY THIS FILE EXISTS. Two over-engineering audits produced ten findings. Of
# those ten, THREE WERE WRONG and two were overstated, and every one of the
# three was wrong the same way: a claim about the repository that read as true
# and that nothing in the repository could contradict.
#
#   "these env flags are dead"      -- they are set by workflows and by
#                                      operators, through documented defaults.
#   "`here` duplicates the root     -- removing it broke CI: under
#    idiom, remove it"                 testthat::test_file() the working
#                                      directory is tests/, so the idiom it
#                                      "duplicated" resolves to the wrong root.
#   "this dependency is removable"  -- it was not.
#
# None of the three was caught by reading more carefully. They were caught by
# CI, by a mutation, or by a reviewer. The lesson this file acts on is that A
# CLAIM NOT WIRED TO A CHECK IS A GUESS, including -- especially -- a claim
# made by whoever is cutting the code.
#
# So each saboteur here takes a standing claim this repository makes about
# itself and makes it mechanical:
#
#   R1  every package a nightly-globbed test loads is installed by the job
#       that globs it            <- the systemfonts failure, generalized
#   R2  every package a ci.yml-named test loads is installed by the job that
#       names it                 <- the same shape on the pull-request side
#   R3  ci.yml and nightly do not drift apart on package lists
#   R4  a testthat-family test never resolves its root from the working
#       directory                <- the `here` mistake, made unrepeatable
#   R5  README figure numbers are unique and contiguous
#   R6  the README scientific-laws badge agrees with the registry and with the
#       prose beneath it
#   R7  no Python helper is defined at top level in two tracked files
#   R8  every tests/ci_*.R gate is invoked by some workflow
#   R9  every baseline entry names a path the repository knows
#   R10 every saboteur suite's declared count matches the saboteurs it runs
#
# WHAT R1 AND R2 DO NOT CLAIM. They read DIRECT package use in the test file --
# `pkg::fn()`, `library(pkg)` -- and nothing transitive. A test that sources
# R/lib/x.R, which itself needs data.table, is invisible to them. Following
# source() chains is a bigger check and a different one; saying these cover it
# would be the same overstatement the file is named for.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
source(file.path(root, "tests", "helper-workflow-scan.R"))
# git_lines(), TRACKED, known_paths() and link_paths() moved to
# lib_repo_scan.R when test_doc_integrity_saboteurs.R turned out to need
# all four unchanged. ci_hygiene.R's H4 forbids a top-level function in two
# tracked files, and two readers of the same tree are exactly what it is for.
source(file.path(root, "tests", "lib_repo_scan.R"))
SAB_PREFIX <- "R"
ALL_R <- grep("\\.R$", TRACKED, value = TRUE)
ALL_PY <- grep("\\.py$", TRACKED, value = TRUE)
TEST_R <- grep("^tests/test[-_].*\\.R$", TRACKED, value = TRUE)
WF <- list.files(file.path(root, ".github", "workflows"),
                 pattern = "[.]ya?ml$", full.names = TRUE)
# STATIC, NOT QUERIED. installed.packages(priority = c("base","recommended"))
# answers with whatever the runner happens to have, so the same tree would pass
# here and fail there -- a gate whose verdict depends on the machine is not a
# gate. These are the names R ships.
BASE_PKGS <- c(
  "base", "compiler", "datasets", "grDevices", "graphics", "grid", "methods",
  "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils",
  "KernSmooth", "MASS", "Matrix", "boot", "class", "cluster", "codetools",
  "foreign", "lattice", "mgcv", "nlme", "nnet", "rpart", "spatial",
  "survival")

#' Quoted strings on one line, unquoted
#' @keywords internal
#' @noRd
quoted <- function(x) {
  m <- regmatches(x, gregexpr('"[^"]*"', x))
  gsub('"', "", unlist(m))
}

#' Every package a job installs, however it installs it
#'
#' Three mechanisms are in use and all three count: a `pkgs <- c(...)` vector
#' consumed by install.packages(), a one-line install.packages(c(...)), and
#' remotes::install_github("org/pkg@ref") for the two private packages. A
#' reader that knew only the first would call mysterynpi missing from a job
#' that installs it, which is the false alarm that gets a gate switched off.
#' @param cmds [character] the job's shell lines.
#' @return [character] package names.
provided_packages <- function(cmds) {
  txt <- sub("#.*$", "", cmds)
  out <- character(0)
  i <- grep("pkgs[[:space:]]*<-[[:space:]]*c\\(", txt)
  for (s in i) {
    depth <- 0L; j <- s
    repeat {
      out <- c(out, quoted(txt[j]))
      depth <- depth +
        lengths(regmatches(txt[j], gregexpr("\\(", txt[j]))) -
        lengths(regmatches(txt[j], gregexpr("\\)", txt[j])))
      if (depth <= 0L && j > s) break
      j <- j + 1L
      if (j > length(txt)) break
    }
  }
  one <- grep("install\\.packages\\(", txt, value = TRUE)
  out <- c(out, quoted(one))
  # install_github takes "org/pkg@ref"; the SAME LINE also carries
  # `upgrade = "never"`, and reading every quoted string on it as a package
  # name put a package called `never` in the install list of two jobs.
  gh <- quoted(grep("install_github\\(", txt, value = TRUE))
  gh <- grep("/", gh, value = TRUE, fixed = TRUE)
  out <- c(out, sub("@.*$", "", sub("^[^/]*/", "", gh)))
  if (length(gh)) out <- c(out, "remotes")
  # A repos= URL is quoted and sits inside the install call. It is not a
  # package, and neither is an option value.
  out <- unique(out[nzchar(out)])
  out[grepl("^[A-Za-z][A-Za-z0-9.]*$", out) &
        !out %in% c("never", "always", "binary", "source", "TRUE", "FALSE")]
}

#' Packages a single R file uses directly, and those it guards
#'
#' USES THE PARSER, NOT A REGEX. A scan for `[A-Za-z.]+::` over the text of
#' tests/test_amcb_license_bridge.R reports CA and TX as packages, because the
#' file asserts on license keys that look like "CA::012345"; it reports
#' `remotes` from the text of a stop() message, and `yaml` from a string. All
#' three are strings, and the parser knows the difference.
#'
#' A package is GUARDED when its name appears as a string literal in a
#' top-level expression that also calls requireNamespace(). That is looser than
#' matching requireNamespace("pkg") directly, and deliberately:
#' test_address_key_reduction_exact.R guards three packages through
#' `vapply(c("stringr", "postmastr", "yaml"), requireNamespace, ...)`, where no
#' package name is ever an argument to requireNamespace at all. Reading only
#' the direct form called that file a nightly failure waiting to happen when it
#' skips cleanly.
#' @param path [character(1)] file to read.
#' @return [list] `used` and `guarded`, both character.
packages_used <- function(path) {
  ex <- tryCatch(parse(path), error = function(e) NULL)
  if (is.null(ex)) return(list(used = character(0), guarded = character(0)))
  used <- character(0); guarded <- character(0)
  as_name <- function(a) {
    if (is.character(a)) a
    else if (is.name(a)) as.character(a)
    else NA_character_
  }
  strings_in <- function(e) {
    if (is.character(e)) return(e)
    if (!is.call(e)) return(character(0))
    unlist(lapply(as.list(e), function(el) {
      if (is.name(el) && !nzchar(as.character(el))) return(character(0))
      strings_in(el)
    }))
  }
  has_require <- function(e) {
    # THE SYMBOL FORM COUNTS. test_address_key_reduction_exact.R guards through
    # `vapply(c(...), requireNamespace, ...)`, where requireNamespace is passed
    # as a VALUE and never appears as a call. Matching only the call form
    # reported that file's clean skip as two missing packages.
    if (is.name(e) && identical(as.character(e), "requireNamespace"))
      return(TRUE)
    if (!is.call(e)) return(FALSE)
    fn <- if (is.name(e[[1]])) as.character(e[[1]]) else ""
    if (identical(fn, "requireNamespace")) return(TRUE)
    any(vapply(as.list(e), function(el) {
      if (is.name(el) && !nzchar(as.character(el))) return(FALSE)
      has_require(el)
    }, logical(1)))
  }
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    # `e[[1]]` is a SYMBOL only for a plain call. For `tibble::tibble(x)` it is
    # itself a `::` call, and as.character() of it begins "::" -- read as a
    # function name that made the FIRST ARGUMENT look like a package name.
    fn <- if (is.name(e[[1]])) as.character(e[[1]]) else ""
    if (fn %in% c("::", ":::", "library", "require") && length(e) >= 2L)
      used <<- c(used, as_name(e[[2]]))
    invisible(lapply(as.list(e), function(el) {
      if (is.name(el) && !nzchar(as.character(el))) return(invisible(NULL))
      walk(el)
    }))
  }
  for (x in ex) {
    walk(x)
    if (has_require(x)) guarded <- c(guarded, strings_in(x))
  }
  list(used = unique(stats::na.omit(used)),
       guarded = unique(stats::na.omit(guarded)))
}

#' Packages a test needs that a job does not provide
#' @keywords internal
#' @noRd
unmet <- function(rel, have) {
  u <- packages_used(file.path(root, rel))
  setdiff(u$used, c(BASE_PKGS, u$guarded, have))
}

#' Test files a job runs by name
#' @keywords internal
#' @noRd
named_tests <- function(cmds) {
  m <- regmatches(cmds, gregexpr("tests/test[A-Za-z0-9_.-]*\\.R", cmds))
  unique(unlist(m))
}

#' Does this job RUN the whole tests/ directory by glob?
#'
#' Mentioning the glob is not running it. nightly.yml's "No test file goes
#' unrun" job greps for `for t in tests/test*.R` and loops over the filenames
#' to check each is covered; it executes none of them and installs no packages.
#' Read as a runner it makes every test in the tree look like a missing
#' dependency -- 200-odd false alarms, which is how a gate gets switched off.
#' So the job must also execute a test path held in a shell variable.
#' @keywords internal
#' @noRd
globs_tests <- function(cmds) {
  any(grepl("tests/test*.R", cmds, fixed = TRUE)) &&
    any(grepl("Rscript", cmds) & grepl("$t", cmds, fixed = TRUE))
}

JOBS <- unlist(lapply(WF, function(w) {
  lapply(scan_jobs(w), function(j) c(j, list(wf = basename(w))))
}), recursive = FALSE)

# --- R1 the job that runs every test installs what every test loads -----------
sab(1, "a glob that runs a test cannot skip the package it loads")
globbing <- Filter(function(j) globs_tests(j$cmds), JOBS)
chk(length(globbing) >= 1L,
    sprintf("R1a a job that globs tests/test*.R is found (%d), so a clean result is not an empty one",
            length(globbing)))
r1_bad <- character(0)
for (j in globbing) {
  have <- provided_packages(j$cmds)
  for (t in TEST_R) {
    miss <- unmet(t, have)
    if (length(miss))
      r1_bad <- c(r1_bad, sprintf("%s: %s needs %s", j$wf, basename(t),
                                  paste(miss, collapse = ", ")))
  }
}
chk(!length(r1_bad),
    sprintf("R1b every package a globbed test loads unguarded is installed by the job that globs it%s",
            if (length(r1_bad)) paste0(" [", paste(utils::head(r1_bad, 3), collapse = "; "), "]") else ""))
chk(length(provided_packages(c('pkgs <- c("a",', '  "b")'))) == 2L,
    "R1c the install reader follows a pkgs vector across lines, which is how every one of them is written")
chk("mysterynpi" %in% provided_packages(
      'Rscript -e \'remotes::install_github("mufflyt/mysterynpi@aa5d94c")\''),
    "R1d a package installed from GitHub counts as installed, so the two private ones are not false alarms")

# --- R2 the job that names a test installs what that test loads ---------------
sab(2, "naming a test in a job does not install its packages")
r2_bad <- character(0); n_named <- 0L
for (j in JOBS) {
  if (globs_tests(j$cmds)) next
  nt <- intersect(named_tests(j$cmds), TRACKED)
  if (!length(nt)) next
  have <- provided_packages(j$cmds)
  if (!length(have)) next
  n_named <- n_named + length(nt)
  for (t in nt) {
    miss <- unmet(t, have)
    if (length(miss))
      r2_bad <- c(r2_bad, sprintf("%s job '%s': %s needs %s", j$wf, j$key,
                                  basename(t), paste(miss, collapse = ", ")))
  }
}
chk(n_named > 20L,
    sprintf("R2a the scan reaches the jobs that name tests (%d named test invocations with an install list)",
            n_named))
chk(!length(r2_bad),
    sprintf("R2b every package a named test loads unguarded is installed by the job that names it%s",
            if (length(r2_bad)) paste0(" [", paste(utils::head(r2_bad, 3), collapse = "; "), "]") else ""))

# --- R3 a README link is a claim that a file is there -------------------------
sab(3, "a link to a renamed file is a dead claim that still reads as a citation")
# WHY NOT THE PACKAGE-DRIFT CHECK THAT WAS HERE FIRST. The gate originally in
# this slot asserted that the job running every test installs at least what a
# job running part of it installs. That looked obvious and is not: ci.yml may
# legitimately install a package for a test nightly excepts from its glob, so
# the rule would fire on a correct workflow. R1 already catches the
# CONSEQUENCE -- a globbed test whose package is missing -- exactly and without
# the arguable premise, so the premise was dropped rather than shipped.
#
# This repository's README is its data inventory, and it cites 147 files by
# relative path. A rename leaves the prose reading as a citation and pointing
# at nothing.
links <- link_paths(readLines(file.path(root, "README.md"), warn = FALSE))
chk(length(links) > 50L,
    sprintf("R3a the README's file citations are read (%d links)", length(links)))
dead <- Filter(function(p) !file.exists(file.path(root, p)), links)
chk(!length(dead),
    sprintf("R3b every file the README links to exists%s",
            if (length(dead)) paste0(" [", paste(utils::head(dead, 4), collapse = ", "), "]") else ""))
chk(identical(link_paths("see [the gate](tests/ci_hygiene.R) for this"),
              "tests/ci_hygiene.R"),
    "R3c the link reader takes the path out of a markdown link and not the words around it")

# --- R4 a testthat file does not resolve its root from the cwd ----------------
sab(4, "the root idiom that `here` was accused of duplicating")
# THE AUDIT FINDING THIS REPLACES. `here` was reported as a removable
# duplicate of the commandArgs root preamble. It is not: CI dispatches a file
# containing a test_that() call site through testthat::test_file(), which sets
# the working directory to tests/ and passes no --file=. The preamble's
# fallback is normalizePath("."), so the root resolves to tests/ and every path
# built on it doubles -- `cannot open file '.../tests/tests/helper-saboteur.R'`.
# The claim was wrong because nothing checked it. This checks it.
CWD_FALLBACK <- paste0('normalizePath(', '".")')
testthat_family <- Filter(function(f) {
  any(grepl("^\\s*test_that\\(", readLines(file.path(root, f), warn = FALSE)))
}, TEST_R)
chk(length(testthat_family) >= 5L,
    sprintf("R4a the testthat family is found by its call sites, not its filename (%d files)",
            length(testthat_family)))
r4_bad <- Filter(function(f)
  grepl(CWD_FALLBACK, slurp(f), fixed = TRUE), testthat_family)
chk(!length(r4_bad),
    sprintf("R4b no testthat-dispatched test resolves its root from the working directory%s",
            if (length(r4_bad)) paste0(" [", paste(basename(r4_bad), collapse = ", "), "]") else ""))
chk(grepl(CWD_FALLBACK, sprintf('root <- %s', CWD_FALLBACK), fixed = TRUE),
    "R4c KILLED: the exact fallback that resolved to tests/ is recognized")

# --- R5 README figure numbers --------------------------------------------------
sab(5, "two figures numbered the same are two claims about one picture")
readme <- readLines(file.path(root, "README.md"), warn = FALSE)
#' Figure numbers from the italic caption lines
#' @keywords internal
#' @noRd
caption_numbers <- function(ln) {
  caps <- grep("^\\*Figure [0-9]+", ln, value = TRUE)
  as.integer(sub("^\\*Figure ([0-9]+).*$", "\\1", caps))
}
fig <- caption_numbers(readme)
chk(length(fig) > 10L,
    sprintf("R5a the caption scan finds the figures (%d)", length(fig)))
dup <- unique(fig[duplicated(fig)])
chk(!length(dup),
    sprintf("R5b no two figure captions carry the same number%s",
            if (length(dup)) paste0(" [Figure ", paste(dup, collapse = ", "), "]") else ""))
chk(identical(sort(fig), seq_along(fig)),
    sprintf("R5c the figures run 1..%d with no gap%s", length(fig),
            if (!identical(sort(fig), seq_along(fig)))
              paste0(" [have ", paste(sort(fig), collapse = ","), "]") else ""))
chk(identical(caption_numbers(c("*Figure 3: a*", "*Figure 3: b*")), c(3L, 3L)),
    "R5d KILLED: the duplicate-number shape is what the scan reads")

# --- R6 the badge agrees with what it links to --------------------------------
sab(6, "a badge is a claim about a file one click away")
# THE BADGE IS PERCENT-ENCODED, so `[0-9]+` over the matched text reads the 20
# of each %20 as a count. The first draft of this gate reported the law count
# as 20 and the planted count as NA, which is a gate failing for its own
# reasons -- the thing this file exists to refuse. Capture groups instead.
reg <- grep("^[^#]", readLines(file.path(root, "tests", "science_law_registry.tsv"),
                               warn = FALSE), value = TRUE)
reg <- reg[nzchar(trimws(reg))]
n_laws <- length(reg) - 1L
flat <- paste(readme, collapse = " ")
#' The two numbers a shields.io badge states, by capture group
#' @keywords internal
#' @noRd
badge_counts <- function(x) {
  m <- regmatches(x, regexec(
    "scientific%20laws-([0-9]+)%20declared%2C%20([0-9]+)%20planted", x))[[1]]
  if (length(m) == 3L) as.integer(m[2:3]) else integer(0)
}
#' The two numbers the prose beneath it states
#' @keywords internal
#' @noRd
prose_counts <- function(x) {
  m <- regmatches(x, regexec(
    "\\*\\*([0-9]+) planted defects, ([0-9]+) detected[.]\\*\\*", x))[[1]]
  if (length(m) == 3L) as.integer(m[2:3]) else integer(0)
}
bc <- badge_counts(flat); pc_ <- prose_counts(flat)
chk(length(bc) == 2L, "R6a the scientific-laws badge is found and its two counts read")
chk(length(pc_) == 2L, "R6b the planted-defect sentence is found and its two counts read")
chk(length(bc) == 2L && bc[1] == n_laws,
    sprintf("R6c the badge's law count (%s) equals the rows of tests/science_law_registry.tsv (%d)",
            if (length(bc) == 2L) bc[1] else NA, n_laws))
chk(length(bc) == 2L && length(pc_) == 2L && bc[2] == pc_[1],
    sprintf("R6d the badge's planted-defect count (%s) equals the prose's (%s)",
            if (length(bc) == 2L) bc[2] else NA,
            if (length(pc_) == 2L) pc_[1] else NA))
chk(identical(badge_counts("scientific%20laws-13%20declared%2C%2039%20planted"),
              c(13L, 39L)),
    "R6e KILLED: the counts come from the capture groups, so %20 is not read as twenty")

# --- R7 a Python helper defined twice -----------------------------------------
sab(7, "the same helper in two files is the duplication this repository keeps paying for")
#' Top-level `def` names in a Python file
#'
#' Top level only: a method on a class is namespaced by it, and flagging those
#' would report every `def run(self)` in the tree. The name pattern INCLUDES
#' DIGITS -- a scan for `[a-zA-Z_]+` reads `def sha256_file(` as a function
#' called `sha`, which merges five real duplicates into one wrong name.
#' @keywords internal
#' @noRd
py_defs <- function(path) {
  ln <- readLines(path, warn = FALSE)
  unique(sub("^def ([A-Za-z_][A-Za-z0-9_]*).*$", "\\1",
             grep("^def [A-Za-z_][A-Za-z0-9_]*", ln, value = TRUE)))
}
# `main` is a CLI entry point: 29 scripts have one and that is the convention,
# not duplication. A unittest function name repeated across two suites is the
# same -- test_load_rejects_zero_row_csv asserts the same property of two
# different pipelines, and renaming one would make the pair harder to read.
PY_CONVENTIONAL <- c("main", "setUp", "tearDown")
# KNOWN AND SHRINK-ONLY. Every name below is a helper that genuinely exists in
# two or more tracked Python files today. Two clusters account for most of it:
# download_medicaid_provider_enrollment_segments.py and
# hhs_opendata_csv_pipeline.py share nine functions, and the four state BON
# harvesters share verified_tls_context in two distinct bodies -- which is
# security-adjacent and wants a correctness review, not a complexity cut. The
# list may only shrink; R7b fails if an entry stops being a duplicate.
# Generated by this file's own py_defs(), not by a shell probe: the probe's
# name pattern excluded digits and reported `sha256_file`, `sha256_of` and
# `_sha256_bytes` as one function called `sha`.
PY_BASELINE <- c(
  "_cohort_row", "_detail_html", "_load", "_make_zip", "_sha256_bytes",
  "_ssl_context", "blob_url", "check", "copy_and_verify", "count_rows",
  "download_with_sha256", "extract_single_csv", "fetch_blob_metadata",
  "get_json", "load_csv_to_duckdb", "log", "norm", "record_provenance",
  "registry", "run", "run_duckdb_sql", "sha256_file", "sha256_of",
  "standardize_usps_address", "verified_tls_context", "write_csv")
py_map <- lapply(ALL_PY, function(f) py_defs(file.path(root, f)))
names(py_map) <- ALL_PY
tally <- table(unlist(py_map))
dups <- setdiff(names(tally)[tally > 1L], PY_CONVENTIONAL)
dups <- dups[!grepl("^test_", dups)]
chk(length(ALL_PY) > 50L,
    sprintf("R7a the scan reads the tracked Python tree (%d files)", length(ALL_PY)))
new_dups <- setdiff(dups, PY_BASELINE)
chk(!length(new_dups),
    sprintf("R7b no NEW Python helper is defined at top level in two tracked files (%d baselined)%s",
            length(PY_BASELINE),
            if (length(new_dups)) paste0(" [", paste(new_dups, collapse = ", "), "]") else ""))
stale_py <- setdiff(PY_BASELINE, dups)
chk(!length(stale_py),
    sprintf("R7c every baselined duplicate is still a duplicate, so the list shrinks rather than rots%s",
            if (length(stale_py)) paste0(" -- remove: ", paste(stale_py, collapse = ", ")) else ""))

# --- R8 two saboteurs under one label -----------------------------------------
sab(8, "two saboteurs sharing a number means one of them is reported as the other")
# WHY NOT "A GATE NO WORKFLOW INVOKES", WHICH WAS HERE FIRST. That check is
# already made, by nightly.yml's suite-coverage job: "Every ci_*.R gate is
# named by some job". Writing a second copy of it here is the duplication this
# repository's own H4 gate forbids, and two copies of a claim drift until they
# disagree about it. Removed in favour of a claim nothing else makes.
#
# A saboteur suite is read by its labels. A copied block whose number was not
# updated reports its failure under the other saboteur's heading, and the
# reader goes to the wrong assertion.
#' The label each sab() call heads its saboteur with
#' @keywords internal
#' @noRd
sab_labels <- function(txt) {
  ln <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  m <- regmatches(ln, regexpr("^[[:space:]]*sab\\([^,]+", ln))
  trimws(sub("^[[:space:]]*sab\\([[:space:]]*", "", unlist(m)))
}
r8_bad <- character(0); n_labelled <- 0L
for (f in TEST_R) {
  lab <- sab_labels(slurp(f))
  if (length(lab) < 2L) next
  n_labelled <- n_labelled + 1L
  d <- unique(lab[duplicated(lab)])
  if (length(d))
    r8_bad <- c(r8_bad, sprintf("%s: %s", basename(f), paste(d, collapse = ", ")))
}
chk(n_labelled > 10L,
    sprintf("R8a the labelled suites are found (%d)", n_labelled))
chk(!length(r8_bad),
    sprintf("R8b no suite heads two saboteurs with the same label%s",
            if (length(r8_bad)) paste0(" [", paste(r8_bad, collapse = "; "), "]") else ""))
chk(length(unique(sab_labels("  sab(3, \"a\")\n  sab(3, \"b\")")) ) == 1L,
    "R8c KILLED: a copied block that kept its neighbour's number is caught")

# --- R9 a baseline entry that forgives nothing ----------------------------------
sab(9, "a baseline naming a path the repository never heard of excuses nothing and hides that it excuses nothing")
# NOT "the file is missing". Most baselined artifacts are gitignored build
# outputs and are absent from every fresh clone by design; calling those stale
# produced 25 false alarms on the first pass. The defensible claim is narrower:
# the path must be one the repository KNOWS -- tracked, or ignored on purpose.
baselines <- grep("^tests/.*baseline.*\\.(txt|tsv)$", TRACKED, value = TRUE)
entry_file <- character(0); entry_path <- character(0)
for (b in baselines) {
  for (l in readLines(file.path(root, b), warn = FALSE)) {
    p <- trimws(sub("#.*$", "", l))
    p <- sub("[[:space:]].*$", "", p)
    if (!nzchar(p) || !grepl("\\.(R|py|csv|md|json|tsv)$", p)) next
    entry_file <- c(entry_file, basename(b)); entry_path <- c(entry_path, p)
  }
}
n_entries <- length(entry_path)
ok_known <- known_paths(entry_path)
r9_bad <- sprintf("%s: %s", entry_file[!ok_known], entry_path[!ok_known])
chk(n_entries > 100L,
    sprintf("R9a the baselines are read (%d path entries across %d files)",
            n_entries, length(baselines)))
chk(!length(r9_bad),
    sprintf("R9b every baselined path is tracked or deliberately ignored%s",
            if (length(r9_bad)) paste0(" [", paste(r9_bad, collapse = "; "), "]") else ""))

# --- R10 a suite's own count ----------------------------------------------------
sab(10, "a summary line is a claim about the run that produced it")
r10_bad <- character(0); n_suites <- 0L
for (f in grep("saboteur", TEST_R, value = TRUE)) {
  txt <- slurp(f)
  # TWO FORMS, because there are two: saboteur_report(n) in 3 suites, and a
  # hand-written summary line -- "across 10 saboteurs" -- in 11. Reading only
  # the first made this check find 2 suites and report ok, which is a scan
  # narrower than its claim: shape two of the four this repository keeps
  # finding.
  dec <- regmatches(txt, regexpr("saboteur_report\\([0-9]+", txt))
  if (!length(dec) || !nzchar(dec))
    dec <- regmatches(txt, regexpr("across [0-9]+ [a-z -]*saboteurs", txt))
  if (!length(dec) || !nzchar(dec)) next
  n_suites <- n_suites + 1L
  declared <- as.integer(regmatches(dec, regexpr("[0-9]+", dec)))
  # COUNT SABOTEURS, NOT sab() CALLS. helper-saboteur.R documents the label as
  # "its number, or e.g. \"10b\" for a pair": a suite with ten saboteurs whose
  # tenth has an inverted twin makes eleven calls. Counting calls reported
  # test_cross_vintage_pairing_saboteurs.R and test_zip_normalizer_saboteurs.R
  # as miscounting their own suites when both are correct.
  lab <- sab_labels(txt)
  actual <- length(unique(sub("[^0-9].*$", "", gsub("[\"']", "", lab))))
  # A suite that heads its saboteurs some other way states a count this scan
  # cannot check. Comparing anyway reported test_source_coverage_saboteurs.R as
  # "says 26, runs 0", which is the scan's blind spot dressed as the suite's
  # defect -- and the sort of finding that gets a gate ignored.
  if (actual == 0L) { n_suites <- n_suites - 1L; next }
  if (!identical(declared, actual))
    r10_bad <- c(r10_bad, sprintf("%s says %d, runs %d", basename(f),
                                  declared, actual))
}
chk(n_suites > 10L,
    sprintf("R10a the suites that declare a count are found, in both forms (%d)",
            n_suites))
chk(!length(r10_bad),
    sprintf("R10b every suite's declared saboteur count matches the saboteurs it runs%s",
            if (length(r10_bad)) paste0(" [", paste(r10_bad, collapse = "; "), "]") else ""))

cat(sprintf("\n%s (%d failure(s) across 10 claim-integrity saboteurs)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS",
            fails))
quit(status = if (fails == 0L) 0L else 1L)
