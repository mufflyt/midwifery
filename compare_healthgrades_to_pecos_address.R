#!/usr/bin/env Rscript
# =============================================================================
# How well does Healthgrades agree with PECOS on a midwife's address?
# =============================================================================
# Sibling of compare_healthgrades_to_nppes_address.R: identical population
# and join logic, DAC/PECOS substituted for NPPES on the other side -- see
# that script's header for why hg_npi is new evidence, not a copy of
# something NPPES already told this project, and compare_pecos_to_nppes_
# address.R's header for why DAC stands in for PECOS (no raw PECOS
# practice-address extract exists). Kept as a SEPARATE comparison rather
# than replacing the NPPES one: this tests a different pair (Healthgrades
# vs. CMS's enrollment-derived address) and the two don't have to agree,
# since NPPES and DAC don't agree with each other either (see
# compare_pecos_to_nppes_address.R's own numbers).
#
# NOT year-matched, same caveat as the NPPES sibling: DAC carries a stated
# vintage (2026), Healthgrades does not.
#
# ONE ROW PER NPI, same hg_site_n == 1 limitation as the NPPES sibling.
#
# Inputs : healthgrades_midwives.csv (person-level, gitignored; scrape_healthgrades_midwives.R)
#          dac_midwives.csv          (person-level, gitignored; extract_dac_midwives.R)
# Outputs: artifacts/healthgrades_vs_pecos_address_agreement.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_agreement_compare.R"))  # shape_address(), compare_two()
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/healthgrades_vs_pecos_address_agreement.csv"

stopifnot(file.exists("healthgrades_midwives.csv"), file.exists("dac_midwives.csv"))

healthgrades <- read_csv("healthgrades_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(hg_status == "ok", nzchar(hg_npi), hg_site_n == "1") %>%
  shape_address("hg_npi", "hg_state", "hg_city", "hg_zip")
healthgrades <- assert_unique_keys(healthgrades, "npi", label = "healthgrades_midwives.csv", dedupe = TRUE)

dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  shape_address("npi", "practice_state", "practice_city", "practice_zip")

# source_pair spells out both sides plainly: "scraped" (no fixed vintage) vs
# DAC/PECOS's 2026 vintage, same unambiguous-on-sight convention as the
# NPPES sibling.
out <- compare_two(healthgrades, dac, "Healthgrades (scraped) vs PECOS/DAC (2026)", "scraped", "2026", "vs_pecos_same_year")
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("healthgrades_midwives.csv", "dac_midwives.csv"))
cli::cli_alert_success("wrote {OUT}")
