#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 15 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: R/lib/ob_hospitals.R -- what makes a hospital "obstetric" -- and the
# county sentence that reports it. This defines the hospital denominator for
# every obstetric-capacity claim in the project.
#
# THE FINDING. 19,352 of 23,830 active hospital records (81.2%) have NO
# OB_SRVC_CD at all. The module handles that correctly, returning a three-way
# yes / no / unknown and carrying n_hosp_ob_unknown through. The SENTENCE did
# not:
#
#     n_hosp_ob == 0  ->  "N active hospitals, none of which reports
#                          obstetric services"
#
# was emitted regardless of why the count was zero. Of the 1,451 counties that
# receive it, 651 (45%) have EVERY active hospital's OB status missing. The
# sentence is generated from pure silence, and a reader hears "no obstetric care
# here" from a field the source never filled in. Unknown is not no -- the same
# principle as cycle 3's suppressed-is-not-zero, now in published prose rather
# than in a denominator.
#
# A SECOND FINDING, smaller and worth stating: the code comment beside that
# sentence asserts the silence is "commonest in small rural counties". It is
# not. All-unknown runs 55.2% in metro counties, 43.1% in remote and 28.1% in
# adjacent. A plausible aside in a comment is not evidence, and this one is
# backwards.
#
# Run: Rscript tests/test_cycle15_ob_capacity.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "ob_hospitals.R"))
source(file.path(root, "R", "lib", "table1_bands.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
PROF <- paste(readLines(file.path(root, "R", "10-county-birth-profiles.R"),
                        warn = FALSE), collapse = "\n")
OC <- build_ob_hospital_counts()
CB <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                show_col_types = FALSE, progress = FALSE,
                                col_types = cols(GEOID = col_character()))) %>%
  mutate(rurality = band_rurality(rucc_2023, RURALITY_LABELS_COHORT))
D <- CB %>% left_join(OC, by = "GEOID", relationship = "many-to-one") %>%
  mutate(across(c(n_hosp_active, n_hosp_ob, n_hosp_ob_unknown), ~ coalesce(.x, 0L)))

cat("\n-- BVA --\n")

# T141 (BVA). The three counts must add up: every active hospital is exactly
# one of yes / no / unknown, so ob + unknown can never exceed active.
{
  bad <- sum(D$n_hosp_ob + D$n_hosp_ob_unknown > D$n_hosp_active)
  chk(bad == 0L,
      sprintf("T141a obstetric + unknown never exceeds active [%d counties violate]", bad))
  chk(all(D$n_hosp_ob >= 0L) && all(D$n_hosp_ob_unknown >= 0L),
      "T141b no count is negative")
}

# T142 (BVA). GEOID is built by pasting state and county FIPS with no padding.
# A 4-character GEOID joins to nothing and silently drops a county.
{
  chk(all(nchar(OC$GEOID) == 5L),
      sprintf("T142 every hospital-derived GEOID is 5 characters [%d are not]",
              sum(nchar(OC$GEOID) != 5L)))
}

# T143 (BVA). A county with zero hospitals and a county with zero OB hospitals
# are different facts and must not collapse.
{
  none <- D %>% filter(n_hosp_active == 0)
  someNoOb <- D %>% filter(n_hosp_active > 0, n_hosp_ob == 0)
  chk(nrow(none) > 0 && nrow(someNoOb) > 0,
      sprintf("T143 no-hospital (%d) and hospital-but-no-OB (%d) are distinct populations",
              nrow(none), nrow(someNoOb)))
}

cat("\n-- SEMANTIC --\n")

# T144 (semantic). THE FIX. A county whose hospitals are ALL unknown must not
# be told "none reports obstetric services" as if a hospital had answered no.
{
  chk(grepl("none of which records whether it", PROF),
      "T144a the all-unknown case gets its own sentence about missing records")
  chk(grepl("n_hosp_ob_unknown >= r\\$n_hosp_active", PROF),
      "T144b the two cases are separated by the unknown count, not by the OB count alone")
}

# T145 (semantic). "reporting obstetric services" is the honest phrasing for a
# yes: it describes what the source says, not what the hospital does.
{
  chk(grepl("reporting obstetric services", PROF),
      "T145a a positive count is phrased as REPORTING, not as having")
  chk(!grepl("no obstetric services|without obstetric services|lacks obstetric", PROF),
      "T145b no sentence asserts the absence of a service from an absent record")
}

# T146 (semantic). ob_status must be three-way. Collapsing unknown into no is
# the whole defect, and it must not reappear.
{
  src <- paste(readLines(file.path(root, "R", "lib", "ob_hospitals.R"), warn = FALSE),
               collapse = "\n")
  chk(grepl('"unknown"', src) && grepl("n_hosp_ob_unknown", src),
      "T146a unknown is a first-class status and is carried out of the function")
  chk(grepl("is\\.na\\(OB_SRVC_CD\\)\\s*~\\s*\"unknown\"", src),
      "T146b a missing service code maps to unknown BEFORE any other branch")
}

cat("\n-- ADVERSARIAL --\n")

# T147 (adversarial). Quantify the misreading the fix prevents, and pin it.
# If this number ever falls to zero the fix is dead code; if it grows, more of
# the map is being described from silence.
{
  affected <- D %>% filter(n_hosp_active > 0, n_hosp_ob == 0,
                           n_hosp_ob_unknown >= n_hosp_active)
  total <- D %>% filter(n_hosp_active > 0, n_hosp_ob == 0)
  chk(nrow(affected) > 0 && nrow(affected) < nrow(total),
      sprintf("T147 %d of %d 'no OB' counties are all-unknown, so both sentences are reachable",
              nrow(affected), nrow(total)))
}

# T148 (adversarial). THE COMMENT THAT WAS WRONG. Silence is not commonest in
# rural counties. Asserted directly so the claim cannot drift back into prose.
{
  by_rur <- D %>% filter(!is.na(rurality), n_hosp_active > 0, n_hosp_ob == 0) %>%
    group_by(rurality) %>%
    summarise(pct = 100 * sum(n_hosp_ob_unknown >= n_hosp_active) / n(), .groups = "drop")
  metro <- by_rur$pct[grepl("^Metro", by_rur$rurality)]
  remote <- by_rur$pct[grepl("remote", by_rur$rurality)]
  chk(length(metro) == 1L && length(remote) == 1L && metro > remote,
      sprintf("T148 all-unknown is MORE common in metro than remote counties [%.1f%% vs %.1f%%]",
              metro, remote))
}

# T149 (adversarial). An unexpected service code must not be asserted as "no".
# The live codes are 0/1/2/3 only, so the trailing branch has never seen
# anything else -- the same coincidence-not-contract shape as the RUCC rule in
# cycle 1, which DID have a trailing TRUE branch and mislabelled everything.
{
  src <- paste(readLines(file.path(root, "R", "lib", "ob_hospitals.R"), warn = FALSE),
               collapse = "\n")
  chk(grepl('OB_SRVC_CD == "0"\\s*~\\s*"no"', src) &&
        grepl('TRUE\\s*~\\s*"unknown"', src),
      "T149a only a recorded 0 means no; an unrecognised code is unknown, not a negative")
  live <- suppressWarnings(read_csv(POS_FILE, show_col_types = FALSE, progress = FALSE,
                                    col_types = cols(.default = col_character())))
  codes <- setdiff(unique(live$OB_SRVC_CD), NA)
  chk(all(codes %in% c("0", "1", "2", "3")),
      sprintf("T149b the live extract carries only known codes, so the branch is untested by data [%s]",
              paste(sort(codes), collapse = ",")))
}

# T150 (adversarial). Row order must not change any county's counts.
{
  h <- suppressWarnings(read_csv(POS_FILE, show_col_types = FALSE, progress = FALSE,
                                 col_types = cols(.default = col_character())))
  set.seed(20260810)
  tmp <- file.path(tempdir(), "pos_shuffled.csv")
  readr::write_csv(h[sample(nrow(h)), ], tmp)
  shuffled <- build_ob_hospital_counts(tmp)
  a <- OC %>% arrange(GEOID); b <- shuffled %>% arrange(GEOID)
  chk(identical(as.data.frame(a), as.data.frame(b)),
      "T150 shuffling the POS file leaves every county count identical")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
