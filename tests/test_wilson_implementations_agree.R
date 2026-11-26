#!/usr/bin/env Rscript
# =============================================================================
# The three Wilson intervals agree, and differ only in UNITS
# =============================================================================
# This repository computes a Wilson score interval in three places, on purpose:
#
#   R/lib/wilson_interval.R::wilson(x, n, conf)         -> PROPORTION, 0..1
#   manuscript/R/build_stats_catalog.R::mw_wilson(x, n, z) -> PERCENT, 0..100
#   tests/ci_science_nightly.R::scn_wilson(x, n, z)        -> PERCENT, 0..100
#
# R/lib/wilson_interval.R states the split is deliberate ("named apart on
# purpose; do not merge them into this one without reading those tests") and
# each is pinned by its own tests. What nothing pinned until now is the
# relationship BETWEEN them, and that is where the risk actually lives:
#
#   - They are the same formula, so a change to one is a silent divergence
#     from the other two. Three copies of a formula that no test compares is
#     the duplication problem with extra steps.
#   - They do NOT return the same thing. One is a proportion and two are
#     percentages. A caller that swaps one for another is wrong by 100x, and
#     0.74 vs 74.26 are both plausible-looking numbers for a confidence bound.
#     build_f2_f3_uncertainty_denominators.R already carries a `pct_bound()`
#     helper whose entire job is that multiplication.
#
# rOpenSci statistical standard G5.4a asks for correctness tests of a method
# against an existing implementation; with three in one repository, the
# comparison is available for free and is the cheapest correctness evidence
# there is. G1.3 asks that statistical terminology be unambiguous, and a
# function returning 0.74 where its neighbour returns 74.26 is the ambiguity
# that standard is about.
#
# No srr tags: this repository is not an R package (no DESCRIPTION, no
# NAMESPACE), so the roclet that reads them does not run here. The standard is
# applied on its merits rather than annotated for a toolchain that is absent.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

ci_section("W1 the three Wilson implementations agree up to units")

# Pull each definition out of the file that owns it rather than re-stating the
# formula here. A fourth copy written for the test to compare against would
# prove only that the test agrees with itself.
extract_fn <- function(path, name) {
  src <- tryCatch(readLines(file.path(root, path), warn = FALSE),
                  error = function(e) character(0))
  i <- grep(sprintf("^\\s*%s <- function", name), src)
  if (!length(i)) return(NULL)
  i <- i[1]; depth <- 0L; end <- NA_integer_
  for (j in seq(i, length(src))) {
    depth <- depth + lengths(regmatches(src[j], gregexpr("\\{", src[j]))) -
                     lengths(regmatches(src[j], gregexpr("\\}", src[j])))
    if (j > i && depth == 0L) { end <- j; break }
  }
  if (is.na(end)) return(NULL)
  env <- new.env(parent = globalenv())
  tryCatch({ eval(parse(text = paste(src[i:end], collapse = "\n")), envir = env)
             get(name, envir = env) }, error = function(e) NULL)
}

source(file.path(root, "R", "lib", "wilson_interval.R"))
mw  <- extract_fn(file.path("manuscript", "R", "build_stats_catalog.R"), "mw_wilson")
scn <- extract_fn(file.path("tests", "ci_science_nightly.R"), "scn_wilson")

if (is.null(mw) || is.null(scn)) {
  ci_fail("W1: could not extract %s. The comparison cannot run, which is a
       failure of this check rather than a pass -- a renamed or restructured
       implementation needs this file updated, not silently skipped.",
       paste(c(if (is.null(mw)) "mw_wilson", if (is.null(scn)) "scn_wilson"),
             collapse = " and "))
  ci_finish()
}

z95 <- stats::qnorm(0.975)

# Boundaries first: 25/25 is the case R/lib/wilson_interval.R was written for,
# and 0/10 and 10/10 are where a normal approximation runs outside [0, 1].
cases <- list(c(25, 25), c(0, 10), c(10, 10), c(1, 10), c(5, 10),
              c(6625, 8813), c(1, 1), c(3, 7))

bad <- character(0)
for (p in cases) {
  x <- p[1]; n <- p[2]
  # as.vector() because the three do not agree on SHAPE either: scn_wilson()
  # builds its result with cbind() so it can be called on vectors of x and n,
  # and returns a 1x2 matrix for scalar input where the other two return a
  # length-2 vector. The values are what this check is about; the shape is
  # asserted separately in W3 so that it, too, cannot change unnoticed.
  a <- as.vector(wilson(x, n, 0.95))
  b <- as.vector(mw(x, n, z95))
  cc <- as.vector(scn(x, n, z95))
  if (!isTRUE(all.equal(a * 100, b, tolerance = 1e-9)) ||
      !isTRUE(all.equal(a * 100, cc, tolerance = 1e-9))) {
    bad <- c(bad, sprintf("%d/%d: wilson=%s mw_wilson=%s scn_wilson=%s",
                          x, n, paste(round(a, 6), collapse = ","),
                          paste(round(b, 6), collapse = ","),
                          paste(round(cc, 6), collapse = ",")))
  }
}

if (length(bad)) {
  ci_fail("W1: %d case(s) where the three Wilson implementations disagree by
       more than the documented 100x scale:\n%s", length(bad),
       paste(sprintf("       %s", bad), collapse = "\n"))
} else {
  ci_ok("all %d cases agree, with wilson() in proportions and the other two in percent",
        length(cases))
}

# The units themselves, asserted rather than assumed. If wilson() ever starts
# returning percentages this check must fail loudly, because every caller that
# multiplies by 100 would then be wrong by 100x.
w_half <- as.vector(wilson(5, 10, 0.95))
m_half <- as.vector(mw(5, 10, z95))
ci_section("W2 the units of each implementation are what callers assume")
if (max(w_half) > 1 || min(w_half) < 0) {
  ci_fail("W2: wilson() returned %s, which is not a proportion in [0, 1].
       Callers such as build_f2_f3_uncertainty_denominators.R multiply its
       output by 100; if it already returns percent they are wrong by 100x.",
       paste(round(w_half, 6), collapse = ", "))
} else {
  ci_ok("wilson() returns a proportion in [0, 1] (%s at 5/10)",
        paste(round(w_half, 4), collapse = ", "))
}
if (max(m_half) <= 1) {
  ci_fail("W2: mw_wilson() returned %s, which looks like a proportion. The
       stats catalog and the manuscript treat it as a percentage.",
       paste(round(m_half, 6), collapse = ", "))
} else {
  ci_ok("mw_wilson()/scn_wilson() return percentages (%s at 5/10)",
        paste(round(m_half, 2), collapse = ", "))
}

ci_section("W3 the return shape of each implementation is what callers assume")
shapes <- list(
  "wilson()"      = wilson(5, 10, 0.95),
  "mw_wilson()"   = mw(5, 10, z95),
  "scn_wilson()"  = scn(5, 10, z95))
got <- vapply(shapes, function(v) if (is.matrix(v)) "matrix" else "vector", character(1))
want <- c("wilson()" = "vector", "mw_wilson()" = "vector", "scn_wilson()" = "matrix")
if (!identical(unname(got[names(want)]), unname(want))) {
  ci_fail("W3: return shapes changed: %s. scn_wilson() returns a 1-row matrix
       because it is cbind()-built for vectorised x and n; the other two
       return a length-2 vector. A caller that indexes [1]/[2] on one works on
       all three today, but one that passes the result to a function expecting
       a plain vector does not. Update this check deliberately if a shape is
       meant to change.",
       paste(sprintf("%s=%s", names(got), got), collapse = ", "))
} else {
  ci_ok("wilson() and mw_wilson() return vectors; scn_wilson() returns a 1x2 matrix, as their callers assume")
}

ci_finish()
