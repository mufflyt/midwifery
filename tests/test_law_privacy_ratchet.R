#!/usr/bin/env Rscript
# =============================================================================
# The law-privacy ratchet detects a law that stops being enforced
# =============================================================================
# ci_law_coverage.R refuses a law registered non-public unless it is declared in
# tests/law_privacy_baseline.tsv. This proves the refusal works, and that the
# declaration cannot outlive its cause.
#
# WHY THIS FILE AND NOT A HAND-RUN CONTROL. The check used to be inline in the
# gate, where exercising it meant perturbing the registry and running the whole
# coverage gate -- minutes per case, and ci_fail() buffers until ci_finish(), so
# a run cut short to save time shows the ok lines and silently loses every
# failure. That is how a first attempt at these controls "passed" three cases it
# had never actually observed.
#
# Run: Rscript tests/test_law_privacy_ratchet.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "law_privacy.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

LAWS <- c("L1", "L2", "L3")

cat("\n-- the four states --\n")

v <- law_privacy_violations(LAWS, rep("public", 3), character(0))
chk(length(v$non_public) == 0L && length(v$undeclared) == 0L && length(v$stale) == 0L,
    "T1 all public, nothing declared: clean")

v <- law_privacy_violations(LAWS, c("public", "public", "private-ok"), character(0))
chk(identical(v$undeclared, "L3") && length(v$stale) == 0L,
    "T2 a law downgraded without a declaration is caught")

v <- law_privacy_violations(LAWS, c("public", "public", "private-ok"), "L3")
chk(length(v$undeclared) == 0L && identical(v$non_public, "L3") && length(v$stale) == 0L,
    "T3 ...and accepted once declared, while staying named as non-public")

v <- law_privacy_violations(LAWS, rep("public", 3), "L3")
chk(identical(v$stale, "L3"),
    "T4 a declaration whose law is public again is stale and must be deleted")

cat("\n-- derived-ok is a downgrade too, not just private-ok --\n")
v <- law_privacy_violations(LAWS, c("public", "derived-ok", "public"), character(0))
chk(identical(v$undeclared, "L2"),
    "T5 derived-ok also needs a declaration (L5 was once mis-registered private-ok)")

cat("\n-- parsing and hygiene --\n")
v <- law_privacy_violations(LAWS, c("public", " private-ok ", "public"), " L2 ")
chk(length(v$undeclared) == 0L,
    "T6 surrounding whitespace in the registry or the baseline does not defeat the match")

chk(inherits(try(law_privacy_violations(c("L1"), c("public", "public"), character(0)),
                 silent = TRUE), "try-error"),
    "T7 mismatched law/privacy lengths stop rather than recycle")

tmp <- tempfile(fileext = ".tsv")
writeLines(c("# a comment", "law\tprivacy\treason"), tmp)
chk(length(law_privacy_declared(tmp)) == 0L,
    "T8 a header-only baseline declares nothing")
writeLines(c("# a comment", "law\tprivacy\treason",
             "L9\tderived-ok\tneeds a 31 MB surface"), tmp)
chk(identical(law_privacy_declared(tmp), "L9"),
    "T9 a declared row is parsed, comments ignored")
chk(length(law_privacy_declared(file.path(tempdir(), "nope.tsv"))) == 0L,
    "T10 an absent baseline declares nothing rather than erroring")

cat("\n-- the real registry and the real baseline --\n")
reg <- local({
  ln <- readLines(file.path(root, "tests", "science_law_registry.tsv"), warn = FALSE)
  ln <- ln[!grepl("^#", ln) & nzchar(trimws(ln))]
  hdr <- strsplit(ln[1], "\t")[[1]]
  d <- do.call(rbind, lapply(ln[-1], function(l) {
    p <- strsplit(l, "\t")[[1]]; length(p) <- length(hdr); p
  }))
  d <- as.data.frame(d, stringsAsFactors = FALSE); names(d) <- hdr; d
})
real <- law_privacy_violations(
  reg$law, reg$privacy,
  law_privacy_declared(file.path(root, "tests", "law_privacy_baseline.tsv")))
chk(length(real$undeclared) == 0L,
    sprintf("T11 no undeclared non-public law in the real registry [%s]",
            if (length(real$undeclared)) paste(real$undeclared, collapse = ", ") else "none"))
chk(length(real$stale) == 0L,
    sprintf("T12 no stale declaration in the real baseline [%s]",
            if (length(real$stale)) paste(real$stale, collapse = ", ") else "none"))

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
