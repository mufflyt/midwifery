#!/usr/bin/env Rscript
# =============================================================================
# How well does PECOS agree with NPPES on a midwife's address?
# =============================================================================
# One comparison, year-matched: DAC against NPPES's OWN panel for THE SAME
# YEAR DAC is dated to -- not today's address, which would conflate
# disagreement with any move that happened since.
#
# DAC is CMS's "Doctors & Clinicians" National Downloadable File, built from
# PECOS enrollment and practice-location data -- not an NPPES self-report.
# There is no raw PECOS practice-address extract (ppefaddr.csv) available to
# this project; CMS does not publish one standalone, and this repo's own
# PECOS pulls (build_pecos_organization_affiliations.R) only have the
# enrollment and reassignment files, neither of which carries a street/city/
# ZIP. DAC is the PECOS-vs-NPPES address comparison this project can run.
#
# Open Payments was compared here too, through 2026-10-23, and removed: CMS
# names NPPES and PECOS as inputs to Open Payments' own covered-recipient
# data pipeline (docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md
# §8), so an Open-Payments-vs-NPPES agreement number was never a check
# against an independent source -- it was partly NPPES checking itself. See
# git history for the prior Open Payments numbers and
# make_address_agreement_additional_figures.R (also removed, same date: its
# three figures existed to compare multiple sources/years at once and became
# redundant once only one source remained).
#
# An Open-Payments-vs-itself (year-over-year) comparison and a DAC-vs-Open-
# Payments comparison were also built and removed earlier (2026-10-22); see
# git history for those numbers.
#
# See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md for what
# this does and does not establish.
#
# Inputs : dac_midwives.csv      (person-level, gitignored; extract_dac_midwives.R)
#          midwife_panel.csv     (person-level, gitignored; NPPES annual snapshots)
# Outputs: artifacts/pecos_vs_nppes_address_agreement.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(purrr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/pecos_vs_nppes_address_agreement.csv"

stopifnot(file.exists("dac_midwives.csv"), file.exists("midwife_panel.csv"))

# Each comparable dataset reduced to the same shape: npi, state, city, zip5.
shape_dac <- function() {
  read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi, state = str_to_upper(str_squish(practice_state)),
              city = str_to_upper(str_squish(practice_city)),
              zip5 = str_sub(practice_zip, 1, 5))
}

dac <- shape_dac()

nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year == "2026")
nppes <- assert_unique_keys(nppes, "npi", label = "midwife_panel.csv", dedupe = TRUE) %>%
  transmute(npi, state = str_to_upper(str_squish(practice_state)),
            city = str_to_upper(str_squish(practice_city)),
            zip5 = str_sub(practice_zip, 1, 5))

# Two already-shaped (npi,state,city,zip5) tables -> one agreement row per level.
# Street was dropped (2026-10-23): free-text street formatting across sources
# never agrees cleanly enough to mean anything -- see
# compare_pecos_to_doximity_address.R's own street numbers before removal.
# ZIP5 is the finest grain this comparison reports.
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

# source_pair spells out BOTH sides' years so it's unambiguous on sight that
# NPPES is pulled from the matching year, not "current" NPPES.
out <- compare_two(dac, nppes, "PECOS/DAC (2026) vs NPPES (2026)", "2026", "2026", "vs_nppes_same_year")
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("dac_midwives.csv", "midwife_panel.csv"))
cli::cli_alert_success("wrote {OUT}")
