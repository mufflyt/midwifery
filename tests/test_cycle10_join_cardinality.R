#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 10 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Cycle 9 found the repo makes 46 bare joins against 8 guarded ones, and that
# the guard itself was unusable. This cycle acts on the inventory.
#
# The measurement that shapes it: NO artifact in this repo currently carries a
# duplicate certification_number. Every person-keyed join is therefore safe --
# today, by coincidence, and not by contract. That is the same shape as the
# .keep_all sites (cycle 5) and the POS tie-break that has never fired.
#
# The fix chosen is dplyr-native rather than a wrapper swap. `relationship =
# "many-to-one"` makes dplyr itself error when the right table has a duplicate
# key, needs no new dependency, and converts a silent fan-out into a loud
# failure at the exact line where it happens. Converting 46 joins to
# safe_left_join() would be a far larger edit for the same guarantee.
#
# Why fan-out is a scientific error and not a data-tidiness one: a left join
# that fans out increases the LEFT row count, and in this pipeline the left row
# count is the cohort -- the denominator of every proportion downstream. One
# duplicate row in a lookup table silently enlarges the cohort.
#
# Run: Rscript tests/test_cycle10_join_cardinality.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
R_FILES <- list.files(file.path(root, "R"), pattern = "\\.R$",
                      recursive = TRUE, full.names = TRUE)
# Blanks the comment lines instead of REMOVING them. An earlier version dropped
# them, so every reported line number indexed the filtered vector and pointed at
# innocent code several lines away -- the counts were right and the diagnostics
# were fiction. A source-scanning test must keep original line numbers or its
# output cannot be acted on.
code_of <- function(f) {
  s <- readLines(f, warn = FALSE)
  s[grepl("^\\s*#", s)] <- ""
  s
}

cat("\n-- BVA --\n")

# T91 (BVA). The guard's own edges. many-to-one must accept a unique right
# table and reject a duplicated one -- at exactly one duplicate, not two.
{
  L <- data.frame(k = c("a", "b"), v = 1:2, stringsAsFactors = FALSE)
  uniq <- data.frame(k = c("a", "b"), w = c(1, 2), stringsAsFactors = FALSE)
  dup1 <- data.frame(k = c("a", "a", "b"), w = c(1, 9, 2), stringsAsFactors = FALSE)
  ok <- tryCatch(nrow(left_join(L, uniq, by = "k", relationship = "many-to-one")),
                 error = function(e) -1L)
  bad <- tryCatch(nrow(left_join(L, dup1, by = "k", relationship = "many-to-one")),
                  error = function(e) -1L)
  chk(ok == 2L, "T91a a unique right table joins cleanly under many-to-one")
  chk(bad == -1L, "T91b a SINGLE duplicate right key is rejected, not fanned out")
}

# T92 (BVA). Degenerate shapes must not error. An empty right table is the
# normal state of an optional enrichment that has not been built yet.
{
  L <- data.frame(k = c("a", "b"), v = 1:2, stringsAsFactors = FALSE)
  E <- data.frame(k = character(0), w = numeric(0), stringsAsFactors = FALSE)
  n <- tryCatch(nrow(left_join(L, E, by = "k", relationship = "many-to-one")),
                error = function(e) -1L)
  chk(n == 2L, "T92a an empty right table preserves every left row")
  z <- tryCatch(nrow(left_join(L[0, ], E, by = "k", relationship = "many-to-one")),
                error = function(e) -1L)
  chk(z == 0L, "T92b zero rows on both sides is not an error")
}

# T93 (BVA). Composite keys. R/12 joins representatives on (state_abbr, cd);
# uniqueness must be evaluated on the PAIR, not either column alone.
{
  L <- data.frame(state_abbr = c("CO", "CO"), cd = c("1", "2"), stringsAsFactors = FALSE)
  Rt <- data.frame(state_abbr = c("CO", "CO"), cd = c("1", "2"),
                   rep = c("A", "B"), stringsAsFactors = FALSE)
  n <- tryCatch(nrow(left_join(L, Rt, by = c("state_abbr", "cd"),
                               relationship = "many-to-one")),
                error = function(e) -1L)
  chk(n == 2L, "T93 a composite key is unique on the pair even when each column repeats")
}

# T94 (BVA). Suffix handling. R/06 joins with suffix = c("", ".fin"), so a
# colliding column keeps the LEFT name and the right side is renamed. Silent
# shadowing here would replace a cohort value with a lookup value.
{
  L <- data.frame(k = "a", state = "CO", stringsAsFactors = FALSE)
  Rt <- data.frame(k = "a", state = "TX", stringsAsFactors = FALSE)
  j <- left_join(L, Rt, by = "k", suffix = c("", ".fin"), relationship = "many-to-one")
  chk(identical(j$state, "CO") && identical(j$state.fin, "TX"),
      sprintf("T94 an empty left suffix keeps the left value and renames the right [%s / %s]",
              j$state, j$state.fin))
}

cat("\n-- SEMANTIC --\n")

# T95 (semantic). THE AUDIT. Every join that builds the analysis cohort must
# declare its cardinality, because those are the joins whose fan-out changes a
# denominator rather than merely widening a table.
{
  cohort_files <- c("05-stage-progression.R", "06-cohort-flow.R",
                    "07-cohort-composition.R", "12-district-profiles.R")
  undeclared <- character(0)
  for (f in R_FILES) {
    if (!basename(f) %in% cohort_files) next
    src <- code_of(f)
    # A fixed 3-line window missed every multi-line join and reported code that
    # WAS declared as undeclared. The call is now read to its closing paren.
    for (i in grep("[^_a-z](left|inner)_join\\(", src)) {
      depth <- 0L; j <- i
      repeat {
        seg <- src[j]
        depth <- depth + lengths(regmatches(seg, gregexpr("\\(", seg))) -
          lengths(regmatches(seg, gregexpr("\\)", seg)))
        if (depth <= 0L || j >= length(src)) break
        j <- j + 1L
      }
      block <- paste(src[i:j], collapse = " ")
      if (!grepl("relationship\\s*=", block)) {
        undeclared <- c(undeclared, sprintf("%s:%d", basename(f), i))
      }
    }
  }
  chk(length(undeclared) == 0L,
      sprintf("T95 every cohort-building join declares its cardinality [%d undeclared: %s]",
              length(undeclared), paste(head(undeclared, 6), collapse = ", ")))
}

# T96 (semantic). The invariant the declaration protects: a left join must not
# change the left row count. This is what "the cohort" means.
{
  cohort <- data.frame(certification_number = sprintf("C%03d", 1:100),
                       stringsAsFactors = FALSE)
  lookup <- data.frame(certification_number = sprintf("C%03d", 1:100),
                       zip5 = "80218", stringsAsFactors = FALSE)
  j <- left_join(cohort, lookup, by = "certification_number",
                 relationship = "many-to-one")
  chk(nrow(j) == nrow(cohort),
      "T96 enriching a 100-person cohort leaves 100 people")
}

# T97 (semantic). A join that is GENUINELY many-to-many must say so, rather
# than being left undeclared and indistinguishable from an unaudited one.
# apportion_ct_legacy() is the honest case: one legacy county to several
# planning regions, declared.
{
  ct <- paste(code_of(file.path(root, "R", "lib", "ct_county_crosswalk.R")),
              collapse = "\n")
  chk(grepl('relationship\\s*=\\s*"many-to-many"', ct),
      "T97 the deliberately many-to-many CT apportionment declares itself as such")
}

cat("\n-- ADVERSARIAL --\n")

# T98 (adversarial). Inject the duplicate the artifacts do not currently have,
# and confirm the guard fires. Without this, T95 only asserts that text exists.
{
  cohort <- data.frame(certification_number = c("C1", "C2"), stringsAsFactors = FALSE)
  poisoned <- data.frame(certification_number = c("C1", "C1", "C2"),
                         zip5 = c("80218", "80219", "10001"), stringsAsFactors = FALSE)
  bare <- suppressWarnings(nrow(left_join(cohort, poisoned,
                                          by = "certification_number")))
  guarded <- tryCatch(nrow(left_join(cohort, poisoned, by = "certification_number",
                                     relationship = "many-to-one")),
                      error = function(e) -1L)
  chk(bare == 3L && guarded == -1L,
      sprintf("T98 one duplicate lookup row grows a 2-person cohort to %d bare, and is refused when declared",
              bare))
}

# T99 (adversarial). Row order must not decide which duplicate wins, in the
# case where a fan-out is later collapsed. If the guard is ever removed, this
# is the failure that returns.
{
  cohort <- data.frame(id = "p1", stringsAsFactors = FALSE)
  a <- data.frame(id = c("p1", "p1"), z = c("A", "B"), stringsAsFactors = FALSE)
  b <- a[c(2, 1), ]
  ja <- suppressWarnings(left_join(cohort, a, by = "id")$z[1])
  jb <- suppressWarnings(left_join(cohort, b, by = "id")$z[1])
  chk(!identical(ja, jb),
      sprintf("T99 an undeclared fan-out IS order-dependent, which is why it must be declared [%s vs %s]",
              ja, jb))
}

# T100 (adversarial). Repo-wide ratchet. 46 bare joins at cycle 9; the count
# must fall or hold, never grow.
{
  bare <- 0L
  for (f in R_FILES) {
    if (basename(f) == "join_safety.R") next
    src <- code_of(f)
    for (i in grep("[^_a-z](left|inner)_join\\(", src)) {
      depth <- 0L; j <- i
      repeat {
        seg <- src[j]
        depth <- depth + lengths(regmatches(seg, gregexpr("\\(", seg))) -
          lengths(regmatches(seg, gregexpr("\\)", seg)))
        if (depth <= 0L || j >= length(src)) break
        j <- j + 1L
      }
      if (!grepl("relationship\\s*=", paste(src[i:j], collapse = " "))) bare <- bare + 1L
    }
  }
  chk(bare <= 38L,
      sprintf("T100 undeclared-join count does not grow beyond the recorded debt [%d of 38]", bare))
  cat(sprintf("       undeclared joins remaining: %d\n", bare))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
