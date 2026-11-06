#!/usr/bin/env Rscript
# =============================================================================
# migration_move_classification.R -- tests
# =============================================================================
# Covers every rule ID in classify_apparent_move() plus the 20 adversarial
# "saboteur" cases from docs/TECHNICAL_APPENDIX_MIGRATION_MOVE_CLASSIFICATION.md
# (each one a deliberately constructed scenario aimed at making the
# classifier produce a WRONG verdict or silently misbehave, not just a
# happy-path check). Saboteur numbers below match that doc's list exactly.
#
# Run: Rscript tests/test_migration_move_classification.R  (exit 1 on fail)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages(library(dplyr))
source(file.path(root, "R", "lib", "migration_move_classification.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

claims_df <- function(...) {
  rows <- list(...)
  do.call(rbind, lapply(rows, function(r) data.frame(npi = r[[1]], source_family = r[[2]], year = as.integer(r[[3]]), claimed_value = r[[4]], stringsAsFactors = FALSE)))
}
loo_df <- function(...) {
  rows <- list(...)
  do.call(rbind, lapply(rows, function(r) data.frame(npi = r[[1]], year = as.integer(r[[2]]), state = r[[3]], variant = r[[4]], method = r[[5]], stringsAsFactors = FALSE)))
}

cat("-- is_gap_transition() --\n")
chk(is_gap_transition(2017L, 2018L), "2017->2018 is a known gap")
chk(is_gap_transition(2023L, 2024L), "2023->2024 is a known gap")
chk(!is_gap_transition(2019L, 2020L), "2019->2020 is not a known gap")
chk(identical(is_gap_transition(c(2017L, 2019L), c(2018L, 2020L)), c(TRUE, FALSE)),
    "vectorized over data-frame columns, not just scalars")

cat("\n-- classify_row_type() (saboteurs #10-13) --\n")
chk(identical(classify_row_type(FALSE, FALSE, "CO", "NM"), "move"), "different states, no abstention -> move")
chk(identical(classify_row_type(FALSE, FALSE, "CO", "CO"), "stable"), "same state -> stable")
chk(identical(classify_row_type(TRUE, FALSE, NA, "CO"), "abstained"),
    "#12: year_from abstained (NA state) -> abstained, not crashed or miscategorized by an NA-as-string bug")
chk(identical(classify_row_type(TRUE, TRUE, NA, NA), "abstained"),
    "#13: both years abstained (NA==NA) -> abstained, NOT 'stable' -- abstention is checked before the NA==NA comparison ever matters")

cat("\n-- build_family_index() / lookup_family(): ambiguity and absence --\n")
idx1 <- list(dac_pecos_combined = build_family_index(
  claims_df(list("1", "dac_pecos_combined", 2020, "CO"), list("1", "dac_pecos_combined", 2021, "NM")), "dac_pecos_combined"))
chk(identical(lookup_family(idx1, "dac_pecos_combined", "1", 2020L)$state, "CO"), "clean single-value lookup resolves")
chk(identical(lookup_family(idx1, "dac_pecos_combined", "9", 2020L)$status, "unavailable"), "no row at all -> unavailable")
chk(identical(lookup_family(idx1, "nonexistent_family", "1", 2020L)$status, "unavailable"),
    "a family absent from the index entirely -> unavailable, never errors")

idx_ambig <- list(dac_pecos_combined = build_family_index(
  claims_df(list("2", "dac_pecos_combined", 2021, "CO"), list("2", "dac_pecos_combined", 2021, "NM")), "dac_pecos_combined"))
amb <- lookup_family(idx_ambig, "dac_pecos_combined", "2", 2021L)
chk(identical(amb$status, "ambiguous") && is.na(amb$state),
    "two conflicting claims, same npi-year -> ambiguous + NA, never arbitrarily resolved to the first row")

cat("\n-- classify_apparent_move(): one rule ID at a time --\n")

# CONF-2FAM, held out
claims_conf <- claims_df(
  list("10", "dac_pecos_combined", 2019, "CO"), list("10", "dac_pecos_combined", 2020, "NM"),
  list("10", "open_payments", 2019, "CO"), list("10", "open_payments", 2020, "NM")
)
fidx_conf <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_conf, f)), FAMILIES)
loo_conf <- loo_df(
  list("10", 2019, "CO", "drop_dac_pecos_combined", "dawid_skene"), list("10", 2020, "NM", "drop_dac_pecos_combined", "dawid_skene"),
  list("10", 2019, "CO", "drop_open_payments", "dawid_skene"), list("10", 2020, "NM", "drop_open_payments", "dawid_skene")
)
loo_idx_conf <- build_loo_index(loo_conf, "dawid_skene")
v_conf <- classify_apparent_move(fidx_conf, loo_idx_conf, "10", 2019L, 2020L, "CO", "NM")
chk(identical(v_conf$rule_id, "CONF-2FAM") && identical(v_conf$classification, "confirmed"),
    "2 independent families support + both held-out variants still show the move -> confirmed")

# CONF-2FAM-NOHOLD (saboteur #3: shallow held-out check must test EACH family)
loo_noheld <- loo_df(
  list("11", 2019, "CO", "drop_dac_pecos_combined", "dawid_skene"), list("11", 2020, "NM", "drop_dac_pecos_combined", "dawid_skene"),
  list("11", 2019, "CO", "drop_open_payments", "dawid_skene"), list("11", 2020, "CO", "drop_open_payments", "dawid_skene")  # no longer moves once open_payments is dropped
)
claims_noheld <- claims_df(
  list("11", "dac_pecos_combined", 2019, "CO"), list("11", "dac_pecos_combined", 2020, "NM"),
  list("11", "open_payments", 2019, "CO"), list("11", "open_payments", 2020, "NM")
)
fidx_noheld <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_noheld, f)), FAMILIES)
v_noheld <- classify_apparent_move(fidx_noheld, build_loo_index(loo_noheld, "dawid_skene"), "11", 2019L, 2020L, "CO", "NM")
chk(identical(v_noheld$rule_id, "CONF-2FAM-NOHOLD") && identical(v_noheld$classification, "confirmed_not_held_out"),
    "#3: 2 families support, but dropping open_payments alone erases the move in the refit -> downgraded, not silently approved")

# ART-CONTRA
claims_contra <- claims_df(list("12", "tmsis_medicaid", 2019, "CO"), list("12", "tmsis_medicaid", 2020, "CO"))
fidx_contra <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_contra, f)), FAMILIES)
v_contra <- classify_apparent_move(fidx_contra, list(), "12", 2019L, 2020L, "CO", "NM")
chk(identical(v_contra$rule_id, "ART-CONTRA") && identical(v_contra$classification, "administrative_artifact"),
    "one family shows the origin state persisting through the destination year -> administrative_artifact (ART-CONTRA)")

# ART-GAP (no evidence either way, but a known gap transition)
v_gap <- classify_apparent_move(list(), list(), "13", 2017L, 2018L, "CO", "NM")
chk(identical(v_gap$rule_id, "ART-GAP") && identical(v_gap$classification, "administrative_artifact"),
    "zero evidence + known gap transition -> administrative_artifact (ART-GAP)")

# MIXED-SPLIT
claims_mixed <- claims_df(
  list("14", "dac_pecos_combined", 2019, "CO"), list("14", "dac_pecos_combined", 2020, "NM"),
  list("14", "open_payments", 2019, "CO"), list("14", "open_payments", 2020, "CO")
)
fidx_mixed <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_mixed, f)), FAMILIES)
v_mixed <- classify_apparent_move(fidx_mixed, list(), "14", 2019L, 2020L, "CO", "NM")
chk(identical(v_mixed$rule_id, "MIXED-SPLIT") && identical(v_mixed$classification, "indeterminate"),
    "one family supports, another contradicts -> indeterminate (MIXED-SPLIT), not artifact and not confirmed")

# POSS-SINGLE
claims_single <- claims_df(list("15", "tmsis_medicaid", 2019, "CO"), list("15", "tmsis_medicaid", 2020, "NM"))
fidx_single <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_single, f)), FAMILIES)
v_single <- classify_apparent_move(fidx_single, list(), "15", 2019L, 2020L, "CO", "NM")
chk(identical(v_single$rule_id, "POSS-SINGLE") && identical(v_single$classification, "possible"),
    "exactly one supporting family -> possible (POSS-SINGLE), not confirmed")

# POSS-NONE
v_none <- classify_apparent_move(list(), list(), "16", 2019L, 2020L, "CO", "NM")
chk(identical(v_none$rule_id, "POSS-NONE") && identical(v_none$classification, "possible"),
    "zero evidence, not a gap transition -> possible (POSS-NONE)")

cat("\n-- saboteur-specific checks --\n")

# #1: duplicate rows for the SAME family must not inflate n_support past 1
claims_dup <- claims_df(
  list("20", "dac_pecos_combined", 2019, "CO"), list("20", "dac_pecos_combined", 2019, "CO"),  # literal duplicate row
  list("20", "dac_pecos_combined", 2020, "NM"), list("20", "dac_pecos_combined", 2020, "NM")
)
fidx_dup <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_dup, f)), FAMILIES)
v_dup <- classify_apparent_move(fidx_dup, list(), "20", 2019L, 2020L, "CO", "NM")
chk(v_dup$classification == "possible" && length(v_dup$support) == 1,
    "#1: duplicate rows within ONE family still count as exactly 1 family, never 2 -- stays 'possible', not 'confirmed'")

# #2: NPPES must never be counted as its own corroborator even if present in claims
claims_nppes <- claims_df(
  list("21", "nppes", 2019, "CO"), list("21", "nppes", 2020, "NM"),
  list("21", "dac_pecos_combined", 2019, "CO"), list("21", "dac_pecos_combined", 2020, "NM")
)
fidx_nppes <- setNames(lapply(c(FAMILIES, "nppes"), function(f) build_family_index(claims_nppes, f)), c(FAMILIES, "nppes"))
v_nppes <- classify_apparent_move(fidx_nppes, list(), "21", 2019L, 2020L, "CO", "NM")
chk(!("nppes" %in% v_nppes$support) && v_nppes$classification == "possible",
    "#2: nppes present in claims with a matching claim is still never counted -- only 1 real external family -> possible")

# #4: facility_affiliation (single 2026 snapshot) must resolve to unavailable for any other year
claims_facility <- claims_df(list("22", "facility_affiliation", 2026, "CO"))
fidx_facility <- list(facility_affiliation = build_family_index(claims_facility, "facility_affiliation"))
chk(identical(lookup_family(fidx_facility, "facility_affiliation", "22", 2026L)$status, "usable"),
    "#4: facility_affiliation IS usable for its one real snapshot year, 2026")
chk(identical(lookup_family(fidx_facility, "facility_affiliation", "22", 2020L)$status, "unavailable"),
    "#4: facility_affiliation resolves to unavailable for any year other than 2026 -- never a fallback/cached answer")

# #5 / #6: ambiguous claims never silently become support or contradict
claims_amb56 <- claims_df(
  list("23", "dac_pecos_combined", 2019, "CO"),
  list("23", "dac_pecos_combined", 2020, "NM"), list("23", "dac_pecos_combined", 2020, "CO")  # ambiguous at year_to: NM (matches) + CO (origin)
)
fidx_amb56 <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_amb56, f)), FAMILIES)
v_amb56 <- classify_apparent_move(fidx_amb56, list(), "23", 2019L, 2020L, "CO", "NM")
chk("dac_pecos_combined" %in% v_amb56$ambiguous && !("dac_pecos_combined" %in% v_amb56$support) && !("dac_pecos_combined" %in% v_amb56$contradict),
    "#5/#6: a family with conflicting claims (one matching state_to, one matching state_from) is flagged ambiguous only -- never support, never contradict")

# #7: rule-evaluation order -- a gap transition with genuine 2-family held-out support must win as CONFIRMED, not be forced to ART-GAP
claims_gapconf <- claims_df(
  list("24", "dac_pecos_combined", 2017, "CO"), list("24", "dac_pecos_combined", 2018, "NM"),
  list("24", "open_payments", 2017, "CO"), list("24", "open_payments", 2018, "NM")
)
fidx_gapconf <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_gapconf, f)), FAMILIES)
loo_gapconf <- loo_df(
  list("24", 2017, "CO", "drop_dac_pecos_combined", "dawid_skene"), list("24", 2018, "NM", "drop_dac_pecos_combined", "dawid_skene"),
  list("24", 2017, "CO", "drop_open_payments", "dawid_skene"), list("24", 2018, "NM", "drop_open_payments", "dawid_skene")
)
v_gapconf <- classify_apparent_move(fidx_gapconf, build_loo_index(loo_gapconf, "dawid_skene"), "24", 2017L, 2018L, "CO", "NM")
chk(identical(v_gapconf$rule_id, "CONF-2FAM"),
    "#7: genuine 2-family held-out support on a known-gap transition still resolves to CONF-2FAM, never downgraded to ART-GAP")

# #8: n_support=1, n_contradict=1 must land in MIXED-SPLIT, never ART-CONTRA (which requires n_support==0)
chk(identical(v_mixed$rule_id, "MIXED-SPLIT"), "#8: already covered above by the MIXED-SPLIT case (n_support=1,n_contradict=1)")

# #9: n_support=2, n_contradict=1 must still fail CONF-2FAM's n_contradict==0 requirement
claims_mixed91 <- claims_df(
  list("25", "dac_pecos_combined", 2019, "CO"), list("25", "dac_pecos_combined", 2020, "NM"),
  list("25", "open_payments", 2019, "CO"), list("25", "open_payments", 2020, "NM"),
  list("25", "tmsis_medicaid", 2019, "CO"), list("25", "tmsis_medicaid", 2020, "CO")
)
fidx_mixed91 <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_mixed91, f)), FAMILIES)
v_mixed91 <- classify_apparent_move(fidx_mixed91, list(), "25", 2019L, 2020L, "CO", "NM")
chk(identical(v_mixed91$rule_id, "MIXED-SPLIT") && length(v_mixed91$support) == 2 && length(v_mixed91$contradict) == 1,
    "#9: 2 supporting + 1 contradicting family -> MIXED-SPLIT, NOT confirmed just because n_support already clears the '2 families' bar")

# #14: held-out lookup must use the SAME method as the primary classification, never a different one
loo_wrongmethod <- loo_df(
  list("26", 2019, "CO", "drop_dac_pecos_combined", "majority"), list("26", 2020, "NM", "drop_dac_pecos_combined", "majority"),
  list("26", 2019, "CO", "drop_dac_pecos_combined", "dawid_skene"), list("26", 2020, "CO", "drop_dac_pecos_combined", "dawid_skene"),  # dawid_skene: move does NOT survive
  list("26", 2019, "CO", "drop_open_payments", "dawid_skene"), list("26", 2020, "NM", "drop_open_payments", "dawid_skene")
)
claims_wrongmethod <- claims_df(
  list("26", "dac_pecos_combined", 2019, "CO"), list("26", "dac_pecos_combined", 2020, "NM"),
  list("26", "open_payments", 2019, "CO"), list("26", "open_payments", 2020, "NM")
)
fidx_wrongmethod <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_wrongmethod, f)), FAMILIES)
v_wrongmethod <- classify_apparent_move(fidx_wrongmethod, build_loo_index(loo_wrongmethod, "dawid_skene"), "26", 2019L, 2020L, "CO", "NM")
chk(identical(v_wrongmethod$rule_id, "CONF-2FAM-NOHOLD"),
    "#14: build_loo_index() filtered to dawid_skene correctly sees dac_pecos_combined's failing drop-variant, not majority's passing one for the same npi/years")

# #15: a missing/mistyped variant key must FAIL the held-out check (default-deny), never default-approve
chk(!held_out_ok(list(), "dac_pecos_combined", "27", 2019L, 2020L),
    "#15: a completely empty loo_idx (simulating a missing/mistyped variant) -> held_out_ok is FALSE, not TRUE")
loo_partial <- loo_df(list("27", 2019, "CO", "drop_open_payments", "dawid_skene"), list("27", 2020, "NM", "drop_open_payments", "dawid_skene"))
chk(!held_out_ok(build_loo_index(loo_partial, "dawid_skene"), "dac_pecos_combined", "27", 2019L, 2020L),
    "#15: the variant that exists (drop_open_payments) must not be silently substituted for the one asked for (drop_dac_pecos_combined)")

# #16: 3 supporting families -> each INDIVIDUAL single-family drop-variant must be checked, not a combined drop-all-3 variant
claims_three <- claims_df(
  list("28", "dac_pecos_combined", 2019, "CO"), list("28", "dac_pecos_combined", 2020, "NM"),
  list("28", "open_payments", 2019, "CO"), list("28", "open_payments", 2020, "NM"),
  list("28", "tmsis_medicaid", 2019, "CO"), list("28", "tmsis_medicaid", 2020, "NM")
)
fidx_three <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_three, f)), FAMILIES)
loo_three <- loo_df(
  list("28", 2019, "CO", "drop_dac_pecos_combined", "dawid_skene"), list("28", 2020, "NM", "drop_dac_pecos_combined", "dawid_skene"),
  list("28", 2019, "CO", "drop_open_payments", "dawid_skene"), list("28", 2020, "NM", "drop_open_payments", "dawid_skene"),
  list("28", 2019, "CO", "drop_tmsis_medicaid", "dawid_skene"), list("28", 2020, "NM", "drop_tmsis_medicaid", "dawid_skene")
  # deliberately NO "drop_all_three"-style combined variant exists at all
)
v_three <- classify_apparent_move(fidx_three, build_loo_index(loo_three, "dawid_skene"), "28", 2019L, 2020L, "CO", "NM")
chk(identical(v_three$rule_id, "CONF-2FAM") && length(v_three$support) == 3,
    "#16: 3 supporting families all individually held-out -> confirmed, using only the 3 single-family drop-variants that actually exist")

# #17: contradiction check uses THIS move's own state_from, not a coincidental match elsewhere
claims_coincidence <- claims_df(list("29", "tmsis_medicaid", 2019, "NY"), list("29", "tmsis_medicaid", 2020, "NY"))
fidx_coincidence <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_coincidence, f)), FAMILIES)
v_coincidence <- classify_apparent_move(fidx_coincidence, list(), "29", 2019L, 2020L, "CO", "NM")
chk(length(v_coincidence$contradict) == 0 && length(v_coincidence$support) == 0,
    "#17: a family showing an unrelated state (NY) that matches neither this move's state_from (CO) nor state_to (NM) contributes nothing -- no spurious contradiction")

# #18: an unrelated NPI's claims in the same index must not contaminate a different NPI's lookup
claims_crosscohort <- claims_df(
  list("30", "dac_pecos_combined", 2019, "CO"), list("30", "dac_pecos_combined", 2020, "NM"),
  list("999999", "dac_pecos_combined", 2019, "CO"), list("999999", "dac_pecos_combined", 2020, "ZZ")  # decoy NPI, different outcome
)
fidx_crosscohort <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_crosscohort, f)), FAMILIES)
chk(identical(lookup_family(fidx_crosscohort, "dac_pecos_combined", "30", 2020L)$state, "NM"),
    "#18: NPI 30's lookup is unaffected by decoy NPI 999999 sharing the same source/year with a different value")

# #19: two adjacent transitions sharing a middle year must classify independently, no cross-leakage
claims_overlap <- claims_df(
  list("31", "dac_pecos_combined", 2019, "CO"), list("31", "dac_pecos_combined", 2020, "NY"), list("31", "dac_pecos_combined", 2021, "NM"),
  list("31", "open_payments", 2019, "CO"), list("31", "open_payments", 2020, "NY"), list("31", "open_payments", 2021, "NM")
)
fidx_overlap <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_overlap, f)), FAMILIES)
v_overlap_1 <- classify_apparent_move(fidx_overlap, list(), "31", 2019L, 2020L, "CO", "NY")
v_overlap_2 <- classify_apparent_move(fidx_overlap, list(), "31", 2020L, 2021L, "NY", "NM")
chk(length(v_overlap_1$support) == 2 && length(v_overlap_2$support) == 2,
    "#19: 2019->2020 and 2020->2021 (sharing year 2020's value) each find their own 2 supporting families")
chk(setequal(v_overlap_1$support, FAMILIES[1:2]) && setequal(v_overlap_2$support, FAMILIES[1:2]),
    "#19: no leakage between the two adjacent transitions -- each computed independently from the shared middle year")

# #20: a genuine contradiction on a known-gap transition must resolve to ART-CONTRA, not be merged with ART-GAP's reason
claims_gapcontra <- claims_df(list("32", "tmsis_medicaid", 2023, "CO"), list("32", "tmsis_medicaid", 2024, "CO"))
fidx_gapcontra <- setNames(lapply(FAMILIES, function(f) build_family_index(claims_gapcontra, f)), FAMILIES)
v_gapcontra <- classify_apparent_move(fidx_gapcontra, list(), "32", 2023L, 2024L, "CO", "NM")
chk(identical(v_gapcontra$rule_id, "ART-CONTRA") && v_gapcontra$reason != v_gap$reason,
    "#20: a real contradiction on 2023->2024 (a known gap) resolves to ART-CONTRA specifically, with a reason string distinguishable from ART-GAP's")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
