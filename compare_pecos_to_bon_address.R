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
# FOUR OF THE SEVEN LIVE BON PULLS GO IN (CA added 2026-10-23):
#   - WA (harvest_live_wa_bon_from_tracked_roster.py) has no address field
#     whatsoever -- credential number, status and expiration date only.
#     EXCLUDED. Confirmed by querying data.wa.gov's live API directly
#     (2026-10-23), not assumed from the harvest script's existing columns.
#   - TX (harvest_live_tx_bon_from_tracked_roster.py) has
#     live_bon_place_of_employment, a free-text employer string ("OpenLoop
#     Healthcare 317 6th Ave Ste 400 Des Moines IA") with no component
#     street/city/state/zip fields -- the same kind of free text that got
#     street dropped from every other comparison in this project
#     (2026-10-23). EXCLUDED rather than regex-parsed. Also confirmed live
#     against data.texas.gov (2026-10-23): no standalone city/state/zip
#     field exists at all.
#   - CA (harvest_live_california_bon_from_tracked_roster.py) has city and
#     county, but NO ZIP FIELD -- the CA DCA roster simply doesn't publish
#     one. Included anyway (2026-10-23) via shape_address()'s zip_col = NULL
#     path: it contributes real state/city rows (1,341 VERIFIED matches,
#     the largest BON sample in this project by a wide margin) and sits out
#     ZIP5 entirely rather than being excluded wholesale the way WA/TX are.
#     Matched by last+first name against the FROZEN cohort (no NPI/license
#     identifier shared with this source), same imperfect-match caveat
#     every name-matched BON script here already carries. Address type
#     (mailing vs. practice) is undocumented, same situation as IL/CT/DE --
#     not confirmed mailing the way CO's was.
#   - CO (harvest_live_co_bon_from_tracked_roster.py) REMOVED 2026-10-23.
#     Its fields are explicitly DORA's own "mailzipcode" -- a board-reported
#     MAILING address, not a practice address. Every other side of every
#     comparison in this project (DAC/PECOS, NPPES, Doximity, Healthgrades)
#     is a practice-location field. Blending CO in -- whether as a caveated
#     per-state row or pooled into the headline number -- compared a
#     mailing address against a practice address and reported the result as
#     if it were the same kind of disagreement the other three states
#     measure. It was 166 of this comparison's 181 pre-removal pooled
#     records and drove ZIP5 agreement down to 6.6%; CT alone (the next
#     largest, n=14) was also only 7.1%, so removing CO did not rescue this
#     comparison's headline number, but it does make the number mean what
#     it claims to mean. See docs/TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_
#     AGREEMENT.md for the full picture across every comparison.
#   - IL, CT, DE all carry a structured, board-reported (not explicitly
#     mailing) city/state/zip. INCLUDED.
#
# Both the per-state rows AND one pooled "all states combined" row are
# reported below -- the per-state rows keep each state's own n visible, the
# pooled row answers "PECOS vs. state BON data overall" directly. The
# pooled row is a real join over the union of every state's verified
# matches, not an average of the per-state percentages (averaging percentages
# would weight IL's 1 record the same as CA's 1,341). Delaware is included
# for completeness even though it currently contributes 0 rows (0 DE
# midwives in the tracked cohort as of this run; see that script's own
# header) -- an honest zero, not an error. CA's zip5 row is comparable_n=0
# by construction (no zip field exists to compare), same honest-zero
# treatment, not an error either.
#
# Inputs : dac_midwives.csv (person-level, gitignored; extract_dac_midwives.R)
#          artifacts/live_california_bon_ingested_midwives_from_tracked_roster.csv
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
source(file.path("R", "lib", "address_agreement_compare.R"))  # shape_address(), compare_address_pair()
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/pecos_vs_bon_address_agreement.csv"

# path, city/state/zip column names, a short label for this state's own
# address "kind" (goes straight into source_pair, so it's visible on sight).
BON_STATES <- list(
  list(path = "artifacts/live_california_bon_ingested_midwives_from_tracked_roster.csv",
       city = "live_bon_city",
       label = "CA BON (board-reported, no state/ZIP field on this source)"),
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

# One compare_address_pair() call per state -- not one pooled join -- so each state's
# own n and address "kind" stays attached to its own rows.
per_state <- map2_dfr(BON_STATES, bon_by_state, function(spec, bon) {
  compare_address_pair(dac, bon, sprintf("PECOS/DAC (2026) vs %s", spec$label),
              "2026", "live", "vs_bon_same_year")
})

# One pooled row: every state's verified matches unioned into a single NPI
# key before joining to DAC. assert_unique_keys catches it if the same NPI
# ever turned up VERIFIED in two different states' pulls (shouldn't happen --
# nppes_state is stable per NPI -- but this would stop the run rather than
# silently keep one and drop the other).
bon_all <- assert_unique_keys(bind_rows(bon_by_state), "npi", label = "pooled BON (CA+IL+CT+DE)", dedupe = TRUE)
pooled <- compare_address_pair(dac, bon_all, "PECOS/DAC (2026) vs BON (CA+IL+CT+DE pooled)",
                       "2026", "live", "vs_bon_same_year_pooled")

out <- bind_rows(per_state, pooled)
print(as.data.frame(out), row.names = FALSE)

write_with_provenance(out, OUT, inputs = c("dac_midwives.csv", BON_PATHS))
cli::cli_alert_success("wrote {OUT}")
