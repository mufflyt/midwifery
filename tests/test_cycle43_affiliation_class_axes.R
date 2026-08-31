#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 43 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: RESOLVES the question cycle 35 raised and left open across 7
# subsequent cycles' resuming notes: does build_organization_affiliation_
# resolver.R's affiliation_class conflate "2 strong arms agree" (e.g. PECOS +
# Care Compare, two independently-verified CMS products) with "2 weak arms
# agree" (e.g. open_payments_org + birth_center_registry, both address/
# directory-derived with no identity verification)?
#
# VERDICT, after actually reading the wiring closely this cycle: YES, at the
# affiliation_class level alone -- both cases produce the identical label
# "multi_source_confirmed", because `affiliation_evidence_count >= 2L` is
# checked FIRST in the case_when, before any arm-specific branch gets a
# chance to fire, regardless of WHICH two arms contributed.
#
# THIS IS NOT A DEFECT. It is a deliberate consequence of splitting evidence
# into THREE separate, orthogonal columns rather than one collapsed verdict
# (this file's own header: "a class describing which evidence supports it,
# and a SEPARATE class describing how current it is"):
#   affiliation_class   WHICH/how-many sources agree (this is where the two
#                       scenarios above are lexically identical)
#   currentness_class   HOW CURRENT the affiliation is -- and here the two
#                       scenarios diverge completely: two weak arms stay
#                       "unknown" (open_payments_org and birth_center_
#                       registry are never passed into classify_affiliation_
#                       status() at all), two strong arms reach
#                       "high_confidence_current"
#   evidence_layer      WHICH LAYER (Medicare vs. non-Medicare) carried the
#                       pair -- also diverges: "medicare_only" vs.
#                       "non_medicare_only"
#   arms                the literal, un-collapsed list of which sources
#                       actually agreed (verified in cycle 35) -- always
#                       available for a reader who needs the full detail
# A reader relying on affiliation_class ALONE cannot tell the two cases
# apart, but no information is actually lost: currentness_class, evidence_
# layer, and arms all correctly distinguish them. This cycle's tests prove
# that claim rather than merely asserting it.
#
# Neither build_organization_affiliation_resolver.R (needs a real crosswalk
# and arm artifacts) nor its wiring block can be sourced end-to-end, so the
# case_when logic is replicated literally (matching cycle 35's approach for
# the same file); classify_affiliation_status() itself is the real,
# directly-sourced function.
#
# Run: Rscript tests/test_cycle43_affiliation_class_axes.R
# =============================================================================

suppressPackageStartupMessages(library(dplyr))
source("R/lib/organization_affiliation_status.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of the resolver's wiring (build_organization_affiliation_
# resolver.R, ~lines 233-251).
c43_classify <- function(p_pecos, p_cc, p_nppes, p_fac, p_bc, p_op, affiliation_evidence_count) {
  affiliation_class <- case_when(
    affiliation_evidence_count >= 2L ~ "multi_source_confirmed",
    p_cc                             ~ "carecompare_current_group",
    p_pecos                          ~ "pecos_reassignment_on_file",
    p_nppes                          ~ "nppes_org_colocation_only",
    p_fac                            ~ "facility_only",
    p_bc                             ~ "birth_center_registry_only",
    p_op                             ~ "open_payments_only",
    TRUE                             ~ "unresolved")
  evidence_layer <- case_when(
    (p_pecos | p_cc) & (p_nppes | p_fac | p_bc) ~ "both_layers",
    p_pecos | p_cc                              ~ "medicare_only",
    TRUE                                        ~ "non_medicare_only")
  currentness_class <- classify_affiliation_status(
    pecos = p_pecos, care_compare = p_cc, nppes = p_nppes | p_fac)
  list(affiliation_class = affiliation_class, evidence_layer = evidence_layer,
       currentness_class = currentness_class)
}

cat("\n-- BVA --\n")

# T43-1. The exact 1-vs-2-arm threshold: a single strong arm (Care Compare
# alone) gets its OWN specific label; adding one more arm crosses the
# boundary into "multi_source_confirmed", even though Care Compare's own
# arm-specific branch would otherwise have matched.
{
  one <- c43_classify(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, 1L)
  two <- c43_classify(TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, 2L)
  chk(identical(one$affiliation_class, "carecompare_current_group"),
      "T43-1a exactly 1 arm (Care Compare) gets its own specific label")
  chk(identical(two$affiliation_class, "multi_source_confirmed"),
      "T43-1b crossing to exactly 2 arms overrides even Care Compare's own branch")
}

# T43-2. The upper boundary is open-ended: 3+ agreeing arms still resolve to
# the same "multi_source_confirmed" label, not a distinct "super-confirmed"
# tier -- the count threshold is a floor (>=2), not a specific match.
{
  three <- c43_classify(TRUE, FALSE, FALSE, FALSE, TRUE, TRUE, 3L)
  chk(identical(three$affiliation_class, "multi_source_confirmed"),
      "T43-2 3 agreeing arms resolve to the same label as 2, not a separate tier")
}

# T43-3. THE CASE_WHEN PRIORITY BOUNDARY. affiliation_evidence_count >= 2L is
# the FIRST branch checked; it wins even when p_cc is TRUE and would
# otherwise match its own more-specific branch two lines later. This is the
# exact ordering the whole "conflation" question depends on.
{
  chk(identical(c43_classify(FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, 2L)$affiliation_class,
                "multi_source_confirmed"),
      "T43-3 the >=2L branch's priority over p_cc's own branch is exactly as documented")
}

cat("\n-- SEMANTIC --\n")

# T43-4. THE RESOLUTION, part 1: two WEAK arms (open_payments_org +
# birth_center_registry, neither identity-verified) and two STRONG arms
# (PECOS + Care Compare, both federally-verified Medicare products) produce
# the IDENTICAL affiliation_class -- confirming the conflation is real at
# this one column.
{
  weak <- c43_classify(FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, 2L)
  strong <- c43_classify(TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, 2L)
  chk(identical(weak$affiliation_class, strong$affiliation_class) &&
        identical(weak$affiliation_class, "multi_source_confirmed"),
      "T43-4 two weak arms and two strong arms both read 'multi_source_confirmed'")
}

# T43-5. THE RESOLUTION, part 2 -- NOT A DEFECT. currentness_class
# distinguishes exactly the two scenarios T43-4 could not: the weak-arm pair
# stays "unknown" (open_payments_org/birth_center_registry are never passed
# into classify_affiliation_status() at all), the strong-arm pair reaches
# "high_confidence_current". A reader checking currentness_class alongside
# affiliation_class always recovers the distinction T43-4 showed was lost.
{
  weak <- c43_classify(FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, 2L)
  strong <- c43_classify(TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, 2L)
  chk(identical(weak$currentness_class, "unknown") &&
        identical(strong$currentness_class, "high_confidence_current"),
      sprintf("T43-5 currentness_class recovers the distinction: weak='%s', strong='%s'",
              weak$currentness_class, strong$currentness_class))
}

# T43-6. THE RESOLUTION, part 3. evidence_layer is a THIRD independent axis
# that also distinguishes the two scenarios: "non_medicare_only" for the
# weak pair, "medicare_only" for the strong pair -- a reader can infer
# relative rigor (Medicare arms undergo federal enrollment verification)
# from this column too, without ever needing a fourth "strength" column.
{
  weak <- c43_classify(FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, 2L)
  strong <- c43_classify(TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, 2L)
  chk(identical(weak$evidence_layer, "non_medicare_only") &&
        identical(strong$evidence_layer, "medicare_only"),
      sprintf("T43-6 evidence_layer also distinguishes: weak='%s', strong='%s'",
              weak$evidence_layer, strong$evidence_layer))
}

# T43-7. A genuinely MIXED pair (one weak arm, open_payments_org, plus one
# strong arm, PECOS) still reads "multi_source_confirmed" -- but
# currentness_class correctly reaches "medicare_reassignment_only" (driven
# entirely by the one strong arm present, exactly as classify_affiliation_
# status()'s own NA-is-absent-not-contrary contract requires: the weak arm
# contributes nothing, for better or worse, to currentness).
{
  mixed <- c43_classify(TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, 2L)
  chk(identical(mixed$affiliation_class, "multi_source_confirmed") &&
        identical(mixed$currentness_class, "medicare_reassignment_only"),
      sprintf("T43-7 a mixed weak+strong pair still confirms, but currentness tracks only the strong arm present (got %s / %s)",
              mixed$affiliation_class, mixed$currentness_class))
}

cat("\n-- ADVERSARIAL --\n")

# T43-8. Three arms where only ONE of three is Medicare-sourced (PECOS +
# birth_center_registry + open_payments_org) -- evidence_layer must still
# correctly report "both_layers" at this 1-of-3 boundary, not silently
# require a MAJORITY of arms to be Medicare-sourced before crediting both
# layers.
{
  three <- c43_classify(TRUE, FALSE, FALSE, FALSE, TRUE, TRUE, 3L)
  chk(identical(three$evidence_layer, "both_layers"),
      sprintf("T43-8 1 Medicare arm out of 3 total is enough for 'both_layers', not requiring a majority (got %s)",
              three$evidence_layer))
}

# T43-9. A single weak arm ALONE (open_payments_org, no corroboration at
# all) must land in "non_medicare_only" on the evidence_layer axis -- the
# boundary this axis has not been directly tested at before (cycle 35's
# T35-4 checked affiliation_class and currentness_class for this exact
# single-arm case, but not evidence_layer).
{
  single <- c43_classify(FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, 1L)
  chk(identical(single$affiliation_class, "open_payments_only") &&
        identical(single$evidence_layer, "non_medicare_only") &&
        identical(single$currentness_class, "unknown"),
      sprintf("T43-9 a single weak arm alone: affiliation='%s', layer='%s', currentness='%s'",
              single$affiliation_class, single$evidence_layer, single$currentness_class))
}

# T43-10. Adversarial malformed-count case: affiliation_evidence_count = 0L
# with a TRUE arm flag present (a hypothetical inconsistency between the
# count and the flags, e.g. a future refactor that computes them from
# different sources) -- the case_when correctly falls through past the
# >=2L branch and resolves on the arm flags alone, since 0 is not >= 2. This
# guards against assuming the count and the flags can never disagree.
{
  inconsistent <- c43_classify(FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, 0L)
  chk(identical(inconsistent$affiliation_class, "open_payments_only"),
      sprintf("T43-10 affiliation_evidence_count=0 with p_op=TRUE falls through to the arm-specific branch, not multi_source_confirmed (got %s)",
              inconsistent$affiliation_class))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
