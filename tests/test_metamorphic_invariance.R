#!/usr/bin/env Rscript
# =============================================================================
# Metamorphic invariance: irrelevant changes must not change the answer
# =============================================================================
# Item 3. Reorder the columns, add one nobody reads, change the line endings,
# quote every field, write it out and read it back -- and the identity
# resolution must be bit-for-bit the same.
#
# WHY THIS IS DIFFERENT FROM THE OTHER SUITES. Ordinary tests hand a function a
# data frame someone built in memory. Production hands it a CSV that came off a
# disk, from an upstream feed that may have added a column, changed its
# quoting, or been written on a different operating system. The transformation
# is irrelevant to the science and invisible in a diff of the numbers, which is
# exactly why it goes unnoticed when it does change something.
#
# ROW ORDER AND CHUNK SIZE ARE DELIBERATELY NOT REPEATED HERE. They are already
# attacked by tests/test_amcb_resolver_permutation.R (300 orderings) and
# tests/test_recovery_resume_equivalence.R (E3, five irregular chunkings). This
# file covers the READ PATH those two do not touch.
#
# IT REUSES THE ADVERSARIAL CORPUS on purpose. tests/fixtures/adversarial_identity/
# already holds people constructed to sit on ties and collisions, so a
# transformation that perturbs anything shows up as a changed identity rather
# than as a rounding difference in a number nobody checks.
#
# NOT EVERYTHING IS INVARIANT, AND THAT IS THE POINT. Case and whitespace in an
# ENUM column are not cosmetic: taxonomy_axis == "midwife" is a comparison
# against a literal. The suite asserts invariance where invariance is claimed,
# and asserts DETECTION where it is not -- silently accepting "MIDWIFE" would
# be worse than rejecting it.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr); library(rlang)})
source(file.path(root, "R", "amcb_resolver.R"))
source(file.path(root, "R", "amcb_cohort_membership.R"))
source(file.path(root, "R", "lib", "common_helpers.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

FIXDIR <- file.path(root, "tests", "fixtures", "adversarial_identity")
CORPUS <- read.csv(file.path(FIXDIR, "corpus.csv"), colClasses = "character")
names(CORPUS)[names(CORPUS) == "synthetic_person"] <- "amcb_id"
names(CORPUS)[names(CORPUS) == "synthetic_npi"]    <- "npi"
CORPUS$name_evidence_class <- as.integer(CORPUS$name_evidence_class)

source(file.path(root, "tests", "helper-resolver-chain.R"))
to_candidates <- chain_to_candidates
classify <- chain_classify

REF <- classify(CORPUS)
cat(sprintf("\nreference: %d people, %d members, %d quarantined, %d held out\n",
            length(REF), sum(REF == "member"), sum(REF == "quarantined"),
            sum(REF == "held_out")))

tmp <- function(ext = ".csv")
  file.path(tempdir(), paste0("meta_", paste(sample(letters, 8), collapse = ""), ext))

# =============================================================================
cat("\n-- M: shape transformations that must change nothing --\n")
# =============================================================================
{
  # Column ORDER. A parser selecting by position rather than by name passes
  # every ordinary test and breaks the moment an upstream feed reorders.
  shuffled_cols <- CORPUS[, sample(ncol(CORPUS)), drop = FALSE]
  chk(identical(classify(shuffled_cols)[names(REF)], REF),
      "M1 shuffling the COLUMN order changes nothing")

  # Reversed column order, specifically: a positional parser often survives a
  # random shuffle by luck and never survives a full reversal.
  chk(identical(classify(CORPUS[, rev(seq_len(ncol(CORPUS))), drop = FALSE])[names(REF)], REF),
      "M2 reversing the column order changes nothing")

  # An EXTRA column nobody reads. Upstream feeds add columns constantly.
  extra <- CORPUS
  extra$upstream_added_this_column <- sprintf("noise-%d", seq_len(nrow(extra)))
  extra$another_one <- NA_character_
  chk(identical(classify(extra)[names(REF)], REF),
      "M3 two unread extra columns change nothing")

  # Row REVERSAL. Cheap, and complements the 300 random orderings elsewhere by
  # hitting the one adversarial order a shuffle almost never produces.
  chk(identical(classify(CORPUS[rev(seq_len(nrow(CORPUS))), , drop = FALSE])[names(REF)], REF),
      "M4 reversing the ROW order changes nothing")

  # Both at once.
  both <- CORPUS[rev(seq_len(nrow(CORPUS))), rev(seq_len(ncol(CORPUS))), drop = FALSE]
  chk(identical(classify(both)[names(REF)], REF),
      "M5 reversing rows AND columns together changes nothing")
}

# =============================================================================
cat("\n-- W: the CSV round trip --\n")
# =============================================================================
# Write it out, read it back, resolve. This is the path production actually
# takes and the one where leading zeros and type inference do their damage.
{
  p <- tmp(); write_csv(CORPUS, p, na = "")
  back <- read_csv(p, show_col_types = FALSE, progress = FALSE,
                   col_types = cols(.default = "c"))
  chk(identical(classify(back)[names(REF)], REF),
      "W1 write -> read -> resolve reproduces the reference exactly")

  # CRLF. Development is on macOS, CI on Linux, and upstream files arrive from
  # Windows.
  p2 <- tmp()
  writeLines(gsub("\n", "\r\n", paste(readLines(p, warn = FALSE), collapse = "\n"),
                  fixed = TRUE), p2, sep = "")
  crlf <- read_csv(p2, show_col_types = FALSE, progress = FALSE,
                   col_types = cols(.default = "c"))
  chk(identical(classify(crlf)[names(REF)], REF),
      "W2 CRLF line endings change nothing")

  # Quote EVERY field rather than only those that need it.
  p3 <- tmp(); write_csv(CORPUS, p3, na = "", quote = "all")
  quoted <- read_csv(p3, show_col_types = FALSE, progress = FALSE,
                     col_types = cols(.default = "c"))
  chk(identical(classify(quoted)[names(REF)], REF),
      "W3 quoting every field changes nothing")

  # Split into irregular pieces, write each, read and recombine.
  p4 <- tmp()
  idx <- split(seq_len(nrow(CORPUS)),
               rep(seq_len(4), length.out = nrow(CORPUS)))
  parts <- lapply(idx, function(i) {
    f <- tmp(); write_csv(CORPUS[i, , drop = FALSE], f, na = "")
    read_csv(f, show_col_types = FALSE, progress = FALSE,
             col_types = cols(.default = "c"))
  })
  recombined <- bind_rows(parts)
  chk(nrow(recombined) == nrow(CORPUS) &&
        identical(classify(recombined)[names(REF)], REF),
      "W4 splitting into 4 files and recombining changes nothing")
}

# =============================================================================
cat("\n-- Z: leading zeros must survive serialization --\n")
# =============================================================================
# IDs must never traverse a numeric type. A county FIPS read as a number loses
# its leading zero and then joins to the wrong county, or to nothing.
{
  ids <- data.frame(
    geoid = c("01001", "02013", "06075", "72001"),
    zip = c("01002", "02134", "90210", "00501"),
    ccn = c("010001", "020001", "050002", "450010"),
    stringsAsFactors = FALSE)

  p <- tmp(); write_csv(ids, p, na = "")

  # Read WITHOUT declaring types -- the mistake this guards.
  guessed <- suppressWarnings(read_csv(p, show_col_types = FALSE, progress = FALSE))
  declared <- read_csv(p, show_col_types = FALSE, progress = FALSE,
                       col_types = cols(.default = "c"))

  chk(identical(as.character(declared$geoid), ids$geoid),
      "Z1 declaring character types round-trips a FIPS with its leading zero")

  # The padding helpers must repair a value that HAS been through numeric
  # inference, because in the wild it will have been.
  chk(identical(pad5(as.character(as.numeric(ids$geoid))), ids$geoid),
      "Z2 pad5() restores a FIPS that was read as a number")
  chk(identical(pad_ccn(as.character(as.numeric(ids$ccn))), ids$ccn),
      "Z3 pad_ccn() restores a CCN that was read as a number")
  chk(identical(zip5_key(ids$zip), ids$zip),
      "Z4 zip5_key() preserves a ZIP that already has its leading zero")

  # A BLANK code must become NA, never a padded zero. "00000" is not a county
  # and "000000" is not a CCN, but both join perfectly to every other blank
  # record -- a missing value wearing the face of a real one. The helpers'
  # own comments describe this defect; nothing tested it, and a mutation
  # removing the guard survived until this was written.
  blanks <- c("", "   ", NA_character_)
  chk(all(is.na(pad5(blanks))),
      sprintf("Z5 pad5() maps blank/whitespace/NA to NA, not \"00000\" [%s]",
              paste(pad5(blanks), collapse = ",")))
  chk(all(is.na(pad_ccn(blanks))),
      sprintf("Z6 pad_ccn() maps blank/whitespace/NA to NA, not \"000000\" [%s]",
              paste(pad_ccn(blanks), collapse = ",")))
  chk(all(is.na(zip5_key(c("", "  ", "NA", "N/A", NA_character_)))),
      sprintf("Z7 zip5_key() maps blank, \"NA\" and \"N/A\" to NA [%s]",
              paste(zip5_key(c("", "  ", "NA", "N/A", NA_character_)), collapse = ",")))

  # And a real code must still survive all three.
  chk(identical(pad5("1001"), "01001"), "Z8 pad5() still pads a real short FIPS")
  chk(identical(pad_ccn("10001"), "010001"), "Z9 pad_ccn() still pads a real short CCN")

  # Report, do not assert: whether readr guesses these as numeric is readr's
  # behaviour, not this repository's contract. What matters is that the helpers
  # above repair it either way.
  lost <- names(ids)[vapply(names(ids),
                            function(k) !is.character(guessed[[k]]), logical(1))]
  cat(sprintf("       type inference without col_types made %d of 3 columns numeric [%s]\n",
              length(lost), if (length(lost)) paste(lost, collapse = ", ") else "none"))
}

# =============================================================================
cat("\n-- N: transformations that are NOT cosmetic must be DETECTED --\n")
# =============================================================================
# Invariance is only a virtue where it is true. taxonomy_axis is compared
# against the literal "midwife"; "MIDWIFE" is a different value and must not be
# quietly accepted as the same one. A suite that asserted blanket
# case-insensitivity here would be asserting a bug.
{
  # FINDING, 2026-08-16. Upper-casing taxonomy_axis moves NOBODY between
  # member / held_out / quarantined, so an outcome-level assertion sees
  # nothing. The tier underneath does move, and it moves the wrong way:
  #
  #     "nursing"    -> sensitivity_nursing
  #     "NURSING"    -> primary_midwifery      <- case drift
  #     " nursing "  -> primary_midwifery      <- whitespace
  #     "garbage"    -> primary_midwifery      <- corrupt value
  #
  # amcb_linkage_tier() tests `npi_tax_class == "nursing"` and falls through to
  # primary_midwifery on anything else. So an UNRECOGNISED taxonomy value is
  # promoted to the STRONGEST tier -- a fail-OPEN. Bad upstream data does not
  # make a match look weaker, it makes it look stronger, which is the opposite
  # of what a resolver should do with information it does not understand.
  #
  # Both tiers are cohort-eligible, so no count changes and no existing test
  # fires. What changes is the published claim about HOW someone was
  # identified.
  #
  # NOT FIXED HERE. The remedy is a policy decision -- reject an unknown
  # taxonomy, or treat unknown as nursing and lose the primary tier for records
  # with dirty data. Current behaviour is pinned below so that changing it is
  # deliberate rather than accidental.
  tier <- function(tax) amcb_linkage_tier("2000000001", 2L, tax)

  chk(identical(tier("nursing"), "sensitivity_nursing"),
      "N1 the exact value 'nursing' yields sensitivity_nursing")

  for (bad in c("NURSING", " nursing ", "Nursing", "garbage", "")) {
    chk(identical(tier(bad), "primary_midwifery"),
        sprintf("N2 CURRENT BEHAVIOUR: taxonomy %-12s -> %s (fail-OPEN, see comment)",
                sprintf("'%s'", bad), tier(bad)))
  }

  cat("\n       ^^ N2 pins a fail-OPEN, it does not endorse it. An unrecognised\n")
  cat("          taxonomy is promoted to the strongest tier. Raised for a\n")
  cat("          policy decision; see the commit message.\n\n")

  # What IS safely assertable today: an unrecognised taxonomy must never make
  # anyone MORE cohort-eligible than the clean value does.
  rank_of <- c(quarantined = 0L, held_out = 1L, member = 2L)
  upper <- CORPUS; upper$taxonomy_axis <- toupper(upper$taxonomy_axis)
  got <- classify(upper)[names(REF)]
  chk(all(rank_of[got] <= rank_of[REF]),
      "N3 an unrecognised taxonomy never increases anyone's cohort eligibility")
}

# =============================================================================
cat("\n-- D: the duplicate-column attack --\n")
# =============================================================================
# Two columns of one name is silent shadowing: one wins, nobody is told which.
{
  p <- tmp()
  hdr <- paste(c(names(CORPUS), "taxonomy_axis"), collapse = ",")
  rows <- apply(cbind(CORPUS, dup = "nursing"), 1,
                function(r) paste(r, collapse = ","))
  writeLines(c(hdr, rows), p)

  dup <- suppressWarnings(tryCatch(
    read_csv(p, show_col_types = FALSE, progress = FALSE,
             col_types = cols(.default = "c")),
    error = function(e) NULL))

  if (is.null(dup)) {
    chk(TRUE, "D1 a duplicated column name is REJECTED at read time")
  } else {
    renamed <- setdiff(names(dup), names(CORPUS))
    chk(length(renamed) > 0L,
        sprintf("D1 a duplicated column is RENAMED rather than silently shadowing [%s]",
                paste(renamed, collapse = ", ")))
    # taxonomy_axis is now taxonomy_axis...6 / ...11, so the resolver cannot
    # find the column at all. Erring is the CORRECT outcome -- silently
    # resolving with a shadowed column would be the dangerous one.
    err <- tryCatch({ classify(dup); NULL }, error = function(e) conditionMessage(e))
    chk(!is.null(err),
        sprintf("D2 a shadowed column makes the resolver FAIL LOUDLY rather than guess [%s]",
                substr(gsub("\\s+", " ", err %||% "no error"), 1, 60)))
  }
}

# =============================================================================
cat("\n-- NC: the harness can detect a non-invariant pipeline --\n")
# =============================================================================
# A metamorphic suite that cannot fail proves nothing. Classify by COLUMN
# POSITION instead of by name -- the bug M1/M2 exist to catch -- and confirm
# the same comparison reports a difference.
{
  positional_classify <- function(df) {
    # Reads the 4th column as the evidence class, whatever it happens to be.
    d <- df
    d$name_evidence_class <- suppressWarnings(as.integer(d[[4L]]))
    d$name_evidence_class[is.na(d$name_evidence_class)] <- 3L
    classify(d)
  }
  ref_p <- positional_classify(CORPUS)
  got_p <- positional_classify(CORPUS[, rev(seq_len(ncol(CORPUS))), drop = FALSE])
  chk(!identical(got_p[names(ref_p)], ref_p),
      "NC a position-based parser IS detected as column-order dependent")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
