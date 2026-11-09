#!/usr/bin/env Rscript
# =============================================================================
# The missing freeze step: linkage crosswalk -> amcb_npi_linkage_FROZEN.csv
# =============================================================================
# artifacts/amcb_npi_linkage_FROZEN.csv has 77 readers in this repo and, until
# now, NO WRITER. frozen_dependency_graph.R:109 even carries a regex to detect
# one, which never matched. The cohort could be read, audited and depended on,
# but not regenerated -- so a better NPPES vintage could not reach any analysis
# that used it. This script is that writer, reconstructed from evidence rather
# than from memory.
#
# HOW THE RULE WAS RECOVERED, since nothing documented it as code. Three
# independent sources agree, which is why this is a reconstruction and not a
# guess:
#   1. The manifest of the existing freeze records the decision in words --
#      run refreeze_option2_20260810T192207, "Option 2: class-5 (surname
#      component) held OUT of analytic membership", cohort_members 16,898,
#      class5_candidates_held_out 156.
#   2. amcb_audit_c5guard.log, written by the original run, counts the evidence
#      classes: 9,411 / 6,483 / 681 / 323 / 156, ambiguous 3,147, unmatched
#      2,108, total 22,309.
#   3. The artifact itself reproduces those counts exactly, and 1+2+3+4 =
#      16,898 = the manifest's membership.
#
# So the rule is:
#   cohort_member := name_evidence_class in {1,2,3,4} AND npi is non-empty
#   class 5       := npi MOVED to class5_candidate_npi, npi blanked, not a member
#   ambiguous/unmatched := no npi, not a member
#
# THE HOLDOUT IS THIS SCRIPT'S JOB, NOT match_amcb_to_npi.R's. Measured on
# artifacts/..._rerun20260901.csv, that script populates class5_candidate_npi
# for 8 rows -- the absence-based demotion (npi_demoted_absence_c5), a
# different and smaller mechanism. The 156-row Option 2 holdout appears only in
# the frozen artifact. Keeping the two separate matters: the linkage stage
# reports what the evidence says, and the freeze decides what the STUDY counts
# as a member. Collapsing them would bury a membership decision inside a
# matching script.
#
# IT WILL NOT SILENTLY REPLACE A FREEZE. Dry run by default, like
# repin_frozen_cohort.R. Writing requires FREEZE_WRITE=1, archives the prior
# freeze under its own date, and refuses outright if the prior artifact does
# not match its own manifest hash -- a freeze that has already drifted must be
# investigated, not overwritten.
#
# Usage:
#   Rscript freeze_cohort.R                 # dry run: report what would change
#   FREEZE_VERIFY=1 Rscript freeze_cohort.R # reproduce the EXISTING freeze from
#                                           #   its recorded source and diff
#   FREEZE_WRITE=1 Rscript freeze_cohort.R  # write a new freeze + manifest
#
# Inputs : SOURCE_CROSSWALK (env; default: latest linkage artifact via
#            R/lib/cohort_artifacts.R)
# Outputs: artifacts/amcb_npi_linkage_FROZEN.csv (+ .manifest.json, + archive)
#
# @family cohort
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(jsonlite); library(digest)
})
source(file.path("R", "lib", "cohort_artifacts.R"))

# ART is a parameter for the same reason source_vintage.R takes data_root: the
# CODE and the ARTIFACTS are not always in the same checkout, and the
# alternative (symlinking artifacts into a git worktree) shadowed TRACKED files
# with another branch's copies earlier in this work and broke a contract gate.
ART        <- Sys.getenv("FREEZE_ART_DIR", "artifacts")
# NAMED *_OUT ON PURPOSE. R/frozen_dependency_graph.R classifies a script as a
# PRODUCER of the freeze -- and so excludes it from the rebuild order, the way
# reconcile_linkage.R is excluded -- by looking for a write_csv() straight at
# the path or at a `*OUT` variable holding it. Called plain `FROZEN` this script
# was discovered as the 78th CONSUMER, and the completeness gate (T5 in
# tests/test_frozen_dependency.R) demanded it be declared as something a
# rebuild runs. A runner that re-freezes the cohort partway through propagating
# it is the 2026-08-10 failure again, so the name is load-bearing, not cosmetic.
FROZEN_OUT <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")
MANIFEST   <- paste0(FROZEN_OUT, ".manifest.json")
MEMBER_CLASSES <- c("1", "2", "3", "4")
HELD_OUT_CLASS <- "5"
HELD_OUT_STATUS <- "candidate_class5_held_out_of_cohort"

VERIFY <- identical(Sys.getenv("FREEZE_VERIFY"), "1")
WRITE  <- identical(Sys.getenv("FREEZE_WRITE"), "1")

#' Apply the membership rule. This is the whole scientific content of the freeze.
apply_freeze_rule <- function(x) {
  stopifnot(all(c("npi", "name_evidence_class") %in% names(x)))
  # NA IS NOT A CLASS, AND ifelse() DOES NOT KNOW THAT. 5,255 rows (ambiguous
  # and unmatched) carry an empty evidence class, which reads as NA. Left as NA,
  # `cls == "5"` is NA, and ifelse(NA, a, b) returns NA -- so every one of those
  # rows had its npi_match_status silently blanked. It passed the first verify
  # only because NA and "" normalise alike in the comparison. Collapsing NA to
  # "" first makes `held` an honest logical.
  cls <- trimws(as.character(x$name_evidence_class))
  cls[is.na(cls)] <- ""
  npi <- trimws(as.character(x$npi)); npi[is.na(npi)] <- ""
  held <- cls == HELD_OUT_CLASS
  # Option 2: a class-5 NPI is PRESERVED, not discarded -- it moves to
  # class5_candidate_npi so the decision stays reversible and auditable. A
  # freeze that deleted the candidate could not be revisited.
  prior_c5 <- if ("class5_candidate_npi" %in% names(x))
    ifelse(is.na(x$class5_candidate_npi), "", trimws(as.character(x$class5_candidate_npi))) else ""
  x$class5_candidate_npi <- ifelse(held & nzchar(npi), npi, prior_c5)
  x$npi <- ifelse(held, "", npi)
  # The status is RESTATED for a held-out row, not left reading "matched" with
  # an empty npi -- which is what made this rule recoverable in the first place
  # and is the only reason a reader can tell a held-out candidate from a
  # genuine non-match. Recovered from the artifact: all 156 class-5 rows carry
  # 'candidate_class5_held_out_of_cohort', overwriting 'matched' (126) and
  # 'matched_nursing_taxonomy' (30). That overwrite discards which taxonomy the
  # held-out candidate matched under; npi_tax_class still records it, so the
  # information survives in the row even though this column no longer shows it.
  if ("npi_match_status" %in% names(x))
    x$npi_match_status <- ifelse(held, HELD_OUT_STATUS, x$npi_match_status)
  x$cohort_member <- cls %in% MEMBER_CLASSES & nzchar(x$npi)
  x
}

SRC <- Sys.getenv("SOURCE_CROSSWALK", "")
if (VERIFY) {
  # Reproduce the EXISTING freeze from the source its own manifest names. If
  # this script cannot rebuild the artifact that is already on disk, it has no
  # business writing the next one.
  if (!file.exists(MANIFEST)) stop("no manifest to verify against: ", MANIFEST, call. = FALSE)
  man <- fromJSON(MANIFEST)
  SRC <- file.path(ART, man$source_crosswalk)
  if (!file.exists(SRC))
    stop(sprintf("manifest names source_crosswalk '%s', which is not on disk.", man$source_crosswalk),
         call. = FALSE)
  cat(sprintf("VERIFY: rebuilding %s from its recorded source %s\n",
              basename(FROZEN_OUT), basename(SRC)))
} else if (!nzchar(SRC)) {
  SRC <- cohort_artifact_path("linkage", art_dir = ART)
  cat(sprintf("source crosswalk (latest linkage artifact): %s\n", basename(SRC)))
}

src <- read_csv(SRC, col_types = cols(.default = "c"), progress = FALSE)
cat(sprintf("source: %s rows, %s columns\n",
            format(nrow(src), big.mark = ","), ncol(src)))
built <- apply_freeze_rule(src)

n_members <- sum(built$cohort_member)
n_held    <- sum(trimws(built$name_evidence_class) == HELD_OUT_CLASS, na.rm = TRUE)
cat(sprintf("freeze rule applied: %s members, %s class-5 held out, %s rows total\n",
            format(n_members, big.mark = ","), format(n_held, big.mark = ","),
            format(nrow(built), big.mark = ",")))
cat("evidence class distribution:\n")
print(table(class = trimws(built$name_evidence_class),
            member = built$cohort_member, useNA = "ifany"))

if (VERIFY) {
  cur <- read_csv(FROZEN_OUT, col_types = cols(.default = "c"), progress = FALSE)
  shared <- intersect(names(cur), names(built))
  key <- "certification_number"
  a <- cur[match(built[[key]], cur[[key]]), shared, drop = FALSE]
  b <- built[, shared, drop = FALSE]
  # STRICT, AND MISSINGNESS IS PART OF THE COMPARISON. A lenient compare that
  # folds NA into "" is how the NA bug in this very script survived its first
  # verification, so NA-vs-empty is counted SEPARATELY rather than forgiven.
  # Only cohort_member is case-normalised, because it is logical on one side and
  # the string "TRUE"/"FALSE" on the other.
  norm <- function(d) as.data.frame(lapply(names(d), function(n) {
    v <- d[[n]]
    v <- if (is.logical(v)) ifelse(v, "TRUE", "FALSE") else trimws(as.character(v))
    if (n == "cohort_member") toupper(v) else v
  }), stringsAsFactors = FALSE, col.names = names(d))
  a <- norm(a); b <- norm(b)
  na_only <- integer(0); diffs <- integer(0)
  for (c in shared) {
    av <- a[[c]]; bv <- b[[c]]
    both_blank <- (is.na(av) | !nzchar(av)) & (is.na(bv) | !nzchar(bv))
    # a blank on both sides, but spelled differently (NA vs "") -- content is
    # the same, representation is not; reported apart so neither hides.
    na_only[c]  <- sum(both_blank & (is.na(av) != is.na(bv)))
    diffs[c] <- sum(!both_blank & (is.na(av) | is.na(bv) | av != bv))
  }
  bad <- diffs[diffs > 0]
  nao <- na_only[na_only > 0]
  if (length(nao)) {
    cat("  NA-vs-empty representation differences (content equal):\n")
    for (c in names(nao)) cat(sprintf("    %-34s %d rows\n", c, nao[[c]]))
  } else cat("  missing values: identical representation in every column\n")

  # CANONICALIZED CONTENT HASH. Raw file bytes would differ on quoting style
  # alone, which says nothing about the data, so BOTH frames are re-serialised
  # through the same writer and those bytes are hashed. Equal hashes mean equal
  # content under one canonical form.
  canon <- function(d, cols) {
    f <- tempfile(fileext = ".csv")
    d2 <- d[order(d[[key]]), cols, drop = FALSE]
    d2 <- as.data.frame(lapply(d2, function(v) {
      v <- if (is.logical(v)) ifelse(v, "TRUE", "FALSE") else trimws(as.character(v))
      ifelse(is.na(v), "", v)
    }), stringsAsFactors = FALSE, col.names = cols)
    readr::write_csv(d2, f, na = "")
    on.exit(unlink(f), add = TRUE)
    digest::digest(file = f, algo = "sha256")
  }
  h_cur <- canon(cur, shared); h_new <- canon(built, shared)
  cat(sprintf("  canonical content sha256 (existing): %s\n", h_cur))
  cat(sprintf("  canonical content sha256 (rebuilt) : %s\n", h_new))
  cat(sprintf("  canonical hashes %s\n",
              if (identical(h_cur, h_new)) "MATCH -- content is identical" else "DIFFER"))
  cat(sprintf("\nVERIFY: %d/%d shared columns reproduce EXACTLY\n",
              sum(diffs == 0), length(shared)))
  only_cur <- setdiff(names(cur), names(built)); only_new <- setdiff(names(built), names(cur))
  if (length(only_cur)) cat("  columns only in the existing freeze:", paste(only_cur, collapse = ", "), "\n")
  if (length(only_new)) cat("  columns only in the rebuild:", paste(only_new, collapse = ", "), "\n")
  if (length(bad)) {
    cat("  COLUMNS THAT DIFFER:\n")
    for (c in names(sort(bad, decreasing = TRUE))) cat(sprintf("    %-34s %d rows\n", c, bad[[c]]))
  }
  cat(sprintf("\nmembership: rebuilt %s vs manifest %s -> %s\n",
              format(n_members, big.mark = ","), format(man$cohort_members, big.mark = ","),
              if (identical(as.integer(n_members), as.integer(man$cohort_members))) "MATCH" else "MISMATCH"))
  cat(sprintf("class-5 held out: rebuilt %s vs manifest %s -> %s\n",
              n_held, man$class5_candidates_held_out,
              if (identical(as.integer(n_held), as.integer(man$class5_candidates_held_out))) "MATCH" else "MISMATCH"))
  ok <- !length(bad) && identical(h_cur, h_new) &&
        identical(as.integer(n_members), as.integer(man$cohort_members)) &&
        identical(as.integer(n_held), as.integer(man$class5_candidates_held_out))
  cat(sprintf("\n%s\n", if (ok) "VERIFY PASSED -- this script reproduces the existing freeze"
                        else "VERIFY FAILED -- do not use this to write a freeze"))
  quit(status = if (ok) 0L else 1L)
}

if (!WRITE) {
  cat("\nDRY RUN (set FREEZE_WRITE=1 to write). Nothing was modified.\n")
  if (file.exists(FROZEN_OUT)) {
    cur <- read_csv(FROZEN_OUT, col_types = cols(.default = "c"), progress = FALSE)
    cur_m <- sum(toupper(trimws(cur$cohort_member)) == "TRUE")
    cat(sprintf("would change membership: %s -> %s (%+d)\n",
                format(cur_m, big.mark = ","), format(n_members, big.mark = ","),
                n_members - cur_m))
  }
  quit(status = 0L)
}

# --- writing a new freeze ----------------------------------------------------
prior_sha <- NA_character_; prior_members <- NA_integer_
if (file.exists(FROZEN_OUT)) {
  prior_sha <- digest(file = FROZEN_OUT, algo = "sha256")
  if (file.exists(MANIFEST)) {
    man <- fromJSON(MANIFEST)
    if (!is.null(man$artifact_sha256) && !identical(man$artifact_sha256, prior_sha))
      stop(sprintf(paste0("the freeze on disk does not match its own manifest.\n",
                          "  manifest: %s\n  on disk : %s\n",
                          "  A drifted freeze must be investigated, not overwritten."),
                   man$artifact_sha256, prior_sha), call. = FALSE)
    prior_members <- man$cohort_members
  }
  arch <- file.path(ART, sprintf("amcb_npi_linkage_FROZEN_%s.csv", format(Sys.Date(), "%Y-%m-%d")))
  if (file.exists(arch))
    stop(sprintf("%s already exists; today's freeze is already archived.", arch), call. = FALSE)
  file.copy(FROZEN_OUT, arch)
  cat(sprintf("archived prior freeze -> %s\n", arch))
}

prior_ids <- if (file.exists(FROZEN_OUT)) {
  c0 <- read_csv(FROZEN_OUT, col_types = cols(.default = "c"), progress = FALSE)
  c0$amcb_id[toupper(trimws(c0$cohort_member)) == "TRUE"]
} else character(0)
new_ids <- built$amcb_id[built$cohort_member]

out <- built %>% mutate(cohort_member = ifelse(cohort_member, "TRUE", "FALSE"))
write_csv(out, FROZEN_OUT, na = "")
sha <- digest(file = FROZEN_OUT, algo = "sha256")

write_json(list(
  run_id = sprintf("freeze_option2_%s", format(Sys.time(), "%Y%m%dT%H%M%S")),
  decision = "Option 2: class-5 (surname component) held OUT of analytic membership",
  rebuilt_by = "freeze_cohort.R (reconstructed producer; see its header)",
  cohort_changed = !identical(sort(prior_ids), sort(new_ids)),
  prior_frozen_sha256 = prior_sha, prior_frozen_members = prior_members,
  artifact_sha256 = sha, artifact_rows = nrow(out), cohort_members = n_members,
  net_membership_change = if (is.na(prior_members)) NA_integer_ else n_members - prior_members,
  added_amcb_ids = setdiff(new_ids, prior_ids), removed_amcb_ids = setdiff(prior_ids, new_ids),
  class5_candidates_held_out = n_held,
  membership_rule = c("primary_midwifery", "sensitivity_nursing", "sensitivity_fuzzy"),
  source_crosswalk = basename(SRC),
  source_crosswalk_sha256 = digest(file = SRC, algo = "sha256"),
  columns = names(out)), MANIFEST, auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("wrote %s (sha256 %s)\n  members %s, %s rows\n  manifest -> %s\n",
            FROZEN_OUT, substr(sha, 1, 16), format(n_members, big.mark = ","),
            format(nrow(out), big.mark = ","), MANIFEST))
