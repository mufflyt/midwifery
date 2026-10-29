#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: the exclusion-flow pipeline (federal adverse action +
# canonical_active_primary())
# =============================================================================
# tests/test_exclusion_invariants.R checks the ordinary ladder arithmetic.
# This file tries to break the three real, reusable functions underneath it
# on purpose -- R/federal_adverse_action_exclusions.R's two functions and
# R/lib/cohort_definitions.R's canonical_active_primary() -- because every
# bug actually found while wiring the CMS NDH exclusion data into the
# exclusion-flow figure (2026-10-26) was exactly this shape: a population or
# rule mismatch between two places that happened to agree as long as a
# dormant code path never ran for real. Every assertion below is grounded in
# the committed implementation, not an assumed one; where a saboteur finds a
# real gap rather than confirming a guard, it says so.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "federal_adverse_action_exclusions.R"))
source(file.path(root, "R", "lib", "cohort_definitions.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

# =============================================================================
# build_federal_adverse_action_flags(): constructing the flags table
# =============================================================================
cat("\n-- build_federal_adverse_action_flags(): adversarial sources --\n")

# S1. The SAME NPI flagged by two different sources must combine into ONE
# row carrying BOTH source names, not two rows -- a reader counting rows
# would double-count the person otherwise.
s1 <- build_federal_adverse_action_flags(list(
  a = data.frame(npi = "1003001835", listed = TRUE),
  b = data.frame(npi = "1003001835", listed = TRUE)))
chk(nrow(s1) == 1L && identical(s1$federal_adverse_action_source, "a; b"),
    "S1 one NPI flagged by two sources combines into one row naming both sources")

# S2. The same NPI appears twice WITHIN one source, once listed, once not.
# The function filters on `listed` before building per-row records, so only
# the listed occurrence should contribute -- not a contradiction, not two
# rows.
s2 <- build_federal_adverse_action_flags(list(
  a = data.frame(npi = c("1003001835", "1003001835"), listed = c(TRUE, FALSE))))
chk(nrow(s2) == 1L && isTRUE(s2$federal_adverse_action_excluded[1]),
    "S2 one source listing the same NPI once TRUE and once FALSE still yields exactly one excluded row")

# S3. FIXED (was a confirmed crash). A malformed NPI (9 digits) should be
# silently dropped, not crash and not appear under a truncated/padded form.
# It used to crash: when zero rows of a source survive the valid-NPI-and-
# listed filter, `data.frame(npi = npi[keep], federal_adverse_action_excluded
# = TRUE, ...)` tried to recycle a length-1 TRUE against a length-0 npi
# vector, and data.frame() refuses that ("arguments imply differing number
# of rows") instead of returning an empty frame. A source consisting
# entirely of malformed NPIs is a real, reachable shape (a one-off bad
# export, a header row misread as data), so this now uses
# rep(TRUE, sum(keep)) to match the filtered length exactly.
s3 <- build_federal_adverse_action_flags(list(a = data.frame(npi = "100300183", listed = TRUE)))
chk(nrow(s3) == 0L,
    "S3 FIXED: a source entirely of malformed NPIs returns 0 rows instead of crashing the whole build")

# S4. A source with no `listed` column at all is treated as "every row in
# this source is listed" (`rep(TRUE, nrow(x))` in the implementation) -- a
# real, documented default, not a bug, but one worth locking in: a future
# source missing this column silently excludes its entire contents rather
# than erroring.
s4 <- build_federal_adverse_action_flags(list(a = data.frame(npi = "1003001835")))
chk(nrow(s4) == 1L && isTRUE(s4$federal_adverse_action_excluded),
    "S4 a source with no `listed` column treats every one of its rows as listed (documented default)")

# S5. A source missing the required `npi` column must stop with a message
# naming WHICH source index failed, not a generic subscript error.
s5_err <- tryCatch(
  build_federal_adverse_action_flags(list(a = data.frame(listed = TRUE))),
  error = function(e) conditionMessage(e))
chk(is.character(s5_err) && grepl("npi", s5_err, fixed = TRUE),
    "S5 a source missing `npi` stops with a message naming the missing column")

# S6. An empty sources list returns the documented zero-row shape, not NULL
# and not an error -- callers downstream (file.exists() guards elsewhere)
# depend on always getting a data.frame back.
s6 <- build_federal_adverse_action_flags(list())
chk(is.data.frame(s6) && nrow(s6) == 0L &&
    identical(names(s6), c("npi", "federal_adverse_action_excluded", "federal_adverse_action_source")),
    "S6 an empty sources list returns the correctly-shaped zero-row frame")

# S7. `listed` accepts "revoked" case-insensitively (in the accepted-value
# list) but a near-miss spelling ("revoke", missing the trailing d) must NOT
# be silently accepted -- the function does exact string membership after
# tolower(), not a prefix or fuzzy match.
s7a <- build_federal_adverse_action_flags(list(a = data.frame(npi = "1003001835", listed = "REVOKED")))
s7b <- build_federal_adverse_action_flags(list(a = data.frame(npi = "1003001835", listed = "revoke")))
chk(nrow(s7a) == 1L && nrow(s7b) == 0L,
    "S7 'REVOKED' (case-insensitive) is accepted; the near-miss 'revoke' is correctly rejected, not fuzzy-matched")

# =============================================================================
# exclude_federal_adverse_actions(): joining flags onto a cohort
# =============================================================================
cat("\n-- exclude_federal_adverse_actions(): adversarial cohorts and flags --\n")

# S8. THE REAL BUG FROM 2026-10-26, reproduced directly. Flagging an NPI that
# is "primary"-matched but held out of canonical_active_primary()'s
# membership rule (a class-5 surname-component match) must NOT be counted as
# excluded from the membership cohort -- that NPI was never part of it. This
# is exactly the mismatch that made matched_after_adverse_n exceed its own
# population in make_cohort_exclusion_flow_figure.R before the fix.
cohort_s8 <- data.frame(
  certification_number = c("C1", "C2"),
  npi                   = c("1000000001", "1000000002"),
  status                = c("ACTIVE", "ACTIVE"),
  linkage_tier          = c("primary_midwifery", "sensitivity_name_component"),
  nppes_state           = c("CO", "CO"))
membership_s8 <- canonical_active_primary(cohort_s8)
flags_s8 <- data.frame(npi = "1000000002", federal_adverse_action_excluded = TRUE)
excl_s8 <- exclude_federal_adverse_actions(membership_s8, flags_s8)
chk(nrow(membership_s8) == 1L && nrow(excl_s8$excluded) == 0L,
    "S8 flagging a class-5 held-out NPI excludes 0 people from the membership cohort (it was never a member)")

# S9. The SAME check run against the "match_status == primary" population
# instead (the pre-#222 fallback) DOES include that NPI -- the two rules
# genuinely disagree on this exact person, which is the whole reason this
# file exists.
cohort_s9 <- data.frame(npi = c("1000000001", "1000000002"))
excl_s9 <- exclude_federal_adverse_actions(cohort_s9, flags_s8)
chk(nrow(excl_s9$excluded) == 1L,
    "S9 the SAME flag, against the broader match_status=='primary' population, correctly excludes 1 -- confirming S8 is a real rule difference, not a no-op flag")

# S10. A duplicated NPI in `flags` with CONFLICTING excluded values is
# resolved by first-row-wins (`!duplicated(flags$npi)`) -- order-dependent,
# documented here as a real fragility rather than left to be discovered
# later. This saboteur locks in the CURRENT behavior so a future change to
# that dedup rule is a deliberate decision, not a silent one.
flags_s10 <- data.frame(
  npi = c("1000000001", "1000000001"),
  federal_adverse_action_excluded = c(TRUE, FALSE))
excl_s10 <- exclude_federal_adverse_actions(data.frame(npi = "1000000001"), flags_s10)
chk(isTRUE(excl_s10$all$federal_adverse_action_excluded[1]),
    "S10 a duplicated flags NPI with conflicting values resolves to whichever row came FIRST (order-dependent, documented)")

# S11. cohort$npi stored as numeric (not character) must still match --
# as.character() on a double must not introduce scientific notation or
# precision loss for a 10-digit NPI, which is well within double precision
# but worth confirming rather than assuming.
excl_s11 <- exclude_federal_adverse_actions(
  data.frame(npi = 1003001835), data.frame(npi = "1003001835", federal_adverse_action_excluded = TRUE))
chk(isTRUE(excl_s11$all$federal_adverse_action_excluded[1]),
    "S11 a numeric (not character) cohort NPI column still matches a character flags NPI")

# S12. Formatting noise in either column (dashes, spaces) must not prevent a
# match -- gsub("[^0-9]", ...) strips non-digits from BOTH sides before
# comparing.
excl_s12 <- exclude_federal_adverse_actions(
  data.frame(npi = "100-300-1835"), data.frame(npi = "1003001835", federal_adverse_action_excluded = TRUE))
chk(isTRUE(excl_s12$all$federal_adverse_action_excluded[1]),
    "S12 punctuation/whitespace noise in the cohort NPI does not block a real match")

# S13. A flagged NPI absent from the cohort entirely contributes nothing --
# no row gains an extra flag, no error, `excluded` has 0 rows.
excl_s13 <- exclude_federal_adverse_actions(
  data.frame(npi = "1000000001"), data.frame(npi = "9999999999", federal_adverse_action_excluded = TRUE))
chk(nrow(excl_s13$excluded) == 0L && !any(excl_s13$all$federal_adverse_action_excluded),
    "S13 a flagged NPI with no match anywhere in the cohort excludes nobody")

# S14. Missing the required `federal_adverse_action_excluded` column in
# `flags` must stop with a message naming it, not a downstream NULL-handling
# crash several lines later.
s14_err <- tryCatch(
  exclude_federal_adverse_actions(data.frame(npi = "1"), data.frame(npi = "1")),
  error = function(e) conditionMessage(e))
chk(is.character(s14_err) && grepl("federal_adverse_action_excluded", s14_err, fixed = TRUE),
    "S14 flags missing federal_adverse_action_excluded stops with a message naming the missing column")

# S15. A cohort missing the requested NPI column stops immediately, rather
# than proceeding with an all-NA key that would silently match nothing.
s15_err <- tryCatch(
  exclude_federal_adverse_actions(data.frame(x = 1), data.frame(npi = "1", federal_adverse_action_excluded = TRUE)),
  error = function(e) conditionMessage(e))
chk(is.character(s15_err) && grepl("NPI column", s15_err, fixed = TRUE),
    "S15 a cohort missing the NPI column stops rather than silently matching nothing")

# S16. Two cohort rows genuinely share one contested NPI (a real shape in
# this project -- ambiguous_contested_npi). Flagging that NPI must exclude
# BOTH rows, not just the first match.
cohort_s16 <- data.frame(certification_number = c("C1", "C2"), npi = c("1000000005", "1000000005"))
excl_s16 <- exclude_federal_adverse_actions(cohort_s16, data.frame(
  npi = "1000000005", federal_adverse_action_excluded = TRUE))
chk(nrow(excl_s16$excluded) == 2L,
    "S16 two cohort rows sharing one contested NPI are BOTH excluded, not just the first")

# S17. REAL GAP, NOT A CONFIRMATION: base R's match() treats NA as matching
# NA by default (no `incomparables` set in the implementation). A cohort row
# with a genuinely missing NPI and a flags row with a genuinely missing NPI
# therefore match each other through the digit-stripped key
# (gsub(...) on NA_character_ is NA_character_ on both sides). This saboteur
# documents the gap rather than asserting it is already closed.
cohort_s17 <- data.frame(npi = c(NA_character_, "1000000009"))
flags_s17 <- data.frame(npi = NA_character_, federal_adverse_action_excluded = TRUE)
excl_s17 <- exclude_federal_adverse_actions(cohort_s17, flags_s17)
gap_open <- isTRUE(excl_s17$all$federal_adverse_action_excluded[1])
chk(gap_open,
    paste("S17 GAP (not fixed by this file): a cohort row with NA npi and a flags row with NA npi",
          "match each other via match()'s NA==NA default -- a missing NPI is spuriously 'excluded'.",
          "Fix in exclude_federal_adverse_actions(): add `incomparables = NA` to the match() call."))

# =============================================================================
# canonical_active_primary(): the membership rule itself
# =============================================================================
cat("\n-- canonical_active_primary(): membership-rule edge cases --\n")

base_cols <- function(...) {
  d <- data.frame(..., stringsAsFactors = FALSE)
  d$nppes_state <- if (!"nppes_state" %in% names(d)) "CO" else d$nppes_state
  d
}

# S18. The same certification_number appears twice with the SAME npi (and
# different incidental columns, e.g. a stale vs fresh nppes_state) -- must
# collapse to exactly one row, deterministically the FIRST occurrence
# (`!duplicated()`), since that choice decides which state's geocoding the
# person is attributed downstream.
cohort_s18 <- base_cols(
  certification_number = c("C1", "C1"),
  status = c("ACTIVE", "ACTIVE"),
  linkage_tier = c("primary_midwifery", "primary_midwifery"),
  npi = c("1000000010", "1000000010"),
  nppes_state = c("CO", "TX"))
res_s18 <- canonical_active_primary(cohort_s18)
chk(nrow(res_s18) == 1L && identical(res_s18$nppes_state[1], "CO"),
    "S18 a certificant listed twice with the SAME npi collapses to one row, keeping the FIRST occurrence's other columns")

# S19. The same certification_number with TWO DIFFERENT real NPIs is an
# identity conflict and must stop, naming the certification number -- never
# silently resolved by row order the way S18's agreeing duplicate is.
cohort_s19 <- base_cols(
  certification_number = c("C2", "C2"),
  status = c("ACTIVE", "ACTIVE"),
  linkage_tier = c("primary_midwifery", "primary_midwifery"),
  npi = c("1000000011", "1000000012"))
s19_err <- tryCatch(canonical_active_primary(cohort_s19), error = function(e) conditionMessage(e))
chk(is.character(s19_err) && grepl("C2", s19_err, fixed = TRUE),
    "S19 one certification number carrying two different NPIs stops, naming the certification number")

# S20. REAL GAP, NOT A CONFIRMATION: the membership filter is
# `!is.na(npi) & nzchar(npi)`, with no trimws(). nzchar(" ") is TRUE (one
# character, a space), so an npi field containing only whitespace passes the
# "has an NPI" test and is counted as a member -- which it should not be.
cohort_s20 <- base_cols(
  certification_number = "C3", status = "ACTIVE",
  linkage_tier = "primary_midwifery", npi = " ")
res_s20 <- canonical_active_primary(cohort_s20)
gap_open_20 <- nrow(res_s20) == 1L
chk(gap_open_20,
    paste("S20 GAP (not fixed by this file): an npi field containing only whitespace passes",
          "nzchar() and is counted as analytic membership. Fix in canonical_active_primary():",
          "use nzchar(trimws(linkage$npi)) instead of nzchar(linkage$npi)."))

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
