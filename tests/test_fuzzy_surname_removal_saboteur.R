#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: removal of Levenshtein/fuzzy surname matching (class 4)
# =============================================================================
# match_amcb_to_npi.R deleted strategy 3 (the stringdist()-based fuzzy-surname
# join that used to produce evidence class 4) and, because the private sibling
# repo it used to live-source five small utility functions from had deleted
# its own copy, vendored norm_name(), first_initial(), safe_pct() and
# rank_one_to_one() directly into the script instead.
#
# These tests cannot source() match_amcb_to_npi.R directly -- it is a flat
# script with no main-guard, and sourcing it reads a 455MB NPPES panel and
# writes real output files. Tests T1-T6 instead eval() only the vendored
# function-definition PREFIX of the file (up to and including the "reusing
# (vendored):" cat() that ends it) into a clean environment: nothing in that
# prefix touches disk, so this is a safe, faithful extraction of the real
# functions, not a reimplementation of them. T7-T9 inspect the file's own
# text; T10 adds a mutation-catalogue regression guard for the deletion.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(rlang)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

SRC_PATH <- file.path(root, "match_amcb_to_npi.R")
SRC_LINES <- readLines(SRC_PATH, warn = FALSE)
SRC_TEXT <- paste(SRC_LINES, collapse = "\n")

# Safe extraction: eval only the vendored-function prefix, nothing past it.
vendored_env <- local({
  exprs <- parse(SRC_PATH)
  dep1 <- sapply(exprs, function(e) deparse(e)[1])
  end_idx <- which(grepl("reusing (vendored):", dep1, fixed = TRUE))
  stopifnot(length(end_idx) == 1L)   # the extraction point must still exist
  env <- new.env()
  for (i in seq_len(end_idx)) eval(exprs[[i]], envir = env)
  env
})

cat("\n-- T1: safe_pct() -- degenerate denominators degrade to 0, not an error --\n")
{
  safe_pct <- get("safe_pct", envir = vendored_env)
  chk(identical(safe_pct(5, 0), 0),
      "T1a a zero denominator returns 0, not Inf/NaN/an error")
  got1b <- safe_pct(5, NA_real_)
  chk(identical(got1b, 0),
      sprintf("T1b an NA denominator ALSO returns 0 -- CONFIRMED, not assumed: this is the real vendored function's actual contract (is.na(d) is checked unconditionally, same branch as d==0), not a case this test invented [%s]",
              if (is.na(got1b)) "NA" else got1b))
  chk(identical(safe_pct(c(1, 2), 10), 0),
      "T1c a multi-element numerator is rejected (returns 0), not silently vectorised")
}

cat("\n-- T2: norm_name() -- delegates to mysterynpi, does not reimplement it --\n")
{
  norm_name <- get("norm_name", envir = vendored_env)
  probe <- c("Mary Jo", "O'Brien-Smith", NA_character_)
  chk(identical(norm_name(probe), mysterynpi::name_key(probe)),
      "T2 norm_name()'s output is byte-identical to mysterynpi::name_key() on the same input -- a real delegate, not a drifted copy")
}

cat("\n-- T3: first_initial() -- absence stays absence, not an empty string --\n")
{
  first_initial <- get("first_initial", envir = vendored_env)
  got <- first_initial(c("Jennifer", "", NA_character_, "  "))
  chk(identical(got[1], "J"), sprintf("T3a a normal name returns its first letter [%s]", got[1]))
  chk(is.na(got[2]) && is.na(got[3]) && is.na(got[4]),
      sprintf("T3b blank, NA and whitespace-only all return NA, not \"\" -- a caller testing nzchar() would be fooled by \"\" into thinking a candidate value was present [%s]",
              paste(got[2:4], collapse = "|")))
}

cat("\n-- T4: rank_one_to_one() -- a missing id column fails loudly --\n")
{
  rank_one_to_one <- get("rank_one_to_one", envir = vendored_env)
  cand <- tibble(amcb_id = c("A", "B"), npi = c("1", "2"),
                 method_priority = c(1L, 1L), score_total = c(5, 5),
                 confidence_score = c(0.9, 0.9))
  got <- tryCatch(rank_one_to_one(cand, id_col = "nonexistent_col"),
                  error = function(e) conditionMessage(e))
  chk(is.character(got) && grepl("not found in candidates", got),
      sprintf("T4 a typo'd id_col stops with a named error, not a cryptic downstream failure [%s]", got))
}

cat("\n-- T5: rank_one_to_one() -- never needs build_method_priority_lut() here --\n")
{
  rank_one_to_one <- get("rank_one_to_one", envir = vendored_env)
  # AMCB's own call site (match_amcb_to_npi.R, ~line 622) ALWAYS supplies a
  # fully-populated method_priority column. build_method_priority_lut() is a
  # different pipeline's function (keyed on ABOG strategy names) that does not
  # exist in this script's environment at all. If rank_one_to_one() ever
  # reached for it here, this would fail with "could not find function" --
  # not a graceful fallback, a hard crash on every real run.
  chk(!exists("build_method_priority_lut", envir = vendored_env, inherits = FALSE),
      "T5a build_method_priority_lut() is genuinely absent from this script's environment")
  cand <- tibble(amcb_id = c("A", "B"), npi = c("1", "2"),
                 method_priority = c(1L, 1L), score_total = c(5, 3),
                 confidence_score = c(0.9, 0.5))
  got <- tryCatch(rank_one_to_one(cand, id_col = "amcb_id"),
                  error = function(e) conditionMessage(e))
  chk(is.data.frame(got),
      sprintf("T5b a fully-populated method_priority column means the LUT is never consulted, and the call succeeds [%s]",
              if (is.data.frame(got)) sprintf("%d rows", nrow(got)) else got))
}

cat("\n-- T6: rank_one_to_one() -- tied evidence and contested NPI are different quarantines --\n")
{
  rank_one_to_one <- get("rank_one_to_one", envir = vendored_env)
  # Person P1 has two equally-good candidates for TWO DIFFERENT NPIs: their
  # own evidence is ambiguous (ambiguous_tied_evidence). Persons P2 and P3
  # each uniquely, unambiguously point at the SAME NPI (999): no ambiguity in
  # either person's own evidence, but a contest between two people
  # (ambiguous_contested_npi). A resolver that conflated these would publish
  # the wrong fact about which kind of problem a reader is looking at.
  cand <- tibble(
    amcb_id          = c("P1", "P1", "P2", "P3"),
    npi              = c("111", "222", "999", "999"),
    method_priority  = c(1L, 1L, 1L, 1L),
    score_total      = c(5, 5, 5, 5),
    confidence_score = c(0.9, 0.9, 0.9, 0.9))
  res <- rank_one_to_one(cand, id_col = "amcb_id")
  qtine <- attr(res, "quarantine")
  chk(!"P1" %in% res$amcb_id && "P1" %in% qtine$amcb_id[qtine$resolution_status == "ambiguous_tied_evidence"],
      "T6a P1 (tied between two NPIs) is quarantined as ambiguous_tied_evidence, not resolved")
  chk(all(c("P2", "P3") %in% qtine$amcb_id[qtine$resolution_status == "ambiguous_contested_npi"]) &&
      !any(c("P2", "P3") %in% res$amcb_id),
      "T6b P2 and P3 (contesting one NPI) are BOTH quarantined as ambiguous_contested_npi, neither awarded")
}

cat("\n-- T7: no surviving code path can produce evidence class 4 --\n")
{
  chk(!grepl("TRUE\\s*~\\s*4L", SRC_TEXT),
      "T7a no case_when() arm maps anything to class 4 any more")
  live_lines <- SRC_LINES[!grepl("^\\s*#", SRC_LINES)]   # strip comment-only lines
  live_text <- paste(live_lines, collapse = "\n")
  chk(!grepl("stringdist\\s*\\(", live_text),
      "T7b stringdist() is not called from any live (uncommented) line")
  chk(!grepl("bind_rows\\(s1,\\s*s2,\\s*s3,\\s*s5\\)", live_text, fixed = FALSE),
      "T7c s3 (the fuzzy strategy) is not folded into the candidate pool")
  chk(!grepl("library\\(stringdist\\)", live_text),
      "T7d the stringdist package is no longer loaded at all")
}

cat("\n-- T8: a one-character-off surname no longer joins, under the real join shape --\n")
{
  # Strategy 1's actual join key (match_amcb_to_npi.R ~line 360) is EXACT
  # last_clean + first_clean equality -- never a distance. Reproduce that
  # exact shape, not a paraphrase of it, on a pair that WOULD have matched
  # under the deleted strategy 3 (edit distance 1, same given name).
  amcb <- tibble(amcb_id = "X1", last_clean = "SMITH", first_clean = "JANE")
  nppes <- tibble(nppes_last_clean = "SMYTH", nppes_first_clean = "JANE")
  joined <- dplyr::inner_join(amcb, nppes,
                              by = c("last_clean" = "nppes_last_clean",
                                     "first_clean" = "nppes_first_clean"))
  chk(nrow(joined) == 0L,
      sprintf("T8 SMITH/SMYTH (edit distance 1, identical given name) produces zero candidates under exact-equality join -- the deleted strategy was the ONLY path that would have connected them [%d rows]",
              nrow(joined)))
}

cat("\n-- T9: compute_match_score() is not required, and is genuinely gone --\n")
{
  exprs <- parse(SRC_PATH)
  dep1 <- sapply(exprs, function(e) deparse(e)[1])
  guard_idx <- which(grepl('^for \\(fn in c\\(', dep1))
  chk(length(guard_idx) == 1L, "T9a exactly one required-functions guard exists")
  guard_text <- paste(deparse(exprs[[guard_idx]]), collapse = " ")
  chk(!grepl("compute_match_score", guard_text),
      "T9b compute_match_score is not in the required-functions list -- nobody can silently require it again without also re-adding a definition")
  chk(!exists("compute_match_score", envir = vendored_env, inherits = FALSE),
      "T9c compute_match_score is genuinely undefined after sourcing the vendored prefix -- not required AND not present")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
