#!/usr/bin/env Rscript
# =============================================================================
# F2 clustered uncertainty + F3 persistence denominators (spec §8)
# =============================================================================
# The pairwise agreement statistics report Wilson intervals, which assume the
# NPI-years are independent Bernoulli trials. They are not: the same midwife
# appears in up to 14 cells, and her agreement behaviour is serially
# correlated, so Wilson understates the width. F2 replaces the pointwise
# interval with a CLUSTER bootstrap -- resample midwives (clusters), not
# NPI-years (trials) -- alongside the Wilson bounds so the gap between the
# two assumptions is printed, not just asserted.
#
# F3 is the denominator problem the lead/lag table could not see: a midwife
# observed in a source at year t but NOT at t+1 was silently dropped from
# every transition count, making attrition indistinguishable from
# persistence. Here each source-year reports who was observed, who was
# followed (observed again in that source at t+1), who was lost from the
# source but still visible in NPPES (source attrition, not workforce exit),
# and among the followed who kept the same state.
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
  by_npi <- split(agree_vec, npi_vec)
  # Cluster mean = mean over resampled clusters of within-cluster mean.
  cluster_means <- vapply(by_npi, mean, numeric(1))
  k <- length(cluster_means)
  if (k < 5) return(c(NA_real_, NA_real_))
  reps <- replicate(B, mean(sample(cluster_means, k, replace = TRUE)))
  unname(quantile(reps, c(0.025, 0.975), na.rm = TRUE))
}

f2 <- agree_cell %>%
  group_by(source, year) %>%
  summarise(n_npi_years = dplyr::n(), n_npis = dplyr::n_distinct(npi),
            n_agree = sum(agree),
            pct_agree = round(100 * mean(agree), 2),
            wilson = list(wilson(sum(agree), dplyr::n())),
            boot = list(boot_ci(agree, npi, B)),
            .groups = "drop") %>%
  mutate(
    wilson_low  = round(100 * vapply(wilson, `[`, numeric(1), 1), 2),
    wilson_high = round(100 * vapply(wilson, `[`, numeric(1), 2), 2),
    boot_low    = round(100 * vapply(boot,   `[`, numeric(1), 1), 2),
    boot_high   = round(100 * vapply(boot,   `[`, numeric(1), 2), 2),
    wilson_width = wilson_high - wilson_low,
    boot_width   = boot_high - boot_low,
    method = sprintf("cluster_bootstrap_B=%d vs wilson_independent", B)) %>%
  select(-wilson, -boot)

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

in_nppes_next <- records %>%
  filter(source != "nppes") %>%
  inner_join(nppes %>% transmute(npi, year_next = year, in_nppes = TRUE),
             by = "npi", relationship = "many-to-many") %>%
  filter(year_next == year + 1L) %>%
  distinct(source, npi, year) %>%
  mutate(in_nppes_next = TRUE)

# The conditional version: provider-years observed in a source at t, absent
# from that source at t+1, and still visible in NPPES at t+1. This is the
# number that turns "X% of records leave the source" into "of those who
# left, Y% did not leave the workforce" -- billing attrition vs exit.
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
  left_join(in_nppes_next %>% group_by(source, year) %>%
              summarise(n_lost_visible_in_nppes = dplyr::n(), .groups = "drop"),
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

write_with_provenance(f2, "artifacts/agreement_cluster_bootstrap_ci.csv",
                      inputs = "artifacts/canonical_source_records.csv", na = "")
write_with_provenance(f3, "artifacts/persistence_denominators.csv",
                      inputs = "artifacts/canonical_source_records.csv", na = "")
cat("F2 cells:", nrow(f2), " F3 cells:", nrow(f3), "\n")
print(as.data.frame(f3 %>% filter(year %in% c(2018, 2020, 2022))), row.names = FALSE)
