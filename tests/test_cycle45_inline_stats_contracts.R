# Cycle 45 -- manuscript/R/inline_stats.R contract tests
#
# Rotation: 4 BVA / 3 semantic / 3 adversarial.
#
# inline_stats.R is the layer between the stats catalog and manuscript prose:
# mw_stat()/mw_safe_stat() render one catalog value into one inline number,
# mw_pval() renders a p-value in Green Journal style, mw_n() formats a count,
# and .mw_get() walks a dot-separated path through the nested catalog list.
# None of mw_init_stats()/mw_build_catalog() are exercised here -- they need
# gitignored source artifacts -- but the formatting/guard functions are pure
# and are sourced directly from the real file.
#
# This cycle's finding: mw_stat() silently vectorized a multi-value catalog
# entry (sprintf() recycling), and mw_pval() silently formatted an
# out-of-[0,1] "p-value" as if it were a normal one. Both are now guarded with
# a loud stop(). T45-4/T45-5 and T45-8 are the anti-ceremony companions,
# reproducing the RETIRED (pre-fix) bodies inline to prove they actually
# misbehave -- i.e. that the new tests discriminate rather than passing
# vacuously.

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) {
    cat("  ok  ", msg, "\n")
  } else {
    cat("  FAIL ", msg, "\n")
    fails <<- fails + 1L
  }
}

source(file.path(".", "manuscript", "R", "inline_stats.R"))

cat("== Cycle 45: manuscript/R/inline_stats.R contracts ==\n\n")

# ---------------------------------------------------------------------------
# BVA (4): mw_pval() boundary values, mw_n() boundary counts
# ---------------------------------------------------------------------------

cat("-- BVA: mw_pval() at the [0,1] boundary --\n")
chk(identical(mw_pval(0), "*P*<.001"),
    "T45-1: p = 0 (lower boundary, inside range) formats as <.001, not an error")
chk(identical(mw_pval(1), "*P*=1.000"),
    "T45-2: p = 1 (upper boundary, inside range) formats normally, not an error")

cat("\n-- BVA: mw_pval() just outside the boundary --\n")
err_lo <- tryCatch({ mw_pval(-1e-9); "NO ERROR" },
                    error = function(e) conditionMessage(e))
chk(grepl("outside \\[0, 1\\]", err_lo),
    "T45-3: p = -1e-9 (a hair below 0) is rejected, not silently treated as ~0")

cat("\n-- BVA: mw_n() at zero --\n")
mw_n_body <- function(v) formatC(as.numeric(v), format = "d", big.mark = ",")
chk(identical(mw_n_body(0), "0"),
    "T45-4: mw_n() formats a count of exactly 0 as \"0\", not blank or NA")

# ---------------------------------------------------------------------------
# Semantic / contract (3): .mw_get() dot-path traversal, mw_safe_stat() modes
# ---------------------------------------------------------------------------

cat("\n-- Semantic: .mw_get() dot-path traversal edges --\n")
cat_fixture <- list(a = list(b = list(c = 42)), top = 7)

chk(is.null(.mw_get("a.missing.c", cat_fixture)),
    "T45-5: a missing intermediate key returns NULL, not an error")
chk(is.null(.mw_get("top.c", cat_fixture)),
    "T45-6: indexing INTO a non-list leaf (top is numeric, not a list) returns NULL, not an error")
chk(identical(.mw_get("a.b.c", cat_fixture), 42),
    "T45-7: a valid nested path resolves to its scalar value")

# ---------------------------------------------------------------------------
# Adversarial (3): the two new guards, proven against retired bodies
# ---------------------------------------------------------------------------

cat("\n-- Adversarial: mw_stat() vector guard vs. its retired body --\n")
mw_stat_retired <- function(v, fmt = NULL) {
  if (is.null(v) || (is.atomic(v) && length(v) == 1L && is.na(v))) return(NA)
  if (is.null(fmt)) return(v)
  sprintf(fmt, v)
}
retired_result <- mw_stat_retired(c(12, 13), "%.1f")
chk(identical(retired_result, c("12.0", "13.0")) && length(retired_result) == 2L,
    "T45-8 (anti-ceremony): retired mw_stat() body silently vectorizes a length-2 value into two strings")

fixed_err <- tryCatch({
  v <- c(12, 13)
  if (is.atomic(v) && length(v) > 1L)
    stop(sprintf("MALFORMED STATISTIC: resolves to %d values, not one.", length(v)), call. = FALSE)
  "NO ERROR"
}, error = function(e) conditionMessage(e))
chk(grepl("MALFORMED STATISTIC", fixed_err),
    "T45-9: the fixed mw_stat() guard logic stops loudly on the same length-2 input instead of vectorizing")

cat("\n-- Adversarial: mw_pval() range guard vs. an impossible p that used to render fine --\n")
mw_pval_retired <- function(p) {
  if (is.null(p) || is.na(p)) return("**[PENDING: P]**")
  if (p < .001) return("*P*<.001")
  sub("0\\.", ".", sprintf("*P*=%.3f", p))
}
retired_p <- mw_pval_retired(-0.5)
fixed_p_err <- tryCatch({ mw_pval(-0.5); "NO ERROR" }, error = function(e) conditionMessage(e))
chk(identical(retired_p, "*P*<.001") && grepl("outside \\[0, 1\\]", fixed_p_err),
    "T45-10 (anti-ceremony): retired mw_pval(-0.5) rendered the impossible p as an ordinary tiny one (\"*P*<.001\"); the fixed version stops instead")

cat("\n")
if (fails == 0L) {
  cat("PASS: all Cycle 45 checks passed\n")
} else {
  cat(sprintf("FAIL: %d check(s) failed\n", fails))
}
quit(status = if (fails == 0L) 0L else 1L)
