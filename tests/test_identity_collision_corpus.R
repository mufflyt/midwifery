#!/usr/bin/env Rscript
# =============================================================================
# L7: contradictory or absent identity evidence cannot increase match certainty
# =============================================================================
# THE LAW
#
#   Removing or contradicting identity evidence may make a pair LESS resolvable.
#   It may never make it MORE resolvable.
#
# And the criterion that matters is not "did it match correctly". It is whether
# an AMBIGUOUS pair stays ambiguous. SCI2 in ci_science_contracts.R polices that
# statically -- no source may resolve an affiliation by picking a winner from
# several. This polices it behaviourally, on the identity functions themselves.
# The two should agree; if they ever disagree, that is itself informative.
#
# THE CORPUS IS SYNTHETIC AND FROZEN. Real collisions live in the frozen
# linkage, which is person-level and gitignored, so a corpus that runs in public
# CI had to be built rather than sampled. Every name is constructed to collide.
#
# WHAT IS ACTUALLY CALLED. middle_state() and
# are_credentials_compatible_midwifery() are the repository's real identity
# functions and are exercised directly. score_one() in match_nppes.R is NOT
# reachable here: it closes over roster and candidate globals and sourcing the
# file runs the whole matcher against a 174 MB candidate table. So this asserts
# the law on the EVIDENCE, which is what a resolver consumes, rather than on a
# reimplementation of the resolver -- a private copy would test the copy.
#
# AMBIGUITY WITHOUT A RESOLVER. A pair is ambiguous when no available evidence
# separates it. That is a property of the evidence, not of any matcher: if two
# candidates return identical classifications on every dimension, nothing in the
# data can prefer one, and a matcher that prefers one is manufacturing a
# distinction. The corpus marks those pairs `distinguishable = no` and this
# asserts that the functions really do fail to separate them.
# =============================================================================

suppressPackageStartupMessages({ library(dplyr) })

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("R", "lib", "ab_middle_name_common.R"))
source(file.path("credential_compatibility.R"))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }

CORPUS <- file.path("tests", "fixtures", "identity_collision_corpus.tsv")
# A HARD FAILURE, not a skip. The corpus is tracked; its absence means the law
# is not being evaluated, which is a failure and not an excuse.
if (!file.exists(CORPUS)) {
  cat(sprintf("  FAIL the frozen corpus %s is absent. It is a tracked file, so this\n", CORPUS))
  cat("       means L7 is not being evaluated at all.\n\nFAILED (1)\n")
  quit(status = 1)
}
raw <- readLines(CORPUS, warn = FALSE)
raw <- raw[!grepl("^#", raw) & nzchar(trimws(raw))]
hdr <- strsplit(raw[1], "\t")[[1]]
cp <- do.call(rbind, lapply(raw[-1], function(l) {
  p <- strsplit(l, "\t", fixed = TRUE)[[1]]; length(p) <- length(hdr); p
}))
cp <- as.data.frame(cp, stringsAsFactors = FALSE); names(cp) <- hdr
cp[is.na(cp)] <- ""

cat(sprintf("\n-- the frozen corpus: %d cases, %d categories --\n",
            nrow(cp), length(unique(cp$category))))
chk(nrow(cp) >= 15L, sprintf("the corpus is non-trivial (%d cases)", nrow(cp)))
chk(!any(duplicated(cp$case_id)), "every case_id is unique")

# --- the real functions, against the frozen expectations ---------------------
cat("\n-- the identity functions still classify the corpus as frozen --\n")
got_mid  <- middle_state(cp$roster_middle, cp$cand_middle)
got_cred <- mapply(are_credentials_compatible_midwifery, cp$roster_cred, cp$cand_cred,
                   USE.NAMES = FALSE)

bad_mid <- which(got_mid != cp$expect_middle)
chk(!length(bad_mid),
    sprintf("middle_state() matches all %d frozen expectations", nrow(cp)))
for (i in bad_mid)
  cat(sprintf("       %s: expected %s, got %s\n", cp$case_id[i], cp$expect_middle[i], got_mid[i]))

bad_cred <- which(as.character(got_cred) != cp$expect_cred_ok)
chk(!length(bad_cred),
    sprintf("the credential gate matches all %d frozen expectations", nrow(cp)))
for (i in bad_cred)
  cat(sprintf("       %s: expected %s, got %s\n", cp$case_id[i], cp$expect_cred_ok[i], got_cred[i]))

# --- the law: masking evidence cannot strengthen a pair ----------------------
# Ordered weakest to strongest as EVIDENCE THAT THE PAIR IS THE SAME PERSON.
# A conflict is the strongest evidence available -- it separates them -- so
# losing a middle name moves a pair from separable to inseparable, never the
# other way.
cat("\n-- the law: removing middle-name evidence cannot separate a pair --\n")
SEPARATES <- function(st) st == "conflict"
pairs <- list(
  list(from = "C03", to = "C16", what = "one side's conflicting middle removed"),
  list(from = "C03", to = "C17", what = "both sides' conflicting middles removed"),
  list(from = "C15", to = "C17", what = "a shared-address pair's initials removed"))
for (p in pairs) {
  a <- which(cp$case_id == p$from); b <- which(cp$case_id == p$to)
  chk(SEPARATES(got_mid[a]) && !SEPARATES(got_mid[b]),
      sprintf("%s -> %s: %s loses the separation, never gains it", p$from, p$to, p$what))
}
chk(!any(SEPARATES(got_mid) & cp$distinguishable == "no"),
    "no pair marked indistinguishable is separated by the middle-name evidence")

# --- ambiguity must survive --------------------------------------------------
cat("\n-- ambiguous pairs stay ambiguous --\n")
amb <- which(cp$distinguishable == "no")
chk(length(amb) >= 6L, sprintf("the corpus carries %d indistinguishable pairs", length(amb)))
sep_amb <- amb[SEPARATES(got_mid[amb]) | !got_cred[amb]]
chk(!length(sep_amb),
    sprintf("none of the %d is separated by any available evidence", length(amb)))
for (i in sep_amb)
  cat(sprintf("       %s was marked indistinguishable but the evidence separates it\n", cp$case_id[i]))

# --- where the pipeline CANNOT satisfy the law -------------------------------
# Held apart and quantified rather than bent to fit, exactly as the ZIP
# truncation limitation is in test_geography_masking_metamorphic.R.
cat("\n-- documented limitation: an absent credential is permissive --\n")
c11 <- which(cp$case_id == "C11"); c12 <- which(cp$case_id == "C12")
chk(!got_cred[c11] && got_cred[c12],
    "C11 -> C12: masking the credential turns an incompatible pair compatible")
cat("       are_credentials_compatible_midwifery() short-circuits to TRUE when either\n")
cat("       side is UNKNOWN, so REMOVING a credential makes a pair MORE acceptable.\n")
cat("       That is the law violated, and it is deliberate: the function is a GATE,\n")
cat("       written to reject only what it positively knows to be incompatible, not\n")
cat("       to require proof of compatibility. Recorded here so the behaviour is\n")
cat("       visible and cannot change silently -- a resolver that treats this gate's\n")
cat("       TRUE as evidence FOR a match, rather than as absence of evidence against\n")
cat("       one, would be reading it wrongly.\n")
n_permissive <- sum(got_cred & (cp$roster_cred == "" | cp$cand_cred == ""))
cat(sprintf("       corpus cases made compatible only by a missing credential: %d\n",
            n_permissive))

# --- an initial agrees with any name sharing it ------------------------------
cat("\n-- documented limitation: an initial cannot distinguish full names --\n")
chk(got_mid[which(cp$case_id == "C04")] == "initial_agreement" &&
    got_mid[which(cp$case_id == "C05")] == "initial_agreement",
    "an initial 'E' agrees with both ELENA and ESTHER")
cat("       middle_state() compares first initials only, so an initial can never\n")
cat("       separate two candidates whose middles share it. A pair distinguished\n")
cat("       ONLY by an initial against a full name is not distinguished at all.\n")

# --- evidence for the coverage registry --------------------------------------
cat("\n")
cat("[LAW] L7 EXERCISED\n")
cat(sprintf("[CONTROL] L7 negative n=%d\n", nrow(cp)))
# POSITIVE: the corpus contains pairs the evidence DOES separate -- a middle
# conflict and a credential conflict -- so the instrument demonstrably responds.
cat(sprintf("[CONTROL] L7 positive n=%d\n",
            sum(got_mid == "conflict") + sum(!got_cred)))

if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
