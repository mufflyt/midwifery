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
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(purrr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/healthgrades_vs_pecos_address_agreement.csv"

stopifnot(file.exists("healthgrades_midwives.csv"), file.exists("dac_midwives.csv"))

# Each comparable dataset reduced to the same shape: npi, state, city, zip5.
shape_healthgrades <- function() {
  read_csv("healthgrades_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    filter(hg_status == "ok", nzchar(hg_npi), hg_site_n == "1") %>%
    transmute(npi = hg_npi, state = str_to_upper(str_squish(hg_state)),
              city = str_to_upper(str_squish(hg_city)),
              zip5 = str_sub(hg_zip, 1, 5))
}

healthgrades <- shape_healthgrades()
healthgrades <- assert_unique_keys(healthgrades, "npi", label = "healthgrades_midwives.csv", dedupe = TRUE)

dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, state = str_to_upper(str_squish(practice_state)),
            city = str_to_upper(str_squish(practice_city)),
            zip5 = str_sub(practice_zip, 1, 5))

# Two already-shaped (npi,state,city,zip5) tables -> one agreement row per level.
# Street was dropped (2026-10-23): free-text street formatting across sources
# never agrees cleanly enough to mean anything. ZIP5 is the finest grain this
# comparison reports.
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

# source_pair spells out both sides plainly: "scraped" (no fixed vintage) vs
# DAC/PECOS's 2026 vintage, same unambiguous-on-sight convention as the
# NPPES sibling.
out <- compare_two(healthgrades, dac, "Healthgrades (scraped) vs PECOS/DAC (2026)", "scraped", "2026", "vs_pecos_same_year")
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("healthgrades_midwives.csv", "dac_midwives.csv"))
cli::cli_alert_success("wrote {OUT}")
