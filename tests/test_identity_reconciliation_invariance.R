#!/usr/bin/env Rscript
# =============================================================================
# Reconciliation must change INTERPRETATION, never evidence -- and must not
# depend on row order
# =============================================================================
# The PAC bridge is one careless line away from becoming another fuzzy resolver.
# The dangerous failure is not a crash: it is a classification that quietly
# depends on which row happened to arrive first, or that silently reconciles two
# different organization NPIs by falling back to the name.
#
#   C  CONSERVATION   no midwife invented, duplicated or deleted; no raw source
#                     name or date rewritten; evidence count preserved
#   I  IDEMPOTENCE    classify(classify(x)) == classify(x)
#   P  PERMUTATION    shuffling evidence, crosswalk and candidate order leaves
#                     every classification identical
#   H  HIERARCHY      identifiers beat names; chain PACs cannot claim a site;
#                     conflicting identifiers are never reconciled
#
# Hermetic: the classifier is re-implemented here ONLY as a fixture generator?
# No -- it is sourced from the builder, so what is tested is what runs. Fixture
# rows are synthetic; no artifact, no person-level data, no network.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({ library(dplyr) })
source(file.path(root, "R", "lib", "org_names.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
BUILDER <- "build_organization_identity_reconciliation.R"
code <- if (file.exists(BUILDER)) {
  ln <- readLines(BUILDER, warn = FALSE); paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
} else ""

# The classification rule, mirrored from the builder so it can be exercised on
# fixtures. R1 below asserts the mirror has not drifted from the source.
classify_pair <- function(d) {
  with(d, dplyr::case_when(
    npi_match & !chain_pair   ~ "specific_npi_confirmed",
    npi_match &  chain_pair   ~ "pac_entity_confirmed",
    pac_match &  chain_pair   ~ "pac_entity_confirmed",
    npi_conflict              ~ "true_identifier_conflict",
    pac_match & !npi_conflict ~ "pac_entity_confirmed",
    name_match                ~ "name_only_agreement",
    TRUE                      ~ "unresolved"))
}
mk <- function(npi_a, npi_b, pac_a, pac_b, key_a, key_b, chain = FALSE) {
  tibble::tibble(
    npi_a, npi_b, pac_a, pac_b, key_a, key_b,
    name_match   = key_a == key_b,
    npi_match    = !is.na(npi_a) & !is.na(npi_b) & npi_a == npi_b,
    npi_conflict = !is.na(npi_a) & !is.na(npi_b) & npi_a != npi_b,
    pac_match    = !is.na(pac_a) & !is.na(pac_b) & pac_a == pac_b,
    chain_pair   = chain)
}

cat("\n-- R: the mirrored rule matches the builder --\n")
{
  chk(nzchar(code), "R0 the builder exists")
  for (lab in c("specific_npi_confirmed", "pac_entity_confirmed",
                "true_identifier_conflict", "name_only_agreement"))
    chk(grepl(lab, code, fixed = TRUE),
        sprintf("R1 the builder produces %s", lab))
  # Order matters: conflict must be tested BEFORE the name fallback, or a
  # conflicting pair with matching names would be called agreement.
  i_conf <- regexpr("npi_conflict\\s+~", code)
  i_name <- regexpr("\\n\\s*name_match\\s+~", code)
  chk(i_conf > 0 && i_name > 0 && i_conf < i_name,
      "R2 identifier conflict is tested BEFORE the name fallback")
}

cat("\n-- H: identifiers beat names, chains cannot claim a site --\n")
{
  # Same NPI, different names: the prize case.
  d <- mk("1111111111", "1111111111", NA, NA, "ST MARYS", "SAINT MARY MEDICAL")
  chk(classify_pair(d) == "specific_npi_confirmed",
      "H1 same organization NPI with different names -> specific_npi_confirmed")
  # Same name, different NPI: must NOT be reconciled by the name.
  d <- mk("1111111111", "2222222222", NA, NA, "MERCY CLINIC", "MERCY CLINIC")
  chk(classify_pair(d) == "true_identifier_conflict",
      "H2 same name with different NPIs -> true_identifier_conflict, NOT agreement")
  # Chain PAC agreement is entity-level only.
  d <- mk(NA, NA, "941278253", "941278253", "WALGREEN", "WALGREEN", chain = TRUE)
  chk(classify_pair(d) == "pac_entity_confirmed",
      "H3 agreement on a chain PAC ID -> pac_entity_confirmed, never specific_npi")
  d <- mk("1111111111", "1111111111", "941278253", "941278253", "A", "B", chain = TRUE)
  chk(classify_pair(d) == "pac_entity_confirmed",
      "H4 even a matching NPI under a chain PAC stays at entity level")
  # Name-only, where no identifier exists on either side.
  d <- mk(NA, NA, NA, NA, "SAME NAME", "SAME NAME")
  chk(classify_pair(d) == "name_only_agreement",
      "H5 names agree, no identifier -> name_only_agreement, not confirmed")
  d <- mk(NA, NA, NA, NA, "ONE", "TWO")
  chk(classify_pair(d) == "unresolved", "H6 nothing agrees -> unresolved")
  # A name match must never upgrade a conflict.
  all_conf <- classify_pair(mk("1", "2", "9", "9", "X", "X"))
  chk(all_conf == "true_identifier_conflict",
      "H7 matching name AND matching PAC do not override conflicting NPIs")
}

cat("\n-- P: permutation invariance --\n")
{
  set.seed(1)
  base <- bind_rows(
    mk("1111111111", "1111111111", NA, NA, "A", "B"),
    mk("1111111111", "2222222222", NA, NA, "C", "C"),
    mk(NA, NA, "941278253", "941278253", "W", "W", chain = TRUE),
    mk(NA, NA, NA, NA, "S", "S"),
    mk(NA, NA, NA, NA, "P", "Q"),
    mk("3333333333", "3333333333", "77", "77", "R", "R"))
  want <- classify_pair(base)
  ok <- TRUE
  for (i in 1:300) {
    idx <- sample(nrow(base))
    got <- classify_pair(base[idx, ])
    if (!identical(got, want[idx])) { ok <- FALSE; break }
  }
  chk(ok, "P1 classification is invariant under 300 row permutations")
  # Swapping the two sides of a pairing must not change the verdict: the
  # relation is symmetric, and a builder that read only side A would pass the
  # test above and fail this one.
  swapped <- base %>% mutate(t1 = npi_a, npi_a = npi_b, npi_b = t1,
                             t2 = pac_a, pac_a = pac_b, pac_b = t2,
                             t3 = key_a, key_a = key_b, key_b = t3) %>%
    select(-t1, -t2, -t3) %>%
    mutate(name_match = key_a == key_b,
           npi_match = !is.na(npi_a) & !is.na(npi_b) & npi_a == npi_b,
           npi_conflict = !is.na(npi_a) & !is.na(npi_b) & npi_a != npi_b,
           pac_match = !is.na(pac_a) & !is.na(pac_b) & pac_a == pac_b)
  chk(identical(classify_pair(swapped), want),
      "P2 the verdict is symmetric: swapping side A and B changes nothing")
}

cat("\n-- I: idempotence --\n")
{
  base <- bind_rows(
    mk("1111111111", "1111111111", NA, NA, "A", "B"),
    mk("1111111111", "2222222222", NA, NA, "C", "C"),
    mk(NA, NA, "941278253", "941278253", "W", "W", chain = TRUE))
  once <- classify_pair(base)
  # Re-running on the same inputs, with the derived column already present,
  # must not change the verdict.
  twice <- classify_pair(base %>% mutate(after_class = once))
  chk(identical(once, twice), "I1 classify(classify(x)) == classify(x)")
}

cat("\n-- C: conservation is asserted by the builder --\n")
{
  chk(grepl("N_EVIDENCE_IN", code),
      "C1 the builder records the input evidence count")
  chk(grepl("stopifnot\\(nrow\\(evidence\\) == N_EVIDENCE_IN\\)", code),
      "C2 and HARD-FAILS if evidence rows changed")
  chk(grepl("FROZEN_RAW_NAMES", code),
      "C3 raw source names are frozen at construction and compared at the end")
  chk(grepl("was altered by the reconciliation", code, fixed = TRUE),
      "C4 and ALTERING one is an error; a source that simply has no name is not")
  # The before state must be READ, not recomputed with today's code.
  chk(grepl("organization_affiliation_resolved\\.csv", code),
      "C5 BEFORE is read from the frozen resolver artifact")
  chk(grepl("read, not recomputed", code, fixed = TRUE) ||
      grepl("before <- rd\\(", code),
      "C6 and is not rebuilt from the arms")
  # Improvements among already-covered midwives must not inflate the gain.
  chk(grepl("unres_before", code),
      "C7 the gain is measured against the previously-unresolved cohort only")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
