#!/usr/bin/env Rscript
# =============================================================================
# How wrong can the rurality distribution be, given who failed to link?
# =============================================================================
# THE PROBLEM THIS ADDRESSES IS THE STUDY'S BINDING LIMITATION, not a data
# quality nuisance. Geography exists only for certificants in the primary
# matched cohort, 14,764 of 22,309 (66.2%), of whom 14,701 carry a usable
# county. Linkage is not missing at random and is not close to it:
#
#     ACTIVE    78.4%        DECEASED  18.8%
#     LAPSED    39.6%        RETIRED   46.1%
#
# Every geographic statement in this project therefore describes the LOCATED
# workforce. Whether it also describes the workforce depends on how the 7,545
# unlinked certificants are distributed across rurality, and that is precisely
# what cannot be observed -- their geography is missing because they did not
# link.
#
# The ten scientific laws cannot see this. A differentially incomplete linkage
# is perfectly self-consistent: the parts sum to their whole, no share exceeds
# its denominator, the computation is deterministic, and every input has a
# declared vintage. L2 through L10 would all pass on a cohort that had silently
# become a sample of the easy-to-find. That is the gap this fills.
#
# WHAT IS PRODUCED, in increasing order of assumption:
#
#   1. MANSKI WORST-CASE BOUNDS. No assumptions at all. The unlinked are placed
#      entirely inside, then entirely outside, each rurality category. The truth
#      is inside these bounds whatever the missingness mechanism. They are wide
#      by construction; that width IS the finding, and reporting a point
#      estimate without it is the error this file exists to prevent.
#
#   2. BOUNDS ON THE ACTIVE POPULATION. A narrower question with a tighter
#      answer: workforce claims are about practising midwives, and ACTIVE
#      certificants link at 78.4% against 66.2% for the roster.
#
#      NOT status-standardized bounds, which was the first attempt here and is
#      pointless. Standardizing the worst case by status returns the overall
#      worst case exactly -- the extreme is attainable inside every stratum at
#      once, so reweighting the same strata by the same sizes cannot move it.
#      It shipped as a column identical to (1) by construction.
#
#   3. INVERSE-PROBABILITY WEIGHTING under missing-at-random given status. A
#      point estimate, valid only if status explains the missingness. It almost
#      certainly does not explain all of it, so this is reported as a
#      sensitivity, never as a correction.
#
#   4. TIPPING POINT. How different from the linked would the unlinked have to
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
  library(dplyr); library(readr); library(tidyr); library(readxl)
})

source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

LINK <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
GEO  <- file.path("artifacts", "midwives_geography_FROZEN.csv")
RUCC <- file.path("data", "rucc_2023.xlsx")
OUT  <- file.path("artifacts", "linkage_selection_bounds.csv")

for (f in c(LINK, GEO, RUCC)) if (!file.exists(f))
  stop(sprintf(paste0("%s is absent. This analysis needs the person-level roster ",
                      "and geography, which are gitignored by design; it runs ",
                      "where the pipeline has been run, not on a bare checkout."), f),
       call. = FALSE)

message("Reading the roster.")
link <- read_csv(LINK, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = col_character()))
message("Roster rows: ", format(nrow(link), big.mark = ","))

message("Reading geography for the linked subset.")
geo <- read_csv(GEO, show_col_types = FALSE, progress = FALSE,
                col_types = cols(.default = col_character()))

message("Reading the RUCC vintage.")
rucc_raw <- readxl::read_excel(RUCC)
fips_col <- grep("fips", names(rucc_raw), ignore.case = TRUE, value = TRUE)[1]
code_col <- grep("^rucc", names(rucc_raw), ignore.case = TRUE, value = TRUE)[1]
if (is.na(fips_col) || is.na(code_col))
  stop("The RUCC file does not carry a FIPS and a RUCC column.", call. = FALSE)
lookup <- build_rucc_lookup(rucc_raw[[fips_col]], rucc_raw[[code_col]])

# --- one row per certificant, with rurality where it exists ------------------
# LEFT JOIN FROM THE ROSTER, never an inner join. The unlinked are the subject
# of this analysis; an inner join would silently delete them and reproduce the
# very bias being measured.
# WHICH "LINKED" IS THE RIGHT ONE, and the first version of this got it wrong.
# Geography exists for 16,898 certificants -- 14,764 `matched` plus 2,134
# `matched_nursing_taxonomy`. The second group is deliberately held OUT of the
# primary cohort by the cross-taxonomy rule: a nursing-only match is never
# promoted into it. Counting them as linked made linkage look like 75.4%
# instead of 66.2% and produced bounds a fifth too narrow.
#
# The bounds must describe the estimate that was actually published, so the
# observed set is the primary matched cohort and nothing else.
PRIMARY <- "matched"

d <- link |>
  select(certification_number, status, npi_match_status) |>
  distinct(certification_number, .keep_all = TRUE) |>
  left_join(geo |>
              select(certification_number, county_best) |>
              distinct(certification_number, .keep_all = TRUE),
            by = "certification_number") |>
  mutate(county = ifelse(is.na(county_best), NA_character_,
                         sprintf("%05s", trimws(county_best)))) |>
  left_join(lookup, by = "county") |>
  mutate(rurality = band_rurality(rucc),
         in_primary = .data$npi_match_status == PRIMARY,
         # Observed means: in the published cohort AND carrying a usable
         # rurality. A primary match whose county never resolved is unobserved
         # for this purpose, because its rurality is exactly what is missing.
         linked = .data$in_primary & !is.na(.data$rurality),
         rurality = ifelse(.data$linked, .data$rurality, NA_character_))

if (nrow(d) != nrow(distinct(link, certification_number)))
  stop("INVARIANT: the joins changed the roster size.", call. = FALSE)

# --- reconcile with the published completeness table -------------------------
# This analysis must not invent its own linkage rate. If the per-status matched
# counts here disagree with artifacts/linkage_completeness_by_status.csv, one of
# the two is describing a different population and the bounds would be built on
# sand.
comp_path <- file.path("artifacts", "linkage_completeness_by_status.csv")
if (file.exists(comp_path)) {
  comp <- read_csv(comp_path, show_col_types = FALSE, progress = FALSE)
  mine <- d |> filter(.data$in_primary) |> count(status, name = "mine")
  cmp <- comp |> select(status, matched) |> left_join(mine, by = "status") |>
    mutate(mine = tidyr::replace_na(.data$mine, 0L),
           gap = .data$mine - .data$matched)
  if (any(cmp$gap != 0)) {
    print(as.data.frame(cmp[cmp$gap != 0, ]), row.names = FALSE)
    stop("INVARIANT: the primary-match counts here disagree with the published completeness table. The two are describing different populations.",
         call. = FALSE)
  }
  message("Reconciled with linkage_completeness_by_status.csv on all ",
          nrow(cmp), " statuses.")
}

n_roster <- nrow(d)
n_linked <- sum(d$linked)
message(sprintf("Certificants: %s   with rurality: %s (%.1f%%)",
                format(n_roster, big.mark = ","), format(n_linked, big.mark = ","),
                100 * n_linked / n_roster))

CATS <- sort(unique(stats::na.omit(d$rurality)))

# --- 1 & 2. bounds, overall and status-standardized --------------------------
# The bound is arithmetic, not a model: of N certificants, k are observed in
# category c and (N - n_obs) are unobserved. The true count is at least k and at
# most k + unobserved.
bounds_for <- function(df) {
  n <- nrow(df); obs <- sum(df$linked); unobs <- n - obs
  vapply(CATS, function(cc) {
    k <- sum(df$rurality == cc, na.rm = TRUE)
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
#
# What DOES tighten the bound is asking a narrower question. Workforce claims
# are about practising midwives, and ACTIVE certificants link far better than
# the roster as a whole, so bounds on the ACTIVE population are materially
# narrower while answering the question a reader usually means.
d_active <- d |> filter(.data$status == "ACTIVE")
act <- bounds_for(d_active)

# --- 3. IPW under MAR given status -------------------------------------------
# Each linked certificant stands in for 1 / P(linked | status) roster members.
# Valid only if status captures the missingness; it does not capture all of it,
# which is why this sits beside the bounds rather than replacing them.
ipw <- d |>
  group_by(status) |>
  mutate(p_link = mean(linked)) |>
  ungroup() |>
  filter(linked, p_link > 0) |>
  count(rurality, wt = 1 / p_link, name = "wsum") |>
  mutate(ipw_pct = 100 * wsum / sum(wsum))

# --- 4. tipping point --------------------------------------------------------
# Solve for the unlinked share u that moves the roster-wide value to a threshold
# t:  (k + u * unobs) / N = t/100.  Reported as the departure from the observed
# linked share, in percentage points, because "how different would they have to
# be" is the question a reader actually has.
tipping <- function(cc, threshold_pct) {
  k <- sum(d$rurality == cc, na.rm = TRUE)
  unobs <- n_roster - n_linked
  u <- (threshold_pct / 100 * n_roster - k) / unobs
  obs_pct <- 100 * k / n_linked
  c(required_unlinked_pct = 100 * u, departure_pp = 100 * u - obs_pct)
}

METRO <- grep("^Metro", CATS, value = TRUE)[1]
tip <- if (!is.na(METRO)) tipping(METRO, 75) else c(NA_real_, NA_real_)

# --- assemble ----------------------------------------------------------------
res <- lapply(CATS, function(cc) {
  data.frame(
    rurality = cc,
    n_linked_in_cat = sum(d$rurality == cc, na.rm = TRUE),
    n_linked = n_linked,
    n_roster = n_roster,
    observed_pct = overall["observed_pct", cc],
    manski_lower_pct = overall["lower_pct", cc],
    manski_upper_pct = overall["upper_pct", cc],
    active_observed_pct = act["observed_pct", cc],
    active_lower_pct = act["lower_pct", cc],
    active_upper_pct = act["upper_pct", cc],
    ipw_pct = ipw$ipw_pct[match(cc, ipw$rurality)],
    stringsAsFactors = FALSE)
}) |> bind_rows() |>
  mutate(bound_width_pp = .data$manski_upper_pct - .data$manski_lower_pct)

message("\n--- selection bounds on the rurality distribution ---")
print(as.data.frame(res |>
  mutate(across(where(is.numeric), ~round(.x, 1)))), row.names = FALSE)

if (!is.na(tip[1]))
  message(sprintf(paste0("\nTipping point: for the roster-wide %s share to fall to 75%%, ",
                         "the %s unlinked\ncertificants would have to be %.1f%% %s -- a departure of ",
                         "%.1f points from the\n%.1f%% observed among the linked."),
                  METRO, format(n_roster - n_linked, big.mark = ","),
                  tip[1], METRO, tip[2],
                  overall["observed_pct", METRO]))

write_with_provenance(res, OUT, inputs = c(LINK, GEO, RUCC))
message("\nwritten: ", OUT)

# The status-level linkage table this rests on, so a reader can see the
# mechanism rather than take the bounds on faith.
by_st <- d |>
  group_by(status) |>
  summarise(n = n(), linked = sum(linked), .groups = "drop") |>
  mutate(pct_linked = round(100 * linked / n, 1)) |>
  arrange(desc(n))
message("\n--- linkage by certification status ---")
print(as.data.frame(by_st), row.names = FALSE)
