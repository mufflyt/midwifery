#!/usr/bin/env Rscript
# =============================================================================
# Sixteen saboteurs: which cohort every script reads
# =============================================================================
# cohort_artifact_path() decides which file thirty-four references across
# eighteen scripts are actually reading, and freeze_cohort.R:133 calls it with
# no window at all -- so whatever it returns becomes the frozen cohort and the
# denominator of every published number. A wrong answer here does not corrupt
# one figure; it corrupts all of them at once, consistently, which is the
# hardest kind of wrong to notice.
#
# The library already refuses the two traps it was written for: a suffixed
# side artifact (`_rerun20260901`) is never silently chosen, and two files
# sharing the latest end year are an error rather than a coin flip. What it
# did not check was the start year. Ordering by end year alone made
# `years-2020-2026` newer than `years-2007-2025`. S1 is that defect.
#
# The standard every saboteur is held to:
#
#   A choice BETWEEN COHORTS must be refused, never made. Latest is only
#   meaningful along the axis the panel actually moves: the end year.
#   Resolution must be by the year window in the NAME, never by mtime -- cp,
#   rsync, a git checkout and a gate run all rewrite mtime without touching a
#   byte of data.
#   A resolved path is handed straight to read_csv(), so it must be a readable
#   file with content, not merely something file.exists() accepts.
#
# S2, S7 and S11 are inverted on purpose: they sabotage this code into
# refusing a legitimate panel extension, confusing the two panel definitions,
# or failing where it is documented to return NA. Without them a later "fix"
# could satisfy the rest by refusing everything.
# =============================================================================

.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
source(file.path(root, "R", "lib", "cohort_artifacts.R"))


# --- the crime scene ---------------------------------------------------------
sandbox <- file.path(tempdir(), "cohort_saboteurs")

artifact_name <- function(window, family = "linkage",
                          definition = "midwifery-plus-nursing")
  sprintf(COHORT_ARTIFACT_PATTERNS[[family]], definition, window)

# Two header lines so a file is non-empty and plausibly a cohort. `bytes = 0`
# writes the truncated-write case; `as_dir = TRUE` the botched-extract case.
cohort_place <- function(name, bytes = NULL, as_dir = FALSE) {
  target <- file.path(sandbox, name)
  if (as_dir) { dir.create(target, recursive = TRUE); return(invisible(target)) }
  if (identical(bytes, 0L)) { file.create(target); return(invisible(target)) }
  writeLines(c("certification_number,npi", "CNM00001,1000000001"), target)
  invisible(target)
}

cohort_restore_scene <- function() {
  unlink(sandbox, recursive = TRUE)
  dir.create(sandbox, recursive = TRUE, showWarnings = FALSE)
}

cohort_resolve <- function(..., family = "linkage") {
  tryCatch(cohort_artifact_path(family, art_dir = sandbox, ...),
           error = function(e) structure(conditionMessage(e), class = "refusal"))
}
cohort_chose <- function(x, name) !refused(x) && identical(basename(x), name)
cohort_says <- function(x, ...) refused(x) &&
  all(vapply(c(...), function(needle) grepl(needle, as.character(x), fixed = TRUE),
             logical(1)))

cat("\n=== baseline ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
baseline <- cohort_resolve()
chk(cohort_chose(baseline, artifact_name("2007-2025")),
    "B1 a single canonical artifact resolves to itself")

# --- S1: the defect -- a start year that moved forward -----------------------
# A truncated rebuild, a test run with a restricted window, or a changed panel
# config produces a window whose START year moved. Ordered by end year alone,
# that file was "the latest cohort" and freeze_cohort.R would have frozen it.
cat("\n=== S1 a 2020-2026 window appears beside 2007-2025 ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
cohort_place(artifact_name("2020-2026"))
s1 <- cohort_resolve()
chk(refused(s1), "S1 refuses rather than picking between two cohorts")
chk(cohort_says(s1, "DIFFERENT START YEARS", "2007, 2020"),
    "S1 the refusal names both start years")
chk(!cohort_chose(s1, artifact_name("2020-2026")),
    "S1 the truncated cohort is never returned as the newest one")

# --- S2 (INVERTED): a genuine panel extension still resolves ----------------
# This is the case the whole file exists to serve: the panel gained a year, so
# the end year moved and the start year did not.
cat("\n=== S2 the panel gains a 2026 snapshot ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
cohort_place(artifact_name("2007-2026"))
s2 <- cohort_resolve()
chk(cohort_chose(s2, artifact_name("2007-2026")),
    "S2 the extended window wins, and nothing is refused")

# --- S3: two files sharing the latest end year ------------------------------
# Two canonical names that share an end year must differ in their start year,
# because the window is the name. So this is the start-year refusal again,
# reached from the other direction, and there is no separate ambiguity branch
# left for it to hit.
cat("\n=== S3 2007-2026 and 2010-2026 both on disk ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2026"))
cohort_place(artifact_name("2010-2026"))
s3 <- cohort_resolve()
chk(cohort_says(s3, "DIFFERENT START YEARS", "2007, 2010"),
    "S3 refuses two cohorts sharing the latest end year")

# --- S4: the suffixed side artifact, which really is on disk ----------------
cat("\n=== S4 a _rerun20260901 variant sits beside the canonical file ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
cohort_place(sub("\\.csv$", "_rerun20260901.csv", artifact_name("2007-2025")))
s4 <- cohort_resolve()
chk(cohort_chose(s4, artifact_name("2007-2025")),
    "S4 the canonical file wins and the rerun does not make it ambiguous")
chk(nrow(cohort_artifact_available("linkage", art_dir = sandbox)) == 1L,
    "S4 the rerun is not even listed as an available window")

# --- S5: only the suffixed variant exists -----------------------------------
cat("\n=== S5 the canonical file is gone, only the rerun remains ===\n")
cohort_restore_scene()
cohort_place(sub("\\.csv$", "_rerun20260901.csv", artifact_name("2007-2025")))
s5 <- cohort_resolve()
chk(refused(s5),
    "S5 a side artifact is never promoted to canonical just by being alone")

# --- S6: a backup whose name ends in .csv twice over ------------------------
cat("\n=== S6 a backup named ..._years-2007-2025.csv_old.csv ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025.csv_old"))
s6 <- cohort_resolve()
chk(refused(s6), "S6 refuses a backup that merely begins with a canonical name")

# --- S7 (INVERTED): the two panel definitions must not cross ----------------
# artifacts/ really holds both panel-midwifery and panel-midwifery-plus-
# nursing linkages. They are different cohorts, and the longer name contains
# the shorter one as a prefix.
cat("\n=== S7 both panel definitions on disk at once ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025", definition = "midwifery"))
cohort_place(artifact_name("2007-2025", definition = "midwifery-plus-nursing"))
s7_short <- cohort_resolve(definition = "midwifery")
s7_long <- cohort_resolve(definition = "midwifery-plus-nursing")
chk(cohort_chose(s7_short, artifact_name("2007-2025", definition = "midwifery")),
    "S7 'midwifery' resolves to the midwifery panel")
chk(cohort_chose(s7_long, artifact_name("2007-2025", definition = "midwifery-plus-nursing")),
    "S7 'midwifery-plus-nursing' resolves to the plus-nursing panel")
chk(nrow(cohort_artifact_available("linkage", "midwifery", sandbox)) == 1L,
    "S7 the shorter definition does not also match the longer one as a prefix")

# --- S8: a truncated write ---------------------------------------------------
cat("\n=== S8 the resolved artifact is zero bytes ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"), bytes = 0L)
s8 <- cohort_resolve()
chk(cohort_says(s8, "ZERO BYTES"),
    "S8 refuses a zero-byte cohort rather than reading it as an empty cohort")

# --- S9: a botched extract ---------------------------------------------------
cat("\n=== S9 a DIRECTORY carries the canonical artifact name ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"), as_dir = TRUE)
s9 <- cohort_resolve()
chk(cohort_says(s9, "DIRECTORY"),
    "S9 refuses a directory, which file.exists() would have accepted")

# --- S10: an unknown family --------------------------------------------------
cat("\n=== S10 a caller asks for a family that does not exist ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
s10 <- cohort_resolve(family = "crosswalk_c5gaurd")
chk(cohort_says(s10, "unknown cohort artifact family", "crosswalk_c5guard"),
    "S10 refuses a misspelled family and lists the real ones")

# --- S11 (INVERTED): must_exist = FALSE is documented to return NA ----------
cat("\n=== S11 nothing on disk, must_exist = FALSE ===\n")
cohort_restore_scene()
s11 <- cohort_resolve(must_exist = FALSE)
chk(!refused(s11) && is.na(s11),
    "S11 returns NA rather than erroring when the caller allows absence")
s11_strict <- cohort_resolve(must_exist = TRUE)
chk(refused(s11_strict), "S11 and still refuses when the caller does not")

# --- S12: an explicit window that is not there ------------------------------
cat("\n=== S12 window = '2007-2030' asked for explicitly ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
s12 <- cohort_resolve(window = "2007-2030")
chk(cohort_says(s12, "cohort artifact not found", "2007-2025"),
    "S12 refuses, and lists the windows that ARE available")

# --- S13: a window that is not two four-digit years --------------------------
# artifacts/ really holds amcb_npi_linkage_panel-midwifery_years-through-2017
# .csv, which is not a window at all.
cat("\n=== S13 malformed windows: 'through-2017', '207-2025', '2007-20250' ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"))
for (bad_window in c("through-2017", "207-2025", "2007-20250"))
  cohort_place(artifact_name(bad_window))
s13 <- cohort_resolve()
chk(cohort_chose(s13, artifact_name("2007-2025")),
    "S13 only the real window is parsed as a cohort")
chk(nrow(cohort_artifact_available("linkage", art_dir = sandbox)) == 1L,
    "S13 none of the three malformed names is listed as an available window")

# --- S14: the mtime trap, which is why this file exists ---------------------
# From the header: six scripts already cohort_resolve this family with
# `cw[order(file.mtime(cw), decreasing = TRUE)][1]`, and that is newest FILE,
# not newest COHORT. cp, rsync, a git checkout and a gate run all rewrite
# mtime without touching a byte of data, and the same mistake dated a scraped
# artifact to "today" in a fresh worktree earlier in this work. Here the OLDER
# cohort is given the NEWER mtime, so anything resolving by timestamp picks
# the 2025 cohort and freezes last year's linkage.
cat("\n=== S14 the 2007-2025 file is touched after the 2007-2026 file ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2026"))
cohort_place(artifact_name("2007-2025"))
Sys.setFileTime(file.path(sandbox, artifact_name("2007-2026")),
                Sys.time() - as.difftime(7, units = "days"))
Sys.setFileTime(file.path(sandbox, artifact_name("2007-2025")), Sys.time())
mtimes <- file.mtime(file.path(sandbox, c(artifact_name("2007-2025"),
                                          artifact_name("2007-2026"))))
chk(mtimes[1] > mtimes[2],
    "S14 the trap is armed: the older cohort has the newer timestamp")
s14 <- cohort_resolve()
chk(cohort_chose(s14, artifact_name("2007-2026")),
    "S14 resolution follows the year window in the name, not the timestamp")

# --- S15: an explicit window pointing at a truncated write ------------------
# The window= branch returns its path directly, so it needs the same check the
# latest-window branch gets. A caller naming a window is being specific, not
# waiving the requirement that the file be readable.
cat("\n=== S15 window = '2007-2025' and that file is zero bytes ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"), bytes = 0L)
s15 <- cohort_resolve(window = "2007-2025")
chk(cohort_says(s15, "ZERO BYTES"),
    "S15 an explicitly named window is checked too, not trusted")
s15_lax <- cohort_resolve(window = "2007-2025", must_exist = FALSE)
chk(!refused(s15_lax),
    "S15 and must_exist = FALSE still returns the path without checking it")

# --- S16: an explicit window pointing at a directory ------------------------
cat("\n=== S16 window = '2007-2025' and a DIRECTORY carries that name ===\n")
cohort_restore_scene()
cohort_place(artifact_name("2007-2025"), as_dir = TRUE)
s16 <- cohort_resolve(window = "2007-2025")
chk(cohort_says(s16, "DIRECTORY"),
    "S16 file.exists() accepts the directory; this refuses it")

cat(sprintf("\n%s  %d failure(s)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS",
            fails))
quit(status = if (fails == 0L) 0L else 1L)
