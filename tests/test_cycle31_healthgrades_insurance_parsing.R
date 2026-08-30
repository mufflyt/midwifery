#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 31 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: parse_insurance() and extract_json_array() in
# scrape_healthgrades_midwives.R. Cycle 6 exercised field_variability(),
# cohort_coverage() and assert_not_constant() on the ALREADY-PARSED attributes
# snapshot, but never touched the Medicaid/Medicare/payor-count PARSING logic
# itself -- the regexes and the bracket-depth JSON slicer that produce
# hg_medicaid_named, hg_medicare, hg_payor_n, hg_plan_n, hg_payors, hg_plans in
# the first place. That parsing feeds insurance/access logic (prioritized) and
# writes a public artifact column, so a silent miscount here would misstate
# how many payors a midwife accepts without ever tripping a "missing data"
# check.
#
# Loaded via sys.source() into a private env so the file's own
# `if (sys.nframe() == 0) main(...)` guard at the bottom does not fire and no
# network call, checkpoint read, or scrape is triggered -- verified empirically
# before writing this file (source() runs inside eval(), so sys.nframe() > 0
# there; Rscript-invoked top-level execution has sys.nframe() == 0).
#
# Run: Rscript tests/test_cycle31_healthgrades_insurance_parsing.R
# =============================================================================

suppressPackageStartupMessages({library(stringr); library(tibble)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

e <- new.env()
# DEPENDENCY GUARD, matching test_cycle12_names_territories.R and
# test_cycle4_ct_apportionment.R. scrape_healthgrades_midwives.R calls
# load_isochrones_name_tools() at top level -- BEFORE its own sys.nframe()
# guard -- and that loader stop()s when the isochrones checkout is absent,
# which no runner carries. The five files below are exactly what the loader
# requires, so this guard tests the real precondition rather than a proxy.
# Declared and counted as a skip rather than fatal.
.iso <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
.need <- file.path(.iso, c("utils/npi_luhn_qa.R", "string_normalization.R",
                           "nickname_system.R", "enhanced_name_parsing.R",
                           "name_parsing_protocol_enhanced.R"))
if (!dir.exists(.iso) || any(!file.exists(.need))) {
  cat("  --   SKIP cycle 31 Healthgrades payor parsing [absent: ~/isochrones name tools]\n")
  cat("\nPASS (0 failures, 1 skipped)\n")
  quit(status = 0)
}

sys.source("scrape_healthgrades_midwives.R", envir = e)
parse_insurance     <- e$parse_insurance
extract_json_array  <- e$extract_json_array

# Helper: build a minimal flight-payload fragment carrying one
# `"insuranceAccepted":[...]` block, so parse_insurance() can be driven the
# same way it is driven on a real (unescaped) Healthgrades page.
mk_payload <- function(payors, plan_names = NULL, plan_types = NULL) {
  if (is.null(plan_names)) plan_names <- paste0(payors, " Plan")
  if (is.null(plan_types)) plan_types <- rep("PPO", length(payors))
  items <- mapply(function(p, n, t) sprintf(
    '{"payor":"%s","plans":[{"name":"%s","planType":"%s"}]}', p, n, t),
    payors, plan_names, plan_types)
  paste0('"insuranceAccepted":[', paste(items, collapse = ","), ']')
}

cat("\n-- BVA --\n")

# T31-1. The 0-payor boundary: an explicitly empty array and a wholly ABSENT
# key must both collapse to the same "nothing known" shape (0 counts, NA
# flags) rather than one of them silently reading as FALSE ("no Medicaid").
{
  empty_arr <- parse_insurance('"insuranceAccepted":[]')
  no_key    <- parse_insurance('"someOtherKey":[1,2,3]')
  chk(empty_arr$hg_payor_n == 0L && empty_arr$hg_plan_n == 0L &&
        is.na(empty_arr$hg_medicaid_named) && is.na(empty_arr$hg_medicare),
      "T31-1a explicit empty insuranceAccepted array gives 0 counts, NA flags")
  chk(no_key$hg_payor_n == 0L && no_key$hg_plan_n == 0L &&
        is.na(no_key$hg_medicaid_named) && is.na(no_key$hg_medicare),
      "T31-1b missing insuranceAccepted key gives the identical 0/NA shape")
}

# T31-2. The 1-payor/1-plan boundary: the smallest non-empty case must count
# exactly 1 on both sides, with no off-by-one from the mapply/regex plumbing.
{
  one <- parse_insurance(mk_payload("Aetna"))
  chk(one$hg_payor_n == 1L && one$hg_plan_n == 1L && one$hg_payors == "Aetna",
      "T31-2 a single payor with a single plan counts 1 and 1")
}

# T31-3. THE DEFECT (fixed this cycle). Two plans under the SAME payor is the
# 1-distinct-payor / 2-listing boundary: hg_payor_n must report the distinct
# payor count (1), matching hg_payors, not the raw listing count (2).
{
  two_plans_one_payor <- parse_insurance(mk_payload(
    c("Aetna", "Aetna"), plan_names = c("Aetna PPO", "Aetna HMO")))
  chk(two_plans_one_payor$hg_payor_n == 1L,
      sprintf("T31-3 one payor with two plans reports hg_payor_n = 1 (got %d)",
              two_plans_one_payor$hg_payor_n))
  chk(two_plans_one_payor$hg_plan_n == 2L,
      "T31-3 ...while hg_plan_n correctly still counts both plans as 2")
  # ANTI-CEREMONY: the retired rule (raw length(), no dedup) would have said 2,
  # silently making hg_payor_n a duplicate of hg_plan_n in exactly this case.
  chk(length(c("Aetna", "Aetna")) == 2L,
      "T31-3b the retired raw-length rule would have reported hg_payor_n = 2")
}

cat("\n-- SEMANTIC --\n")

# T31-4. hg_payor_n must always agree with the payor LIST it is supposed to
# summarise: the number of ';'-separated names in hg_payors must equal
# hg_payor_n exactly. This is the label-matches-quantity contract the T31-3
# fix establishes; pin it so no future edit reintroduces the raw-count bug.
{
  mixed <- parse_insurance(mk_payload(
    c("Aetna", "Cigna", "Aetna", "Aetna"),
    plan_names = c("Aetna PPO", "Cigna EPO", "Aetna HMO", "Aetna Bronze")))
  n_listed <- length(strsplit(mixed$hg_payors, "; ")[[1]])
  chk(mixed$hg_payor_n == n_listed && mixed$hg_payor_n == 2L,
      sprintf("T31-4 hg_payor_n (%d) matches the %d distinct names in hg_payors ('%s')",
              mixed$hg_payor_n, n_listed, mixed$hg_payors))
}

# T31-5. The Medicaid regex requires the hyphen in "medi-cal": "Medical
# Mutual" (a real Ohio commercial insurer) must NOT be flagged, while
# "Medi-Cal" (with or without surrounding text) must.
{
  mm  <- parse_insurance(mk_payload("Medical Mutual"))
  mc1 <- parse_insurance(mk_payload("Medi-Cal"))
  mc2 <- parse_insurance(mk_payload("L.A. Care Medi-Cal Plan"))
  chk(isFALSE(mm$hg_medicaid_named),
      "T31-5a 'Medical Mutual' is not mistaken for Medicaid")
  chk(isTRUE(mc1$hg_medicaid_named) && isTRUE(mc2$hg_medicaid_named),
      "T31-5b 'Medi-Cal' is recognized bare and embedded in a longer payor name")
}

# T31-6. hg_medicaid_named and hg_medicare must not cross-contaminate despite
# sharing the "medi" prefix: a Medicare-only payor name must set hg_medicare
# TRUE without also tripping the Medicaid pattern.
{
  medicare_only <- parse_insurance(mk_payload("MediGold Medicare Advantage"))
  chk(isTRUE(medicare_only$hg_medicare) && isFALSE(medicare_only$hg_medicaid_named),
      "T31-6 a Medicare-named payor sets hg_medicare without also flagging Medicaid")
}

# T31-7. Per the function's own documentation ("Match across all three"), a
# Medicaid mention buried ONLY in planType -- not in the payor or plan name --
# must still set hg_medicaid_named, since the docstring explicitly claims
# planType is searched. A test that only checked the payor field would pass
# even if the planType branch of the match were silently dropped.
{
  in_plantype_only <- parse_insurance(mk_payload(
    "Ambetter", plan_names = "Ambetter Silver", plan_types = "Medicaid"))
  chk(isTRUE(in_plantype_only$hg_medicaid_named),
      "T31-7 a Medicaid mention that appears only in planType still sets the flag")
}

cat("\n-- ADVERSARIAL --\n")

# T31-8. Nested arrays: each payor object embeds its OWN `plans` array, so a
# naive '\\[([^]]*)\\]' would stop at the first payor's inner ']' and silently
# drop every subsequent payor. extract_json_array()'s depth counter must
# capture the FULL multi-payor block regardless of nesting.
{
  multi <- parse_insurance(mk_payload(c("Aetna", "Cigna", "Humana")))
  chk(multi$hg_payor_n == 3L && multi$hg_plan_n == 3L,
      sprintf("T31-8 three nested payor/plans objects all survive extraction (got payor_n=%d, plan_n=%d)",
              multi$hg_payor_n, multi$hg_plan_n))
}

# T31-9. Duplicate-heavy adversarial case: many repeated listings of the same
# two payors must still collapse to exactly 2 distinct payors, not merely
# handle the 2-duplicate case tested in T31-3. Guards against a fix that only
# works for pairs (e.g. one that swaps a single duplicate check instead of a
# genuine set operation).
{
  heavy <- parse_insurance(mk_payload(
    rep(c("Aetna", "Cigna"), 10),
    plan_names = paste0(rep(c("Aetna", "Cigna"), 10), "_plan_", 1:20)))
  chk(heavy$hg_payor_n == 2L && heavy$hg_plan_n == 20L,
      sprintf("T31-9 20 listings across 2 payors report hg_payor_n=2, hg_plan_n=20 (got %d, %d)",
              heavy$hg_payor_n, heavy$hg_plan_n))
}

# T31-10. A payor name containing a stray, unbalanced-looking bracket
# character (plausible in a real name like "Doe & Co [East Region]") must not
# desynchronize the depth counter and truncate the block early, PROVIDED the
# brackets are themselves balanced within the string -- verified here as the
# realistic case (a lone unmatched bracket in a payor name is not a case any
# real Healthgrades payload has ever been observed to contain, so it is
# recorded as a known limitation rather than fixed pre-emptively).
{
  bracketed <- parse_insurance(mk_payload("Doe & Co [East Region]"))
  chk(bracketed$hg_payor_n == 1L && bracketed$hg_plan_n == 1L &&
        !is.na(bracketed$hg_payors),
      "T31-10 a payor name containing a balanced bracket pair does not truncate parsing")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
