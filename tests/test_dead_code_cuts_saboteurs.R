#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-22 dead-code and duplication cuts
# =============================================================================
# Five laws, one per cut, each planted back and required to be caught. A
# deletion that nothing guards comes back: the code that was deleted had a
# reason to exist once, and the next person to need something like it writes
# it again rather than finding the entry that says why it went.
#
# WHAT WAS CUT, and the law that keeps it cut:
#
#   C1  17 top-level functions nothing referenced, 1,266 lines with the
#       cascade -- five more helpers in tests/helper-data-generation.R went
#       dead the moment their only callers did. LAW: a tracked .R file does
#       not define a top-level function that nothing else in the tree names.
#   C2  8 duplicated function bodies, each copied under a different name, so
#       ci_hygiene.R H4 could not see them: it compares NAMES. LAW: no two
#       non-test files carry an identical function body of four lines or more.
#   C3  five definitions shadowing base R -- `%||%` in four files with four
#       different meanings, plus save(), q(), row() and norm(). LAW: no
#       top-level definition takes a name base R already uses.
#   C4  three wrappers whose whole body forwarded identical arguments to one
#       callee. LAW: a non-test function is not a bare pass-through.
#   C5  mw_build_catalog() at 1,424 lines and cyclomatic complexity 136, the
#       worst in the tree. Three self-contained sections lifted out whole.
#       LAW: the caller calls each section exactly once and each section
#       returns the catalog it was handed.
#
# Reuses tools/measure_code_complexity.R, which is the repository's own
# measurement and already parses every tracked file; a second parser here
# would be the duplication this suite exists to catch.
#
# This is the SECOND round of cuts to carry a suite.
# tests/test_ponytail_cuts_saboteurs.R (PR #328) owns the first round's four
# laws -- harness copied not sourced, @archive paths executed, the
# all-character reader defined twice, a root resolver that disagrees with
# CI -- and is untouched here. Separate files because a suite named for one
# round that grows a second round's laws stops being readable as either.
#
# Run: Rscript tests/test_dead_code_cuts_saboteurs.R
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "tests", "helper-saboteur.R"))
source(file.path(root, "tools", "measure_code_complexity.R"))

all_files  <- mcc_files(include_tests = TRUE)
code_files <- mcc_files(include_tests = FALSE)

# -----------------------------------------------------------------------------
sab(1, "no tracked file defines a top-level function nothing references")
# -----------------------------------------------------------------------------
# One pass over the corpus, not one grep per name: 1,496 names against 137,000
# lines is the shape that turns a gate into a four-minute step nobody runs.
#
# TWO EXCLUSIONS, each for a measurement reason rather than a taste one:
#   * `%...%` operator names, because the identifier regex cannot see them and
#     a name it cannot see reads as unreferenced;
#   * `e$name` assignments into an environment, which are mutations and not
#     definitions (tests/ci_duckdb_mutation_tests.R builds four).
#
# THERE IS NO ALLOWLIST, and there was nearly one. The first version of this
# check listed mw_pct_ci() and mw_wordcount() as "referenced only by prose",
# because it built its corpus with `ls-files "*.qmd"` and friends -- the bare
# pathspec Q2a of tests/test_gate_integrity_saboteurs.R refuses, having once
# been measured reading 267 of 645 files. The corpus was short, the two
# functions looked dead, and the allowlist would have recorded a truncated
# scan as a property of the code. Listing every tracked file once and
# filtering in R found both callers and emptied the list.
# LISTED ONCE AND FILTERED IN R, never `ls-files "*.ext"`. Q2a of
# tests/test_gate_integrity_saboteurs.R refuses that pathspec because it has
# been observed reading only the repository root -- 267 of 645 files on the run
# that produced the rule -- while the message beside it says "every tracked
# file". This is the form tools/measure_code_complexity.R uses for the same
# reason.
corpus_paths <- c(all_files,
                  grep("[.](qmd|Rmd|md|yml|yaml|py)$",
                       system2("git", c("ls-files"), stdout = TRUE), value = TRUE))
corpus <- unlist(lapply(corpus_paths, function(f)
  if (file.exists(f)) readLines(f, warn = FALSE) else character(0)))
freq <- table(unlist(regmatches(corpus, gregexpr("[A-Za-z._][A-Za-z0-9._]*", corpus))))
defined <- do.call(rbind, lapply(all_files, function(f) {
  cl <- mcc_closures(f)
  if (!length(cl)) return(NULL)
  data.frame(file = f, nm = vapply(cl, `[[`, "", "nm"), stringsAsFactors = FALSE)
}))
unreferenced <- function(d) {
  d <- d[!grepl("[%$]", d$nm), , drop = FALSE]
  n <- as.integer(freq[d$nm]); n[is.na(n)] <- 0L
  d[n <= 1L, , drop = FALSE]
}
dead <- unreferenced(defined)
chk(nrow(dead) == 0L,
    sprintf("C1a no tracked file defines a function nothing references (%d definitions scanned)%s",
            nrow(defined),
            if (nrow(dead)) paste0(" [", paste(sprintf("%s:%s", basename(dead$file), dead$nm),
                                               collapse = ", "), "]") else ""))

sab(2, "SABOTEUR: put one of the deleted functions back")
# gen_addresses() was 108 lines and the largest single thing cut. Restoring the
# NAME alone is enough, which is the point: the scan reads definitions and
# references, not bodies, so a one-line revival is caught exactly like the
# 108-line one.
# The name is synthetic ON PURPOSE. Naming the real one here would put it in
# the corpus this scan reads, and a name this file mentions is a name with a
# reference -- the saboteur would then be testing the corpus, not the law.
planted <- paste0("zz", "_revived_fixture_helper")
revived <- rbind(defined,
                 data.frame(file = "tests/helper-data-generation.R",
                            nm = planted, stringsAsFactors = FALSE))
caught <- unreferenced(revived)
chk(nrow(caught) == 1L && identical(caught$nm, planted),
    "C1b KILLED: a definition nothing references is caught, and nothing else is")

sab(3, "NEAR MISS: a function referenced exactly once elsewhere is not dead")
alive <- rbind(defined, data.frame(file = "x.R", nm = "mcc_duplicates",
                                   stringsAsFactors = FALSE))
chk(!"mcc_duplicates" %in% unreferenced(alive)$nm,
    "C1c a function this very file calls is not reported dead")

# -----------------------------------------------------------------------------
sab(4, "no two non-test files carry the same function body")
# -----------------------------------------------------------------------------
# THE RATCHET IS TWO, and both entries are deliberate. A shared file costs a
# source() line in every caller; at five and six lines these two pay more in
# plumbing than they save in text. They are named so the set can only shrink:
# a third duplicate fails this gate.
DUP_BASELINE <- c("write_fig == save_identity_figure", "centroid_counts")
dup_label <- function(g) paste(unique(g$fn), collapse = " == ")
dups <- mcc_duplicates(code_files, min_loc = 4L)
labels <- unname(sort(vapply(dups, dup_label, "")))
chk(identical(labels, sort(DUP_BASELINE)),
    sprintf("C2a duplicate bodies are exactly the %d baselined [%s]",
            length(DUP_BASELINE), paste(labels, collapse = "; ")))

sab(5, "SABOTEUR: copy a body back under a second name")
# Written to a throwaway pair of files and run through the REAL scanner.
# Asserting that a string I just built contains the body I put in it would
# prove nothing; mcc_duplicates() has to be the thing that fires.
d <- file.path(tempdir(), paste0("dup-", as.integer(runif(1, 1, 1e9))))
dir.create(d)
body_txt <- c("f <- function(x) {", "  y <- x + 1", "  z <- y * 2",
              "  w <- z - 3", "  w", "}")
writeLines(body_txt, file.path(d, "a.R"))
writeLines(sub("^f <-", "g <-", body_txt), file.path(d, "b.R"))
chk(length(mcc_duplicates(file.path(d, c("a.R", "b.R")), min_loc = 4L)) == 1L,
    "C2b KILLED: the same body under two names is caught by the real scanner")
writeLines(c("h <- function(x) {", "  y <- x + 1", "  y", "}"), file.path(d, "c.R"))
chk(length(mcc_duplicates(file.path(d, c("a.R", "c.R")), min_loc = 4L)) == 0L,
    "C2c NEAR MISS: two different bodies are not flagged")

# -----------------------------------------------------------------------------
sab(6, "no definition takes a name base R already uses")
# -----------------------------------------------------------------------------
# `save <- function(p, name, w, h)` shadowed base::save() for every line after
# it in make_trilliant_figures.R, `q()` shadowed quit, and four files each
# defined `%||%` with four different meanings while base R has shipped one
# since 4.4. A reader cannot tell a shadowed name from the real one by looking.
base_names <- ls(baseenv(), all.names = TRUE)
shadowers <- function(files) {
  out <- character(0)
  for (f in files) for (cl in mcc_closures(f))
    if (cl$nm %in% base_names) out <- c(out, sprintf("%s:%s", basename(f), cl$nm))
  out
}
sh <- shadowers(all_files)
chk(length(sh) == 0L,
    sprintf("C3a no tracked file shadows a base R name%s",
            if (length(sh)) paste0(" [", paste(sh, collapse = ", "), "]") else ""))

sab(7, "SABOTEUR: redefine the operator base R ships")
writeLines(c("`%||%` <- function(x, y) if (is.null(x)) y else x",
             "save <- function(p) invisible(p)"), file.path(d, "shadow.R"))
chk(length(shadowers(file.path(d, "shadow.R"))) == 2L,
    "C3b KILLED: a local %||% and a local save() are both caught")
writeLines("`%|na|%` <- function(a, b) if (all(is.na(a))) b else a",
           file.path(d, "noshadow.R"))
chk(length(shadowers(file.path(d, "noshadow.R"))) == 0L,
    "C3c NEAR MISS: a distinctly named operator is not a shadow")

# -----------------------------------------------------------------------------
sab(8, "no non-test function is a bare pass-through")
# -----------------------------------------------------------------------------
# middle_initial(x) called first_initial(x) and nothing else; have(p) called
# file.exists(p); lk(x) called as_duckdb_tibble(x). A name is not an
# abstraction. THE FOUR BASELINED ONES earn their names: two are the
# intent-naming the linkage code reads by (normalize_city, normalize_person_name),
# one is the documented single-source shim for the shared package, and one is a
# namespaced call the parser reports as its own callee.
# safe_divide_manu and amcb_middle_agreement are documented single-source
# shims to shared packages, each carrying the rule's rationale and naming the
# tests that own it; normalize_city and normalize_person_name are the
# intent-naming the linkage code reads by; norm_name is a namespaced call the
# parser reports as its own callee.
PASSTHROUGH_BASELINE <- c("safe_divide_manu", "amcb_middle_agreement",
                          "normalize_city", "normalize_person_name", "norm_name")
passthroughs <- function(files) {
  out <- character(0)
  for (f in files) for (cl in mcc_closures(f)) {
    b <- body(cl$fn)
    if (is.call(b) && identical(as.character(b[[1]])[1], "{")) {
      if (length(b) != 2L) next
      b <- b[[2]]
    }
    if (!is.call(b)) next
    if (as.character(b[[1]])[1] %in% c("if", "for", "while", "{", "return", "switch")) next
    fa <- names(formals(cl$fn))
    ca <- vapply(as.list(b)[-1], function(a) paste(deparse(a), collapse = ""), character(1))
    if (length(fa) && length(ca) == length(fa) && all(unname(ca) == fa))
      out <- c(out, cl$nm)
  }
  out
}
pt <- setdiff(passthroughs(code_files), PASSTHROUGH_BASELINE)
chk(length(pt) == 0L,
    sprintf("C4a no new pass-through wrapper%s",
            if (length(pt)) paste0(" [", paste(pt, collapse = ", "), "]") else ""))

sab(9, "SABOTEUR: write the alias back")
writeLines(c("first_initial <- function(x) substr(x, 1, 1)",
             "middle_initial <- function(x) first_initial(x)"),
           file.path(d, "alias.R"))
chk("middle_initial" %in% passthroughs(file.path(d, "alias.R")),
    "C4b KILLED: middle_initial() forwarding to first_initial() is caught")
writeLines("trim_initial <- function(x) substr(trimws(x), 1, 1)", file.path(d, "real.R"))
chk(length(passthroughs(file.path(d, "real.R"))) == 0L,
    "C4c NEAR MISS: a function that does work before delegating is not a wrapper")

# -----------------------------------------------------------------------------
sab(10, "the catalog calls each extracted section exactly once")
# -----------------------------------------------------------------------------
# mw_build_catalog() was 1,424 lines at cyclomatic complexity 136. Three
# sections that read only committed artifacts and write only their own keys
# came out whole, leaving 987 lines at 98. The split is only safe while the
# caller still calls them: an extracted section nobody calls is a section
# whose keys silently vanish from every number in the manuscript.
cat_path <- file.path(root, "manuscript", "R", "build_stats_catalog.R")
cat_src  <- readLines(cat_path, warn = FALSE)
sections <- sub(" <- function.*$", "",
                grep("^mw_section_[a-z_]+ <- function", cat_src, value = TRUE))
chk(length(sections) >= 3L,
    sprintf("C5a the catalog file defines %d section function(s) [%s]",
            length(sections), paste(sections, collapse = ", ")))

# PARSED, NOT BRACE-COUNTED. The extracted sections are top-level functions, so
# their inner blocks close at column 0 exactly like the function does; the first
# `^}` after a definition is an inner block, not the end. An earlier version of
# this check counted braces and reported all three sections as not returning the
# catalog while they all did.
cat_ex <- parse(cat_path, keep.source = TRUE)
fn_body <- function(src, nm) {
  for (i in seq_along(src)) {
    e <- src[[i]]
    if (is.call(e) && length(e) == 3L && as.character(e[[1]])[1] %in% c("<-", "=") &&
        identical(deparse(e[[2]])[1], nm)) return(e[[3]])
  }
  NULL
}
# Calls counted over the PARSED body, so a section named in a comment is not a
# call. The comment above the call site names it, and an earlier version of this
# check read that comment as a second call and failed on correct code.
count_calls <- function(expr, nm, acc = 0L) {
  if (is.call(expr)) {
    if (identical(deparse(expr[[1]])[1], nm)) acc <- acc + 1L
    for (i in seq_along(expr)) acc <- tryCatch(count_calls(expr[[i]], nm, acc),
                                               error = function(z) acc)
  }
  acc
}
builder <- fn_body(cat_ex, "mw_build_catalog")
miscalled <- Filter(function(s) count_calls(body(eval(builder)), s) != 1L, sections)
chk(length(miscalled) == 0L,
    sprintf("C5b mw_build_catalog() calls each section exactly once%s",
            if (length(miscalled)) paste0(" [", paste(miscalled, collapse = ", "), "]") else ""))
last_expr_is_cat <- function(nm, src = cat_ex) {
  b <- body(eval(fn_body(src, nm)))
  identical(deparse(b[[length(b)]]), "cat_")
}
unreturned <- Filter(function(s) !last_expr_is_cat(s), sections)
chk(length(unreturned) == 0L,
    sprintf("C5c every section returns the catalog it was handed%s",
            if (length(unreturned)) paste0(" [", paste(unreturned, collapse = ", "), "]") else ""))

sab(11, "SABOTEUR: drop a section call, and stop a section returning the catalog")
dropped <- parse(text = paste(cat_src[!grepl("^  cat_ <- mw_section_dbacc\\(", cat_src)],
                              collapse = "\n"), keep.source = FALSE)
chk(count_calls(body(eval(fn_body(dropped, "mw_build_catalog"))), "mw_section_dbacc") == 0L,
    "C5d KILLED: a section the caller no longer calls is caught")
unret <- parse(text = paste(sub("^  cat_$", "  invisible(NULL)", cat_src), collapse = "\n"),
               keep.source = FALSE)
chk(!last_expr_is_cat("mw_section_dbacc", unret),
    "C5e KILLED: a section that stops returning the catalog is caught")

unlink(d, recursive = TRUE)
saboteur_report(11)
