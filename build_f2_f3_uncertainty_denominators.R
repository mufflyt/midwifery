#!/usr/bin/env Rscript
# =============================================================================
# F2 clustered uncertainty + F3 persistence denominators (spec §8)
# =============================================================================
# The pairwise agreement statistics report Wilson intervals, which assume the
# NPI-years are independent Bernoulli trials. They are not: the same midwife
# appears in up to 14 cells, and her agreement behaviour is serially
# correlated, so Wilson understates the width. F2 reports a CLUSTER bootstrap
# -- resample midwives (clusters), not NPI-years (trials) -- alongside the
# Wilson bounds so the gap between the two assumptions is printed, not just
# asserted.
#
# SCOPE IS THE WHOLE POINT, and this script got it wrong until 2026-11-21.
# The bootstrap used to run inside group_by(source, year). Within one
# source-year `agree_cell` holds exactly one row per NPI, so every cluster was
# a singleton, resampling them reproduced the i.i.d. bootstrap, and the
# printed interval was Wilson's assumption a second time (n_npi_years ==
# n_npis in all 30 rows; boot_width averaged 0.98x wilson_width -- narrower,
# where a positive intracluster correlation must make it wider).
#
# A midwife is only in several cells once years are POOLED, so the clustered
# interval is reported at scope = "pooled", one row per source, where a
# cluster carries up to 14 NPI-years. The per-year rows keep Wilson and
# withhold the bootstrap columns rather than print a singleton resample.
#
# F3 is the denominator problem the lead/lag table could not see: a midwife
# observed in a source at year t but NOT at t+1 was silently dropped from
# every transition count, making attrition indistinguishable from
# persistence. Here each source-year reports who was observed, who was
# followed (observed again in that source at t+1), who was lost from the
# source but still visible in NPPES (source attrition, not workforce exit),
# and among the followed who kept the same state.
#
# REFERENCES (rOpenSci statistical standard G1.0). Attributed separately
# because the three pieces of this method come from three places, and the
# percentile interval in particular is NOT from the 1979 paper.
#
#   Efron, B. (1979). Bootstrap methods: another look at the jackknife.
#   The Annals of Statistics 7(1), 1-26. doi:10.1214/aos/1176344552
#     -- the bootstrap principle: resample the observed units with
#     replacement and recompute the statistic.
#
#   Efron, B. & Tibshirani, R. J. (1993). An Introduction to the Bootstrap.
#   Chapman & Hall, Monographs on Statistics and Applied Probability 57.
#   ISBN 0-412-04231-2.
#     -- the PERCENTILE interval, which is what quantile(reps, c(.025, .975))
#     below computes. It is a deliberately plain choice: no bias correction
#     or acceleration (BCa), so the bounds are the empirical quantiles of the
#     replicate distribution and nothing more.
#
#   Field, C. A. & Welsh, A. H. (2007). Bootstrapping clustered data.
#   Journal of the Royal Statistical Society Series B 69(3), 369-390.
#   doi:10.1111/j.1467-9868.2007.00593.x
#     -- resampling CLUSTERS rather than observations, which is the whole
#     point of the pooled scope below: a midwife, not an NPI-year, is the
#     independent unit. It also sets out why the variance estimate depends on
#     which level you resample, which is the error this script made until
#     2026-11-21 by resampling inside a source-year where every cluster has
#     one member.
#
# Input : artifacts/canonical_source_records.csv (build_canonical_source_records.R)
# Output: artifacts/agreement_cluster_bootstrap_ci.csv
#         artifacts/persistence_denominators.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})
source(file.path("R", "lib", "wilson_interval.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

set.seed(20261114)
B <- 400L

records <- read_csv("artifacts/canonical_source_records.csv",
                    col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(year = as.integer(year),
         usable_for_trend = usable_for_trend == "TRUE") %>%
  filter(usable_for_trend)

nppes <- records %>% filter(source == "nppes") %>%
  group_by(npi, year) %>% summarise(nppes_state = first(state), .groups = "drop")
sources <- setdiff(unique(records$source), "nppes")

## ---- F2: cluster bootstrap over NPIs ---------------------------------------
# Agreement is per NPI-year and set-valued on the source side: an NPI with
# several states in a source-year agrees if ANY of them equals the NPPES
# state (the estimand the audit uses, not an arbitrary modal pick).
agree_cell <- records %>%
  filter(source != "nppes") %>%
  left_join(nppes, by = c("npi", "year")) %>%
  filter(!is.na(nppes_state)) %>%
  group_by(source, npi, year) %>%
  summarise(agree = any(state == nppes_state), .groups = "drop")

boot_ci <- function(agree_vec, npi_vec, B) {
  # RATIO ESTIMATOR, not a mean of per-NPI means. pct_agree is an NPI-year
  # mean, so each resampled cluster must contribute its years to BOTH the
  # numerator and the denominator; averaging within-cluster means instead
  # silently reweights every midwife equally and targets a different quantity
  # than the point estimate the interval is printed beside.
  n_by <- tapply(agree_vec, npi_vec, length)
  k_by <- tapply(agree_vec, npi_vec, sum)
  k <- length(n_by)
  if (k < 5) return(c(NA_real_, NA_real_))
  reps <- replicate(B, {
    i <- sample.int(k, k, replace = TRUE)
    sum(k_by[i]) / sum(n_by[i])
  })
  unname(quantile(reps, c(0.025, 0.975), na.rm = TRUE))
}

pct_bound <- function(w, i) round(100 * vapply(w, `[`, numeric(1), i), 2)

# Per year: Wilson only. Each NPI appears once in a source-year, so there is
# no cluster here to resample and the bootstrap columns are withheld.
f2_year <- agree_cell %>%
  group_by(source, year) %>%
  summarise(n_npi_years = dplyr::n(), n_npis = dplyr::n_distinct(npi),
            n_agree = sum(agree),
            pct_agree = round(100 * mean(agree), 2),
            wilson = list(wilson(sum(agree), dplyr::n())),
            .groups = "drop") %>%
  mutate(scope = "year",
         wilson_low = pct_bound(wilson, 1), wilson_high = pct_bound(wilson, 2),
         boot_low = NA_real_, boot_high = NA_real_,
         method = "wilson_independent") %>%
  select(-wilson)

# Pooled over the source's whole window: now a cluster is a midwife's run of
# years and the design effect is measurable.
f2_pooled <- agree_cell %>%
  group_by(source) %>%
  summarise(n_npi_years = dplyr::n(), n_npis = dplyr::n_distinct(npi),
            n_agree = sum(agree),
            pct_agree = round(100 * mean(agree), 2),
            wilson = list(wilson(sum(agree), dplyr::n())),
            boot = list(boot_ci(agree, npi, B)),
            .groups = "drop") %>%
  mutate(scope = "pooled", year = NA_integer_,
         wilson_low = pct_bound(wilson, 1), wilson_high = pct_bound(wilson, 2),
         boot_low = pct_bound(boot, 1), boot_high = pct_bound(boot, 2),
         method = sprintf("cluster_bootstrap_B=%d vs wilson_independent", B)) %>%
  select(-wilson, -boot)

f2 <- bind_rows(f2_year, f2_pooled) %>%
  mutate(wilson_width = wilson_high - wilson_low,
         boot_width   = boot_high - boot_low,
         design_effect = round(boot_width / wilson_width, 2)) %>%
  arrange(source, scope, year) %>%
  select(source, scope, year, n_npi_years, n_npis, n_agree, pct_agree,
         wilson_low, wilson_high, boot_low, boot_high,
         wilson_width, boot_width, design_effect, method)

## ---- F3: persistence denominators ------------------------------------------
all_years <- records %>% group_by(source) %>%
  summarise(years = list(sort(unique(year))), .groups = "drop")

f3 <- records %>%
  group_by(source, year) %>%
  summarise(n_observed = dplyr::n_distinct(npi), .groups = "drop")

followed <- records %>%
  inner_join(records %>% select(source, npi, year_next = year),
             by = c("source", "npi"),
             relationship = "many-to-many") %>%
  filter(year_next == year + 1L) %>%
  distinct(source, npi, year) %>%
  mutate(followed = TRUE)

same_state <- records %>%
  inner_join(records %>% select(source, npi, state_next = state, year_next = year),
             by = c("source", "npi"), relationship = "many-to-many") %>%
  filter(year_next == year + 1L) %>%
  group_by(source, npi, year) %>%
  summarise(same = any(state == state_next), .groups = "drop")

# Provider-years observed in a source at t, absent from that source at t+1,
# and still visible in NPPES at t+1. This is the number that turns "X% of
# records leave the source" into "of those who left, Y% did not leave the
# workforce" -- billing attrition vs exit.
#
# The anti_join against `followed` is the whole point and is not optional. An
# earlier column here (`n_lost_visible_in_nppes`) omitted it and so counted
# every provider-year visible in NPPES at t+1 whether or not it had left the
# source: 9,013 of 9,770 for medicaid_enrollment 2018, against 98 real
# leavers still in the registry. It was a `lost`-named column that was not a
# leaver count, so it has been removed rather than renamed.
lost_source_but_in_nppes <- records %>%
  filter(source != "nppes") %>%
  anti_join(followed %>% select(source, npi, year),
            by = c("source", "npi", "year")) %>%
  inner_join(nppes %>% transmute(npi, year_next = year, in_nppes = TRUE),
             by = "npi", relationship = "many-to-many") %>%
  filter(year_next == year + 1L) %>%
  distinct(source, npi, year)

f3 <- f3 %>%
  left_join(followed %>% group_by(source, year) %>%
              summarise(n_followed_source = dplyr::n(), .groups = "drop"),
            by = c("source", "year")) %>%
  left_join(same_state %>% group_by(source, year) %>%
              summarise(n_same_state = sum(same), n_changed_state = sum(!same),
                        .groups = "drop"),
            by = c("source", "year")) %>%
  left_join(lost_source_but_in_nppes %>% group_by(source, year) %>%
              summarise(n_lost_source_but_in_nppes = dplyr::n(),
                        .groups = "drop"),
            by = c("source", "year")) %>%
  mutate(across(starts_with("n_"), ~ tidyr::replace_na(.x, 0L)),
         n_lost_from_source = n_observed - n_followed_source,
         pct_followed = round(100 * n_followed_source / n_observed, 1),
         pct_same_given_followed =
           ifelse(n_followed_source > 0,
                  round(100 * n_same_state / n_followed_source, 1), NA_real_))

## ---- Withhold the follow-up columns where t+1 is not observed --------------
# A ZERO AND A BLANK ARE NOT THE SAME CLAIM, and this is the whole of DEBT D14
# items 1 and 2. At a source's LAST year there is no t+1, so nobody can be
# followed: n_followed_source is 0 and n_lost_from_source == n_observed by
# arithmetic, not by attrition. Summed across years, that one degenerate row
# dominated the pooled rate -- Medicaid's "left source" read 16.9% where the
# evaluable years give 0.8%.
#
# The registry closes separately. A source-year whose t+1 falls past NPPES's
# last year cannot distinguish "absent from the registry" from "the registry
# has not been observed yet", so scoring it as a confirmed absence made PECOS
# print 16.4% leaver-visibility against an evaluable 96.5% -- a number that
# contradicted the sentence it was printed under.
#
# Withholding rather than filtering is deliberate: the row still reports
# n_observed, which IS known at t, and a consumer that sums a blank gets NA
# instead of a confidently wrong number. Dropping the rows would have hidden
# that the window ends.
source_max <- f3 %>% group_by(source) %>%
  summarise(last_year = max(year), .groups = "drop")
nppes_max <- max(nppes$year)

f3 <- f3 %>%
  left_join(source_max, by = "source") %>%
  mutate(
    .source_edge = year >= last_year,
    .registry_edge = year + 1L > nppes_max,
    across(c(n_followed_source, n_same_state, n_changed_state,
             n_lost_from_source, pct_followed, pct_same_given_followed),
           ~ replace(.x, .source_edge, NA)),
    # Defined only when the source AND the registry both have a t+1.
    n_lost_source_but_in_nppes =
      replace(n_lost_source_but_in_nppes, .source_edge | .registry_edge, NA)) %>%
  select(-last_year, -.source_edge, -.registry_edge)

write_with_provenance(f2, "artifacts/agreement_cluster_bootstrap_ci.csv",
                      inputs = "artifacts/canonical_source_records.csv", na = "")
write_with_provenance(f3, "artifacts/persistence_denominators.csv",
                      inputs = "artifacts/canonical_source_records.csv", na = "")
cat("F2 cells:", nrow(f2), " F3 cells:", nrow(f3), "\n")
print(as.data.frame(f3 %>% filter(year %in% c(2018, 2020, 2022))), row.names = FALSE)
