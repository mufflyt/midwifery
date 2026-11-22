#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests for the 2026-11-21 complexity-review fixes
# =============================================================================
# Four fixes landed together. A test that only asserts the fixed code works is
# worth little -- it passes just as happily against a reverted fix that happens
# to agree on the one input the test chose. Each group below therefore plants
# the ORIGINAL defect back and requires the guard to die on it, and adds at
# least one NEAR MISS: a different-but-correct implementation that must still
# pass, so the guard cannot regress into "must be written exactly this way".
#
#   R1-R7   amcb_license_bridge.R normalize_text() folds accents
#           DETERMINISTICALLY. It used base::iconv(to = "ASCII//TRANSLIT"),
#           whose output is the C library's choice: libiconv (macOS) emits the
#           combining mark and glibc (the CI runners) does not, so the same
#           midwife's name became MU NOZ on one machine and MUNOZ on the other.
#   R8-R13  ci_hygiene.R H6 catches one name bound to a function twice in a
#           single scope. mw_build_catalog() bound `g` three times in one
#           913-line body; `if (...) { }` is not a scope in R, so all three
#           landed in the one environment and two took the same arity with
#           incompatible first-argument types.
#   R14-R22 No formal of the four safe_*_join wrappers is accepted and then
#           ignored. require_complete_keys defaulted TRUE and was read only
#           inside a branch that stops, because it delegates to
#           R/join_metrics.R, which does not exist here. Six more formals were
#           in the same state across the other three wrappers.
#   R23-R24 join_coverage_report() is called with NAMED arguments.
#
# Run: Rscript tests/test_review_fixes_saboteurs.R   (exit 1 on any failure)
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(stringr)})
SAB_PREFIX <- "R"

# Sourcing runs the script's library() calls but, thanks to its sys.nframe()
# guard, NOT its pipeline -- the same safe extraction tests/
# test_fuzzy_surname_removal_saboteur.R documents for match_amcb_to_npi.R.
source(file.path(root, "amcb_license_bridge.R"))


# =============================================================================
# R1-R7  A name key must not depend on which machine built it
# =============================================================================
# The property under test is THE FOLD: an accented spelling and its unaccented
# spelling must produce one key. That is stated without reference to any
# implementation, and it is true on every platform -- which matters, because the
# defect itself is NOT reproducible on one platform. Asserting "the old code
# gives the wrong answer" would pass on macOS and FAIL on the Linux runners,
# where iconv happens to agree with the fix. So the platform-dependence is
# pinned statically (R5) and the fold is pinned behaviourally (R1-R4, R6).

ACCENTED <- c("Muñoz", "José", "Åsa", "François", "Nuñez")
PLAIN    <- c("Munoz",      "Jose",      "Asa",      "Francois",      "Nunez")

# Rebuild normalize_text()'s pipeline with the fold step swapped out. Everything
# except `fold` is copied from the live function, so a case isolates the fold.
with_fold <- function(fold) function(x) {
  cleaned <- fold(blank_to_na(x))
  cleaned <- cleaned |>
    stringr::str_to_upper() |>
    stringr::str_replace_all("[^A-Z0-9 ]", " ") |>
    stringr::str_squish()
  cleaned[!is.na(cleaned) & cleaned == ""] <- NA_character_
  cleaned
}
folds_match <- function(f) all(mapply(function(a, b) identical(f(a), f(b)),
                                     ACCENTED, PLAIN))

sab(1, "the live normalizer folds every accent to its ASCII letter")
chk(folds_match(normalize_person_name),
    sprintf("R1 all %d accented/plain pairs share one key [%s]",
            length(ACCENTED),
            paste(normalize_person_name(ACCENTED), collapse = ",")))

sab(2, "SABOTEUR: delete the fold entirely")
# [^A-Z0-9 ] then turns the accented letter into a SPACE: MU OZ, not MUNOZ.
no_fold <- with_fold(identity)
chk(!folds_match(no_fold),
    sprintf("R2 no fold -> keys diverge, guard dies [%s vs %s]",
            no_fold("Muñoz"), no_fold("Munoz")))

sab(3, "SABOTEUR: fold by DROPPING the non-ASCII character")
# iconv(sub = "") deletes it rather than transliterating: MUOZ, not MUNOZ. This
# is the plausible wrong fix -- it is deterministic, so determinism alone is not
# the property; the letter has to survive.
drop_fold <- with_fold(function(x) iconv(x, from = "UTF-8", to = "ASCII", sub = ""))
chk(!folds_match(drop_fold),
    sprintf("R3 dropping the character -> keys diverge, guard dies [%s vs %s]",
            drop_fold("Muñoz"), drop_fold("Munoz")))

sab(4, "NEAR MISS: a different, correct fold must still pass")
# Pure base R, no ICU. The law is the fold, not stringi::stri_trans_general --
# a guard that insisted on one implementation would block its own replacement.
chartr_fold <- with_fold(function(x) chartr(
  "áàâäãåéèêëíìîïóòôöõúùûüñçÁÀÂÄÃÅÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑÇ",
  "aaaaaaeeeeiiiiooooouuuuncAAAAAAEEEEIIIIOOOOOUUUUNC", x))
chk(folds_match(chartr_fold),
    "R4 a base-R chartr fold satisfies the same law (not implementation-locked)")

sab(5, "the platform-dependent call is gone from the source")
# Pinned statically because it cannot be pinned behaviourally: on a glibc
# runner the old call returns the RIGHT answer, so a runtime assertion would
# pass there and this defect would come back green.
# Read CODE, not comments. This file's own fix carries a comment naming the
# call it removed -- which is how this repository documents a defect, and
# ci_hygiene.R does the same -- so a plain text search would flag the
# explanation as the defect. STR_CONST and SYMBOL_FUNCTION_CALL tokens are the
# code; COMMENT tokens are not.
code_tokens <- function(rel, token) {
  pd <- utils::getParseData(parse(file.path(root, rel), keep.source = TRUE))
  pd$text[pd$token == token]
}
chk(!any(grepl("ASCII//TRANSLIT", code_tokens("amcb_license_bridge.R", "STR_CONST"),
                fixed = TRUE)),
    "R5 no string literal in amcb_license_bridge.R asks iconv to transliterate")
chk("stri_trans_general" %in% code_tokens("amcb_license_bridge.R",
                                          "SYMBOL_FUNCTION_CALL"),
    "R6 and a fold is actually CALLED, rather than the step having been dropped")

sab(7, "the NA contract did not change while fixing the fold")
chk(is.na(normalize_person_name(NA)) && is.na(normalize_person_name("")) &&
      is.na(normalize_person_name("   ")),
    "R7 NA, empty and all-blank still normalize to NA")


# =============================================================================
# R8-R13  H6: one name bound to a function twice in one scope
# =============================================================================
# These run the REAL tests/ci_hygiene.R, as a subprocess, inside a throwaway git
# repository. Two reasons it must be a real git repo: H4/H6 read `git ls-files`,
# so a gate pointed at untracked files sees an empty repository and passes
# vacuously; and H3 reads .gitignore with readLines(), which ERRORS rather than
# warns when the file is absent.
scaffold <- function(dir, files) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  file.copy(file.path(root, "tests", "ci_hygiene.R"),
            file.path(dir, "tests", "ci_hygiene.R"))
  writeLines(c("*.tmp"), file.path(dir, ".gitignore"))
  for (nm in names(files)) writeLines(files[[nm]], file.path(dir, nm))
  system2("git", c("-C", shQuote(dir), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
}

# TRUE when the gate refused. The `cd` is load-bearing: ci_hygiene.R resolves
# its own root from --file=, so it must be invoked by its path inside dir.
gate_fails <- function(dir) {
  st <- suppressWarnings(system2(
    "sh", c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_hygiene.R",
                                  shQuote(dir)))),
    stdout = NULL, stderr = NULL))
  !identical(as.integer(st), 0L)
}

h6_case <- function(label, files, expect_fail = TRUE) {
  dir <- file.path(tempdir(), paste0("h6", sample.int(1e6, 1)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scaffold(dir, files)
  chk(identical(gate_fails(dir), expect_fail), label)
}

sab(8, "SABOTEUR: one name bound twice in a single function body")
h6_case("R8 two bindings of `h` in one function body -> H6 refuses",
        list("a.R" = c(
          "f <- function(x) {",
          "  h <- function(v) v + 1",
          "  y <- h(x)",
          "  h <- function(v) v * 2",
          "  h(y)",
          "}")))

sab(9, "SABOTEUR: the catalog's exact shape -- rebound inside if-blocks")
# The defect as it actually occurred: each binding sits in its own `if` block
# with its own calls, which LOOKS scoped and is not. A gate that only looked at
# the same brace level would have missed this one.
h6_case("R9 bindings in two sibling if-blocks -> H6 refuses (if is not a scope)",
        list("b.R" = c(
          "build <- function(a, b) {",
          "  out <- list()",
          "  if (!is.null(a)) {",
          "    gx <- function(r, col) r[[col]][1]",
          "    out$one <- gx(a, \"n\")",
          "  }",
          "  if (!is.null(b)) {",
          "    gx <- function(k, col) b[b$key == k, col]",
          "    out$two <- gx(\"x\", \"n\")",
          "  }",
          "  out",
          "}")))

sab(10, "NEAR MISS: the same name in two DIFFERENT functions")
h6_case("R10 one name per scope across two functions -> H6 passes",
        list("c.R" = c(
          "f1 <- function(x) { h <- function(v) v + 1; h(x) }",
          "f2 <- function(x) { h <- function(v) v * 2; h(x) }")),
        expect_fail = FALSE)

sab(11, "NEAR MISS: a nested helper whose name matches a nested helper elsewhere")
# H6's law is per-scope. Two scopes each binding `h` once is legal, and must
# stay legal, or every test harness in the tree would trip it.
h6_case("R11 nested `h` in two files, once each -> H6 passes",
        list("d.R" = c("f <- function(x) { h <- function(v) v + 1; h(x) }"),
             "e.R" = c("g <- function(x) { h <- function(v) v - 1; h(x) }")),
        expect_fail = FALSE)

sab(12, "NEAR MISS: rebinding a non-function is not H6's business")
h6_case("R12 a plain value reassigned twice -> H6 passes (functions only)",
        list("f.R" = c(
          "f <- function(x) {",
          "  n <- 1",
          "  n <- n + x",
          "  n",
          "}")),
        expect_fail = FALSE)

sab(13, "the real catalog carries no rebinding, and the dead accessor is gone")
cat_src <- slurp("manuscript/R/build_stats_catalog.R")
cat_defs <- regmatches(
  strsplit(cat_src, "\n")[[1]],
  regexpr("[.A-Za-z_][A-Za-z0-9_.]*(?= *<- *function)",
          strsplit(cat_src, "\n")[[1]], perl = TRUE))
chk(!any(duplicated(cat_defs)),
    sprintf("R13a no name defined twice in build_stats_catalog.R (%d definitions)",
            length(cat_defs)))
chk(!grepl("pick <- function(frame, pattern, column)", cat_src, fixed = TRUE),
    "R13b the dead pick(frame, pattern, column) is deleted, not renamed")


# =============================================================================
# R14-R15  join_coverage_report() is called by name
# =============================================================================
# WHAT WAS HERE, AND WHY IT IS GONE. Nine saboteurs (the old R14-R22) asserted
# that no safe_*_join wrapper accepts a formal it never reads, sabotaging the
# require_complete_keys shape and the arguments the inline path cannot honour.
# The 2026-11-20 complexity audit on main then deleted safe_inner_join(),
# safe_semi_join() and safe_anti_join() outright -- zero production call sites --
# and tests/test_complexity_cuts_saboteurs.R now owns that law in a stronger
# form: C1a refuses a redefinition of a deleted wrapper, C1b refuses a call to
# one, C1c kills a wrapper copied back from the upstream isochrones copy, and
# C2a-C2f own the dead delegation, its refusal, and the one argument six
# upstream call sites still pass. Nine saboteurs written against a structure
# that no longer exists would have measured the wrong law, and two of them
# could not even parse it.
#
# What survives is the call-shape law below, which the audit did not cover.
JS <- slurp("R/join_safety.R")

# =============================================================================
# R14-R15  join_coverage_report() is called by name
# =============================================================================
# Its signature ends in validation thresholds (min_coverage, verbose). Both
# call sites passed five arguments positionally, so inserting a formal ahead of
# min_coverage would have slid a threshold into `verbose` with no call site
# changing and no error raised.
positional_calls <- function(text) {
  pd <- utils::getParseData(parse(text = text, keep.source = TRUE))
  ids <- pd$id[pd$token == "SYMBOL_FUNCTION_CALL" &
                 pd$text == "join_coverage_report"]
  bad <- 0L
  for (id in ids) {
    # the enclosing call expression, then its argument tokens
    expr <- pd$parent[pd$id == id]
    call_id <- pd$parent[pd$id == expr]
    kids <- pd$id[pd$parent == call_id]
    toks <- pd$token[pd$parent == call_id]
    # a named argument shows up as SYMBOL_SUB + EQ_SUB
    n_args <- sum(toks == "expr") - 1L
    n_named <- sum(toks == "EQ_SUB")
    if (n_args > 0L && n_named < n_args) bad <- bad + 1L
  }
  bad
}

sab(14, "every call in the real file is named")
chk(positional_calls(JS) == 0L,
    sprintf("R14 no positional join_coverage_report() call remains (%d call site(s))",
            length(gregexpr("join_coverage_report(", JS, fixed = TRUE)[[1]])))

sab(15, "SABOTEUR: make one call positional again")
sab24 <- sub(
  "  join_coverage_report(left_before = left_n, joined_rows = matched_rows,\n                       label_left = label_left, label_right = label_right,\n                       min_coverage = min_coverage)",
  "  join_coverage_report(left_n, matched_rows, label_left, label_right, min_coverage)",
  JS, fixed = TRUE)
chk(!identical(sab24, JS), "R15a the saboteur actually changed the source")
chk(positional_calls(sab24) >= 1L,
    "R15b a positional call is caught")

saboteur_report(15)
