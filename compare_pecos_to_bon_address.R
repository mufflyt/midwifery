#!/usr/bin/env Rscript
# =============================================================================
# How well does PECOS agree with each state Board of Nursing's address?
# =============================================================================
# Sibling of compare_pecos_to_nppes_address.R: same DAC-as-PECOS stand-in
# (see that script's header for why), same cascading-grain method
# (state/city/zip5, inner join by NPI -- every live BON artifact already
# carries npi directly, read from the tracked roster it was built against,
# so no crosswalk hop is needed here the way the Doximity comparison needed
# one).
#
# ONLY FOUR OF THE SIX LIVE BON PULLS HAVE A COMPARABLE ADDRESS AT ALL:
#   - WA (harvest_live_wa_bon_from_tracked_roster.py) has no address field
#     whatsoever -- credential number, status and expiration date only.
#     EXCLUDED.
#   - TX (harvest_live_tx_bon_from_tracked_roster.py) has
#     live_bon_place_of_employment, a free-text employer string ("OpenLoop
#     Healthcare 317 6th Ave Ste 400 Des Moines IA") with no component
#     street/city/state/zip fields -- the same kind of free text that got
#     street dropped from every other comparison in this project
#     (2026-10-23). EXCLUDED rather than regex-parsed.
#   - CO, IL, CT, DE all carry a structured city/state/zip. INCLUDED.
#
# EACH STATE'S ADDRESS IS A DIFFERENT KIND OF "BON address." Colorado's
# fields are explicitly DORA's own "mailzipcode" -- a board-reported MAILING
# address (see harvest_live_co_bon_from_tracked_roster.py's own header).
# Illinois/Connecticut/Delaware document no mailing-vs-practice distinction
# at all. Both the per-state rows AND one pooled "all states combined" row
# are reported below -- the per-state rows keep that heterogeneity visible,
# the pooled row answers "PECOS vs. state BON data overall" directly. The
# pooled row is a real join over the union of all four states' verified
# matches, not an average of the per-state percentages (averaging percentages
# would weight a 1-record state the same as a 166-record one). Delaware is
# included for completeness even though it currently contributes 0 rows (0
# DE midwives in the tracked cohort as of this run; see that script's own
# header) -- an honest zero, not an error.
#
# Inputs : dac_midwives.csv (person-level, gitignored; extract_dac_midwives.R)
#          artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv
#          artifacts/live_illinois_bon_ingested_midwives_from_tracked_roster.csv
#          artifacts/live_connecticut_bon_ingested_midwives_from_tracked_roster.csv
#          artifacts/live_delaware_bon_ingested_midwives_from_tracked_roster.csv
# Outputs: artifacts/pecos_vs_bon_address_agreement.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(purrr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_agreement_compare.R"))  # shape_address(), compare_two()
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/pecos_vs_bon_address_agreement.csv"

# path, city/state/zip column names, a short label for this state's own
# address "kind" (goes straight into source_pair, so it's visible on sight).
BON_STATES <- list(
  list(path = "artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv",
       city = "live_bon_mail_city", state = "live_bon_mail_state", zip = "live_bon_mail_zip",
       label = "CO BON (mailing address)"),
  list(path = "artifacts/live_illinois_bon_ingested_midwives_from_tracked_roster.csv",
       city = "live_bon_city", state = "live_bon_state", zip = "live_bon_zip",
       label = "IL BON (board-reported)"),
  list(path = "artifacts/live_connecticut_bon_ingested_midwives_from_tracked_roster.csv",
       city = "live_bon_city", state = "live_bon_state", zip = "live_bon_zip",
       label = "CT BON (board-reported)"),
  list(path = "artifacts/live_delaware_bon_ingested_midwives_from_tracked_roster.csv",
       city = "live_bon_city", state = "live_bon_state", zip = "live_bon_zip",
       label = "DE BON (board-reported)")
)

BON_PATHS <- map_chr(BON_STATES, "path")
stopifnot(file.exists("dac_midwives.csv"), all(file.exists(BON_PATHS)))

dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  shape_address("npi", "practice_state", "practice_city", "practice_zip")

# Shape every state once; reused for both the per-state rows and the pooled
# one. Verified-match rows only (live_bon_match_status == "VERIFIED_LIVE_BON"):
# UNMATCHED/AMBIGUOUS rows carry no board address to compare at all (see
# each harvest script's own header for that three-way split).
bon_by_state <- map(BON_STATES, function(spec) {
  bon <- read_csv(spec$path, col_types = cols(.default = "c"), progress = FALSE) %>%
    filter(live_bon_match_status == "VERIFIED_LIVE_BON", nzchar(npi)) %>%
    shape_address("npi", spec$state, spec$city, spec$zip)
  assert_unique_keys(bon, "npi", label = basename(spec$path), dedupe = TRUE)
})

# One compare_two() call per state -- not one pooled join -- so each state's
# own n and address "kind" stays attached to its own rows.
per_state <- map2_dfr(BON_STATES, bon_by_state, function(spec, bon) {
  compare_two(dac, bon, sprintf("PECOS/DAC (2026) vs %s", spec$label),
              "2026", "live", "vs_bon_same_year")
})

# One pooled row: every state's verified matches unioned into a single NPI
# key before joining to DAC. assert_unique_keys catches it if the same NPI
# ever turned up VERIFIED in two different states' pulls (shouldn't happen --
# nppes_state is stable per NPI -- but this would stop the run rather than
# silently keep one and drop the other).
bon_all <- assert_unique_keys(bind_rows(bon_by_state), "npi", label = "pooled BON (CO+IL+CT+DE)", dedupe = TRUE)
pooled <- compare_two(dac, bon_all, "PECOS/DAC (2026) vs BON (CO+IL+CT+DE pooled)",
                       "2026", "live", "vs_bon_same_year_pooled")

out <- bind_rows(per_state, pooled)
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("dac_midwives.csv", BON_PATHS))
cli::cli_alert_success("wrote {OUT}")
