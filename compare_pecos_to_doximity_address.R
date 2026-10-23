#!/usr/bin/env Rscript
# =============================================================================
# How well does PECOS agree with Doximity's self-reported address?
# =============================================================================
# Direct parallel to compare_pecos_to_nppes_address.R: same DAC-as-PECOS
# stand-in (see that script's header for why), same cascading-grain method
# (state/city/zip5 agreement). The difference is the other side and how it
# reaches an NPI to join on.
#
# STREET WAS TRIED AND DROPPED (2026-10-23): 21.7% agreement on n=1,821,
# driven at least partly by Doximity's scraped address_line smashing suite
# text onto the street with no separator (e.g. "1 Baltimore Pl NWSte 105"),
# which norm_street()'s suite-stripping regex doesn't catch. Free-text
# street comparison across these two sources doesn't produce a number worth
# reporting. ZIP5 is the finest grain this comparison reports.
#
# DOXIMITY HAS NO NPI ON ITS PROFILES. scrape_doximity_public_cnm.R's own
# cohort match (its PASS 3) is a plain first-name + last-name join against
# artifacts/tracked_roster_active_primary_linked.csv, with no geography
# constraint and no NPI involved -- a common-name collision silently keeps
# whichever cohort row the join produces first (distinct(certification_number,
# .keep_all = TRUE)), not a reviewed or flagged choice. That match is already
# on disk as artifacts/doximity_public_matched.csv (4,712 rows, name-matched,
# certification_number is the only person-identifying key it carries).
#
# This script adds a SECOND, separate join: certification_number -> npi,
# via artifacts/tracked_roster_active_primary_linked.csv -- the same tracked,
# reviewed linkage the state-board-of-nursing harvest scripts already use.
# That second hop is deterministic (one roster row per certification_number,
# already reviewed), but it does not retroactively fix the first hop's
# name-only matching. Any address disagreement measured here is therefore
# upper-bounded by BOTH a genuine PECOS/Doximity data conflict AND Doximity's
# own name-match error rate -- this comparison cannot tell those two apart.
# Treat it as weaker evidence than the PECOS-vs-NPPES comparison, consistent
# with @archive/experiment_external_org_sources.R's own assessment of
# Doximity as "the weakest provenance ... and the least verifiable" of the
# external sources it tried.
#
# NOT year-matched. DAC carries a stated vintage; Doximity profiles carry
# date_created/date_modified per profile (not used here) but
# doximity_public_matched.csv itself has no single run date comparable to
# DAC's. Same caveat as compare_healthgrades_to_nppes_address.R.
#
# Inputs : dac_midwives.csv                  (person-level, gitignored; extract_dac_midwives.R)
#          doximity_public_matched.csv       (person-level, gitignored; scrape_doximity_public_cnm.R)
#          tracked_roster_active_primary_linked.csv (tracked; certification_number -> npi crosswalk)
# Outputs: artifacts/pecos_vs_doximity_address_agreement.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(purrr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/pecos_vs_doximity_address_agreement.csv"
ROSTER_FILE <- "artifacts/tracked_roster_active_primary_linked.csv"

stopifnot(file.exists("dac_midwives.csv"),
          file.exists("artifacts/doximity_public_matched.csv"),
          file.exists(ROSTER_FILE))

# Each comparable dataset reduced to the same shape: npi, state, city, zip5.
shape_dac <- function() {
  read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi, state = str_to_upper(str_squish(practice_state)),
              city = str_to_upper(str_squish(practice_city)),
              zip5 = str_sub(practice_zip, 1, 5))
}

dac <- shape_dac()

# certification_number -> npi, the same tracked, reviewed crosswalk the
# state-board-of-nursing harvest scripts use.
crosswalk <- read_csv(ROSTER_FILE, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(nzchar(npi)) %>%
  select(certification_number, npi)
crosswalk <- assert_unique_keys(crosswalk, "certification_number", label = ROSTER_FILE, dedupe = TRUE)

# city_zip is "City, ST ZIP5" (one combined field; Doximity carries no
# standalone zip column) -- zip5 is the trailing 5 digits.
shape_doximity <- function() {
  read_csv("artifacts/doximity_public_matched.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    inner_join(crosswalk, by = "certification_number") %>%
    transmute(npi, state = str_to_upper(str_squish(state)),
              city = str_to_upper(str_squish(city)),
              zip5 = str_extract(city_zip, "[0-9]{5}$"))
}

doximity <- shape_doximity()
doximity <- assert_unique_keys(doximity, "npi", label = "doximity_public_matched.csv", dedupe = TRUE)

# Two already-shaped (npi,state,city,zip5) tables -> one agreement row per level.
compare_two <- function(a, b, label, year_a, year_b, comparison_type, levels = c("state", "city", "zip5")) {
  joined <- inner_join(a, b, by = "npi", suffix = c("_a", "_b"))
  map_dfr(levels, function(lv) {
    x <- joined[[paste0(lv, "_a")]]; y <- joined[[paste0(lv, "_b")]]
    comparable <- sum(nzchar(x) & nzchar(y), na.rm = TRUE)
    agree <- sum(nzchar(x) & nzchar(y) & x == y, na.rm = TRUE)
    tibble(comparison_type = comparison_type, source_pair = label,
           year_a = year_a, year_b = year_b, level = lv,
           comparable_n = comparable, agree_n = agree,
           agree_pct = if (comparable > 0) round(100 * agree / comparable, 1) else NA_real_)
  })
}

out <- compare_two(dac, doximity, "PECOS/DAC (2026) vs Doximity (name-matched, undated)", "2026", "undated", "vs_doximity_name_matched")
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("dac_midwives.csv", "artifacts/doximity_public_matched.csv", ROSTER_FILE))
cli::cli_alert_success("wrote {OUT}")
