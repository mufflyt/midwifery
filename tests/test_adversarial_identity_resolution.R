#!/usr/bin/env Rscript
# =============================================================================
# Adversarial identity resolution: can the resolver tell identification from
# "one candidate happened to look best"?
# =============================================================================
# Items 7 + 45 + 46. A permanent, versioned synthetic corpus of the ways an
# identity resolver gets fooled, held in tests/fixtures/adversarial_identity/
# so that later work -- metamorphic tests, source-dropout, threshold sweeps --
# reuses these exact people rather than inventing new ones.
#
# THE CORPUS IS NOT OPTIMISED FOR MATCH RATE. Most of it is SUPPOSED to stay
# unresolved. A change that raises the match rate here is a regression until
# proven otherwise: the whole point is that "no candidate is identifiable" is
# the correct scientific answer far more often than a matching pipeline's
# instincts suggest.
#
# WHAT IS EXERCISED. The production chain, end to end and nothing copied:
#
#   amcb_resolve()        R/amcb_resolver.R      stage 1: unique best class
#   amcb_linkage_tier()   R/amcb_resolver.R      evidence tier
#   is_cohort_member()    R/amcb_cohort_membership.R   eligibility
#
# WHAT IS NOT, AND THIS MATTERS. Several adversarial families the corpus names
# -- license-state collisions, credential incompatibility, address agreement,
# former-name provenance -- are decided during CANDIDATE GENERATION in
# match_amcb_to_npi.R, upstream of everything callable here. They reach the
# resolver already reduced to an evidence class. Encoding them as candidate
# rows and then asserting on them would test THIS FILE'S encoding, not the
# resolver, so they are represented by the evidence class generation would
# assign and the limitation is reported rather than papered over. See the
# LIMITS section at the end, which prints every such family by name.
#
# No real people. No production person-level data. Every NPI here is synthetic
# and outside the ranges the pipeline uses.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(rlang)})
source(file.path(root, "R", "amcb_resolver.R"))
source(file.path(root, "R", "amcb_cohort_membership.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

FIXDIR <- file.path(root, "tests", "fixtures", "adversarial_identity")
CORPUS <- read.csv(file.path(FIXDIR, "corpus.csv"), colClasses = "character")
DECOY  <- read.csv(file.path(FIXDIR, "decoy_escalation.csv"), colClasses = "character")
# The fixture columns are named synthetic_npi / expect_synthetic_npi, not npi.
# tests/ci_leak_guard.R matches the WHOLE column name "npi" on every tracked
# CSV, and its baseline is a ratchet that may shrink and never grow. These are
# invented identifiers for invented people, so the right move is not to buy an
# exemption but to not look like person-level data in the first place.
# amcb_id is in PERSON_COLS too. Same reasoning, same fix.
names(CORPUS)[names(CORPUS) == "synthetic_person"] <- "amcb_id"
names(DECOY)[names(DECOY) == "synthetic_person"] <- "amcb_id"
names(CORPUS)[names(CORPUS) == "synthetic_npi"] <- "npi"
names(CORPUS)[names(CORPUS) == "expect_synthetic_npi"] <- "expect_npi"
names(DECOY)[names(DECOY) == "synthetic_npi"] <- "npi"
CORPUS$name_evidence_class <- as.integer(CORPUS$name_evidence_class)
DECOY$name_evidence_class  <- as.integer(DECOY$name_evidence_class)
DECOY$step <- as.integer(DECOY$step)

# -----------------------------------------------------------------------------
# The production decision chain, as one call. Nothing here reimplements a rule.
# -----------------------------------------------------------------------------
source(file.path(root, "tests", "helper-resolver-chain.R"))
to_candidates <- chain_to_candidates
classify <- function(df) chain_classify(df, detail = TRUE)

npi_of <- function(res, id) {
  r <- res$resolved[res$resolved$amcb_id == id, , drop = FALSE]
  if (nrow(r) == 1L) r$npi else NA_character_
}

cat(sprintf("\ncorpus: %d rows, %d people, %d families\n",
            nrow(CORPUS), n_distinct(CORPUS$amcb_id), n_distinct(CORPUS$family)))

# =============================================================================
cat("\n-- J: the corpus must genuinely be adversarial --\n")
# =============================================================================
# Tested FIRST. Every assertion below is meaningless if a future edit quietly
# makes the corpus easy, and an easy corpus passes silently.
{
  chk(sum(CORPUS$kind == "positive") >= 8L,
      sprintf("J1 corpus holds %d positive-control rows", sum(CORPUS$kind == "positive")))
  chk(sum(CORPUS$kind == "negative") >= 10L,
      sprintf("J2 corpus holds %d negative-control rows", sum(CORPUS$kind == "negative")))
  chk(sum(CORPUS$expect == "quarantined") >= 10L,
      sprintf("J3 %d rows are EXPECTED to stay unresolved", sum(CORPUS$expect == "quarantined")))

  base <- amcb_resolve(to_candidates(CORPUS))
  ties <- base$pool_stats %>% filter(n_at_best_class > 1L)
  chk(nrow(ties) >= 5L, sprintf("J4 %d people are tied at their best class", nrow(ties)))

  contested <- base$resolved %>% count(npi) %>% filter(n > 1L)
  chk(nrow(contested) >= 1L,
      sprintf("J5 %d npi(s) are claimed by more than one person", nrow(contested)))

  chk(n_distinct(CORPUS$family[CORPUS$kind == "collision"]) >= 3L,
      sprintf("J6 %d distinct collision families",
              n_distinct(CORPUS$family[CORPUS$kind == "collision"])))
  chk(any(CORPUS$name_evidence_class == 5L) && any(CORPUS$name_evidence_class == 4L),
      "J7 corpus contains class-4 and class-5 evidence, not only strong classes")
  chk(n_distinct(DECOY$name_evidence_class) >= 4L,
      sprintf("J8 decoys span %d evidence strengths",
              n_distinct(DECOY$name_evidence_class)))
  chk(any(CORPUS$taxonomy_axis == "nursing"),
      "J9 corpus contains a nursing-taxonomy candidate")
}

# =============================================================================
cat("\n-- A: positive controls must resolve, to the declared NPI --\n")
# =============================================================================
{
  res <- classify(CORPUS)
  pos <- CORPUS %>% filter(kind == "positive", expect == "member") %>%
    distinct(amcb_id, expect_npi, family)
  wrong <- 0L
  for (i in seq_len(nrow(pos))) {
    got <- res$outcome[[pos$amcb_id[i]]]
    npi <- npi_of(res, pos$amcb_id[i])
    ok <- identical(got, "member") && identical(npi, pos$expect_npi[i])
    if (!ok) { wrong <- wrong + 1L
      cat(sprintf("       %-28s got %s npi=%s, expected member npi=%s\n",
                  pos$family[i], got, npi, pos$expect_npi[i])) }
  }
  chk(wrong == 0L, sprintf("A1 all %d positive controls resolve to their declared NPI [%d wrong]",
                           nrow(pos), wrong))
}

# =============================================================================
cat("\n-- B/G: ZERO negative controls may falsely resolve --\n")
# =============================================================================
# No percentage tolerance. One false identity in this corpus fails the gate.
{
  res <- classify(CORPUS)
  neg <- CORPUS %>% filter(kind == "negative") %>% distinct(amcb_id, expect, family)
  false_positive <- character(0)
  for (i in seq_len(nrow(neg))) {
    got <- res$outcome[[neg$amcb_id[i]]]
    if (identical(neg$expect[i], "quarantined") && !identical(got, "quarantined")) {
      false_positive <- c(false_positive, sprintf("%s(%s)", neg$family[i], got))
    }
    if (identical(neg$expect[i], "held_out") && identical(got, "member")) {
      false_positive <- c(false_positive, sprintf("%s(admitted to cohort)", neg$family[i]))
    }
  }
  chk(length(false_positive) == 0L,
      sprintf("B1 false accepted identities across the negative corpus = %d [%s]",
              length(false_positive), paste(false_positive, collapse = ", ")))

  held <- neg$amcb_id[neg$expect == "held_out"]
  chk(all(res$outcome[held] == "held_out"),
      sprintf("B2 weak-evidence people are HELD OUT, not admitted [%s]",
              paste(res$outcome[held], collapse = ", ")))
}

# =============================================================================
cat("\n-- B3: the eligibility policy itself is pinned --\n")
# =============================================================================
# Building this corpus, I assumed a fuzzy surname match was sensitivity-only.
# It is not: COHORT_MEMBERSHIP_TIERS deliberately admits sensitivity_fuzzy, so
# a surname within edit distance 2 plus an exact given name enters the analytic
# cohort. That is a real scientific choice and it should not be discoverable
# only by being surprised, so it is pinned here by value.
{
  chk(identical(sort(COHORT_MEMBERSHIP_TIERS),
                sort(c("primary_midwifery", "sensitivity_nursing", "sensitivity_fuzzy"))),
      sprintf("B3a cohort-eligible tiers are exactly the three declared [%s]",
              paste(COHORT_MEMBERSHIP_TIERS, collapse = ", ")))
  chk(!("sensitivity_name_component" %in% COHORT_MEMBERSHIP_TIERS),
      "B3b class-5 surname fragments are NOT cohort-eligible")
  chk("sensitivity_fuzzy" %in% COHORT_MEMBERSHIP_TIERS,
      "B3c class-4 fuzzy surnames ARE cohort-eligible (declared policy, not an accident)")
}

# =============================================================================
cat("\n-- B4: the TIER itself, not merely eligibility --\n")
# =============================================================================
# Asserting membership alone is not enough. Mutation testing promoted class-4
# to primary_midwifery and every membership assertion still passed, because
# sensitivity_fuzzy and primary_midwifery are BOTH cohort-eligible -- the
# outcome was identical while the reported evidence strength was a lie. The
# tier is a published claim about how a person was identified, so it is pinned
# per class directly.
{
  want <- c("1" = "primary_midwifery", "2" = "primary_midwifery",
            "3" = "primary_midwifery", "4" = "sensitivity_fuzzy",
            "5" = "sensitivity_name_component")
  for (cl in names(want)) {
    got <- amcb_linkage_tier("2000000001", as.integer(cl), "midwife")
    chk(identical(got, unname(want[cl])),
        sprintf("B4 class %s -> %s [got %s]", cl, want[cl], got))
  }
  chk(identical(amcb_linkage_tier("2000000001", 2L, "nursing"),
                "sensitivity_nursing"),
      "B4 class 2 with a nursing-taxonomy NPI -> sensitivity_nursing")

  # Missing evidence must never be read as agreement. classify() only ever
  # hands is_cohort_member() RESOLVED rows, so a mutation making an absent NPI
  # count as present survived unnoticed. Exercise the boundary directly.
  chk(!is_cohort_member(NA_character_, "primary_midwifery"),
      "B4 an absent NPI is NOT membership, whatever the tier says")
  chk(!is_cohort_member("", "primary_midwifery"),
      "B4 an empty NPI is NOT membership")
  chk(is_cohort_member("2000000001", "primary_midwifery"),
      "B4 a present NPI in an allowlisted tier IS membership")
  chk(!is_cohort_member("2000000001", "quarantined"),
      "B4 a present NPI in a non-allowlisted tier is NOT membership")
  chk(identical(amcb_linkage_tier(NA_character_, 2L, "midwife",
                                  match_status = "ambiguous_pool"), "quarantined"),
      "B4 no NPI plus an ambiguous status -> quarantined")
  chk(identical(amcb_linkage_tier(NA_character_, 2L, "midwife"), "unmatched"),
      "B4 no NPI and no ambiguity -> unmatched")
}

# =============================================================================
cat("\n-- C: nightmare collision families --\n")
# =============================================================================
{
  res <- classify(CORPUS)
  for (fam in c("collision-twin", "collision-maiden-married",
                "negative-normalized-collision", "negative-taxonomy-decides")) {
    ids <- unique(CORPUS$amcb_id[CORPUS$family == fam])
    got <- res$outcome[ids]
    chk(all(got == "quarantined"),
        sprintf("C %-32s stays unresolved [%s]", fam, paste(unique(got), collapse = ",")))
  }

  # NPI contention. Stage 1 CANNOT enforce one-NPI-one-person: that is
  # rank_one_to_one(), stage 2, in the private isochrones repository. What can
  # be asserted here is that the contention is DETECTABLE, which is the input
  # stage 2 needs. Asserting it were already enforced would be a false claim.
  contested <- res$resolved %>% count(npi) %>% filter(n > 1L)
  chk(nrow(contested) >= 1L,
      sprintf("C-NPI contention is detectable at stage 1 [%d contested npi(s)]",
              nrow(contested)))
}

# =============================================================================
cat("\n-- D: decoy escalation trajectories --\n")
# =============================================================================
# The most important section. Add false candidates one at a time to a true
# identity and record the resolver state after each. The TRAJECTORY is the
# contract, not any single outcome.
{
  for (fam in unique(DECOY$family)) {
    steps <- DECOY %>% filter(family == fam) %>% arrange(step)
    got <- character(nrow(steps))
    for (k in seq_len(nrow(steps))) {
      sofar <- steps[seq_len(k), , drop = FALSE]
      got[k] <- classify(sofar)$outcome[[sofar$amcb_id[1]]]
    }
    want <- steps$expect
    chk(identical(got, want),
        sprintf("D %-22s trajectory %s", fam, paste(got, collapse = " -> ")))
    if (!identical(got, want)) {
      cat(sprintf("       expected: %s\n", paste(want, collapse = " -> ")))
    }

    # Once ambiguous, adding further weak candidates must not un-ambiguate.
    first_amb <- which(got == "quarantined")[1]
    if (!is.na(first_amb) && first_amb < length(got)) {
      chk(all(got[first_amb:length(got)] == "quarantined"),
          sprintf("D %-22s never recovers certainty after becoming ambiguous", fam))
    }
  }
}

# =============================================================================
cat("\n-- E: evidence monotonicity --\n")
# =============================================================================
{
  # Adding an EQUALLY identifying second person must move toward ambiguity,
  # never arbitrary selection.
  one <- DECOY %>% filter(family == "decoy-brennan", step == 0)
  equal_rival <- one; equal_rival$npi <- "2000000399"
  both <- bind_rows(one, equal_rival)
  chk(classify(both)$outcome[["DEC02"]] == "quarantined",
      "E1 an equally identifying second candidate produces ambiguity, not a pick")

  # Removing the rival may legitimately restore resolution.
  chk(classify(one)$outcome[["DEC02"]] == "member",
      "E2 removing the competing candidate restores resolution")

  # Taxonomy alone must never establish identity.
  tax_only <- one; tax_only$npi <- "2000000398"; tax_only$taxonomy_axis <- "nursing"
  chk(classify(bind_rows(one, tax_only))$outcome[["DEC02"]] == "quarantined",
      "E3 changing taxonomy alone does not establish personal identity")

  # Weaker evidence added to a resolved person must not disturb it.
  weak <- one; weak$npi <- "2000000397"; weak$name_evidence_class <- 5L
  chk(classify(bind_rows(one, weak))$outcome[["DEC02"]] == "member",
      "E4 a weaker decoy cannot displace a stronger true candidate")

  # Confidence must fall strictly as class weakens (kept from the permutation
  # suite; the corpus exercises classes 1,2,4,5 in resolved rows).
  conf <- amcb_resolve(to_candidates(CORPUS))$resolved %>%
    distinct(name_evidence_class, confidence_score) %>% arrange(name_evidence_class)
  chk(nrow(conf) >= 3L && all(diff(conf$confidence_score) < 0),
      sprintf("E5 confidence falls strictly as evidence weakens [%s]",
              paste(sprintf("c%d=%.2f", conf$name_evidence_class,
                            conf$confidence_score), collapse = " ")))
}

# =============================================================================
cat("\n-- F: fail-closed under evidence removal --\n")
# =============================================================================
# Removing evidence must never INCREASE certainty or invent a new identity.
{
  pos <- CORPUS %>% filter(kind == "positive")
  base_res <- classify(pos)
  rank_of <- c(quarantined = 0L, held_out = 1L, member = 2L)

  worse_or_equal <- TRUE; invented <- character(0)
  # Weaken each person's evidence one class at a time, and drop rows entirely.
  for (id in unique(pos$amcb_id)) {
    for (mode in c("weaken", "drop_one")) {
      mod <- pos
      if (mode == "weaken") {
        i <- mod$amcb_id == id
        mod$name_evidence_class[i] <- pmin(5L, mod$name_evidence_class[i] + 1L)
      } else {
        i <- which(mod$amcb_id == id)[1]
        mod <- mod[-i, , drop = FALSE]
      }
      if (!id %in% mod$amcb_id) next
      got <- classify(mod)$outcome[[id]]
      if (rank_of[[got]] > rank_of[[base_res$outcome[[id]]]]) {
        worse_or_equal <- FALSE
        invented <- c(invented, sprintf("%s:%s %s->%s", id, mode,
                                        base_res$outcome[[id]], got))
      }
    }
  }
  chk(worse_or_equal,
      sprintf("F1 weakening or removing evidence never increases certainty [%s]",
              if (length(invented)) paste(invented, collapse = "; ") else "none"))

  # Blanking the evidence entirely must never produce a member.
  none <- pos; none$name_evidence_class <- 5L
  out <- classify(none)$outcome
  chk(!any(out == "member"),
      sprintf("F2 reducing everyone to fragment evidence admits nobody [%s]",
              paste(unique(out), collapse = ",")))
}

# =============================================================================
cat("\n-- H: independent reference resolver --\n")
# =============================================================================
# Deliberately simple, base R only, sharing NO production helper. It expresses
# one rule: insufficiently unique identifying evidence -> do not identify.
# Its purpose is to catch production and its tests reproducing one mistake.
{
  reference_resolve <- function(df) {
    ids <- sort(unique(df$amcb_id))
    out <- character(length(ids)); names(out) <- ids
    for (id in ids) {
      rows <- df[df$amcb_id == id, , drop = FALSE]
      best <- min(rows$name_evidence_class)
      at_best <- rows[rows$name_evidence_class == best, , drop = FALSE]
      distinct_npi <- unique(at_best$npi)
      # Class 5 -- a surname FRAGMENT -- is the only class held out of the
      # cohort. Class 4 (whole surname within edit distance 2 plus exact given
      # name) IS eligible. The reference first used >= 4 here, disagreed with
      # production, and the disagreement was the reference being wrong about
      # declared policy rather than production being wrong about the science.
      out[id] <- if (length(distinct_npi) != 1L) "quarantined"
                 else if (best >= 5L) "held_out"
                 else "member"
    }
    out
  }

  prod <- classify(CORPUS)$outcome
  ref  <- reference_resolve(CORPUS)
  common <- intersect(names(prod), names(ref))
  disagree <- common[prod[common] != ref[common]]
  chk(length(disagree) == 0L,
      sprintf("H1 production agrees with the independent reference on all %d people [%s]",
              length(common),
              if (length(disagree))
                paste(sprintf("%s: prod=%s ref=%s", disagree, prod[disagree],
                              ref[disagree]), collapse = "; ") else "no disagreement"))
}

# =============================================================================
cat("\n-- permutation invariance over the whole corpus --\n")
# =============================================================================
{
  set.seed(20260816)
  ref <- classify(CORPUS)$outcome
  diffs <- 0L
  for (i in seq_len(200L)) {
    got <- classify(CORPUS[sample(nrow(CORPUS)), , drop = FALSE])$outcome
    if (!identical(got[names(ref)], ref)) diffs <- diffs + 1L
  }
  chk(diffs == 0L,
      sprintf("P1 corpus outcomes invariant across 200 candidate orderings [%d differed]",
              diffs))
}

# =============================================================================
cat("\n-- LIMITS: what this corpus cannot decide here --\n")
# =============================================================================
# Reported every run, by name, so the gap is a standing fact rather than
# something rediscovered later.
{
  cat("       These adversarial families are decided during CANDIDATE\n")
  cat("       GENERATION in match_amcb_to_npi.R, upstream of every function\n")
  cat("       callable here. They reach the resolver already reduced to an\n")
  cat("       evidence class, so the corpus represents them by that class:\n")
  cat("         - license number identical across two states\n")
  cat("         - credential incompatible with midwifery\n")
  cat("         - shared practice address / shared organization\n")
  cat("         - former-name provenance (which surname was the maiden name)\n")
  cat("         - stale address creating false geographic agreement\n")
  cat("       And one-NPI-one-person is enforced by rank_one_to_one(), stage 2,\n")
  cat("       in the private mufflyt/isochrones repository. Stage 1 can only\n")
  cat("       DETECT contention, which C-NPI asserts.\n")
}

# =============================================================================
cat("\n-- L: aggregate report (no person-level data) --\n")
# =============================================================================
{
  res <- classify(CORPUS)
  pos <- CORPUS %>% filter(kind == "positive") %>% distinct(amcb_id, expect)
  neg <- CORPUS %>% filter(kind == "negative") %>% distinct(amcb_id, expect)
  correct_pos <- sum(res$outcome[pos$amcb_id] == pos$expect)
  false_res <- sum(neg$expect == "quarantined" &
                     res$outcome[neg$amcb_id] != "quarantined")
  false_unres <- sum(pos$expect == "member" & res$outcome[pos$amcb_id] != "member")

  cat(sprintf("       positive controls        %d\n", nrow(pos)))
  cat(sprintf("       negative controls        %d\n", nrow(neg)))
  cat(sprintf("       expected unresolved      %d\n", sum(CORPUS$expect == "quarantined" &
                                                            !duplicated(CORPUS$amcb_id))))
  cat(sprintf("       correct resolutions      %d\n", correct_pos))
  cat(sprintf("       FALSE resolutions        %d\n", false_res))
  cat(sprintf("       false unresolved         %d\n", false_unres))
  cat(sprintf("       decoy families           %d\n", n_distinct(DECOY$family)))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
