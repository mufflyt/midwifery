#!/usr/bin/env Rscript
# =============================================================================
# corroboration_lookup.R -- tests
# =============================================================================
# Covers the two pure functions audit_migration_corroboration_by_transition.R
# depends on: an ambiguity-safe single-state lookup (never arbitrarily picks
# the first of several conflicting rows), and the shared-lineage-aware
# independence check (DAC+PECOS alone must never count as independent
# corroboration).
#
# Run: Rscript tests/test_corroboration_lookup.R  (exit 1 on fail)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "corroboration_lookup.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("-- lookup_state() --\n")
src <- data.frame(
  npi   = c("1", "1", "2", "2", "3"),
  year  = c(2020L, 2021L, 2020L, 2020L, 2020L),
  state = c("CO", "CO", "TX", "FL", "NY"),
  stringsAsFactors = FALSE
)

r_none <- lookup_state(src, "9", 2020L)
chk(is.na(r_none$state) && !r_none$ambiguous, "no matching row -> NA, not ambiguous")

r_clean <- lookup_state(src, "1", 2020L)
chk(identical(r_clean$state, "CO") && !r_clean$ambiguous, "single matching row -> that state, not ambiguous")

r_dup_same <- lookup_state(src, "1", 2021L)
chk(identical(r_dup_same$state, "CO") && !r_dup_same$ambiguous, "duplicate identical state -> resolves cleanly")

r_ambig <- lookup_state(src, "2", 2020L)
chk(is.na(r_ambig$state) && r_ambig$ambiguous, "two DIFFERENT states, same npi-year -> NA + ambiguous (never v[1])")

cat("\n-- is_independent_source_set() --\n")
chk(!is_independent_source_set(c("dac_physician_compare")), "single source -> not independent")
chk(!is_independent_source_set(character(0)), "no sources -> not independent")
chk(!is_independent_source_set(c("dac_physician_compare", "pecos_revalidation")),
    "DAC+PECOS alone -> NOT independent (shared PECOS lineage)")
chk(!is_independent_source_set(c("pecos_revalidation", "dac_physician_compare")),
    "order-independent: PECOS+DAC -> still not independent")
chk(is_independent_source_set(c("dac_physician_compare", "open_payments")),
    "DAC+Open Payments -> independent")
chk(is_independent_source_set(c("pecos_revalidation", "open_payments")),
    "PECOS+Open Payments -> independent")
chk(is_independent_source_set(c("dac_physician_compare", "pecos_revalidation", "open_payments")),
    "all three -> independent (not wholly inside the shared-lineage group)")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
