# =============================================================================
# Nightly science contracts: the published numbers must survive recomputation
# =============================================================================
# ci_science_contracts.R polices the CODE -- it reads tracked source and asks
# whether a script claims more than its data supports. It runs on every push and
# is deliberately cheap, so it never opens an artifact beyond its header row.
#
# This file polices the OUTPUT. It reads every tracked artifact end to end and
# asks the question a reader of the paper would ask: does this number follow
# from the numbers printed beside it? A percentage whose denominator is not the
# one shown, an interval computed on a different denominator from its own point
# estimate, a stratum that silently drops rows, a rate reported where the
# denominator is empty -- none of these is visible in the source, and none is
# visible in a header row. They are only visible if you do the arithmetic.
#
# It is nightly rather than per-push because it does the arithmetic on all of
# it: 149 artifacts, ~9 MB at the widest, every row of every percentage column.
#
#   SCN1  A checkable percentage reproduces. Where the file itself carries the
#         numerator and the denominator, 100*num/den must equal the published
#         value on EVERY row -- not most rows. A formula that holds for nine
#         strata and breaks on the tenth is the signature of a stale denominator.
#
#   SCN2  A rate on an empty denominator is missing, not zero. 0/0 is undefined;
#         published as 0 it becomes the claim that none of them had the property,
#         which is the same defect A2 catches for suppressed counts.
#
#   SCN3  A stratification is exhaustive. Where a denominator is shown beside
#         the strata, the strata must sum to it. Rows that fall out of a
#         breakdown do not announce themselves -- every percentage in the block
#         still looks well formed.
#
#   SCN4  No group is collapsed onto a single level of a variable that varies
#         elsewhere. A stratum in which 100% of a large group takes one value,
#         when the same variable is spread across levels in a sibling group, is
#         a failed join reported as a finding.
#
#   SCN5  An interval matches the denominator beside it. Recomputing the Wilson
#         interval from the published numerator and denominator is the check
#         that a confidence interval was computed on the sample it is printed
#         next to; an interval on the wrong denominator is invisible otherwise,
#         and it is the one error that makes a null result look significant.
#
#   SCN6  Ascertainment is accounted for. Where a file names an unresolved
#         count, resolved + unresolved must equal the eligible denominator, so
#         a reader can see what the percentage is a percentage OF.
#
#   SCN7  A cohort flow ledger balances. cohort_flow_A_to_B.csv asserts a
#         transition; its removals cannot exceed A, and what survives them
#         cannot exceed B.
#
# DISCOVERY, NOT ENUMERATION. No gate here names an artifact. Each finds the
# structure it checks -- a percentage column, a denominator held constant within
# a group, an interval pair -- so an artifact added tomorrow is checked tonight.
# The two baselines below name files, and they are the only places that do.
#
# Base R only. Tracked files only. No network, no person-level data.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

# CSV reading is ci_read_head(path, -1L) from ci_report.R, called directly.
# ci_science_contracts.R records why there is no local alias: H4 counts a
# one-line delegator as a second top-level definition, correctly, since the
# delegator is what would drift.

# -----------------------------------------------------------------------------
# Shared structure detection
# -----------------------------------------------------------------------------
# Columns arrive as character so the PRINTED form is available -- the number of
# decimal places a value was written to is what sets the tolerance, and
# as.numeric() throws that away.

scn_num <- function(x) {
  v <- suppressWarnings(as.numeric(x))
  if (all(is.na(v))) NULL else v
}

# A count: non-negative and whole. Ids qualify and that is intended -- a GEOID
# is arithmetically a count, and excluding it by name would mean maintaining a
# list of id-shaped names that a new artifact immediately falsifies. The probe
# rule below is what keeps a spurious id/id pair from being mistaken for a
# formula, not the column name.
scn_is_count <- function(v) {
  # NA-SAFE, and it has to be. `all()` over a comparison involving Inf returns
  # NA, not FALSE: abs(Inf - round(Inf)) is NaN, NaN < 1e-9 is NA. The caller
  # subsets names(d) by this result, so a single NA turned one column name into
  # NA_character_, and nums[[NA_character_]] then failed inside ave() with
  # "first argument must be a vector" -- a crash, not a finding, two artifacts
  # away from the column that caused it.
  #
  # It arrived via a hex hash. artifacts/osmde_strict_containment_summary.csv
  # carries 2,852 location_hash values and one of them parses as Inf, which is
  # enough. A column holding a non-finite value is not a count either way, so
  # rejecting it outright is both the safe answer and the correct one.
  if (any(is.infinite(v))) return(FALSE)
  if (!any(is.finite(v))) return(FALSE)
  isTRUE(all(is.na(v) | (v >= 0 & abs(v - round(v)) < 1e-9)))
}

# Decimal places in the printed value. 99.94121537218018 was written at full
# precision and must reproduce exactly; 67.3 was rounded to one place and can
# only be held to half of the last digit.
scn_decimals <- function(s) {
  s <- s[!is.na(s) & nzchar(s)]
  if (!length(s)) return(0L)
  m <- regmatches(s, regexpr("\\.[0-9]+$", s))
  if (!length(m)) return(0L)
  max(nchar(m) - 1L)
}

scn_tol <- function(s) min(max(0.5 * 10^(-scn_decimals(s)), 1e-6), 0.05) + 1e-9

# A percent-like column: named like one, numeric, and on a 0-100 scale. The
# scale test is not redundant with S3 -- S3 gates NEW columns arriving as
# proportions; this one has to recognise what is already here.
SCN_PCTNAME <- "(^|_)(pct|percent|perc|share|prop)([_.]|$)|_pct$|^pct"

scn_pct_cols <- function(d, nums) {
  cand <- names(d)[grepl(SCN_PCTNAME, names(d), ignore.case = TRUE) &
                   !vapply(nums, is.null, logical(1))]
  cand[vapply(cand, function(cn) {
    v <- nums[[cn]]
    any(!is.na(v)) && all(is.na(v) | (v >= -1e-9 & v <= 100 + 1e-9))
  }, logical(1))]
}

# Grouping columns: non-numeric and genuinely repeating. Capped at 60 levels --
# above that a "group total" is a per-row total, which is not a denominator
# anybody reported, and building 3,000 of them is most of this file's runtime.
scn_group_cols <- function(d, nums) {
  names(d)[vapply(names(d), function(cn) {
    if (!is.null(nums[[cn]])) return(FALSE)
    u <- length(unique(d[[cn]]))
    u >= 1L && u <= 60L && u < nrow(d)
  }, logical(1))]
}

# Every denominator a reader could compute FROM THE FILE: a column, a column
# total, or a column total within a group. The third is how a table with no N
# column still states its denominator -- cohort_additions_by_mechanism.csv
# reports pct against the sum of n within each `field`.
scn_denominators <- function(d, nums, counts, groups) {
  dens <- list()
  for (cn in counts) dens[[cn]] <- nums[[cn]]
  for (cn in counts) {
    dens[[sprintf("sum(%s)", cn)]] <- rep(sum(nums[[cn]], na.rm = TRUE), nrow(d))
    for (g in groups)
      dens[[sprintf("sum(%s) by %s", cn, g)]] <-
        stats::ave(nums[[cn]], d[[g]], FUN = function(z) sum(z, na.rm = TRUE))
  }
  dens
}

# The formula behind a published percentage, or NULL.
#
# ESTABLISHED FROM EVIDENCE, NOT FROM NAMES. Requiring `n`/`N` would check five
# artifacts and miss the rest; guessing from column names would be wrong the
# first time an author picked a different one. A pair qualifies only if it
# reproduces at least SCN_MIN_PROBE percentages that are NOT zero -- zero
# divides by anything and matches everything, which is how `study_midwives /
# sum(ahrf_cah)` appeared to explain 735 rows of a county file it has no
# relationship to -- and at least 90% of the rows overall, so that a genuine
# formula is still found in a file carrying a handful of exceptions.
#
# The probe is also what makes this affordable. Testing three scalars before
# the full-vector comparison turns ~300,000 candidate pairs on the widest county
# file from minutes into seconds.
SCN_MIN_PROBE <- 3L

scn_formula <- function(pv, tol, nums, counts, dens) {
  best <- NULL
  for (nm in counts) {
    nv <- nums[[nm]]
    for (dn in names(dens)) {
      dv <- dens[[dn]]
      usable <- !is.na(pv) & !is.na(nv) & !is.na(dv) & dv > 0
      if (!any(usable)) next
      # Probe: the first few rows carrying a non-zero percentage.
      probe <- which(usable & pv > tol)
      if (length(probe) < SCN_MIN_PROBE) next
      probe <- utils::head(probe, SCN_MIN_PROBE)
      if (!all(abs(pv[probe] - 100 * nv[probe] / dv[probe]) <= tol)) next
      agree <- abs(pv[usable] - 100 * nv[usable] / dv[usable]) <= tol
      if (mean(agree) < 0.9) next
      score <- sum(agree & pv[usable] > tol)
      if (is.null(best) || score > best$score)
        best <- list(score = score, num = nm, den = dn,
                     agree = agree, usable = usable)
    }
  }
  best
}

# Wilson score interval, recomputed here rather than sourced from the scripts
# that produce these artifacts. That is deliberate and is the one place this
# repository's use-the-canonical-function rule is inverted: a check that calls
# the same function as the producer cannot detect a wrong denominator, because
# both sides make the same mistake. Independent arithmetic is the whole point.
#
# z = 1.96 reproduces every committed interval to 7e-15; qnorm(0.975) differs by
# up to 0.001 pp. SCN5's tolerance admits either.
scn_wilson <- function(x, n, z = 1.96) {
  p <- x / n
  d <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / d
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  cbind(100 * (centre - half), 100 * (centre + half))
}

# -----------------------------------------------------------------------------
# Read every tracked artifact once. Every gate below reads from here.
# -----------------------------------------------------------------------------
scn_files <- ci_tracked("artifacts/*.csv")
scn_files <- scn_files[!grepl("provenance[.]json$", scn_files)]

if (!length(scn_files)) {
  ci_skip("no tracked artifacts/*.csv; nothing to recompute")
  ci_finish()
}

SCN <- list()
for (f in scn_files) {
  d <- suppressWarnings(ci_read_head(f, -1L, root = root))
  if (is.null(d) || !nrow(d) || !ncol(d)) next
  nums <- lapply(d, scn_num)
  cn_all <- names(d)[!is.na(names(d)) & nzchar(names(d))]
  counts <- cn_all[vapply(cn_all, function(cn) {
    v <- nums[[cn]]; !is.null(v) && isTRUE(scn_is_count(v)) }, logical(1))]
  SCN[[f]] <- list(d = d, nums = nums, counts = counts,
                   groups = scn_group_cols(d, nums),
                   pcts = scn_pct_cols(d, nums))
}

# Formulas, established once and reused by SCN1 and SCN2.
SCN_FORMULAS <- list()
for (f in names(SCN)) {
  s <- SCN[[f]]
  if (!length(s$pcts) || !length(s$counts)) next
  dens <- scn_denominators(s$d, s$nums, s$counts, s$groups)
  for (p in s$pcts) {
    fit <- scn_formula(s$nums[[p]], scn_tol(s$d[[p]]), s$nums, s$counts, dens)
    if (is.null(fit)) next
    fit$file <- f; fit$col <- p; fit$dvec <- dens[[fit$den]]
    SCN_FORMULAS[[length(SCN_FORMULAS) + 1L]] <- fit
  }
}

# -----------------------------------------------------------------------------
ci_section("SCN1 a checkable percentage reproduces on every row")

off <- character(0)
for (fit in SCN_FORMULAS) {
  if (all(fit$agree)) next
  rows <- which(fit$usable)[!fit$agree]
  off <- c(off, sprintf("%s: %s = %s / %s fails on %d of %d row(s), first at row %d",
                        fit$file, fit$col, fit$num, fit$den,
                        sum(!fit$agree), sum(fit$usable), rows[1]))
}
if (length(off)) {
  ci_fail("SCN1: %d published percentage(s) do not follow from the counts beside them:\n%s\n       The formula holds on the other rows, so the column is not simply\n       computed differently -- these rows are on a different denominator.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("%d percentage column(s) reproduce exactly from their own counts (%d artifacts read)",
        length(SCN_FORMULAS), length(SCN))
}

# -----------------------------------------------------------------------------
ci_section("SCN2 a rate on an empty denominator is missing, not zero")

# KNOWN, AWAITING A DECISION -- not forgiven. Rewriting an artifact to make a
# new gate pass is the wrong direction of causation; the fix belongs to whoever
# owns the script that writes it.
#
# state_obstetric_workforce.csv reports pct_generalist_city_centroid = 0 for AS,
# GU and MP, each of which has general_obgyn = 0. Nought obstetricians is not
# "0% of obstetricians", and a reader ranking states by this column reads three
# territories as fully served by non-city-centroid geocoding.
#
# The baseline can only shrink: a fourth site fails, and fixing one of these
# requires deleting its line here.
SCN2_BASELINE <- c("artifacts/state_obstetric_workforce.csv")

off <- character(0); known <- character(0)
for (fit in SCN_FORMULAS) {
  pv <- SCN[[fit$file]]$nums[[fit$col]]
  z <- which(!is.na(fit$dvec) & fit$dvec == 0 & !is.na(pv))
  if (!length(z)) next
  entry <- sprintf("%s: %s = %s / %s carries a value on %d row(s) where the denominator is 0 (row %d = %s)",
                   fit$file, fit$col, fit$num, fit$den, length(z), z[1],
                   format(pv[z[1]]))
  if (fit$file %in% SCN2_BASELINE) known <- c(known, entry) else off <- c(off, entry)
}
# Only a STILL-TRACKED baselined file can be stale. A file that has been deleted
# is gone, not fixed -- treating its absence as a fix is what made the SCI2
# equivalent fire in every scaffold that did not contain all three of its files.
scn_stale <- setdiff(intersect(SCN2_BASELINE, names(SCN)),
                     unique(sub(":.*$", "", known)))
if (length(scn_stale)) {
  ci_fail("SCN2: %d baselined artifact(s) no longer report a rate on an empty denominator:\n%s\n       Remove them from SCN2_BASELINE so the baseline keeps shrinking.",
          length(scn_stale), paste(sprintf("       %s", scn_stale), collapse = "\n"))
}
if (length(known)) {
  ci_skip("SCN2: %d known empty-denominator rate(s) awaiting a decision:", length(known))
  for (k in known) cat(sprintf("       %s\n", k))
}
if (length(off)) {
  ci_fail("SCN2: %d rate(s) are reported where the denominator is empty:\n%s\n       0/0 is undefined. Write NA; a 0 says the property was absent in a\n       group that has no members to have it.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("no rate is published on an empty denominator")
}

# -----------------------------------------------------------------------------
ci_section("SCN3 a stratification is exhaustive")

# A block is (grouping column, count column, denominator column) where the
# denominator is CONSTANT within each group -- the shape of a breakdown that
# prints its own total. The relationship is established from evidence: the
# denominator must equal the group total in at least half the groups before the
# rest are held to it, so a column that is merely constant within a group is
# not mistaken for a denominator it was never meant to be.
scn_blocks <- function(s) {
  out <- list()
  for (g in s$groups) {
    key <- s$d[[g]]
    if (length(unique(key)) < 1L) next
    for (kn in s$counts) for (dn in setdiff(s$counts, kn)) {
      dv <- s$nums[[dn]]; kv <- s$nums[[kn]]
      const <- tapply(dv, key, function(z) length(unique(z[!is.na(z)])) == 1L)
      if (!all(const, na.rm = TRUE)) next
      tot <- tapply(kv, key, function(z) sum(z, na.rm = TRUE))
      den <- tapply(dv, key, function(z) z[!is.na(z)][1])
      ok <- !is.na(den) & den > 0
      if (sum(ok) < 1L) next
      agree <- tot[ok] == den[ok]
      if (mean(agree) < 0.5) next
      out[[length(out) + 1L]] <- list(group = g, count = kn, den = dn,
                                      tot = tot[ok], denv = den[ok],
                                      agree = agree, levels = names(tot)[ok])
    }
  }
  out
}

off <- character(0); n_blocks <- 0L
for (f in names(SCN)) {
  s <- SCN[[f]]
  if (!length(s$groups) || length(s$counts) < 2L) next
  for (b in scn_blocks(s)) {
    n_blocks <- n_blocks + 1L
    if (all(b$agree)) next
    bad <- which(!b$agree)
    off <- c(off, sprintf("%s: within %s, sum(%s) != %s for %d group(s), e.g. %s (%s vs %s)",
                          f, b$group, b$count, b$den, length(bad),
                          b$levels[bad[1]], format(b$tot[bad[1]]), format(b$denv[bad[1]])))
  }
}
if (length(off)) {
  ci_fail("SCN3: %d stratified block(s) do not sum to the denominator printed beside them:\n%s\n       Rows are missing from the breakdown. Every percentage in the block is\n       computed against a total the table does not show.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("all %d stratified block(s) sum to their stated denominator", n_blocks)
}

# -----------------------------------------------------------------------------
ci_section("SCN4 no group collapses onto one level of a variable that varies elsewhere")

# 100% of a group in a single stratum is either a real finding or a failed join,
# and the two are told apart by the siblings: if the same variable is spread
# across levels for another group in the same table, the collapsed group's
# geography (or certification, or status) was not measured -- it was defaulted.
#
# Guarded three ways so a small or genuinely uniform group is not flagged: the
# group must have at least SCN4_MIN members, another group must show at least
# two levels, and the vocabulary must contain more than one level overall.
SCN4_MIN <- 100L

# A group that sits entirely in an UNKNOWN level is doing the right thing. This
# gate's own failure message says "if the variable is unknown for it, say
# Unknown" -- so firing on a table that says exactly that is the gate
# contradicting its own remedy. It did: the moment the Alaska defect was fixed
# and 1,545 midwives moved from "Nonmetro, remote (7-9)" to "Unknown", SCN4
# flagged the corrected artifact. A collapse onto a REAL level is a failed
# join; a collapse onto an absence level is a measurement nobody could make.
SCN4_ABSENT <- "^\\s*(unknown|unk|missing|not reported|not observed|not available|none|n/?a)\\s*$"

# EMPTY, and it should stay that way.
#
# It held composition_rucc_cat.csv for one day. All 1,545 midwives in
# `2_newly_npi_resolved` were published as "Nonmetro, remote (7-9)", and the
# cause was not the RUCC banding: 903 rows of the Census ZCTA-county file have
# no ZCTA, two of the four private copies of the ZIP->county crosswalk failed
# to drop them, group_by() collapsed all 903 into one NA-keyed row pointing at
# Yukon-Koyukuk, Alaska, and left_join() matches NA to NA. Every midwife with
# no practice ZIP was placed in a remote Alaskan county with a real RUCC, which
# is why coalesce(..., "Unknown") never fired. Fixed by defining the crosswalk
# once, in R/lib/zip_county_crosswalk.R, where an NA key is an error.
#
# This gate found it. Nothing else in the repository would have: the code reads
# correctly at every one of the four sites, and the wrong answer is only
# visible in the arithmetic of the output.
SCN4_BASELINE <- character(0)

off <- character(0); known <- character(0); n_checked <- 0L
for (f in names(SCN)) {
  s <- SCN[[f]]
  if (!length(s$groups) || !length(s$counts)) next
  for (b in scn_blocks(s)) {
    lvl <- setdiff(s$groups, b$group)
    if (!length(lvl)) next
    lv <- lvl[1]
    key <- s$d[[b$group]]
    if (length(unique(s$d[[lv]])) < 2L) next
    n_levels <- tapply(s$nums[[b$count]] > 0, key, function(z) sum(z, na.rm = TRUE))
    n_levels <- n_levels[b$levels]
    if (!any(n_levels > 1L, na.rm = TRUE)) next   # nothing varies anywhere
    n_checked <- n_checked + 1L
    flat <- which(n_levels == 1L & b$denv >= SCN4_MIN)
    for (i in flat) {
      one <- s$d[[lv]][key == b$levels[i] & !is.na(s$nums[[b$count]]) &
                       s$nums[[b$count]] > 0][1]
      if (!is.na(one) && grepl(SCN4_ABSENT, one, ignore.case = TRUE)) next
      entry <- sprintf("%s: %s `%s` (n = %s) is 100%% `%s`; sibling groups span up to %d level(s)",
                       f, b$group, b$levels[i], format(b$denv[i]), one,
                       max(n_levels, na.rm = TRUE))
      if (f %in% SCN4_BASELINE) known <- c(known, entry) else off <- c(off, entry)
    }
  }
}
scn_stale <- setdiff(intersect(SCN4_BASELINE, names(SCN)),
                     unique(sub(":.*$", "", known)))
if (length(scn_stale)) {
  ci_fail("SCN4: %d baselined artifact(s) no longer collapse a group onto one level:\n%s\n       Remove them from SCN4_BASELINE so the baseline keeps shrinking.",
          length(scn_stale), paste(sprintf("       %s", scn_stale), collapse = "\n"))
}
if (length(known)) {
  ci_skip("SCN4: %d known collapsed stratum(s) awaiting a decision:", length(known))
  for (k in known) cat(sprintf("       %s\n", k))
}
if (length(off)) {
  ci_fail("SCN4: %d group(s) sit entirely in one level of a variable that varies elsewhere:\n%s\n       A group of this size with no spread was almost certainly defaulted by a\n       failed join. If the variable is unknown for it, say Unknown.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("no group is collapsed onto a single level (%d block(s) checked)", n_checked)
}

# -----------------------------------------------------------------------------
ci_section("SCN5 an interval contains its estimate and matches its own denominator")

# 0.05 pp admits z = 1.96 and qnorm(0.975) alike, and admits an exact or
# Agresti-Coull interval on the same denominator. It does not admit an interval
# computed on a DIFFERENT denominator, which is what this gate is for: at
# n = 14,595 against n = 16,892 the half-width moves by more than a point.
SCN5_TOL <- 0.05

scn_lo <- "^(ci_low|ci_lower|conf[._]low|lcl|lower_ci)$"
scn_hi <- "^(ci_high|ci_upper|conf[._]high|ucl|upper_ci)$"

off <- character(0); n_int <- 0L; n_wilson <- 0L
for (f in names(SCN)) {
  s <- SCN[[f]]
  lo <- grep(scn_lo, names(s$d), ignore.case = TRUE, value = TRUE)
  hi <- grep(scn_hi, names(s$d), ignore.case = TRUE, value = TRUE)
  if (!length(lo) || !length(hi)) next
  L <- s$nums[[lo[1]]]; H <- s$nums[[hi[1]]]
  if (is.null(L) || is.null(H)) next
  # The estimate: the percentage column this file's formula search recognised.
  fits <- Filter(function(x) identical(x$file, f), SCN_FORMULAS)
  est <- if (length(fits)) fits[[1]]$col else scn_pct_cols(s$d, s$nums)[1]
  if (is.na(est)) next
  P <- s$nums[[est]]
  n_int <- n_int + sum(!is.na(L) & !is.na(H))

  bad <- which(!is.na(L) & !is.na(H) & L > H + 1e-9)
  if (length(bad))
    off <- c(off, sprintf("%s: %s > %s on %d row(s), first at row %d",
                          f, lo[1], hi[1], length(bad), bad[1]))
  out <- which(!is.na(P) & !is.na(L) & !is.na(H) & (P < L - 1e-9 | P > H + 1e-9))
  if (length(out))
    off <- c(off, sprintf("%s: %s falls outside [%s, %s] on %d row(s), first at row %d",
                          f, est, lo[1], hi[1], length(out), out[1]))
  rng <- which((!is.na(L) & L < -1e-9) | (!is.na(H) & H > 100 + 1e-9))
  if (length(rng))
    off <- c(off, sprintf("%s: interval leaves [0, 100] on %d row(s), first at row %d",
                          f, length(rng), rng[1]))

  # The denominator the interval must have used is the one the percentage used.
  if (!length(fits)) next
  fit <- Filter(function(x) identical(x$col, est), fits)
  if (!length(fit)) next
  fit <- fit[[1]]
  X <- s$nums[[fit$num]]; N <- fit$dvec
  ok <- !is.na(X) & !is.na(N) & N > 0 & !is.na(L) & !is.na(H)
  if (!any(ok)) next
  w <- scn_wilson(X[ok], N[ok])
  dev <- pmax(abs(w[, 1] - L[ok]), abs(w[, 2] - H[ok]))
  n_wilson <- n_wilson + sum(ok)
  if (any(dev > SCN5_TOL)) {
    i <- which(ok)[which.max(dev)]
    off <- c(off, sprintf("%s: interval on row %d is [%.4f, %.4f]; Wilson on %s/%s = %d/%s is [%.4f, %.4f], off by %.3f pp",
                          f, i, L[i], H[i], fit$num, fit$den, X[i], format(N[i]),
                          scn_wilson(X[i], N[i])[1], scn_wilson(X[i], N[i])[2],
                          max(dev)))
  }
}
if (length(off)) {
  ci_fail("SCN5: %d interval defect(s):\n%s\n       An interval that does not reproduce from the denominator printed beside\n       it was computed on a different sample from its own point estimate.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("%d interval(s) contain their estimate; %d reproduce Wilson on their own denominator",
        n_int, n_wilson)
}

# -----------------------------------------------------------------------------
ci_section("SCN6 ascertainment is accounted for")

# Where a file publishes a percentage AND names an unresolved count, the
# unresolved count must be part of a set of columns that adds to that
# percentage's denominator. That is the only way a reader can tell whether the
# denominator includes the unresolved -- and in
# stage_progression_like_for_like.csv the two readings differ by a factor of
# three, which is the size of the effect the paper reports.
#
# SCOPED TO FILES THAT PUBLISH A PERCENTAGE, deliberately. An earlier version
# demanded a partition from every file naming an unresolved count and flagged
# dac_hospital_affiliation_summary.csv, a one-row summary of OVERLAPPING
# indicator counts -- with_hospital, any_critical, multi_hospital -- which is
# not a breakdown and has no denominator to partition. Nothing there misleads
# anyone, and a gate that demands a partition from a file that never claimed
# one is the kind of false positive that gets a nightly switched off.
SCN_UNRES <- "unresolved|unascertained|unmatched|unknown_n|n_missing"

# Subset sums of the other counts. Bounded: at most four columns, and at most
# two once a file is wide enough that the search would dominate the run. A
# disposition table nobody can add up in four terms is not one a reader adds up
# either.
scn_completes <- function(uv, target, others, nums) {
  # The denominator column itself is not a term in its own decomposition.
  others <- others[!vapply(others, function(nm) {
    v <- nums[[nm]]; ok <- !is.na(v) & !is.na(target)
    any(ok) && all(v[ok] == target[ok])
  }, logical(1))]

  # TRY THE WHOLE SET FIRST. An exhaustive breakdown -- one column per
  # disposition, which is what a table SHOULD look like -- decomposes the
  # denominator into as many terms as it has categories, and the subset search
  # below never reaches that far. linkage_completeness_by_status.csv was
  # rewritten to be exhaustive in exactly this shape, seven dispositions
  # summing to n, and this gate still called it unaccounted because it only
  # looked four terms deep. A gate that rejects the corrected form of the very
  # thing it asked for teaches people to ignore it.
  if (length(others)) {
    s <- uv
    for (nm in others) s <- s + nums[[nm]]
    ok <- !is.na(s) & !is.na(target)
    if (any(ok) && all(s[ok] == target[ok])) return(others)
  }

  depth <- if (length(others) > 15L) 2L else 4L
  depth <- min(depth, length(others))
  for (k in seq_len(depth)) {
    combos <- utils::combn(others, k, simplify = FALSE)
    for (cc in combos) {
      s <- uv
      for (nm in cc) s <- s + nums[[nm]]
      ok <- !is.na(s) & !is.na(target)
      if (!any(ok)) next
      if (all(s[ok] == target[ok])) return(cc)
    }
  }
  NULL
}

# EMPTY, and it should stay that way.
#
# It held linkage_completeness_by_status.csv for one day. Four hand-named
# dispositions summed to 20,473 of 22,309 rows, leaving 1,836 people (8.2%,
# 845 of them ACTIVE) inside the denominator and outside every column beside
# it. The names were also stale: the producing script tested a `match_status`
# column the frozen linkage had renamed, and `frozen$match_status` on a tibble
# returns NULL rather than raising, so the JSON manifest reported zero
# primaries without complaint. Fixed by pivoting the disposition column instead
# of enumerating it, so `n` is the sum of the columns rather than an
# independent count and the two cannot disagree.
SCN6_BASELINE <- character(0)

off <- character(0); known <- character(0); n_part <- 0L
for (f in names(SCN)) {
  s <- SCN[[f]]
  un <- grep(SCN_UNRES, s$counts, ignore.case = TRUE, value = TRUE)
  if (!length(un)) next
  fits <- Filter(function(x) identical(x$file, f), SCN_FORMULAS)
  if (!length(fits)) next            # no published percentage; nothing to scope
  for (u in un) {
    uv <- s$nums[[u]]
    for (fit in fits) {
      others <- setdiff(s$counts, u)
      cc <- scn_completes(uv, fit$dvec, others, s$nums)
      if (!is.null(cc)) { n_part <- n_part + 1L; next }
      entry <- sprintf("%s: %s belongs to no set of columns adding to %s, the denominator behind %s",
                       f, u, fit$den, fit$col)
      if (f %in% SCN6_BASELINE) known <- c(known, entry) else off <- c(off, entry)
    }
  }
}
scn_stale <- setdiff(intersect(SCN6_BASELINE, names(SCN)),
                     unique(sub(":.*$", "", known)))
if (length(scn_stale)) {
  ci_fail("SCN6: %d baselined artifact(s) now account for their unresolved count:\n%s\n       Remove them from SCN6_BASELINE so the baseline keeps shrinking.",
          length(scn_stale), paste(sprintf("       %s", scn_stale), collapse = "\n"))
}
if (length(known)) {
  ci_skip("SCN6: %d known unaccounted disposition(s) awaiting a decision:", length(known))
  for (k in known) cat(sprintf("       %s\n", k))
}
if (length(off)) {
  ci_fail("SCN6: %d unresolved count(s) do not account for their denominator:\n%s\n       A reader adding the dispositions must reach the denominator the\n       percentage was computed on. People who reach neither are invisible.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("every unresolved count accounts for its denominator (%d)", n_part)
}

# -----------------------------------------------------------------------------
ci_section("SCN7 a cohort flow ledger balances")

flows <- grep("cohort_flow_[0-9]+_to_[0-9]+[.]csv$", names(SCN), value = TRUE)
off <- character(0)
if (!length(flows)) {
  ci_skip("no cohort_flow_A_to_B artifact tracked; skipped")
} else {
  for (f in flows) {
    m <- regmatches(basename(f), regexec("cohort_flow_([0-9]+)_to_([0-9]+)", basename(f)))[[1]]
    A <- as.numeric(m[2]); B <- as.numeric(m[3])
    s <- SCN[[f]]
    if (!length(s$counts)) { off <- c(off, sprintf("%s: no count column to sum", f)); next }
    removed <- sum(s$nums[[s$counts[1]]], na.rm = TRUE)
    retained <- A - removed
    if (removed > A) {
      off <- c(off, sprintf("%s: removes %s from a cohort of %s", f, format(removed), format(A)))
    } else if (retained > B) {
      off <- c(off, sprintf("%s: %s survive the listed removals but the cohort ends at %s -- %s people leave with no reason recorded",
                            f, format(retained), format(B), format(retained - B)))
    } else {
      # Corroboration: the retained count should be a denominator somewhere.
      seen <- FALSE
      for (g in names(SCN)) {
        for (cn in SCN[[g]]$counts)
          if (any(SCN[[g]]$nums[[cn]] == retained, na.rm = TRUE)) { seen <- TRUE; break }
        if (seen) break
      }
      if (seen) {
        ci_ok("%s: %s - %s removed = %s retained, + %s added = %s (retained count corroborated)",
              basename(f), format(A), format(removed), format(retained),
              format(B - retained), format(B))
      } else {
        ci_skip("%s: balances (%s - %s = %s, + %s = %s) but no tracked artifact carries the retained count",
                basename(f), format(A), format(removed), format(retained),
                format(B - retained), format(B))
      }
    }
  }
  if (length(off)) {
    ci_fail("SCN7: %d cohort flow ledger(s) do not balance:\n%s\n       A CONSORT flow that does not add up means people left the cohort for a\n       reason nobody wrote down.",
            length(off), paste(sprintf("       %s", off), collapse = "\n"))
  }
}

ci_finish()
