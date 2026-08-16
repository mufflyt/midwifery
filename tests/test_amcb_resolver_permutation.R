#!/usr/bin/env Rscript
# =============================================================================
# Permutation attack: identity must not depend on candidate order
# =============================================================================
# A golden linkage fixture is run through the resolver hundreds of times with
# the candidate rows shuffled. The accepted NPI and the ambiguity state must be
# identical every single time.
#
# WHY THIS AND NOT MORE UNIT TESTS. An ordering bug is invisible to ordinary
# testing because a fixture written by hand arrives in one order and passes in
# that order forever. It surfaces in production as a person acquiring a
# different NPI because an upstream file was re-sorted -- a changed identity
# with no changed evidence, and no error anywhere.
#
# THE FIXTURE IS BUILT TO BE HOSTILE. A permutation test over data with no ties
# proves nothing: unique maxima are order-invariant trivially. Every person here
# exists to make ordering matter -- exact ties at the best class, ties broken
# only by a weaker class, several people contesting one NPI, and one person
# whose two candidate rows for the SAME NPI tie on evidence class.
#
# Hermetic: no artifact, no network, no ~/isochrones. It runs on a runner,
# which is the point -- the resolver's other stage cannot.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(rlang)})
source(file.path(root, "R", "amcb_resolver.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Named mk_cand rather than cand: test_cross_taxonomy_hierarchy.R already
# defines cand() at top level and ci_hygiene H4 caught the collision. Worth
# knowing that gate reads `git ls-files`, so a NEW file is invisible to it
# until committed -- this passed locally and failed in CI for that reason.
mk_cand <- function(amcb_id, npi, cls, tax = "midwife", method = "m", variant = "V") {
  data.frame(amcb_id = amcb_id, npi = npi, name_evidence_class = as.integer(cls),
             taxonomy_axis = tax, match_method = method,
             match_strategy = as.integer(cls), mid_match = 0L,
             nppes_matched_last = variant, nppes_matched_first = variant,
             nppes_mid_init = "", stringsAsFactors = FALSE)
}

# -----------------------------------------------------------------------------
# The golden fixture. Every person is here to make ordering matter.
# -----------------------------------------------------------------------------
FIX <- dplyr::bind_rows(
  # P1 clean: one candidate, class 1. Must resolve, every ordering.
  mk_cand("P1", "1000000001", 1),

  # P2 EXACT TIE at the best class. Two different NPIs, both class 2. The
  # correct answer is AMBIGUOUS -- and a greedy pick would silently choose
  # whichever arrived first.
  mk_cand("P2", "1000000002", 2),
  mk_cand("P2", "1000000003", 2),

  # P3 tie broken by evidence: one class 2, one class 3. Must resolve to the
  # class 2 NPI regardless of which row is seen first.
  mk_cand("P3", "1000000004", 2),
  mk_cand("P3", "1000000005", 3),

  # P4 THREE-WAY tie at class 3. Ambiguous.
  mk_cand("P4", "1000000006", 3),
  mk_cand("P4", "1000000007", 3),
  mk_cand("P4", "1000000008", 3),

  # P5 and P6 both want NPI ...009 at class 2, and each also has a weaker
  # alternative. Stage 1 resolves both; the bijection is stage 2's problem.
  # Included so a future contested-NPI rule is exercised by these permutations.
  mk_cand("P5", "1000000009", 2),
  mk_cand("P5", "1000000010", 4),
  mk_cand("P6", "1000000009", 2),
  mk_cand("P6", "1000000011", 4),

  # P7 taxonomy must NOT break an identity tie. Same class, different taxonomy.
  # If taxonomy ever becomes a tiebreak, this person stops being ambiguous and
  # this test fails -- which is the intent.
  mk_cand("P7", "1000000012", 2, tax = "midwife"),
  mk_cand("P7", "1000000013", 2, tax = "nursing"),

  # P8 class 5 alone. Resolvable at stage 1; held out later by tier rules.
  mk_cand("P8", "1000000014", 5),

  # P9 SAME NPI twice, tied on class, different recorded variants. The accepted
  # identity is unambiguous; only which spelling is RECORDED can wobble.
  mk_cand("P9", "1000000015", 2, variant = "AAA"),
  mk_cand("P9", "1000000015", 2, variant = "BBB"),

  # P10 same NPI twice at DIFFERENT classes: the stronger must always win.
  mk_cand("P10", "1000000016", 4, variant = "WEAK"),
  mk_cand("P10", "1000000016", 2, variant = "STRONG"),

  # P11 resolves AT class 4, and P12 at class 5. Without these, no resolved row
  # ever carries a class-4 or class-5 confidence and the ordering between them
  # is untested -- which is exactly how the class4/class5 swap survived its
  # first mutation run.
  mk_cand("P11", "1000000017", 4),
  mk_cand("P12", "1000000018", 5)
)

N_PERM <- as.integer(Sys.getenv("PERMUTATIONS", "300"))

cat(sprintf("\nfixture: %d candidate rows, %d people; %d permutations\n",
            nrow(FIX), dplyr::n_distinct(FIX$amcb_id), N_PERM))

# -----------------------------------------------------------------------------
cat("\n-- the fixture must actually be hostile --\n")
# -----------------------------------------------------------------------------
# A permutation test over data without ties is decoration. Prove the fixture
# contains the conditions it claims to before trusting any result from it.
{
  base <- amcb_resolve(FIX)
  ties <- base$pool_stats %>% filter(n_at_best_class > 1L)
  chk(nrow(ties) >= 3L,
      sprintf("F1 fixture contains %d people tied at their best class", nrow(ties)))

  contested <- base$resolved %>% count(npi) %>% filter(n > 1L)
  chk(nrow(contested) >= 1L,
      sprintf("F2 fixture contains %d NPI(s) claimed by more than one person",
              nrow(contested)))

  dup_rows <- FIX %>% count(amcb_id, npi, name_evidence_class) %>% filter(n > 1L)
  chk(nrow(dup_rows) >= 1L,
      sprintf("F3 fixture contains %d duplicated (person, NPI, class) row group(s)",
              nrow(dup_rows)))

  chk(length(base$quarantined_ids) >= 3L,
      sprintf("F4 fixture produces %d quarantined people",
              length(base$quarantined_ids)))
}

# -----------------------------------------------------------------------------
cat("\n-- THE ATTACK: identity under permutation --\n")
# -----------------------------------------------------------------------------
{
  fingerprint <- function(res) {
    # The scientific claim: who resolved, to which NPI, at what class, and who
    # was quarantined. Deliberately EXCLUDES the recorded name variant, which is
    # provenance rather than identity and is checked separately below.
    r <- res$resolved %>%
      arrange(amcb_id, npi) %>%
      transmute(amcb_id, npi, name_evidence_class, resolution,
                confidence_score = round(confidence_score, 6))
    list(resolved = r,
         quarantined = sort(res$quarantined_ids),
         pool = res$pool_stats %>% arrange(amcb_id) %>%
           transmute(amcb_id, n_candidates_pre_rank, best_evidence_class,
                     n_at_best_class))
  }

  set.seed(20260816)
  ref <- fingerprint(amcb_resolve(FIX))

  identity_diffs <- 0L; quar_diffs <- 0L; pool_diffs <- 0L; variant_diffs <- 0L
  ref_variant <- amcb_resolve(FIX)$per_npi %>% arrange(amcb_id, npi) %>%
    transmute(amcb_id, npi, nppes_matched_last)

  for (i in seq_len(N_PERM)) {
    shuffled <- FIX[sample(nrow(FIX)), , drop = FALSE]
    got <- amcb_resolve(shuffled)
    fp <- fingerprint(got)

    if (!identical(fp$resolved, ref$resolved))       identity_diffs <- identity_diffs + 1L
    if (!identical(fp$quarantined, ref$quarantined)) quar_diffs     <- quar_diffs + 1L
    if (!identical(fp$pool, ref$pool))               pool_diffs     <- pool_diffs + 1L

    v <- got$per_npi %>% arrange(amcb_id, npi) %>%
      transmute(amcb_id, npi, nppes_matched_last)
    if (!identical(as.data.frame(v), as.data.frame(ref_variant)))
      variant_diffs <- variant_diffs + 1L
  }

  chk(identity_diffs == 0L,
      sprintf("PERM1 accepted identity is invariant across %d orderings [%d differed]",
              N_PERM, identity_diffs))
  chk(quar_diffs == 0L,
      sprintf("PERM2 the quarantined set is invariant across %d orderings [%d differed]",
              N_PERM, quar_diffs))
  chk(pool_diffs == 0L,
      sprintf("PERM3 candidate-pool statistics are invariant [%d differed]", pool_diffs))

  # Reported, not asserted. which.min() takes the FIRST minimum, so a person
  # with two rows for one NPI tied at the same class records whichever spelling
  # arrived first. That is provenance about a spelling, not a claim about who
  # someone is -- but it should be VISIBLE rather than discovered later.
  if (variant_diffs > 0L) {
    cat(sprintf("       NOTE the RECORDED NAME VARIANT changed in %d of %d orderings.\n",
                variant_diffs, N_PERM))
    cat("            Identity is unaffected (PERM1). This is which.min() taking\n")
    cat("            the first minimum among tied candidate rows for one NPI.\n")
  } else {
    cat("       recorded name variant was also stable\n")
  }
}

# -----------------------------------------------------------------------------
cat("\n-- confidence must fall monotonically as evidence weakens --\n")
# -----------------------------------------------------------------------------
# Evidence classes are ORDERED: 1 is the strongest, 5 the weakest. Confidence
# must respect that ordering, and class 5 sitting below class 4 is a deliberate
# scientific claim -- a partial surname fragment is weaker evidence than a whole
# surname within edit distance 2.
#
# Nothing checked this. Mutation testing swapped the class-4 and class-5 scores
# and every assertion still passed, because no person in the fixture RESOLVED at
# class 4. P11 and P12 exist to make both values observable.
{
  res <- amcb_resolve(FIX)$resolved
  conf <- res %>% distinct(name_evidence_class, confidence_score) %>%
    arrange(name_evidence_class)

  chk(nrow(conf) >= 4L,
      sprintf("MONO0 the fixture resolves at %d distinct evidence classes [%s]",
              nrow(conf), paste(conf$name_evidence_class, collapse = ",")))

  chk(all(diff(conf$confidence_score) < 0),
      sprintf("MONO1 confidence falls strictly as class weakens [%s]",
              paste(sprintf("c%d=%.2f", conf$name_evidence_class,
                            conf$confidence_score), collapse = " ")))

  c4 <- conf$confidence_score[conf$name_evidence_class == 4L]
  c5 <- conf$confidence_score[conf$name_evidence_class == 5L]
  chk(length(c4) == 1L && length(c5) == 1L && c5 < c4,
      sprintf("MONO2 class 5 (surname fragment) ranks BELOW class 4 (fuzzy whole surname) [%.2f < %.2f]",
              if (length(c5)) c5 else NA_real_, if (length(c4)) c4 else NA_real_))
}

# -----------------------------------------------------------------------------
cat("\n-- reversal and sorted orders, not just random ones --\n")
# -----------------------------------------------------------------------------
# Random shuffles rarely produce the adversarial orders a real pipeline hits:
# an upstream file sorted by NPI, or by class, or reversed. Test those exactly.
{
  ref <- amcb_resolve(FIX)
  key <- function(r) paste(sort(paste(r$resolved$amcb_id, r$resolved$npi)), collapse = "|")
  qkey <- function(r) paste(sort(r$quarantined_ids), collapse = "|")

  orders <- list(
    reversed      = FIX[rev(seq_len(nrow(FIX))), , drop = FALSE],
    by_npi        = FIX[order(FIX$npi), , drop = FALSE],
    by_npi_desc   = FIX[order(FIX$npi, decreasing = TRUE), , drop = FALSE],
    by_class      = FIX[order(FIX$name_evidence_class), , drop = FALSE],
    by_class_desc = FIX[order(FIX$name_evidence_class, decreasing = TRUE), , drop = FALSE],
    by_person     = FIX[order(FIX$amcb_id), , drop = FALSE]
  )
  for (nm in names(orders)) {
    got <- amcb_resolve(orders[[nm]])
    chk(identical(key(got), key(ref)) && identical(qkey(got), qkey(ref)),
        sprintf("ORD %s ordering yields the same identities and quarantine set", nm))
  }
}

# -----------------------------------------------------------------------------
cat("\n-- NEGATIVE CONTROL: the attack must be able to fail --\n")
# -----------------------------------------------------------------------------
# A permutation test that cannot detect an order-dependent resolver proves
# nothing. Resolve the tied people by "first row wins" -- the bug this file
# exists to catch -- and confirm the same comparison reports instability.
{
  # THE BUG, and it has to operate on the RAW candidate frame. My first attempt
  # planted it after amcb_per_npi(), and the control did not fire: group_by() |>
  # summarise() SORTS by group key, so input order is already normalised away
  # before any greedy pick happens.
  #
  # That is worth recording as a finding rather than a footnote. The resolver's
  # order-invariance is real, but it is INCIDENTAL -- inherited from dplyr's
  # grouping, not from an explicit rule. Replace that summarise with anything
  # order-preserving and the invariance evaporates silently. This test would
  # then catch it, which is the point.
  order_dependent_resolve <- function(candidates) {
    rs <- candidates |>
      dplyr::group_by(.data$amcb_id) |>
      dplyr::filter(.data$name_evidence_class ==
                      min(.data$name_evidence_class)) |>
      # First row at the best class wins, in whatever order it arrived.
      dplyr::slice(1L) |>
      dplyr::ungroup() |>
      dplyr::select(dplyr::all_of(c("amcb_id", "npi", "name_evidence_class")))
    list(resolved = rs, quarantined_ids = setdiff(unique(candidates$amcb_id),
                                                  unique(rs$amcb_id)))
  }

  k <- function(r) paste(sort(paste(r$resolved$amcb_id, r$resolved$npi)), collapse = "|")
  set.seed(99)
  refb <- order_dependent_resolve(FIX)
  differed <- 0L
  for (i in seq_len(60L)) {
    got <- order_dependent_resolve(FIX[sample(nrow(FIX)), , drop = FALSE])
    if (!identical(k(got), k(refb))) differed <- differed + 1L
  }
  chk(differed > 0L,
      sprintf("NC a first-row-wins resolver IS detected as order-dependent [%d/60 orderings differed]",
              differed))
}

# -----------------------------------------------------------------------------
cat("\n-- the pipeline must USE these rules, not carry a second copy --\n")
# -----------------------------------------------------------------------------
# Everything above tests R/amcb_resolver.R. That is only meaningful if
# match_amcb_to_npi.R actually CALLS it. If the pipeline ever grows its own copy
# of these expressions again, this file silently reverts to testing a spare part
# -- production and its test reproducing the same mistake independently, which
# is the failure this kind of testing is supposed to prevent.
{
  src <- paste(readLines(file.path(root, "match_amcb_to_npi.R"), warn = FALSE),
               collapse = "\n")

  chk(grepl("amcb_resolver.R", src, fixed = TRUE),
      "WIRE1 match_amcb_to_npi.R sources R/amcb_resolver.R")

  for (fn in c("amcb_per_npi(", "amcb_pool_stats(",
               "amcb_resolve_best_class(", "amcb_quarantined_ids(")) {
    chk(grepl(fn, src, fixed = TRUE),
        sprintf("WIRE2 the pipeline calls %s()", sub("[(]$", "", fn)))
  }

  # The decisive expression: exactly one candidate at the strongest class. If
  # this reappears inline in the pipeline, there are two copies again.
  chk(!grepl("n_at_best_class == 1L", src, fixed = TRUE),
      "WIRE3 the pipeline no longer carries its own copy of the n_at_best_class rule")
  chk(!grepl("best_evidence_class = min(name_evidence_class)", src, fixed = TRUE),
      "WIRE4 the pipeline no longer carries its own copy of the best-class rule")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
