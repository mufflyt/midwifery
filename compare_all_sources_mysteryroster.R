#!/usr/bin/env Rscript
# =============================================================================
# Every source that can name a midwife's state, compared with mysteryroster
# =============================================================================
# build_cross_source_comparison.R answers four questions about ten sources.
# This script asks mysteryroster's full no-gold-standard toolkit of as many
# sources as this machine can actually load -- including Medicare Part B and
# Part D, which that script does not carry -- and writes each comparison as
# its own artifact.
#
# WHY A PACKAGE AND NOT MORE LOCAL CODE. mysteryroster 0.3.0 (github.com/
# mufflyt/mysteryroster) is the carved-out core of the ENT/OB-GYN registry
# validity work, and its vignette "Comparing Sources Without a Gold Standard"
# is this exact analysis on a SIMULATED midwifery panel, calibrated to this
# project's own published findings. Running it on the real panel is the point;
# re-deriving agreement, lead-lag, churn and fusion here would be a second
# implementation of code that already has tests.
#
# NOT EVERY SOURCE CAN ANSWER EVERY QUESTION, and the script is built around
# that rather than papering over it. Two tiers, named separately:
#
#   LONGITUDINAL  a state for an NPI in a given YEAR, so it can carry
#                 agreement-over-time, lead/lag, churn and fusion:
#                 nppes, pecos_revalidation, medicare_part_b, medicare_part_d,
#                 medicaid_enrollment (moved out of SNAPSHOT 2026-11-10),
#                 open_payments.
#   SNAPSHOT      one state per NPI with no usable year, so it can only carry
#                 presence and current-state agreement: dac_physician_compare,
#                 facility_affiliation_ccn (the NPI -> CCN route),
#                 healthgrades, doximity, state_boards_of_nursing,
#                 cms_ndh_fhir.
#
# Giving a snapshot a year it does not have would manufacture a time series,
# and every lead/lag number computed from it would be an artifact of that
# invention. So snapshots enter the presence overlap and the current-state
# matrix, and are kept out of everything that reads a year.
#
# TWO SOURCES ARE ABSENT ON THIS MACHINE AND ARE REPORTED, NOT SILENTLY
# DROPPED. artifacts/physician_compare_historical_midwives.csv (DAC 2013-2022)
# cannot be rebuilt here: extract_physician_compare_historical_midwives.R
# needs five local NBER-mirror CSVs under data/raw/cms_physician_compare/ that
# this clone does not have, so DAC enters as its 2026 snapshot only and its
# history is missing. Anything the absent file would have said about DAC's lag
# is simply not measured here. See the `sources_unavailable` artifact.
#
# PART D NOW CARRIES A STATE FOR EVERY YEAR, 2013-2024. It used to carry one
# for 2022-2023 only, and the other eleven years entered here as a separate
# presence-only source, medicare_part_d_presence. The CMS by-provider files
# downloaded on 2026-11-09 give those eleven years a state, so that second
# source has been REMOVED rather than left in place: it would now hold exactly
# the npi/year pairs of medicare_part_d itself under a different name, and the
# overlap, consensus and fusion steps would count Part D twice -- inflating
# agreement for free, in the same way Part B and Part D already do by sharing
# a claims lineage. See extract_medicare_part_b_d_cohort_states.R.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv and the per-source extracts
#          listed in SOURCE_FILES below
# Outputs: artifacts/mrost_source_inventory.csv
#          artifacts/mrost_sources_unavailable.csv
#          artifacts/mrost_presence_overlap_zones.csv
#          artifacts/mrost_presence_by_source.csv
#          artifacts/mrost_coverage_by_year.csv
#          artifacts/mrost_agreement_pairwise.csv
#          artifacts/mrost_agreement_current_snapshot.csv
#          artifacts/mrost_corroboration.csv
#          artifacts/mrost_odd_one_out_rate.csv
#          artifacts/mrost_consensus_tier.csv
#          artifacts/mrost_churn_by_source.csv
#          artifacts/mrost_lead_lag.csv
#          artifacts/mrost_truth_fusion_agreement.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tibble)
  library(mysteryroster)
})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

COHORT <- "artifacts/amcb_npi_linkage_FROZEN.csv"
ART    <- "artifacts"
stopifnot(utils::packageVersion("mysteryroster") >= "0.3.0")

link <- read_csv(COHORT, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>%
  transmute(certification_number, npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi))
cohort_npis <- unique(link$npi)
cat(sprintf("cohort: %s NPIs\n", format(length(cohort_npis), big.mark = ",")))

#' Restrict a loaded source to the frozen cohort
#'
#' Every source is filtered to the cohort before anything is counted, so that a
#' coverage percentage always has the same denominator and two sources are never
#' compared over different populations.
#'
#' @param df [data.frame] any source with an `npi` column.
#' @return [data.frame] the rows whose NPI is in the frozen linkage.
keep_cohort <- function(df) df %>% filter(npi %in% cohort_npis)
#' Collapse a snapshot source to one state per NPI
#'
#' The same modal rule the longitudinal extracts use -- most rows wins, ties
#' alphabetical so a rerun is identical. Applied only to SNAPSHOT sources, which
#' have no year to group within. A longitudinal source must never be passed
#' through here: collapsing its years into a single modal state is precisely the
#' error that made the DOGE Medicaid enrollment segments look like the worst
#' source in the first run of this comparison, when the segments carry
#' ENRL_START_DT and ENRL_END_DT and should be expanded by date-range overlap
#' into one state per NPI-year instead.
#'
#' @param df [data.frame] a snapshot source with `npi` and `state`.
#' @return [data.frame] npi, state -- one row per NPI.
one_per_npi <- function(df) df %>% filter(!is.na(npi), !is.na(state)) %>%
  count(npi, state, name = "n") %>%
  arrange(npi, desc(n), state) %>% group_by(npi) %>% slice(1) %>% ungroup() %>%
  select(npi, state)

#' Load a source only if its file is actually there, and survive it if not
#'
#' Fifteen sources are assembled here and no clone of this project has all
#' fifteen. A source that cannot be read must become a recorded absence -- see
#' `note_missing()` and the `sources_unavailable` artifact -- never a crash that
#' takes the other fourteen down with it, and never a silent zero that reads as
#' "this source covers nobody".
#'
#' @param path [character] file path, or a glob; both are tested.
#' @param f [function] a nullary reader called only when the path resolves.
#' @return whatever `f()` returns, or NULL if the file is missing or the read
#'   threw -- the error message is printed before NULL is returned, so a
#'   malformed file is distinguishable from an absent one in the log.
read_if <- function(path, f) {
  if (!file.exists(path) && !length(Sys.glob(path))) return(NULL)
  tryCatch(f(), error = function(e) { cat(sprintf("  ! %s: %s\n", path, conditionMessage(e))); NULL })
}

unavailable <- tibble(source = character(), path = character(), reason = character())
#' Record that a source could not be loaded, and why
#'
#' An absence is a finding about this clone, not a blank to be skipped past. The
#' accumulated table is written out as `mrost_sources_unavailable.csv` so that a
#' reader of the results can tell "this source disagreed" from "this source was
#' never consulted" -- the distinction that matters most when the headline is
#' which sources agree.
#'
#' @param src [character] source label, matching the name it would have had.
#' @param path [character] where it was looked for.
#' @param reason [character] why it was not usable, in a sentence.
#' @return invisibly NULL; appends to `unavailable` in the enclosing scope.
note_missing <- function(src, path, reason) {
  unavailable <<- bind_rows(unavailable, tibble(source = src, path = path, reason = reason))
  cat(sprintf("  MISSING %-26s %s\n", src, reason))
}

# ---------------------------------------------------------------- longitudinal
cat("\nLoading LONGITUDINAL sources (npi, year, state):\n")
longi <- list()

longi$nppes <- read_if("midwife_panel.csv", function()
  read_csv("midwife_panel.csv", col_select = c(npi, snapshot_year, practice_state),
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(snapshot_year),
              state = clean_state(practice_state)) %>%
    filter(!is.na(npi), !is.na(year), !is.na(state)) %>% keep_cohort() %>% distinct())

longi$pecos_revalidation <- read_if(file.path(ART, "pecos_revalidation_cohort_state_by_year.csv"), function()
  read_csv(file.path(ART, "pecos_revalidation_cohort_state_by_year.csv"),
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
    filter(!is.na(npi), !is.na(year), !is.na(state)) %>% keep_cohort() %>% distinct())

longi$medicare_part_b <- read_if(file.path(ART, "cohort_midwives_part_b_state_by_year.csv"), function()
  read_csv(file.path(ART, "cohort_midwives_part_b_state_by_year.csv"),
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state)) %>%
    filter(!is.na(state)) %>% keep_cohort() %>% distinct())

longi$medicare_part_d <- read_if(file.path(ART, "cohort_midwives_part_d_state_by_year.csv"), function()
  read_csv(file.path(ART, "cohort_midwives_part_d_state_by_year.csv"),
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state)) %>%
    filter(!is.na(state)) %>% keep_cohort() %>% distinct())

# OPEN PAYMENTS IS LONGITUDINAL NOW, 2021-2025, NOT A SINGLE YEAR.
# It sat in this tier with only 2024 extracted, producing zero transitions and
# four skipped lead/lag pairings, while the raw releases for 2013-2023 and
# 2025 were on the volume the whole time. extract_open_payments_cohort_by_year.R
# reads all of them: 21,067 NPI-years, 8,496 midwives, 2013-2025.
#
# ONLY 2021 ONWARDS ENTERS THE COMPARISON. Certified nurse-midwives did not
# become covered recipients until the SUPPORT Act expansion hit program year
# 2021, and before that this cohort has 4-21 midwives a year against 3,018 in
# 2021 -- a 500-fold discontinuity at the rule change. Those trace years are
# real observations but they are not a trend, and feeding them to churn or
# lead/lag would manufacture transitions from a handful of people who were
# reportable under some other recipient category. The producer marks them
# usable_for_trend = FALSE and this filter honours it.
#
# 2013-2014 additionally carry no NPI in the source at all; they are linked
# retrospectively through a profile -> NPI lookup learned from 2021-2025 and
# are evidence class B. They are excluded here for the eligibility reason
# above, which also keeps the retrospective rows out of the comparison.
longi$open_payments <- read_if(
  file.path(ART, "open_payments_midwife_presence_by_year.csv"), function()
  read_csv(file.path(ART, "open_payments_midwife_presence_by_year.csv"),
           col_types = cols(.default = "c"), progress = FALSE) %>%
    filter(usable_for_trend == "TRUE") %>%
    transmute(npi = trimws(npi), year = as.integer(program_year),
              state = clean_state(state)) %>%
    filter(!is.na(npi), !is.na(year), !is.na(state)) %>% keep_cohort() %>%
    distinct())

if (is.null(longi$nppes)) stop("nppes panel is required and absent", call. = FALSE)
longi <- longi[!vapply(longi, is.null, logical(1))]
# A source may legitimately name two states for one NPI-year (two practice
# addresses). The toolkit needs one value per id-year, so reduce by the same
# modal rule the rest of the repo uses: most rows, ties alphabetical.
longi <- lapply(longi, function(d)
  d %>% count(npi, year, state, name = "n") %>%
    arrange(npi, year, desc(n), state) %>%
    group_by(npi, year) %>% slice(1) %>% ungroup() %>% select(npi, year, state))
for (n in names(longi)) cat(sprintf("  %-22s %7s NPI-years  %6s NPIs  %d-%d\n", n,
  format(nrow(longi[[n]]), big.mark = ","), format(n_distinct(longi[[n]]$npi), big.mark = ","),
  min(longi[[n]]$year), max(longi[[n]]$year)))

# -------------------------------------------------------------------- snapshot
cat("\nLoading SNAPSHOT sources (one state per NPI, no usable year):\n")
snap <- list()

snap$dac_physician_compare <- read_if("dac_midwives.csv", function()
  read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), state = clean_state(practice_state)) %>%
    keep_cohort() %>% one_per_npi())
if (!file.exists(file.path(ART, "physician_compare_historical_midwives.csv")))
  note_missing("dac_physician_compare_history", file.path(ART, "physician_compare_historical_midwives.csv"),
    "needs 5 local NBER CSVs under data/raw/cms_physician_compare/ that this clone lacks; DAC enters as its 2026 snapshot only")

snap$facility_affiliation_ccn <- read_if(file.path(ART, "dac_facility_affiliations.csv"), function()
  read_csv(file.path(ART, "dac_facility_affiliations.csv"), col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), state = clean_state(state)) %>% keep_cohort() %>% one_per_npi())

snap$healthgrades <- read_if("healthgrades_midwives.csv", function()
  read_csv("healthgrades_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(hg_npi), state = clean_state(hg_state)) %>% keep_cohort() %>% one_per_npi())

snap$doximity <- read_if(file.path(ART, "doximity_public_matched.csv"), function()
  read_csv(file.path(ART, "doximity_public_matched.csv"), col_types = cols(.default = "c"), progress = FALSE) %>%
    left_join(link, by = "certification_number", relationship = "many-to-one") %>%
    transmute(npi = trimws(npi), state = clean_state(state)) %>% keep_cohort() %>% one_per_npi())

bon_files <- Sys.glob(file.path(ART, "live_*_bon_ingested_midwives_from_tracked_roster.csv"))
snap$state_boards_of_nursing <- if (!length(bon_files)) NULL else
  bind_rows(lapply(bon_files, function(f) read_csv(f, col_types = cols(.default = "c"), progress = FALSE))) %>%
    filter(live_bon_match_status == "VERIFIED_LIVE_BON") %>%
    transmute(npi = trimws(npi), state = clean_state(live_bon_state)) %>% keep_cohort() %>% one_per_npi()

snap$cms_ndh_fhir <- read_if(file.path(ART, "cms_ndh_midwives.csv"), function()
  read_csv(file.path(ART, "cms_ndh_midwives.csv"), col_types = cols(.default = "c"), progress = FALSE) %>%
    filter(toupper(ndh_found) %in% c("TRUE", "1")) %>%
    transmute(npi = trimws(npi),
              state = clean_state(str_match(ndh_addresses, "\\b([A-Z]{2})\\s+\\d{5}")[, 2])) %>%
    keep_cohort() %>% one_per_npi())

# DOGE T-MSIS Medicaid enrollment segments (opendata.hhs.gov, 2026-07-24).
# MEDICAID ENROLMENT IS LONGITUDINAL, AND USED TO BE READ AS A SNAPSHOT.
# Until 2026-11-10 this block reduced the whole T-MSIS segments file to one
# modal state per NPI and put it in the SNAPSHOT tier, so a career-long state
# was compared against every other source's contemporaneous value. The file
# carries ENRL_START_DT and ENRL_END_DT; expanding by date-range overlap
# yields 119,527 cohort NPI-years, 2013-2024.
#
# Measured, not assumed: the old modal state differs from the year-specific
# state on 14.4% of NPI-years -- 30.5% in 2013 decaying monotonically to 5.7%
# in 2024, which is the signature of comparing one fixed value against a
# moving one. That is why medicaid_enrollment carried an odd-one-out rate of
# 0.166, five times the next source, and the lowest fusion agreement of the
# fourteen. See extract_medicaid_enrollment_state_by_year.R and
# artifacts/medicaid_enrollment_modal_vs_yearly.csv.
#
# CLASS B, NOT CLASS A. One file published 2026-07-24 describing years of
# history is retrospectively reported, not twelve independently dated
# observations, and 2013-2017 is additionally left-censored: no segment that
# closed before 2018-01-01 is in the file at all, so coverage in those years
# is survivorship. The states are sound; the coverage trend is not.
longi$medicaid_enrollment <- read_if(
  file.path(ART, "medicaid_enrollment_cohort_state_by_year.csv"), function()
  read_csv(file.path(ART, "medicaid_enrollment_cohort_state_by_year.csv"),
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year),
              state = clean_state(state)) %>%
    filter(!is.na(npi), !is.na(year), !is.na(state)) %>% keep_cohort() %>%
    distinct())
if (is.null(longi$medicaid_enrollment))
  note_missing("medicaid_enrollment",
               file.path(ART, "medicaid_enrollment_cohort_state_by_year.csv"),
               "run extract_medicaid_enrollment_state_by_year.R first")

snap <- snap[!vapply(snap, is.null, logical(1))]
for (n in names(snap)) cat(sprintf("  %-26s %6s NPIs\n", n, format(nrow(snap[[n]]), big.mark = ",")))

# ---------------------------------------------- 1. presence overlap, ALL sources
cat("\n[1] presence overlap across every source\n")
presence_sets <- c(
  lapply(longi, function(d) unique(d$npi)),
  lapply(snap,  function(d) unique(d$npi)))
# DOGE Medicaid provider spending by NDC (opendata.hhs.gov, 2026-07-24) -- the
# "medicaid-provider-spending" dataset, which is NOT the enrollment-segments
# file above. It carries BILLING_PROVIDER_NPI_NUM, PRESCRIBING_PROVIDER_NPI_NUM,
# an NDC, a claim month and dollars -- and NO state, confirmed against its
# parquet schema. So it can say she was dispensing-adjacent in a given month
# and nothing about where, which makes it a presence source and never a state
# source. Both NPI roles are kept separate: a midwife who PRESCRIBES is a
# different claim than a pharmacy that BILLS under her, and collapsing them
# would read 101 billing NPIs as 101 more prescribers.
MEDICAID_SPEND_REL <- file.path("doge_opendata", "medicaid_provider_spending_ndc_2026_07_24",
                                "medicaid-provider-spending-ndc.parquet")
local({
  p <- samsung_volume_path(MEDICAID_SPEND_REL, must_exist = FALSE)
  if (is.na(p)) { note_missing("medicaid_spending_ndc", MEDICAID_SPEND_REL, "Samsung volume not mounted"); return(invisible(NULL)) }
  con <- duckdb_connect(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "wanted", data.frame(npi = cohort_npis), overwrite = TRUE)
  roles <- c(medicaid_spending_prescriber = "PRESCRIBING_PROVIDER_NPI_NUM",
             medicaid_spending_biller     = "BILLING_PROVIDER_NPI_NUM")
  for (label in names(roles)) {
    hit <- DBI::dbGetQuery(con, sprintf(
      "SELECT DISTINCT w.npi FROM read_parquet(%s) s JOIN wanted w ON w.npi = trim(s.%s)",
      DBI::dbQuoteString(con, p), DBI::dbQuoteIdentifier(con, roles[[label]])))
    if (nrow(hit)) presence_sets[[label]] <<- hit$npi
  }
})

ov <- registry_overlap(presence_sets, id = "npi")
zones <- overlap_zone_counts(ov)   # errors if the zone counts do not close
cat(sprintf("  %s NPIs in >=1 source, %s distinct overlap zones\n",
            format(nrow(ov), big.mark = ","), format(nrow(zones), big.mark = ",")))

pres_by_src <- tibble(source = names(presence_sets),
                      n_npis = vapply(presence_sets, length, 1L)) %>%
  mutate(pct_of_cohort = round(100 * n_npis / length(cohort_npis), 1),
         tier = case_when(source %in% names(longi) ~ "longitudinal",
                          source %in% names(snap) ~ "snapshot",
                          TRUE ~ "presence_only")) %>%
  arrange(desc(n_npis))
print(as.data.frame(pres_by_src), row.names = FALSE)

write_with_provenance(pres_by_src, file.path(ART, "mrost_presence_by_source.csv"), inputs = COHORT, na = "")
write_with_provenance(zones, file.path(ART, "mrost_presence_overlap_zones.csv"), inputs = COHORT, na = "")

inventory <- bind_rows(
  tibble(source = names(longi), tier = "longitudinal",
         n_rows = vapply(longi, nrow, 1L),
         n_npis = vapply(longi, function(d) n_distinct(d$npi), 1L),
         year_min = vapply(longi, function(d) min(d$year), 1L),
         year_max = vapply(longi, function(d) max(d$year), 1L)),
  tibble(source = names(snap), tier = "snapshot",
         n_rows = vapply(snap, nrow, 1L),
         n_npis = vapply(snap, nrow, 1L),
         year_min = NA_integer_, year_max = NA_integer_))
write_with_provenance(inventory, file.path(ART, "mrost_source_inventory.csv"), inputs = COHORT, na = "")
if (nrow(unavailable))
  write_with_provenance(unavailable, file.path(ART, "mrost_sources_unavailable.csv"), inputs = COHORT, na = "")

# -------------------------------------------------- 2. coverage, by year
cat("\n[2] coverage by year (longitudinal sources)\n")
cov <- attribute_coverage(longi, "state")
cov_year <- cov$by_year
write_with_provenance(cov_year, file.path(ART, "mrost_coverage_by_year.csv"), inputs = COHORT, na = "")
print(head(as.data.frame(cov_year), 8), row.names = FALSE)

# -------------------------------------------------- 3. pairwise agreement
cat("\n[3] pairwise state agreement, longitudinal\n")
agr <- attribute_agreement(longi, "state")
agr_sum <- agr %>% group_by(source_a, source_b) %>%
  summarise(n_comparable = n(), n_agree = sum(agree), .groups = "drop") %>%
  mutate(pct_agree = round(100 * n_agree / n_comparable, 1)) %>%
  arrange(desc(n_comparable))
print(as.data.frame(agr_sum), row.names = FALSE)
write_with_provenance(agr_sum, file.path(ART, "mrost_agreement_pairwise.csv"), inputs = COHORT, na = "")

# -------------------------------- 4. current-snapshot agreement, ALL sources
cat("\n[4] current-state agreement across every source (latest year each)\n")
current <- c(
  lapply(longi, function(d) d %>% filter(year == max(year)) %>% transmute(npi, year = 1L, state)),
  lapply(snap,  function(d) d %>% transmute(npi, year = 1L, state)))
agr_now <- attribute_agreement(current, "state") %>%
  group_by(source_a, source_b) %>%
  summarise(n_comparable = n(), n_agree = sum(agree), .groups = "drop") %>%
  mutate(pct_agree = round(100 * n_agree / n_comparable, 1)) %>%
  arrange(desc(n_comparable))
print(as.data.frame(agr_now), row.names = FALSE)
write_with_provenance(agr_now, file.path(ART, "mrost_agreement_current_snapshot.csv"), inputs = COHORT, na = "")

# -------------------------------------------------- 5. corroboration + outlier
cat("\n[5] corroboration and odd-one-out\n")
corr <- attribute_source_corroboration(longi, "state")
print(as.data.frame(corr), row.names = FALSE)
write_with_provenance(corr, file.path(ART, "mrost_corroboration.csv"), inputs = COHORT, na = "")

if (length(current) >= 3) {
  ooo_rate <- attribute_odd_one_out_rate(attribute_odd_one_out(current, "state"))
  print(as.data.frame(ooo_rate), row.names = FALSE)
  write_with_provenance(ooo_rate, file.path(ART, "mrost_odd_one_out_rate.csv"), inputs = COHORT, na = "")
}

tier <- attribute_consensus_tier(current, "state")
tier_sum <- tier %>% count(tier, name = "n_npis") %>%
  mutate(pct = round(100 * n_npis / sum(n_npis), 1))
print(as.data.frame(tier_sum), row.names = FALSE)
write_with_provenance(tier_sum, file.path(ART, "mrost_consensus_tier.csv"), inputs = COHORT, na = "")

# THE PER-NPI TIER IS KEPT, not just its tally. It was computed here and
# discarded, which meant any analysis asking "who disagrees, and what else is
# true of them?" had to recompute it from scratch or go without -- the licence
# -count cross-tabulation in the state-source audit vignette went without, and
# its figure became unreproducible when the intermediate was lost. Writing the
# per-NPI assignment costs one line and makes that class of question answerable
# from a tracked artifact. Carries no name, address or date of birth: an NPI is
# a public provider identifier, and the tier is derived from public sources.
# attribute_consensus_tier() names the entity column `id`, not `npi`; it is
# renamed on the way out so the artifact joins to every other mrost table
# without the caller having to know that. The agreement detail is kept too --
# how many sources reported, how many distinct values they gave, and the
# concordance percentage -- because a tier label alone cannot distinguish
# "two sources, one disagreed" from "seven sources, three disagreed".
write_with_provenance(
  tier %>%
    transmute(npi = as.character(id), year, n_reporting, n_distinct_values,
              concordance_pct, tier) %>%
    arrange(npi),
  file.path(ART, "mrost_consensus_tier_by_npi.csv"),
  inputs = COHORT, na = "")

# -------------------------------------------------- 6. churn per source
cat("\n[6] churn: how often each source's own value flips\n")
churn <- bind_rows(lapply(names(longi), function(n) {
  d <- longi[[n]]
  if (n_distinct(d$year) < 2) return(NULL)
  o <- attribute_churn_rate(d, "state")$overall
  tibble(source = n, n_transitions = o$n_transitions, n_changed = o$n_changed,
         pct = o$pct, ci_low = o$ci_low, ci_high = o$ci_high)
}))
print(as.data.frame(churn), row.names = FALSE)
write_with_provenance(churn, file.path(ART, "mrost_churn_by_source.csv"), inputs = COHORT, na = "")

# -------------------------------------------------- 7. lead / lag vs NPPES
cat("\n[7] lead/lag against NPPES\n")
ll <- bind_rows(lapply(setdiff(names(longi), "nppes"), function(n) {
  r <- tryCatch(attribute_lead_lag_matrix(longi$nppes, longi[[n]], "state"),
                error = function(e) NULL)
  if (is.null(r)) return(NULL)
  r$source_b <- n; r
}))
if (nrow(ll)) {
  print(as.data.frame(ll[, c("source_b", "n_paired_transitions", "n_discordant_at_t",
                             "b_adopts_a_at_t1_pct", "a_reverts_to_b_at_t1_pct",
                             "persistent_discordant_at_t1_pct")]), row.names = FALSE)
  write_with_provenance(ll, file.path(ART, "mrost_lead_lag.csv"), inputs = COHORT, na = "")
}

# -------------------------------------------------- 8. truth fusion
cat("\n[8] truth fusion (majority) vs each source\n")
claims <- bind_rows(lapply(names(current), function(n)
  current[[n]] %>% transmute(entity_id = npi, attribute = "state", source_id = n,
                             claimed_value = state, reference_year = 2026L)))
fus <- tryCatch(attribute_truth_fusion(claims, method = "majority"), error = function(e) {
  cat("  truth fusion failed:", conditionMessage(e), "\n"); NULL })
if (!is.null(fus)) {
  # Abstentions are rows where majority could not pick a value at all. Scoring
  # a source against an abstention would be scoring it against nothing, so
  # they are dropped here and counted in the log instead.
  fv <- fus$predictions %>% filter(!abstained) %>%
    transmute(entity_id, fused = predicted_value)
  cat(sprintf("  fused %s entities (%s abstained and excluded)\n",
              format(nrow(fv), big.mark = ","),
              format(sum(fus$predictions$abstained), big.mark = ",")))
  agree_fus <- bind_rows(lapply(names(current), function(n)
    current[[n]] %>% transmute(entity_id = npi, state) %>%
      inner_join(fv, by = "entity_id") %>%
      summarise(source = n, n_comparable = n(),
                n_agree = sum(state == fused, na.rm = TRUE)) )) %>%
    mutate(pct_agree_with_fused = round(100 * n_agree / n_comparable, 1)) %>%
    arrange(desc(pct_agree_with_fused))
  print(as.data.frame(agree_fus), row.names = FALSE)
  write_with_provenance(agree_fus, file.path(ART, "mrost_truth_fusion_agreement.csv"),
                        inputs = COHORT, na = "")
}

cat("\nDone.\n")
