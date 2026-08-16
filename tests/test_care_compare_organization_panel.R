#!/usr/bin/env Rscript
# =============================================================================
# Care Compare organization panel: what a snapshot series may and may not claim
# =============================================================================
# The panel is NPI x organization x vintage. Its risks are not join bugs, they
# are claims about TIME that the snapshots do not support.
#
#   * A gap between snapshots hides everything inside it. A midwife who moved
#     twice between two files reads as one move, or as none if she returned.
#   * A 26-month change rate is not an annual rate, and dividing it by 26/12
#     would assume a constant hazard nobody has demonstrated.
#   * "Not in this vintage" is not "had no organization". Care Compare lists
#     clinicians CMS publishes; absence is a publication fact.
#
# THE VALIDITY CHECK THAT MAKES THE PANEL BELIEVABLE. Change must scale with
# elapsed time. Measured: 1.4% of midwives changed organization between
# snapshots one month apart, 28.9% between snapshots 26 months apart. Had the
# one-month figure also been ~29%, the measure would be tracking file churn
# rather than movement, and every transition number built on it would be noise.
# That ratio is asserted below, because it is the difference between a finding
# and an artifact.
#
# Hermetic where it can be: the reasoning is tested on small frames, and the
# real-artifact invariants skip loudly when the artifact is absent.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})
source(file.path(root, "tests", "helper-optional-inputs.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

SRC <- file.path(root, "build_care_compare_organization_panel.R")
ART <- file.path(root, "artifacts", "midwife_organization_panel.csv")
SUM <- file.path(root, "artifacts", "midwife_organization_panel_summary.csv")
src  <- paste(readLines(SRC, warn = FALSE), collapse = "\n")
code <- { ln <- readLines(SRC, warn = FALSE)
          paste(ln[!grepl("^\\s*#", ln)], collapse = "\n") }

# =============================================================================
cat("\n-- V: vintages are discovered, and the newest wins --\n")
# =============================================================================
{
  chk(grepl("find_vintages", code, fixed = TRUE),
      "V1 vintages are discovered rather than hardcoded")
  # A hardcoded list silently stops growing, and this file's whole value is in
  # accumulating snapshots.
  chk(!grepl('vintages <- c\\("20', code),
      "V2 no hardcoded vintage list")
  # Preferring the newer file on a collision is the guard against the mistake
  # that produced a two-year-old enrollment measurement earlier in this project.
  chk(grepl("desc(.data$mtime)", code, fixed = TRUE),
      "V3 on a duplicate vintage the more recent file wins")
  chk(grepl("vintage_inferred", code, fixed = TRUE),
      "V4 a vintage inferred from mtime is labelled as inferred, not asserted")
}

# =============================================================================
cat("\n-- T: the panel must not overclaim about time --\n")
# =============================================================================
{
  chk(grepl("does NOT support an annual transition rate", src, fixed = TRUE),
      "T1 the run states that a span rate is not an annual rate")
  chk(grepl("reads as ONE change", src, fixed = TRUE),
      "T2 and that movement inside a gap is invisible")
  chk(grepl("no change can be measured", src, fixed = TRUE),
      "T3 a single vintage is refused as a basis for change")

  # A 26-month span divided into an annual rate is the obvious error. Test the
  # ARITHMETIC, not the vocabulary: the first version grepped for "annual" and
  # matched the cat() string that WARNS against annualising -- a checker
  # tripping over its own warning, which is the third time that shape of bug
  # has appeared in this suite.
  arith <- grepl("/\\s*12\\b", code) || grepl("\\*\\s*12\\b", code) ||
           grepl("12\\s*/\\s*gap", code) || grepl("per_year|annualis|annualiz", code)
  chk(!arith, "T4 no annualisation ARITHMETIC appears in the code")

  # And the warning itself must still be there, since T1 relies on it.
  chk(grepl("annual transition rate", src, fixed = TRUE),
      "T4b the warning against annualising is still printed")
}

# =============================================================================
cat("\n-- A: absence is a publication fact, not a finding --\n")
# =============================================================================
{
  chk(grepl("listed_without_group", code, fixed = TRUE),
      "A1 a clinician listed with no group is labelled, not dropped")
  chk(grepl("Refusing to write an empty panel", src, fixed = TRUE),
      "A2 a missing input is a hard stop, not an empty panel")
}

# =============================================================================
cat("\n-- R: the real panel --\n")
# =============================================================================
{
  if (have_inputs(ART, "panel invariants")) {
    p <- read_csv(ART, col_types = cols(.default = "c"), progress = FALSE)

    chk(all(c("midwife_npi", "vintage", "org_pac_id", "organization_name",
              "affiliation_source", "n_concurrent_organizations") %in% names(p)),
        "R1 the panel carries the declared schema")
    chk(!"employer" %in% names(p), "R2 there is no employer column")
    chk(n_distinct(p$vintage) >= 2L,
        sprintf("R3 the panel spans %d vintages", n_distinct(p$vintage)))

    # Grain: one row per (midwife, vintage, organization, location).
    chk(sum(duplicated(p)) == 0L,
        sprintf("R4 no fully duplicated panel row [%d]", sum(duplicated(p))))

    g <- p %>% filter(has_group == "TRUE")
    sets <- g %>% distinct(midwife_npi, vintage, org_pac_id) %>%
      group_by(midwife_npi, vintage) %>%
      summarise(orgs = paste(sort(unique(org_pac_id)), collapse = "|"),
                .groups = "drop") %>%
      pivot_wider(names_from = vintage, values_from = orgs)

    vs <- sort(unique(g$vintage))
    if (length(vs) >= 3L) {
      # THE VALIDITY CHECK. Change over a SHORT interval must be far smaller
      # than change over a LONG one. If they are similar, the measure is
      # tracking file churn rather than movement between organizations.
      near <- vs[c(length(vs) - 1L, length(vs))]
      far  <- vs[c(1L, length(vs))]
      rate <- function(a, b) {
        d <- sets %>% filter(!is.na(.data[[a]]), !is.na(.data[[b]]))
        if (!nrow(d)) return(NA_real_)
        mean(d[[a]] != d[[b]])
      }
      r_near <- rate(near[1], near[2]); r_far <- rate(far[1], far[2])
      chk(!is.na(r_near) && !is.na(r_far) && r_near < r_far / 3,
          sprintf("R5 change scales with elapsed time [%s->%s %.1f%% vs %s->%s %.1f%%]",
                  near[1], near[2], 100 * r_near, far[1], far[2], 100 * r_far))
      cat(sprintf("       a similar pair would mean the measure tracks file churn,\n"))
      cat(sprintf("       not movement, and every transition figure would be noise.\n"))
    } else {
      cat("  --   SKIP R5 validity check needs three vintages\n")
    }
  }

  if (have_inputs(SUM, "tracked summary suppression")) {
    s <- read_csv(SUM, col_types = cols(.default = "c"), progress = FALSE)
    n <- suppressWarnings(as.integer(s$n_midwives))
    chk(all(is.na(n) | n >= 11L),
        sprintf("R6 no unsuppressed cell under 11 [min %s]",
                if (all(is.na(n))) "all NA" else min(n, na.rm = TRUE)))
    chk(all(grepl("^[A-Z]{2}$", s$practice_state)),
        "R7 states are two-letter codes")
  }
}

optional_inputs_summary()
cat(sprintf("\n%s (%d failures, %d skipped)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, optional_skip_count()))
quit(status = if (fails == 0L) 0L else 1L)
