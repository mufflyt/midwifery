#!/usr/bin/env Rscript
# =============================================================================
# How wrong can the rurality distribution be, given who is not in the cohort?
# =============================================================================
# THE PROBLEM THIS ADDRESSES IS THE STUDY'S BINDING LIMITATION, not a data
# quality nuisance. The published cohort is 16,892 of 22,309 certificants, and
# it is not a random sample of the roster: cohort membership runs from 84.6% of
# ACTIVE certificants down to 35.5% of DECEASED ones, and the share with an
# assignable county from 77.2% down to 19.8%.
#
# Every geographic statement in this project therefore describes the LOCATED
# workforce. Whether it also describes the workforce depends on how the
# certificants with no assignable county are distributed across rurality.
#
# THE BOUNDS MUST BRACKET THE ESTIMATE THAT WAS ACTUALLY PUBLISHED, and the
# first version of this file did not. It rebuilt rurality from `county_best` in
# midwives_geography_FROZEN.csv -- the GEOCODED county -- and defined the cohort
# as npi_match_status == "matched". The published composition does neither. It
# comes from R/07-cohort-composition.R, which derives rurality from the practice
# ZIP through the Census ZCTA-county crosswalk precisely so that it is
# "observable regardless of geocoding success", and it reports the analytic
# cohort, not the primary-match subset. The two disagreed by 160 people and
# anchored the interval on 89.8% when the published figure rests on 13,277 of
# 14,861. An interval whose endpoints are arithmetic on a population the paper
# never reports is not a bound on the paper's number.
#
# So the rurality assignment here is the published one, helper for helper, and
# an invariant below refuses to write anything unless it reproduces
# composition_rucc_cat.csv exactly.
#
# WHAT IS PRODUCED, in increasing order of assumption:
#
#   1. MANSKI WORST-CASE BOUNDS. No assumptions at all. The certificants with no
#      assignable county are placed entirely inside, then entirely outside, each
#      rurality category. The truth is inside these bounds whatever the
#      missingness mechanism. They are wide by construction; that width IS the
#      finding, and reporting a point estimate without it is the error this file
#      exists to prevent.
#
#   2. THE SAME BOUND USING WHAT IS ACTUALLY OBSERVED OUTSIDE THE COHORT. Also
#      assumption-free, and narrower, because rurality is NOT missing for
#      everyone outside the cohort. 1,358 of the 5,417 non-cohort certificants
#      carry a practice ZIP that resolves to a county, and discarding them to
#      preserve a tidy "linked versus unlinked" story would be throwing away
#      evidence in order to report a wider interval. Their metropolitan share is
#      reported beside the cohort's, because whether they resemble it is the
#      single most informative fact available about the missingness.
#
#   3. BOUNDS ON THE ACTIVE POPULATION. A narrower question with a tighter
#      answer: workforce claims are about practising midwives.
#
#      NOT status-standardized bounds, which was the first attempt here and is
#      pointless. Standardizing the worst case by status returns the overall
#      worst case exactly -- the extreme is attainable inside every stratum at
#      once, so reweighting the same strata by the same sizes cannot move it.
#      It shipped as a column identical to (1) by construction.
#
#   4. INVERSE-PROBABILITY WEIGHTING under missing-at-random given status. A
#      point estimate, valid only if status explains the missingness. It almost
#      certainly does not explain all of it, so this is reported as a
#      sensitivity, never as a correction.
#
#   5. TIPPING POINT. How different from the cohort would the unobserved have to
#      be, in percentage points, to move the headline conclusion? A conclusion
#      that survives an implausible departure is robust; one that breaks under a
#      small departure is not, and the number says which.
#
# NOTHING HERE CHANGES A PUBLISHED ESTIMATE. It states how far a published
# estimate could be from the quantity it is taken to describe.
#
# Person-level inputs are gitignored and are not redistributed. The written
# artifact is aggregate: counts and percentages by status and rurality.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr)
})

# The published rurality assignment, helper for helper. band_rurality with
# RURALITY_LABELS_COHORT and zip_county_dominant are the same functions
# R/07-cohort-composition.R calls; reimplementing either here is how the two
# artifacts drifted apart the first time.
source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "zip_county_crosswalk.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

ART <- "artifacts"; DATA <- "data"
LINK   <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")
STAGE2 <- file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")
COHORT <- file.path(ART, "frozen_cohort", "analytic_cohort.csv")
ZCTA   <- file.path(DATA, "zcta_county_2020.txt")
CBASE  <- file.path(DATA, "county_base.csv")
OUT    <- file.path(ART, "linkage_selection_bounds.csv")

for (f in c(LINK, STAGE2, COHORT, ZCTA, CBASE)) if (!file.exists(f))
  stop(sprintf(paste0("%s is absent. This analysis needs the person-level roster ",
                      "and the frozen cohort, which are gitignored by design; it ",
                      "runs where the pipeline has been run, not on a bare checkout."), f),
       call. = FALSE)

message("Reading the roster.")
link <- chr(LINK) |> distinct(certification_number, .keep_all = TRUE)
message("Roster rows: ", format(nrow(link), big.mark = ","))

message("Reading the frozen Stage-2 characteristics and the published cohort.")
s2  <- chr(STAGE2) |> distinct(certification_number, .keep_all = TRUE)
coh <- chr(COHORT)

message("Reading the ZIP-county crosswalk and the county RUCC base.")
zc <- zip_county_dominant(ZCTA)
cb <- read_csv(CBASE, show_col_types = FALSE, col_types = cols(GEOID = col_character()))

# --- one row per certificant, with rurality where the ZIP resolves ------------
# LEFT JOIN FROM THE ROSTER, never an inner join. The certificants outside the
# cohort are the subject of this analysis; an inner join would silently delete
# them and reproduce the very bias being measured.
d <- link |>
  select(certification_number, status) |>
  left_join(s2 |> select(certification_number, practice_zip, s2_npi = npi),
            by = "certification_number") |>
  mutate(zip5 = zip5_key(practice_zip)) |>
  left_join(zc, by = "zip5", relationship = "many-to-one") |>
  left_join(select(cb, GEOID, rucc_2023), by = "GEOID", relationship = "many-to-one") |>
  mutate(rurality  = band_rurality(rucc_2023, RURALITY_LABELS_COHORT),
         in_cohort = .data$certification_number %in% coh$certification_number,
         # Observed means: in the published cohort AND carrying a usable
         # rurality. A cohort member whose ZIP never resolved is unobserved for
         # this purpose, because its rurality is exactly what is missing.
         linked = .data$in_cohort & !is.na(.data$rurality))

if (nrow(d) != nrow(distinct(link, certification_number)))
  stop("INVARIANT: the joins changed the roster size.", call. = FALSE)

# --- reconcile with the published composition --------------------------------
# This analysis must not invent its own rurality distribution. The published
# 86.5% is the RETAINED group of the four-way composition -- certificants that
# were in Stage 2 with an NPI and survived into the final cohort -- so that
# group is reconstructed here and compared cell by cell. If a single count
# disagrees, the bounds would be arithmetic on a population the paper does not
# report, which is the exact defect this rewrite exists to remove.
comp_path <- file.path(ART, "composition_rucc_cat.csv")
retained <- intersect(s2$certification_number[!is.na(s2$npi)], coh$certification_number)
if (file.exists(comp_path)) {
  comp <- read_csv(comp_path, show_col_types = FALSE, progress = FALSE) |>
    filter(.data$group == "1_retained") |>
    select(level, published_n = n)
  mine <- d |>
    filter(.data$certification_number %in% retained) |>
    count(level = coalesce(.data$rurality, "Unknown"), name = "mine")
  cmp <- full_join(comp, mine, by = "level") |>
    mutate(across(c(published_n, mine), ~ tidyr::replace_na(.x, 0L)),
           gap = .data$mine - .data$published_n)
  if (any(cmp$gap != 0)) {
    print(as.data.frame(cmp), row.names = FALSE)
    stop("INVARIANT: the rurality counts here disagree with composition_rucc_cat.csv. The two are describing different populations, and the bounds would not bracket the published estimate.",
         call. = FALSE)
  }
  message("Reconciled with composition_rucc_cat.csv on all ", nrow(cmp),
          " rurality cells of the retained group.")
}

n_roster <- nrow(d)
n_linked <- sum(d$linked)
message(sprintf("Certificants: %s   in cohort with rurality: %s (%.1f%%)",
                format(n_roster, big.mark = ","), format(n_linked, big.mark = ","),
                100 * n_linked / n_roster))

CATS <- sort(unique(stats::na.omit(d$rurality)))

# --- 1 & 3. bounds, overall and among ACTIVE certificants --------------------
# The bound is arithmetic, not a model: of N certificants, k are observed in
# category c and (N - n_obs) are unobserved. The true count is at least k and at
# most k + unobserved.
bounds_for <- function(df, flag = "linked") {
  n <- nrow(df); obs <- sum(df[[flag]]); unobs <- n - obs
  vapply(CATS, function(cc) {
    k <- sum(df$rurality == cc & df[[flag]], na.rm = TRUE)
    c(observed_pct = if (obs > 0) 100 * k / obs else NA_real_,
      lower_pct = 100 * k / n,
      upper_pct = 100 * (k + unobs) / n)
  }, numeric(3))
}

overall <- bounds_for(d)

# ACTIVE ONLY, which is a different question and a tighter answer. Standardizing
# the worst case by status returns the overall worst case exactly -- the extreme
# is attainable inside every stratum at once, so reweighting the same strata by
# the same sizes changes nothing. That is arithmetic, not a modelling choice,
# and the first version of this file reported it as a separate column that was
# identical to the first by construction.
act <- bounds_for(d |> filter(.data$status == "ACTIVE"))

# --- 2. the same bound, not discarding what is observed outside the cohort ----
# Rurality is missing because a ZIP did not resolve, NOT because a certificant
# failed to enter the cohort. Those are different events, and conflating them
# throws away the 1,358 non-cohort certificants whose county IS known. The
# worst-case bound over everyone with an assignable county is still
# assumption-free and is strictly narrower, so reporting only the cohort-anchored
# pair would be overstating the ignorance.
d <- d |> mutate(zip_observed = !is.na(.data$rurality))
zipb <- bounds_for(d, "zip_observed")
n_zip <- sum(d$zip_observed)

# --- 4. IPW under MAR given status -------------------------------------------
# Each observed certificant stands in for 1 / P(observed | status) roster
# members. Valid only if status captures the missingness; it does not capture
# all of it, which is why this sits beside the bounds rather than replacing them.
ipw <- d |>
  group_by(status) |>
  mutate(p_link = mean(linked)) |>
  ungroup() |>
  filter(linked, p_link > 0) |>
  count(rurality, wt = 1 / p_link, name = "wsum") |>
  mutate(ipw_pct = 100 * wsum / sum(wsum))

# --- 5. tipping point --------------------------------------------------------
# Solve for the unobserved share u that moves the roster-wide value to a
# threshold t:  (k + u * unobs) / N = t/100.  Reported as the departure from the
# observed cohort share, in percentage points, because "how different would they
# have to be" is the question a reader actually has.
tipping <- function(cc, threshold_pct) {
  k <- sum(d$rurality == cc & d$linked, na.rm = TRUE)
  unobs <- n_roster - n_linked
  u <- (threshold_pct / 100 * n_roster - k) / unobs
  c(required_unobserved_pct = 100 * u, departure_pp = 100 * u - 100 * k / n_linked)
}

METRO <- grep("^Metro", CATS, value = TRUE)[1]
TIP_THRESHOLD <- 75
tip <- if (!is.na(METRO)) tipping(METRO, TIP_THRESHOLD) else c(NA_real_, NA_real_)

# --- what the unobserved look like, for the quarter of them that is visible ---
# WHETHER THE UNOBSERVED RESEMBLE THE COHORT is the question the bounds cannot
# answer and this can, for the non-cohort certificants whose ZIP does resolve.
# It is the only direct evidence about the direction of the selection, so it is
# written into the artifact rather than printed and lost: a number the
# manuscript reports must be generated, not read off a console log.
outside <- d |> filter(!in_cohort, zip_observed)
outside_pct <- vapply(CATS, function(cc)
  100 * sum(outside$rurality == cc) / nrow(outside), numeric(1))

# --- assemble ----------------------------------------------------------------
# n_cohort_all is the denominator the manuscript prints against: the retained
# group INCLUDING its no-assignable-county members. It is carried so that the
# published 86.5% is derivable from this artifact rather than from a second one
# with a different definition, which is how the two drifted apart before.
n_cohort_all <- length(retained)
res <- lapply(CATS, function(cc) {
  k <- sum(d$rurality == cc & d$linked, na.rm = TRUE)
  data.frame(
    rurality = cc,
    n_linked_in_cat = k,
    n_linked = n_linked,
    n_roster = n_roster,
    n_cohort_all = n_cohort_all,
    published_pct_with_unknown = 100 * k / n_cohort_all,
    observed_pct = overall["observed_pct", cc],
    manski_lower_pct = overall["lower_pct", cc],
    manski_upper_pct = overall["upper_pct", cc],
    n_zip_observed = n_zip,
    zip_observed_pct = zipb["observed_pct", cc],
    zip_lower_pct = zipb["lower_pct", cc],
    zip_upper_pct = zipb["upper_pct", cc],
    active_observed_pct = act["observed_pct", cc],
    active_lower_pct = act["lower_pct", cc],
    active_upper_pct = act["upper_pct", cc],
    ipw_pct = ipw$ipw_pct[match(cc, ipw$rurality)],
    n_outside_observed = nrow(outside),
    outside_observed_pct = outside_pct[[cc]],
    outside_minus_cohort_pp = outside_pct[[cc]] - overall["observed_pct", cc],
    # The tipping point is a question about ONE category against ONE threshold,
    # so it is populated for that category and left NA elsewhere rather than
    # invented for the others. A column of plausible numbers nobody asked for is
    # how a reader ends up quoting the tipping point for remote counties.
    tipping_threshold_pct = if (identical(cc, METRO)) TIP_THRESHOLD else NA_real_,
    tipping_required_unobserved_pct = if (identical(cc, METRO)) tip[[1]] else NA_real_,
    tipping_departure_pp = if (identical(cc, METRO)) tip[[2]] else NA_real_,
    stringsAsFactors = FALSE)
}) |> bind_rows() |>
  mutate(bound_width_pp = .data$manski_upper_pct - .data$manski_lower_pct,
         zip_bound_width_pp = .data$zip_upper_pct - .data$zip_lower_pct)

message("\n--- selection bounds on the rurality distribution ---")
print(as.data.frame(res |>
  select(rurality, observed_pct, manski_lower_pct, manski_upper_pct,
         zip_lower_pct, zip_upper_pct, active_lower_pct, active_upper_pct,
         ipw_pct) |>
  mutate(across(where(is.numeric), ~round(.x, 1)))), row.names = FALSE)

if (!is.na(tip[1]))
  message(sprintf(paste0("\nTipping point: for the roster-wide %s share to fall to 75%%, ",
                         "the %s certificants\nwith no assignable county would have to be %.1f%% %s -- a departure of ",
                         "%.1f points\nfrom the %.1f%% observed in the cohort."),
                  METRO, format(n_roster - n_linked, big.mark = ","),
                  tip[1], METRO, tip[2],
                  overall["observed_pct", METRO]))

write_with_provenance(res, OUT, inputs = c(LINK, STAGE2, COHORT, ZCTA, CBASE))
message("\nwritten: ", OUT)

# The status-level table this rests on, so a reader can see the mechanism
# rather than take the bounds on faith.
by_st <- d |>
  group_by(status) |>
  summarise(n = n(), in_cohort = sum(in_cohort), linked = sum(linked),
            .groups = "drop") |>
  mutate(pct_in_cohort = round(100 * in_cohort / n, 1),
         pct_linked = round(100 * linked / n, 1)) |>
  arrange(desc(n))
message("\n--- cohort membership and observed rurality by certification status ---")
print(as.data.frame(by_st), row.names = FALSE)

message(sprintf("\n--- rurality of the %s NON-COHORT certificants whose ZIP does resolve ---",
                format(nrow(outside), big.mark = ",")))
print(as.data.frame(outside |> count(rurality, name = "n") |>
  mutate(pct = round(100 * n / sum(n), 1),
         cohort_pct = round(overall["observed_pct", rurality], 1),
         diff_pp = round(pct - cohort_pct, 1))), row.names = FALSE)
