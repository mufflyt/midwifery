#!/usr/bin/env Rscript
# =============================================================================
# Law coverage: no scientific assertion may go unexercised
# =============================================================================
# Every other gate answers "did the science hold?". This one answers a question
# none of them can: "was the science actually checked?"
#
# A law that is written but never evaluated reports nothing and fails nothing.
# It is indistinguishable, in a green build, from a law that passed. This
# repository has already produced that shape twice -- a gate that crashed and
# read as flakiness, and a masking test that exited 0 when its inputs were
# absent. Coverage is the gate that refuses it.
#
# THE MAPPING IS DATA, NOT PROSE. tests/science_law_registry.tsv declares which
# laws exist, which file evaluates each, which file plants its defect, and
# whether a skip is ever legitimate. Nothing here is inferred from a filename or
# a comment, because that inference is exactly what goes stale.
#
# THREE STATES, so that SKIP cannot become a generic escape hatch:
#
#   PASS                   the law ran and was evaluated on a non-empty subject
#                          set. n=0 is a vacuous pass and is rejected.
#   EXPECTED_PRIVATE_SKIP  the law is registered `private-ok` and its
#                          person-level input is absent. Legal, counted, and
#                          reported -- never silent.
#   FAIL                   anything else. A `public` law that skipped, a law
#                          that emitted nothing, a law with no planted defect,
#                          or a defect that survived.
#
# UNEXPECTED SKIPS ARE THEMSELVES A FAILURE. That number must be zero.
#
# Base R. Runs the gates as subprocesses and reads what they print, which is the
# same evidence a person reads.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

REG <- file.path(root, "tests", "science_law_registry.tsv")
if (!file.exists(REG)) {
  ci_fail("the law registry %s is missing. Without it nothing declares what this\n       repository claims to enforce, and coverage cannot be measured.", REG)
  ci_finish()
}

lines <- readLines(REG, warn = FALSE)
lines <- lines[!grepl("^#", lines) & nzchar(trimws(lines))]
hdr <- strsplit(lines[1], "\t")[[1]]
reg <- do.call(rbind, lapply(lines[-1], function(l) {
  p <- strsplit(l, "\t")[[1]]; length(p) <- length(hdr); p
}))
reg <- as.data.frame(reg, stringsAsFactors = FALSE)
names(reg) <- hdr

ci_section(sprintf("scientific laws declared: %d", nrow(reg)))

# --- run each distinct gate once, keep its output ----------------------------
run_file <- function(rel) {
  f <- file.path(root, rel)
  if (!file.exists(f)) return(list(text = "", missing = TRUE))
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && Rscript %s 2>&1", shQuote(root), shQuote(rel)))),
    stdout = TRUE, stderr = TRUE))
  list(text = paste(out, collapse = "\n"), missing = FALSE)
}
sources <- unique(c(reg$gate, reg$mutation))
outs <- stats::setNames(lapply(sources, run_file), sources)

for (s in sources) if (isTRUE(outs[[s]]$missing))
  ci_fail("registered file %s does not exist. A law whose gate is absent is a law\n       nobody is checking.", s)

# --- score every law ---------------------------------------------------------
state <- character(nrow(reg)); subj <- integer(nrow(reg)); pos <- integer(nrow(reg))
mut_total <- integer(nrow(reg)); mut_killed <- integer(nrow(reg))
unexpected_skips <- 0L

for (i in seq_len(nrow(reg))) {
  law <- reg$law[i]
  gate <- outs[[reg$gate[i]]]$text
  mtxt <- outs[[reg$mutation[i]]]$text

  exercised <- grepl(sprintf("\\[LAW\\] %s EXERCISED", law), gate)
  skipped   <- grepl(sprintf("\\[LAW\\] %s SKIPPED", law), gate)

  n <- 0L
  m <- regmatches(gate, regexpr(sprintf("\\[CONTROL\\] %s negative n=[ ]*[0-9]+", law), gate))
  if (length(m)) n <- as.integer(sub(".*n=[ ]*", "", m))
  subj[i] <- n

  # POSITIVE CONTROL, required and not inferred. A law with only a negative
  # control has proved it did not fire; it has not proved it COULD. Until this
  # was added, coverage parsed `negative` alone and a law whose detector was
  # inert would have counted as fully covered.
  pm <- regmatches(gate, regexpr(sprintf("\\[CONTROL\\] %s positive n=[ ]*[0-9]+", law), gate))
  pos[i] <- if (length(pm)) as.integer(sub(".*n=[ ]*", "", pm)) else 0L

  muts <- regmatches(mtxt, gregexpr(sprintf("\\[MUTATION\\] %s \\S+ (DETECTED|SURVIVED)", law), mtxt))[[1]]
  mut_total[i]  <- length(muts)
  mut_killed[i] <- sum(grepl("DETECTED$", muts))

  # PASS means "ran, on a non-empty subject set". The positive-control
  # requirement is checked separately below so that a law missing one is
  # reported as missing a positive control -- not as never having run, which is
  # a different defect with a different fix.
  state[i] <- if (exercised && n > 0L) "PASS"
              else if (skipped && identical(reg$privacy[i], "private-ok")) "EXPECTED_PRIVATE_SKIP"
              else "FAIL"
  if (state[i] == "FAIL" && (skipped || !exercised)) unexpected_skips <- unexpected_skips + 1L
}

for (i in seq_len(nrow(reg))) {
  cat(sprintf("  %-4s %-40s %-22s neg=%-8s pos=%-3d defects=%d/%d\n",
              reg$law[i], substr(reg$title[i], 1, 40), state[i],
              format(subj[i], big.mark = ","), pos[i], mut_killed[i], mut_total[i]))
}

# --- the coverage contract ---------------------------------------------------
ci_section("coverage")

n_law <- nrow(reg)
n_pass <- sum(state == "PASS")
n_priv <- sum(state == "EXPECTED_PRIVATE_SKIP")
n_neg  <- sum(subj > 0L)
n_mut_ok <- sum(mut_total > 0L & mut_killed == mut_total)
tot_mut <- sum(mut_total); tot_killed <- sum(mut_killed)

cat(sprintf("  Scientific laws declared:    %d\n", n_law))
cat(sprintf("  Laws exercised:              %d/%d\n", n_pass + n_priv, n_law))
cat(sprintf("  Negative controls (n>0):     %d/%d\n", n_neg, n_law))
cat(sprintf("  Positive controls (n>0):     %d/%d\n", sum(pos > 0L), sum(state == "PASS")))
cat(sprintf("  Laws with a planted defect:  %d/%d\n", sum(mut_total > 0L), n_law))
cat(sprintf("  Planted defects detected:    %d/%d\n", tot_killed, tot_mut))
cat(sprintf("  Expected private skips:      %d\n", n_priv))
cat(sprintf("  Unexpected skips:            %d\n", unexpected_skips))

bad <- which(state == "FAIL")
if (length(bad)) {
  ci_fail("%d law(s) were not exercised:\n%s\n       A law that does not run is indistinguishable from one that passed.",
          length(bad),
          paste(sprintf("       %s (%s) -- %s", reg$law[bad], reg$privacy[bad],
                        ifelse(subj[bad] == 0L, "no subjects", "no evidence emitted")),
                collapse = "\n"))
}
vac <- which(state == "PASS" & subj == 0L)
if (length(vac)) {
  ci_fail("%d law(s) passed vacuously on zero subjects:\n%s",
          length(vac), paste(sprintf("       %s", reg$law[vac]), collapse = "\n"))
}
# Only a law that RAN can be held to a positive control. A registered
# private-ok law whose person-level input is absent emitted nothing at all --
# requiring proof from a run that did not happen would make the private-ok path
# impossible to satisfy, which the coverage-detect harness caught immediately.
nopos <- which(state == "PASS" & pos == 0L)
if (length(nopos)) {
  ci_fail("%d law(s) have no POSITIVE control:\n%s\n       A negative control proves the law did not fire. Only a positive control\n       proves it could -- without one, an inert detector reads as a clean pass.",
          length(nopos), paste(sprintf("       %s (%s)", reg$law[nopos], reg$title[nopos]),
                               collapse = "\n"))
}
nomut <- which(mut_total == 0L)
if (length(nomut)) {
  ci_fail("%d law(s) have no planted defect:\n%s\n       Without one there is no evidence the law can fail, and a law that cannot\n       fail is a sentence, not a law.",
          length(nomut), paste(sprintf("       %s (%s)", reg$law[nomut], reg$title[nomut]),
                               collapse = "\n"))
}
surv <- which(mut_total > 0L & mut_killed < mut_total)
if (length(surv)) {
  ci_fail("%d law(s) let a planted defect survive:\n%s\n       The law is green and no longer detects what it exists to detect.",
          length(surv), paste(sprintf("       %s: %d of %d killed", reg$law[surv],
                                      mut_killed[surv], mut_total[surv]), collapse = "\n"))
}
if (unexpected_skips > 0L) {
  ci_fail("%d unexpected skip(s). A public law may not skip: its inputs are tracked,\n       so absence means the law is not being evaluated at all.", unexpected_skips)
}
if (!length(bad) && !length(nomut) && !length(surv) && !length(nopos) &&
    unexpected_skips == 0L) {
  ci_ok("%d/%d laws exercised, %d/%d positive controls, %d/%d planted defects detected, 0 unexpected skips",
        n_pass + n_priv, n_law, sum(pos > 0L), n_law, tot_killed, tot_mut)
}

ci_finish()
