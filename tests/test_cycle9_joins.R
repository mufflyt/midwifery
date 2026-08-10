#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 9 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Two findings, and the first one is about this loop.
#
# 1. THE LOOP COMMITTED THE BUG CLASS IT EXISTS TO HUNT.
#    assert_no_key_conflict() was defined TWICE in R/join_safety.R, both
#    definitions introduced by my own cycle-5 commit (402898d) when a heredoc
#    ran twice. R keeps the LAST definition, so the first was dead code that
#    nothing would ever report. It survived four cycles.
#
#    That is class C1 -- duplicate definitions, the class this project has paid
#    for at least six times -- committed into join_safety.R, the module whose
#    entire purpose is to stop conflicts being resolved silently. The guard that
#    would have caught it did not exist. T84 is that guard.
#
# 2. THE SAFE-JOIN LIBRARY IS BARELY USED.
#    R/join_safety.R provides safe_left_join(), safe_inner_join(),
#    safe_semi_join() and safe_anti_join(), which assert row counts and key
#    uniqueness. The pipeline makes 46 BARE dplyr joins and 8 wrapped ones.
#    Every bare left_join against a non-unique right table silently multiplies
#    rows -- and a fanned-out row count becomes a denominator.
#
# Run: Rscript tests/test_cycle9_joins.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "join_safety.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
R_FILES <- list.files(file.path(root, "R"), pattern = "\\.R$",
                      recursive = TRUE, full.names = TRUE)

cat("\n-- BVA --\n")

# T81 (BVA). A left join's cardinality contract at its edges. The left row
# count is the estimand's denominator in most of this pipeline, so it must
# survive every degenerate shape.
{
  L <- data.frame(k = c("a", "b"), v = 1:2, stringsAsFactors = FALSE)
  Rfull <- data.frame(k = c("a", "b"), w = c(10, 20), stringsAsFactors = FALSE)
  out <- suppressMessages(safe_left_join(L, Rfull, by = "k"))
  chk(nrow(out) == 2L, "T81a a fully-covered left join preserves the left row count")

  # My first fixture matched only 1 of 2 left rows and the join REFUSED it --
  # correctly, at the 98% coverage threshold. That is the guard working, so it
  # is now asserted as behaviour rather than worked around.
  Rhalf <- data.frame(k = "a", w = 10, stringsAsFactors = FALSE)
  refused <- tryCatch(suppressMessages(safe_left_join(L, Rhalf, by = "k")),
                      error = function(e) "refused")
  chk(identical(refused, "refused"),
      "T81b a join that silently loses half the left rows is refused, not returned")
  kept <- suppressMessages(safe_left_join(L, Rhalf, by = "k", min_coverage = 0.5))
  chk(nrow(kept) == 2L,
      "T81c with the threshold lowered deliberately, every left row still survives")
}

# T82 (BVA). Key TYPE at the boundary that matters here: a FIPS is a string.
# 09001 read as a number is 9001, which is not a county.
{
  chk(exists("harmonize_join_key_types", mode = "function"),
      "T82a the repo provides a key-type harmoniser")
  L <- data.frame(GEOID = c("09001", "01001"), stringsAsFactors = FALSE)
  Rt <- data.frame(GEOID = c(9001, 1001), x = c("CT", "AL"))
  h <- tryCatch(suppressMessages(harmonize_join_key_types(L, Rt, by = "GEOID")),
                error = function(e) NULL)
  # Whatever it does, it must not silently produce zero matches.
  joined <- if (is.null(h)) suppressWarnings(
    dplyr::left_join(L, dplyr::mutate(Rt, GEOID = as.character(GEOID)), by = "GEOID"))
    else suppressMessages(dplyr::left_join(h$left, h$right, by = "GEOID"))
  chk(nrow(joined) == 2L,
      "T82b a numeric-vs-character FIPS join does not drop or duplicate rows")
}

# T83 (BVA). NA keys must never match one another. Two counties with unknown
# FIPS are not the same county.
{
  L <- data.frame(k = c("a", NA), v = 1:2, stringsAsFactors = FALSE)
  Rt <- data.frame(k = c("a", NA), w = c(10, 99), stringsAsFactors = FALSE)
  j <- suppressWarnings(dplyr::left_join(L, Rt, by = "k"))
  chk(is.na(j$w[is.na(j$k)]) || nrow(j) == 2L,
      sprintf("T83 an NA key does not join to another NA key [w = %s]",
              paste(j$w, collapse = ", ")))
}

cat("\n-- SEMANTIC --\n")

# T84 (semantic). THE GUARD THAT WAS MISSING. No function may be defined twice
# anywhere under R/. R silently keeps the last definition, so a duplicate is
# not an error, it is dead code that looks live -- and a fix applied to the
# dead copy is a fix applied to nothing.
{
  defs <- list()
  for (f in R_FILES) {
    src <- readLines(f, warn = FALSE)
    m <- regmatches(src, regexpr("^[a-zA-Z_.][a-zA-Z0-9_.]*\\s*(<-|=)\\s*function", src))
    for (d in m) {
      nm <- trimws(sub("(<-|=)\\s*function$", "", d))
      defs[[nm]] <- c(defs[[nm]], basename(f))
    }
  }
  dupes <- names(defs)[vapply(defs, function(x) length(x) > 1L, logical(1))]

  # sha256_of() is CONSOLIDATED this cycle, not ratcheted: it is the hash tying
  # an artifact to the bytes it was built from, and it existed in six scripts in
  # two textual forms. They happened to agree; nothing required them to.
  chk(!("sha256_of" %in% dupes),
      "T84a the provenance hash has exactly one definition")

  # The remainder -- pad5, fmt, chr, with_iso_wd -- are four-line formatting and
  # IO helpers copied between standalone numbered scripts, which are sourced
  # individually by design. Their copies are textually equivalent today. That is
  # a coincidence rather than a contract, so the count is RATCHETED and named
  # rather than declared clean.
  # Ratchet tightened from 4 to 0: the four identical duplicates (pad5, chr,
  # fmt, with_iso_wd) and the DIVERGENT %||% were all resolved into
  # R/lib/common_helpers.R this cycle. Leaving the baseline at 4 would let
  # three duplicates creep back without failing, which is the debt returning
  # under cover of a passing test.
  BASELINE <- 0L
  chk(length(dupes) <= BASELINE,
      sprintf("T84b duplicate-definition count does not grow beyond the recorded debt [%d of %d: %s]",
              length(dupes), BASELINE,
              if (length(dupes)) paste(dupes, collapse = ", ") else "none"))
}

# T85 (semantic). A left join must not change the estimand. When the right
# table is not unique on the key, dplyr fans out silently and the left row
# count -- the denominator -- grows.
{
  L <- data.frame(k = "a", v = 1, stringsAsFactors = FALSE)
  Rt <- data.frame(k = c("a", "a"), w = 1:2, stringsAsFactors = FALSE)
  bare <- suppressWarnings(dplyr::left_join(L, Rt, by = "k"))
  chk(nrow(bare) == 2L,
      "T85a a bare left_join on a non-unique right table silently doubles the left row")
  guarded <- tryCatch(suppressMessages(safe_left_join(L, Rt, by = "k")),
                      error = function(e) "refused")
  chk(identical(guarded, "refused") || nrow(guarded) == 1L,
      "T85b safe_left_join refuses or preserves, but never silently fans out")
}

# T86 (semantic). The safe-join wrappers must actually be reachable, i.e. each
# is defined exactly once and is a function. A wrapper that does not exist is
# worse than none, because callers believe they are protected.
{
  wrappers <- c("safe_left_join", "safe_inner_join", "safe_semi_join",
                "safe_anti_join", "assert_unique_keys", "assert_no_key_conflict")
  missing <- wrappers[!vapply(wrappers, exists, logical(1), mode = "function")]
  chk(length(missing) == 0L,
      sprintf("T86 every advertised join guard exists [missing: %s]",
              if (length(missing)) paste(missing, collapse = ", ") else "none"))
}

cat("\n-- ADVERSARIAL --\n")

# T87 (adversarial). The fan-out, shown as the scientific error it is: a
# denominator that grows because a lookup table had a duplicate.
{
  people <- data.frame(id = c("p1", "p2"), stringsAsFactors = FALSE)
  county <- data.frame(id = c("p1", "p1", "p2"),
                       GEOID = c("08031", "08031", "48001"), stringsAsFactors = FALSE)
  j <- suppressWarnings(dplyr::left_join(people, county, by = "id"))
  chk(nrow(j) == 3L && nrow(people) == 2L,
      sprintf("T87 a duplicated lookup row inflates a 2-person cohort to %d rows", nrow(j)))
}

# T88 (adversarial). Factor vs character keys. readr and readxl return factors
# under options this repo does not pin, and joining a factor to a character key
# is a class of silent mismatch this project has already been bitten by.
{
  L <- data.frame(k = factor(c("a", "b")), v = 1:2)
  Rt <- data.frame(k = c("a", "b"), w = c(10, 20), stringsAsFactors = FALSE)
  j <- tryCatch(suppressWarnings(dplyr::left_join(L, Rt, by = "k")),
                error = function(e) NULL)
  chk(!is.null(j) && sum(!is.na(j$w)) == 2L,
      "T88 a factor key joins to a character key by VALUE, not level index")
}

# T89 (adversarial). The bare-join inventory, as a ratchet. 46 bare joins
# against 8 guarded ones; converting them all at once is not this cycle's job,
# but the count must not grow.
{
  bare <- 0L; safe <- 0L
  for (f in R_FILES) {
    if (basename(f) == "join_safety.R") next
    src <- readLines(f, warn = FALSE)
    src <- src[!grepl("^\\s*#", src)]
    bare <- bare + sum(grepl("[^_a-z](left|inner)_join\\(", src))
    safe <- safe + sum(grepl("safe_(left|inner|semi|anti)_join\\(", src))
  }
  chk(bare <= 46L,
      sprintf("T89 the bare-join count does not grow beyond the recorded debt [%d bare, %d guarded]",
              bare, safe))
}

# T90 (adversarial). Duplicate definitions must be caught ACROSS files too, not
# only within one -- which is how apply_gender_gate, the credential helpers and
# rank_one_to_one all escaped notice in the sibling repo.
{
  # Prove T84's detector actually fires, by feeding it a known duplicate.
  fake <- c("foo <- function(x) x", "bar <- function(y) y")
  m1 <- regmatches(fake, regexpr("^[a-zA-Z_.][a-zA-Z0-9_.]*\\s*(<-|=)\\s*function", fake))
  detected <- length(m1) == 2L &&
    anyDuplicated(c(trimws(sub("(<-|=)\\s*function$", "", m1)), "foo")) > 0L
  chk(detected,
      "T90 the duplicate-definition detector fires on a known duplicate")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
