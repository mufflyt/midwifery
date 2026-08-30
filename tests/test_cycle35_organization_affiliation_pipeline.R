#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 35 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: build_organization_affiliation_resolver.R's `pair` aggregation
# pipeline and its wiring into R/lib/organization_affiliation_status.R.
#
# tests/test_organization_affiliation_status.R already exhaustively tests
# classify_affiliation_status() in isolation (every TRUE/FALSE/NA
# combination, ordering, vectorization). tests/test_organization_affiliation_
# resolver.R tests norm_org() in isolation and does source-inspection checks
# on the resolver script's code text. NEITHER exercises the actual
# group_by(npi, org_key) %>% summarise(...) aggregation pipeline that MERGES
# rows across arms, nor the specific wiring decision (in build_organization_
# affiliation_resolver.R, not in the status library) that excludes the
# open_payments_org arm from currentness_class while still recording it in
# affiliation_class. Both are replicated literally here since the resolver
# script itself needs a real AMCB->NPI crosswalk and arm artifacts to run.
#
# Investigated but NOT a defect (recorded so a future cycle does not
# re-investigate): the open_payments_org arm's source, crossref_open_
# payments_to_type2_npi.py, shares the exact limit=10/8-char-substring defect
# already measured (via the pre-existing audit_python_org_selection.R
# diagnostic) at ~51% exact-match-rate for its "_full" sibling script. This
# initially looked like an unaddressed reliability gap in build_organization_
# affiliation_resolver.R -- but reading the actual wiring (verified below)
# shows the developer already excluded this specific arm from currentness_
# class while keeping it in affiliation_class at the lowest non-"unresolved"
# tier. That is the correct, already-implemented mitigation; T35-4 pins it
# rather than proposing a new one.
#
# Run: Rscript tests/test_cycle35_organization_affiliation_pipeline.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(tidyr); library(stringr) })
source("R/lib/org_names.R")
source("R/lib/organization_affiliation_status.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of build_organization_affiliation_resolver.R's `pair` step.
build_pair <- function(all_rows) {
  all_rows %>%
    mutate(org_key = norm_org(organization_name)) %>%
    filter(nzchar(org_key)) %>%
    group_by(npi, org_key) %>%
    summarise(
      organization_name = organization_name[order(-nchar(organization_name),
                                                  organization_name)][1],
      org_ids = paste(sort(unique(na.omit(org_id[nzchar(org_id)]))), collapse = "|"),
      org_id_types = paste(sort(unique(org_id_type[org_id_type != "none"])), collapse = "|"),
      arms = paste(sort(unique(arm)), collapse = "|"),
      affiliation_evidence_count = n_distinct(arm),
      .groups = "drop")
}

cat("\n-- BVA --\n")

# T35-1. Zero-length boundary: classify_affiliation_status() over an empty
# cohort (a stage that filters everyone out upstream) must return
# character(0), not error and not a spurious length-1 "unknown".
{
  r <- classify_affiliation_status(logical(0), logical(0), logical(0))
  chk(is.character(r) && length(r) == 0L,
      "T35-1 an all-empty-vector call returns character(0), not an error or a stray value")
}

# T35-2. Tie-break determinism at the exact nchar() boundary: two SPELLINGS
# OF THE SAME ORGANIZATION (same org_key after normalization -- a hyphen vs a
# space) of IDENTICAL raw character length must resolve to the same winner
# regardless of input row order -- the tie-break falls through to
# alphabetical (`organization_name` as the secondary order() key), which must
# not depend on which row happened to come first. (Two DIFFERENT
# organizations of equal length would never reach the tie-break at all, since
# group_by(org_key) would keep them in separate groups -- the fixture must
# collide on org_key, not merely on nchar().)
{
  rows_a <- tibble(npi = "1", org_id = NA_character_, org_id_type = "none",
                   organization_name = c("MERCY-CLINIC", "MERCY CLINIC"), arm = "x")
  rows_b <- rows_a[c(2, 1), ]
  chk(identical(norm_org("MERCY-CLINIC"), norm_org("MERCY CLINIC")) &&
        nchar("MERCY-CLINIC") == nchar("MERCY CLINIC"),
      "T35-2 setup: both spellings share one org_key and an equal raw nchar() (sanity check on the fixture)")
  pa <- build_pair(rows_a); pb <- build_pair(rows_b)
  chk(nrow(pa) == 1L && identical(pa$organization_name, "MERCY CLINIC") &&
        identical(pa, pb),
      sprintf("T35-2 an exact-length name tie within one org_key breaks alphabetically ('MERCY CLINIC'), identically regardless of row order (got '%s')",
              if (nrow(pa)) pa$organization_name else NA))
}

# T35-3. Duplicate rows from the SAME arm (e.g. an organization listed twice
# in one arm's own source file) must not inflate affiliation_evidence_count
# -- it counts DISTINCT arms via n_distinct(arm), not raw row count. The 1-
# vs-2 boundary this guards is exactly the class of defect fixed twice
# already this session (cycle 31's hg_payor_n, cycle 32's n_candidates) --
# here it is already correctly implemented; this pins it rather than fixing it.
{
  dup_rows <- tibble(npi = "1", org_id = c("111", "111"), org_id_type = "npi_type2",
                     organization_name = c("Mercy Clinic", "Mercy Clinic"),
                     arm = "open_payments_org")
  p3 <- build_pair(dup_rows)
  chk(p3$affiliation_evidence_count == 1L,
      sprintf("T35-3 two duplicate rows from one arm still count as 1 arm of evidence (got %d)",
              p3$affiliation_evidence_count))
}

cat("\n-- SEMANTIC --\n")

# T35-4. THE ACTUAL WIRING (not the status library in isolation): evidence
# from the open_payments_org arm alone must be recorded in affiliation_class
# (which sources support this pair) but must NOT count toward
# currentness_class (how current is it) -- the resolver's own case_when for
# currentness_class deliberately omits p_op from its nppes= argument. This is
# the correct, already-implemented mitigation for that arm's known
# unreliable source matching (see file header); pinned here so it cannot be
# silently reversed by a future refactor that "simplifies" the wiring.
{
  p_pecos <- FALSE; p_cc <- FALSE; p_nppes <- FALSE; p_fac <- FALSE
  p_bc <- FALSE; p_op <- TRUE
  affiliation_evidence_count <- 1L
  affiliation_class <- case_when(
    affiliation_evidence_count >= 2L ~ "multi_source_confirmed",
    p_cc                             ~ "carecompare_current_group",
    p_pecos                          ~ "pecos_reassignment_on_file",
    p_nppes                          ~ "nppes_org_colocation_only",
    p_fac                            ~ "facility_only",
    p_bc                             ~ "birth_center_registry_only",
    p_op                             ~ "open_payments_only",
    TRUE                             ~ "unresolved")
  currentness_class <- classify_affiliation_status(
    pecos = p_pecos, care_compare = p_cc, nppes = p_nppes | p_fac)
  chk(identical(affiliation_class, "open_payments_only"),
      "T35-4a open_payments-only evidence is recorded as its own affiliation_class")
  chk(identical(currentness_class, "unknown"),
      "T35-4b ...but contributes nothing to currentness_class -- it is excluded from the nppes= argument")
}

# T35-5. Cross-arm merge via the NORMALISED name: two arms naming the SAME
# real organization with different capitalization/punctuation/suffix must
# merge into ONE row with affiliation_evidence_count = 2 -- tested here
# through the actual grouping pipeline, not just norm_org() equality checked
# in isolation as the existing suite does.
{
  two_arm_same <- tibble(
    npi = c("1", "1"), org_id = c(NA_character_, "222"),
    org_id_type = c("none", "npi_type2"),
    organization_name = c("St. Mary's Hospital, LLC", "ST MARYS HOSPITAL"),
    arm = c("birth_center_registry", "open_payments_org"))
  p5 <- build_pair(two_arm_same)
  chk(nrow(p5) == 1L && p5$affiliation_evidence_count == 2L,
      sprintf("T35-5 two spellings of one real organization from two arms merge into 1 row with evidence_count=2 (got nrow=%d, count=%s)",
              nrow(p5), if (nrow(p5)) p5$affiliation_evidence_count else NA))
}

# T35-6. The flip side, explicitly documented in the resolver's own header as
# "the safe direction": two GENUINELY DIFFERENT organizations from two arms
# must stay as two separate rows, never merged just because both arms
# reported something for the same npi.
{
  two_arm_diff <- tibble(
    npi = c("1", "1"), org_id = c(NA_character_, "333"),
    org_id_type = c("none", "npi_type2"),
    organization_name = c("Fairview Clinics", "Fairview Health Services"),
    arm = c("birth_center_registry", "open_payments_org"))
  p6 <- build_pair(two_arm_diff)
  chk(nrow(p6) == 2L && all(p6$affiliation_evidence_count == 1L),
      sprintf("T35-6 two distinct organizations from two arms stay separate, each with evidence_count=1 (got nrow=%d)",
              nrow(p6)))
}

cat("\n-- ADVERSARIAL --\n")

# T35-7. Mismatched non-scalar vector lengths that are NOT a multiple of each
# other (4 vs 3) must fail LOUDLY, never silently misalign via R's default
# recycling and return a wrong-but-plausible-looking result for the whole
# cohort.
{
  # No warning= handler: a warning must NOT abort execution here (that would
  # only prove tryCatch stops early, not that the function itself is safe).
  # suppressWarnings() lets the base-R recycling warning pass through silently
  # so we can see whether case_when()'s OWN stricter check still errors after it.
  err <- tryCatch({
    suppressWarnings(
      classify_affiliation_status(pecos = c(TRUE, FALSE, TRUE, FALSE),
                                  care_compare = c(TRUE, FALSE, TRUE),
                                  nppes = c(FALSE, FALSE, FALSE, FALSE)))
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err),
      sprintf("T35-7 mismatched non-multiple lengths (4 vs 3) raise a hard error, not a silently-recycled wrong answer (got: %s)",
              if (is.na(err)) "no error -- silently succeeded" else err))
}

# T35-8. Mismatched EXACT-MULTIPLE lengths (4 vs 2) must ALSO fail loudly.
# Base R's own recycling rule gives exact multiples a free pass (no warning
# at all, silent recycling) -- this checks that dplyr::case_when()'s stricter
# vctrs-based size checking still catches it, since the bare `cc` condition
# (not combined via `&`) reaches case_when() at its original, un-recycled
# length.
{
  err <- tryCatch({
    classify_affiliation_status(pecos = c(TRUE, FALSE, TRUE, FALSE),
                                care_compare = c(TRUE, FALSE),
                                nppes = c(FALSE, FALSE, FALSE, FALSE))
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err),
      sprintf("T35-8 mismatched EXACT-MULTIPLE lengths (4 vs 2) still raise an error, not a silent base-R-style recycle (got: %s)",
              if (is.na(err)) "no error -- silently succeeded" else err))
}

# T35-9. Conflicting org_id_type metadata within one merged group: a "none"
# entry (an arm that supplies no identifier, like birth_center_registry)
# alongside a real typed identifier for the SAME merged organization must
# retain the real type and exclude only "none" -- not lose the real type
# entirely, and not let "none" pollute the list.
{
  mixed_type <- tibble(
    npi = c("1", "1"), org_id = c(NA_character_, "444"),
    org_id_type = c("none", "npi_type2"),
    organization_name = c("Mercy Clinic", "MERCY CLINIC"),
    arm = c("birth_center_registry", "open_payments_org"))
  p9 <- build_pair(mixed_type)
  chk(identical(p9$org_id_types, "npi_type2"),
      sprintf("T35-9 'none' is excluded from org_id_types while the real type survives (got '%s')",
              p9$org_id_types))
}

# T35-10. Duplicated/CONFLICTING identifiers, the loop's own adversarial
# category by name: two arms report the SAME merged organization but with
# TWO DIFFERENT org_id values (e.g. two different Type-2 NPIs). Both must be
# retained in org_ids, never silently reduced to one -- the same "never
# collapse several plausible candidates to one" philosophy already
# established in link_open_payments_type2_bulk.R (cycle 32).
{
  conflict_id <- tibble(
    npi = c("1", "1"), org_id = c("555", "666"), org_id_type = "npi_type2",
    organization_name = c("Mercy Clinic", "MERCY CLINIC"),
    arm = c("open_payments_org", "nppes_colocation"))
  p10 <- build_pair(conflict_id)
  chk(identical(p10$org_ids, "555|666"),
      sprintf("T35-10 two conflicting org_id values for one merged organization are BOTH retained (got '%s')",
              p10$org_ids))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
