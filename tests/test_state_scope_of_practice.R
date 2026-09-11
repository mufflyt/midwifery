#!/usr/bin/env Rscript
# =============================================================================
# State scope-of-practice classification and its join onto geography artifacts
# =============================================================================
# HERMETIC. Reads only committed artifacts/*.csv, no network, no person-level
# data -- runs in CI.
#
# WHAT THIS GUARDS. build_state_scope_of_practice.R hand-transcribes a
# 51-jurisdiction classification from Ranchoff & Declercq (2020) Tables 1 and
# 3. A transcription slip here (a state in the wrong bucket, a duplicate, a
# missing jurisdiction) would silently bias every downstream comparison by
# scope-of-practice status without producing any error -- the join would
# still run, just against the wrong labels. Spot-checking specific states
# against the paper's own stated definitions catches that class of error;
# checking only the totals would not (a transposition can preserve the count).
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages(library(readr))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- artifacts/state_scope_of_practice.csv: structure --\n")
SOP <- read_csv("artifacts/state_scope_of_practice.csv", show_col_types = FALSE)
chk(nrow(SOP) == 51L, sprintf("T1 51 jurisdictions (50 states + DC), got %d", nrow(SOP)))
chk(!anyDuplicated(SOP$state), "T2 no duplicate state")
chk(setequal(SOP$practice_authority_continuous,
             c("Autonomous", "Collaborative_supervisory", "Changed_during_window_excluded")),
    "T3 practice_authority_continuous uses exactly the three documented categories")
chk(setequal(SOP$practice_authority_2016, c("Autonomous", "Collaborative_supervisory")),
    "T4 practice_authority_2016 has no 'excluded' rows -- it is a complete classification")
chk(sum(SOP$practice_authority_continuous == "Autonomous") == 21L &&
      sum(SOP$practice_authority_continuous == "Collaborative_supervisory") == 24L &&
      sum(SOP$practice_authority_continuous == "Changed_during_window_excluded") == 6L,
    "T5 continuous counts match the paper's abstract exactly: 20 states + DC, 24, 6")
chk(sum(SOP$practice_authority_2016 == "Autonomous") == 26L &&
      sum(SOP$practice_authority_2016 == "Collaborative_supervisory") == 25L,
    "T6 2016-snapshot counts: 26 autonomous, 25 collaborative")

cat("\n-- spot-check specific jurisdictions against the source paper --\n")
row <- function(s) SOP[SOP$state == s, ]
chk(identical(row("DC")$practice_authority_continuous, "Autonomous"),
    "T7 DC is continuous-autonomous (in the 20 states + DC)")
chk(identical(row("CA")$practice_authority_continuous, "Collaborative_supervisory"),
    "T8 CA is continuous-collaborative/supervisory")
chk(identical(row("MI")$practice_authority_continuous, "Changed_during_window_excluded") &&
      identical(row("MI")$practice_authority_2016, "Collaborative_supervisory"),
    "T9 MI changed mid-window (autonomous 2013 -> collaborative 2014) and reverts to collaborative by 2016")
chk(identical(row("NJ")$practice_authority_continuous, "Changed_during_window_excluded") &&
      identical(row("NJ")$practice_authority_2016, "Autonomous"),
    "T10 NJ changed twice (autonomous -> collaborative 2015 -> autonomous 2016) and is autonomous by 2016")
chk(identical(row("WY")$practice_authority_continuous, "Autonomous"),
    "T11 WY is continuous-autonomous")
chk(identical(row("TX")$practice_authority_continuous, "Collaborative_supervisory"),
    "T12 TX is continuous-collaborative/supervisory")

cat("\n-- join: no US jurisdiction silently lost, no non-US row silently kept --\n")
iso_path <- "artifacts/isochrone_representation_by_scope_of_practice.csv"
if (!file.exists(iso_path)) {
  cat(sprintf("  --   SKIP join checks: %s absent\n", iso_path))
} else {
  iso_src <- read_csv("artifacts/isochrone_representation_by_state.csv", show_col_types = FALSE)
  iso_j   <- read_csv(iso_path, show_col_types = FALSE)
  us_in_src <- unique(iso_src$nppes_state[iso_src$nppes_state %in% SOP$state])
  chk(setequal(us_in_src, unique(iso_j$nppes_state)),
      "T13 every US jurisdiction present in the source geography artifact survives the join")
  chk(all(iso_j$nppes_state %in% SOP$state),
      "T14 no non-US-jurisdiction row (military APO/FPO, foreign geocoding artifact) leaked into the joined output")
  chk(all(c("practice_authority_continuous", "practice_authority_2016") %in% names(iso_j)),
      "T15 both classification columns are present in the joined artifact")
}

if (fails) { cat(sprintf("\nFAILED (%d)\n", fails)); quit(status = 1L) }
cat("\nPASS (0 failures)\n")
