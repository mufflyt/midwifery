#!/usr/bin/env Rscript
# =============================================================================
# Does ci_denominator_contracts.R actually detect anything?
# =============================================================================
# A gate whose regex matches nothing passes exactly like a clean repository,
# and a gate whose arithmetic check reads a column that no longer exists passes
# too. This file builds a minimal repository that the gate PASSES, then
# perturbs one thing per case and requires the gate to fail -- the same
# construction tests/test_science_contracts_detect.R uses, and for the same
# reason.
#
# Minimal on purpose. A copy of the real repository carries all five live
# defects, so every planted defect would be indistinguishable from them.
#
# The near-miss cases matter as much as the planted ones. Both false positives
# the denominator gates produced on their first run are cases here --
# build_lead_lag_decomposition.R carrying two columns through a transmute()
# without dividing them, and a 1,500-line catalog whose unrelated `year <`
# satisfied the year-restriction check from four hundred lines away -- so the
# precision cannot silently regress.
#
# Shells out to Rscript once per case in a temporary git repository, so it
# costs ~40s. That is the whole reason the gate is trustworthy.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
GATE   <- file.path(root, "tests", "ci_denominator_contracts.R")
REPORT <- file.path(root, "tests", "ci_report.R")
stopifnot(file.exists(GATE), file.exists(REPORT))

failures <- character(0)
chk <- function(ok, msg) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else failures <<- c(failures, msg)
}

wl <- function(dir, rel, lines) writeLines(lines, file.path(dir, rel))

# --- the clean fixtures ------------------------------------------------------
# Two billing sources plus the registry. 2020-2022 observed, so 2022 is the
# panel edge for everyone and 2021 is the last year whose t+1 the registry can
# see.
#
# THE EDGE ROWS WITHHOLD THEIR FOLLOW-UP COLUMNS, which is the fixed form D2
# asks the producer for: a blank cell cannot be summed into a wrong rate, where
# a zero can. An earlier version of this fixture wrote the zeros the live
# artifact carries and the "clean" scaffold failed D2 -- correctly, which made
# every near-miss case below vacuous and hid two real false positives.
PERS_CLEAN <- c(
  "source,year,n_observed,n_followed_source,n_same_state,n_changed_state,n_lost_source_but_in_nppes,n_lost_from_source,pct_followed,pct_same_given_followed",
  "src_a,2020,1000,980,950,30,19,20,98.0,96.9",
  "src_a,2021,1100,1080,1050,30,19,20,98.2,97.2",
  "src_a,2022,1200,,,,,,,",
  "src_b,2020,500,480,470,10,19,20,96.0,97.9",
  "src_b,2021,520,500,490,10,19,20,96.2,98.0",
  "src_b,2022,540,,,,,,,",
  "nppes,2020,2000,1980,1950,30,0,20,99.0,98.5",
  "nppes,2021,2100,2080,2050,30,0,20,99.0,98.6",
  "nppes,2022,2200,,,,,,,")

# Counts that fit the group they belong to: the three concordance-breaking
# counts inside n_concordant_at_t, the resolution counts inside
# n_discordant_at_t, and the three discordance shares summing under 100.
LL_CLEAN <- c(
  "attribute,n_paired_transitions,n_concordant_at_t,a_breaks_concordance_first,b_breaks_concordance_first,both_move_together_at_t1,n_discordant_at_t,b_adopts_a_at_t1_n,b_adopts_a_at_t1_pct,a_reverts_to_b_at_t1_n,a_reverts_to_b_at_t1_pct,persistent_discordant_at_t1_pct,base_year,disc_base_n,source_b",
  "state,1000,900,20,30,10,100,10,10.0,20,20.0,65.0,2020,25,src_a",
  "state,800,700,10,20,5,100,5,5.0,15,15.0,75.0,2020,20,src_b")

CANON_CLEAN <- c(
  "amcb_id,npi,source,year,state,usable_for_trend",
  "1,1000000001,nppes,2020,CO,TRUE",
  "2,1000000002,nppes,2020,NY,TRUE",
  "1,1000000001,src_a,2020,CO,TRUE",
  "2,1000000002,src_a,2020,TX,FALSE")

# A pooling consumer that restricts to the years with follow-up. This is the
# fixed form of the defect D1 describes, and the clean case proves the gate
# accepts it.
CONSUMER_CLEAN <- c(
  'p <- read.csv("artifacts/persistence_denominators.csv")',
  'mx <- tapply(p$year, p$source, max)',
  'p <- p[p$year < mx[p$source], , drop = FALSE]',
  'agg <- aggregate(cbind(n_observed, n_lost_from_source) ~ source, data = p, FUN = sum)',
  'print(agg)')

# A state-scoring consumer of the canonical records that honours the flag.
UFT_CLEAN <- c(
  'x <- read.csv("artifacts/canonical_source_records.csv")',
  'x <- x[x$usable_for_trend == "TRUE", , drop = FALSE]',
  'print(table(x$state))')

scaffold <- function(dir) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "artifacts"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "manuscript", "R"), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE, file.path(dir, "tests", "ci_denominator_contracts.R"))
  file.copy(REPORT, file.path(dir, "tests", "ci_report.R"))
  wl(dir, "artifacts/persistence_denominators.csv", PERS_CLEAN)
  wl(dir, "artifacts/mrost_lead_lag.csv", LL_CLEAN)
  wl(dir, "artifacts/canonical_source_records.csv", CANON_CLEAN)
  wl(dir, "pool_persistence.R", CONSUMER_CLEAN)
  wl(dir, "score_agreement.R", UFT_CLEAN)
  # git init + add, because ci_tracked() asks git, not the filesystem. A gate
  # run against untracked files sees an empty repository and passes vacuously.
  system2("git", c("-C", shQuote(dir), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
}

# Returns TRUE when the gate FAILED. The `cd` is load-bearing: the gate
# resolves its own root as getwd(), so without it every case runs against the
# real repository, where all five defects are live and every assertion passes
# for the wrong reason.
gate_fails <- function(dir) {
  st <- suppressWarnings(system2(
    "sh", c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_denominator_contracts.R",
                                  shQuote(dir)))),
    stdout = NULL, stderr = NULL))
  !identical(as.integer(st), 0L)
}

# One case: scaffold, perturb, run. `expect_fail = FALSE` is a near miss.
case <- function(label, perturb, expect_fail = TRUE) {
  dir <- file.path(tempdir(), paste0("den", sample.int(1e6, 1)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scaffold(dir)
  perturb(dir)
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
  got <- gate_fails(dir)
  chk(identical(got, expect_fail), label)
}

cat("\n-- the scaffold itself is clean --\n")
dir <- file.path(tempdir(), paste0("den_clean", sample.int(1e6, 1)))
dir.create(dir, recursive = TRUE, showWarnings = FALSE)
scaffold(dir)
chk(!gate_fails(dir),
    "a clean repository passes (otherwise every case below is vacuous)")
unlink(dir, recursive = TRUE)

cat("\n-- planted defects, one per gate --\n")

case("D1 detects an interior year with no follow-up (the edge is no longer the only one)",
     function(d) {
       p <- PERS_CLEAN
       # src_a 2021 reports no follow-up at all, so a degenerate row now sits
       # inside the panel where the zero would be real attrition, and the
       # edge-exclusion rule no longer describes the shape.
       p[3] <- "src_a,2021,1100,0,0,0,19,1100,0.0,"
       wl(d, "artifacts/persistence_denominators.csv", p)
     })

case("D1 detects a consumer pooling every year with no year restriction",
     function(d) {
       wl(d, "pool_persistence.R", c(
         'p <- read.csv("artifacts/persistence_denominators.csv")',
         'agg <- aggregate(cbind(n_observed, n_lost_from_source) ~ source, data = p, FUN = sum)',
         'print(agg)'))
     })

case("D2 detects more registry-visible leavers than leavers",
     function(d) {
       p <- PERS_CLEAN
       p[2] <- "src_a,2020,1000,980,950,30,99,20,98.0,96.9"
       wl(d, "artifacts/persistence_denominators.csv", p)
     })

case("D2 detects a leaver-visibility share that moves >5 points off the panel edge",
     function(d) {
       p <- PERS_CLEAN
       # The live PECOS shape: the edge year DECLARES 1,200 leavers and zero
       # registry visibility instead of withholding both, so pooling drags
       # src_a from 95% down near 1.5%. This is the case the real artifact is
       # in today, and the one the fixed form above makes impossible.
       p[4] <- "src_a,2022,1200,0,0,0,0,1200,0.0,"
       wl(d, "artifacts/persistence_denominators.csv", p)
     })

case("D3 detects a discordance decomposition that already exceeds 100%",
     function(d) {
       l <- LL_CLEAN
       l[2] <- "state,1000,900,20,30,10,100,10,40.0,20,40.0,65.0,2020,25,src_a"
       wl(d, "artifacts/mrost_lead_lag.csv", l)
     })

case("D3 detects both_move_together_at_t1 divided by n_discordant_at_t",
     function(d) {
       wl(d, "manuscript/show_lead_lag.R", c(
         'rs <- read.csv("artifacts/mrost_lead_lag.csv")',
         'out <- data.frame(',
         '  src = rs$source_b,',
         '  both = 100 * as.numeric(rs$both_move_together_at_t1) /',
         '    as.numeric(rs$n_discordant_at_t))',
         'print(out)'))
     })

case("D4 detects a pooled count printed under a base-year label",
     function(d) {
       wl(d, "manuscript/show_base_year.R", c(
         'rs <- read.csv("artifacts/mrost_lead_lag.csv")',
         'out <- data.frame(`Base year` = rs$base_year,',
         '                  `Discordant (n)` = rs$n_discordant_at_t,',
         '                  check.names = FALSE)',
         'print(out)'))
     })

case("D5 detects a state-scoring consumer that ignores usable_for_trend",
     function(d) {
       wl(d, "score_agreement.R", c(
         'x <- read.csv("artifacts/canonical_source_records.csv")',
         'print(table(x$state, x$source))'))
     })

case("D1 detects a pooling block whose only year restriction is four hundred lines away",
     function(d) {
       # The build_stats_catalog.R shape, and the gate's second false negative:
       # a long file whose unrelated `year < cutoff` satisfied the check from
       # far outside the block that pools the denominators. The gate must still
       # fail here, so this case expects a failure for a PRECISION reason.
       wl(d, "big_catalog.R", c(
         'other <- read.csv("artifacts/canonical_source_records.csv")',
         'other <- other[other$usable_for_trend == "TRUE", , drop = FALSE]',
         'recent <- other[other$year < 2022, , drop = FALSE]',
         'print(nrow(recent))',
         # PADDING MUST BE CODE. The first version of this case padded with 60
         # COMMENT lines, which ci_code_lines() strips before the window is
         # cut -- so the restriction landed three stripped lines from the
         # pooling block, inside the window, and the case passed for a reason
         # that had nothing to do with distance.
         sprintf('pad_%02d <- nrow(other)', seq_len(60)),
         'p <- read.csv("artifacts/persistence_denominators.csv")',
         'agg <- aggregate(cbind(n_observed, n_lost_from_source) ~ source, data = p, FUN = sum)',
         'print(agg)'))
     })

cat("\n-- near misses that must NOT fail --\n")

case("D1 does NOT reject an edge row that DECLARES its degeneracy instead of withholding it",
     function(d) {
       # Both shapes are legal at the edge. The live artifact uses the declared
       # form, so a structural check that accepted only the withheld form would
       # fail the whole repository for the shape it already has.
       # The declared edge rows carry a visibility share matching the
       # evaluable years, so D2 is satisfied and this case tests D1's
       # structural check alone. An edge row that declares 1,200 leavers and
       # zero visibility is the D2 case above, not this one.
       p <- PERS_CLEAN
       p[4] <- "src_a,2022,1200,0,0,0,1140,1200,0.0,"
       p[7] <- "src_b,2022,540,0,0,0,513,540,0.0,"
       p[10] <- "nppes,2022,2200,0,0,0,0,2200,0.0,"
       wl(d, "artifacts/persistence_denominators.csv", p)
     }, expect_fail = FALSE)

case("D3 does NOT flag a script that merely CARRIES both columns through a transmute",
     function(d) {
       # The build_lead_lag_decomposition.R shape, and the gate's first false
       # positive: both names appear in one call, eight lines apart, and
       # nothing is divided by anything.
       wl(d, "carry_lead_lag.R", c(
         'll <- read.csv("artifacts/mrost_lead_lag.csv")',
         'out <- data.frame(',
         '  source = ll$source_b,',
         '  n_discordant_at_t = as.integer(ll$n_discordant_at_t),',
         '  pct_a = as.numeric(ll$b_adopts_a_at_t1_pct),',
         '  pct_b = as.numeric(ll$a_reverts_to_b_at_t1_pct),',
         '  pct_c = as.numeric(ll$persistent_discordant_at_t1_pct),',
         '  pct_d = as.numeric(ll$cross_section_in_prior_b_pct),',
         '  both_move_together_n = as.integer(ll$both_move_together_at_t1),',
         '  base_year = as.integer(ll$base_year))',
         'print(out)'))
     }, expect_fail = FALSE)

case("D5 does NOT flag a consumer of the canonical records that never scores state",
     function(d) {
       wl(d, "count_rows.R", c(
         'x <- read.csv("artifacts/canonical_source_records.csv")',
         'print(nrow(x))'))
     }, expect_fail = FALSE)

case("the gates do NOT flag the forbidden expressions NAMED in their own comments",
     function(d) {
       wl(d, "documented.R", c(
         "# This script must never divide both_move_together_at_t1 by",
         "# n_discordant_at_t, and must never print a `Base year` column from",
         "# the pooled count. It also must not pool",
         "# persistence_denominators.csv over n_lost_from_source with sum().",
         'print("nothing here does any of that")'))
     }, expect_fail = FALSE)

# D5's private-input skip, in BOTH directions. The skip was added because
# artifacts/canonical_source_records.csv is gitignored, so the old
# unconditional ci_fail() fired on every runner and D5 could never pass in CI.
# A skip that forgives any missing input would be a much worse gate than the
# one it replaced, so the discrimination -- `git check-ignore` on that exact
# path -- is what these two cases pin, not the skip itself.
case("D5 SKIPS when the canonical records are absent AND gitignored",
     function(dir) {
       unlink(file.path(dir, "artifacts", "canonical_source_records.csv"))
       wl(dir, ".gitignore", "artifacts/canonical_source_records.csv")
     }, expect_fail = FALSE)

case("D5 still FAILS when the canonical records are absent but TRACKED",
     function(dir) {
       unlink(file.path(dir, "artifacts", "canonical_source_records.csv"))
     }, expect_fail = TRUE)

cat("\n")
if (length(failures)) {
  for (f in failures) cat(sprintf("FAIL %s\n", f))
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
