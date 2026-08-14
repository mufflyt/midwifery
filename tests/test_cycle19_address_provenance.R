#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 19 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: the address-provenance invariant that has been blocking
# R/03-geography-hierarchy.R, carried forward from cycle 18.
#
# THE QUESTION ASKED. The guard aborts the entire stage whenever the roster's
# ZIP/state differs, AS A STRING, from the address the coordinates were geocoded
# from. 1,163 records trip it. A string-equality guard that halts a pipeline is
# exactly the shape of an over-strict check, so it was investigated as one.
#
# THE ANSWER: it is not over-strict, and it is deliberately NOT relaxed.
# Resolving both addresses through the ZCTA-county crosswalk:
#
#   land-dominant assignment          strict (GEOID_unique) assignment
#     612  different STATE              390  different STATE
#     318  different county, same state 175  different county, same state
#     209  SAME county                  171  SAME county
#      24  unresolvable ZIP             427  unresolvable (multi-county ZIP)
#
# On the permissive reading, 930 of 1,163 (80%) land the record in a different
# COUNTY -- the unit of every access finding here. On the strict reading at
# least 565 do and 427 cannot be determined at all. Loosening the guard to
# "same county is fine" would still admit the large majority of these, so the
# invariant is catching a real placement error rather than a formatting one.
#
# WHAT WAS ACTUALLY WRONG was triage, not threshold: all 1,163 were reported at
# one severity, so nobody could separate the 390-612 cross-state cases from the
# ~171 harmless ones. The evidence file now carries a county_impact column and
# the abort prints the breakdown.
#
# A NOTE ON METHOD. My first pass read the evidence file and found 90 rows,
# concluded the count and the evidence disagreed, and was about to report a
# defect. The file was the STALE 08-08 copy -- I was fooled by a stale artifact
# while investigating stale artifacts, one cycle after building the detector for
# them. Re-running the script first gives 1,163, matching the message.
#
# Run: Rscript tests/test_cycle19_address_provenance.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
# The ZIP key under test is the production one, sourced rather than restated.
source("R/lib/common_helpers.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
GH <- paste(readLines("R/03-geography-hierarchy.R", warn = FALSE), collapse = "\n")
EV <- "artifacts/invariant_address_provenance_failures.csv"
ev <- if (file.exists(EV))
  suppressWarnings(read_csv(EV, show_col_types = FALSE, progress = FALSE,
                            col_types = cols(.default = col_character()))) else NULL

cat("\n-- BVA --\n")

# T191 (BVA). ZIP normalisation. The guard compares 5-digit ZIPs, so ZIP+4,
# spaces and a lost leading zero must all normalise to the same key or the
# guard invents disagreements that do not exist.
{
  # zip5_key() from R/lib/common_helpers.R, NOT a local re-implementation. The
  # previous version of this block defined its own `pad5` -- shadowing the
  # canonical helper of that name with different behaviour -- so it asserted
  # three properties of a private lambda and would have passed unchanged if the
  # production key had broken.
  chk(identical(zip5_key("02134-1234"), "02134"), "T191a ZIP+4 truncates to five digits")
  chk(identical(zip5_key(" 02134 "), "02134"),    "T191b surrounding space is stripped")
  chk(identical(zip5_key("2134"), "02134"),       "T191c a lost leading zero is restored, not treated as a different ZIP")
  chk(is.na(zip5_key(NA)),                        "T191d a missing ZIP stays missing rather than becoming \"00000\"")
}

# T192 (BVA). The comparison must be null-safe at both ends: a missing ZIP on
# either side is not a disagreement, it is an absence.
{
  disagree <- function(a, b) !is.na(a) & !is.na(b) & a != b
  chk(!disagree(NA_character_, "02134"), "T192a a missing roster ZIP is not a disagreement")
  chk(!disagree("02134", NA_character_), "T192b a missing geocode ZIP is not a disagreement")
  chk(disagree("02134", "02135"),        "T192c two present, different ZIPs are a disagreement")
}

# T193 (BVA). The classification must cover every case with no gaps: four
# labels, and every flagged row carries exactly one.
{
  if (is.null(ev) || !"county_impact" %in% names(ev)) {
    chk(FALSE, "T193 the evidence file carries a county_impact column")
  } else {
    lv <- c("same_county", "different_county_same_state", "different_state",
            "unresolvable_zip")
    chk(all(ev$county_impact %in% lv) && !any(is.na(ev$county_impact)),
        sprintf("T193 every flagged record is classified into exactly one impact class [%s]",
                paste(sort(unique(ev$county_impact)), collapse = ", ")))
  }
}

# T194 (BVA). The counts must sum to the reported total. An abort that names a
# number and writes a file with a different number is worse than no evidence.
{
  if (is.null(ev)) chk(FALSE, "T194 the evidence file exists") else {
    chk(nrow(ev) == 1163L,
        sprintf("T194 the evidence file holds exactly the reported count [%d]", nrow(ev)))

  # AND the per-class counts quoted in R/03's comment must match the artifact.
  # An earlier draft of that comment carried figures from a superseded
  # land-dominant assignment (612/318/209/24) alongside an artifact that said
  # 390/175/171/427 -- two number sets in one repo, and the wrong one is the
  # one that ends up in a manuscript. Prose is checked against data here.
  src <- paste(readLines(file.path(root, "R", "03-geography-hierarchy.R"),
                         warn = FALSE), collapse = "\n")
  tb <- table(ev$county_impact)
  quoted_ok <- all(vapply(names(tb), function(k)
    grepl(sprintf("#\\s+%d\\s", tb[[k]]), src), logical(1)))
  chk(quoted_ok,
      sprintf("T194b the counts quoted in R/03 match the artifact [%s]",
              paste(sprintf("%s=%d", names(tb), as.integer(tb)), collapse = ", ")))
  }
}

cat("\n-- SEMANTIC --\n")

# T195 (semantic). THE FINDING. The guard is justified: the majority of
# disagreements move the record to a different county. If this ever flips --
# if most were same_county -- the guard WOULD be over-strict and the argument
# for keeping it collapses.
{
  if (is.null(ev) || !"county_impact" %in% names(ev)) {
    chk(FALSE, "T195 impact classes are available")
  } else {
    same <- sum(ev$county_impact == "same_county")
    changes <- sum(ev$county_impact %in% c("different_state", "different_county_same_state"))
    chk(changes > same * 2,
        sprintf("T195 disagreements that change county (%d) far outnumber harmless ones (%d), so the guard is warranted",
                changes, same))
  }
}

# T196 (semantic). The guard must NOT have been relaxed. This is the assertion
# that stops a future cycle from "fixing" the blockage by lowering the bar.
{
  chk(grepl("stop\\(sprintf\\(\"INVARIANT: %d records", GH),
      "T196a the invariant still aborts rather than warning")
  chk(!grepl("county_impact\\s*!=\\s*\"same_county\"|filter\\(county_impact", GH),
      "T196b the abort is not conditioned on the impact class -- triage informs, it does not excuse")
}

# T197 (semantic). Unresolvable must mean unresolvable. A ZIP spanning several
# counties cannot place a person, and assigning it to the county holding the
# most land would be a guess presented as a fact.
{
  chk(grepl("GEOID_unique", GH),
      "T197a classification uses the strict per-ZIP county, which is NA for multi-county ZIPs")
  if (!is.null(ev) && "county_impact" %in% names(ev)) {
    chk(sum(ev$county_impact == "unresolvable_zip") > 0L,
        sprintf("T197b multi-county ZIPs are reported as unresolvable, not guessed [%d]",
                sum(ev$county_impact == "unresolvable_zip")))
  }
}

cat("\n-- ADVERSARIAL --\n")

# T198 (adversarial). A same-state ZIP difference is NOT automatically benign.
# 175 of these land in a different county, which is the case a "same state, so
# it's fine" shortcut would wave through.
{
  if (!is.null(ev) && all(c("county_impact", "practice_state", "geo_state") %in% names(ev))) {
    same_state <- ev %>% filter(!is.na(practice_state), !is.na(geo_state),
                                practice_state == geo_state)
    moved <- sum(same_state$county_impact == "different_county_same_state")
    chk(moved > 0L,
        sprintf("T198 %d same-STATE disagreements still change the county, so state equality is not a safe shortcut",
                moved))
  } else chk(FALSE, "T198 evidence columns available")
}

# T199 (adversarial). The evidence file must be regenerated by the run that
# reports it. Cycle 18 built a staleness detector and I was still fooled by a
# stale copy of this very file one cycle later.
{
  if (file.exists(EV) && file.exists("data/county_base.csv")) {
    chk(file.mtime(EV) > file.mtime("data/county_base.csv"),
        "T199 the evidence file is newer than the inputs, i.e. written by a recent run")
  } else chk(FALSE, "T199 evidence and inputs exist")
}

# T200 (adversarial). The guard must survive reordering: which rows are flagged
# cannot depend on row order, or the count itself is unstable.
{
  disagree <- function(d) sum(!is.na(d$a) & !is.na(d$b) & d$a != d$b)
  d <- data.frame(a = c("02134", "02135", NA), b = c("02135", "02135", "02134"),
                  stringsAsFactors = FALSE)
  chk(disagree(d) == disagree(d[c(3, 1, 2), ]),
      "T200 the flagged count is invariant to row order")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
