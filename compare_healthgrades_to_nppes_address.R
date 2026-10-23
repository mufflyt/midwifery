#!/usr/bin/env Rscript
# =============================================================================
# How well does Healthgrades agree with NPPES on a midwife's address?
# =============================================================================
# Direct parallel to compare_pecos_to_nppes_address.R: same cascading-grain
# method (state/city/zip5 agreement, inner join by NPI), same output shape
# -- but a different population and a different kind of "agreement."
#
# scrape_healthgrades_midwives.R targets midwives_unmatched.csv: certificants
# this project could NOT find an NPI for by name/certification matching, so
# they carry no NPPES address at all in this project's existing linkage.
# Healthgrades' own page recovers an NPI independently (regex + Luhn check on
# embedded JS; see that script's header) -- hg_npi is therefore NEW evidence,
# not a copy of something NPPES already told this project. This comparison
# measures: for the subset of previously NPI-less certificants where
# Healthgrades surfaced a plausible NPI, and that NPI turns out to exist in
# NPPES's own panel, does Healthgrades' scraped address agree with what that
# NPI's NPPES record says?
#
# NOT year-matched the way DAC was. DAC carries its own stated vintage and
# was deliberately read for the same year as the NPPES snapshot it was
# checked against. This scrape has no comparable "as of" field -- hg_url was
# fetched whenever scrape_healthgrades_midwives.R last ran against that
# provider's page, which may be days or months before the NPPES snapshot
# year used here (2026). A disagreement here can therefore be staleness, not
# a genuine source conflict -- a caveat the DAC comparison does not carry.
#
# ONE ROW PER NPI. A midwife can have multiple Healthgrades practice sites
# (hg_site_n); only the first (hg_site_n == 1) is kept. A multi-site NPI
# compared against a single NPPES address has the same one-site-of-several
# limitation the DAC/PECOS comparison already accepts -- see that script and
# the appendix for why picking one site is not a new problem introduced here.
#
# Inputs : healthgrades_midwives.csv (person-level, gitignored; scrape_healthgrades_midwives.R)
#          midwife_panel.csv         (person-level, gitignored; NPPES annual snapshots)
# Outputs: artifacts/healthgrades_vs_nppes_address_agreement.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(purrr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/healthgrades_vs_nppes_address_agreement.csv"

stopifnot(file.exists("healthgrades_midwives.csv"), file.exists("midwife_panel.csv"))

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

nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year == "2026")
nppes <- assert_unique_keys(nppes, "npi", label = "midwife_panel.csv", dedupe = TRUE) %>%
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
# NPPES's 2026 snapshot, so it's unambiguous on sight that these are not
# year-matched the way the PECOS/DAC comparison is.
out <- compare_two(healthgrades, nppes, "Healthgrades (scraped) vs NPPES (2026)", "scraped", "2026", "vs_nppes_same_year")
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("healthgrades_midwives.csv", "midwife_panel.csv"))
cli::cli_alert_success("wrote {OUT}")
