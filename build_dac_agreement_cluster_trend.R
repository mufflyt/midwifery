#!/usr/bin/env Rscript

suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "source_coverage.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

audit <- validate_source_coverage(read_source_manifest(), publication_mode = TRUE,
                                  source_ids = c("nppes", "dac_physician_compare"))
nppes_path <- declared_path(audit, "nppes")
dac_history_path <- declared_path(audit, "dac_physician_compare", 2025L)

nppes <- read_csv(nppes_path, col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year),
            state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(year), !is.na(state)) %>%
  distinct(npi, year, state)

dac <- read_csv(dac_history_path, col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)),
            state = clean_state(practice_state)) %>%
  filter(year <= 2025L, !is.na(npi), nzchar(npi), !is.na(year), !is.na(state)) %>%
  distinct(npi, year, state)

# One Bernoulli observation per clinician-year: agreement means the two state
# sets intersect. This avoids treating several directory locations for one NPI
# as independent records while retaining multistate information.
cells <- dac %>%
  inner_join(nppes, by = c("npi", "year"), suffix = c("_dac", "_nppes"),
             relationship = "many-to-many") %>%
  group_by(npi, year) %>%
  summarise(agree = any(state_dac == state_nppes), .groups = "drop") %>%
  filter(year >= 2013L, year <= 2025L)

stopifnot(nrow(cells) > 0, n_distinct(cells$year) >= 3,
          nrow(cells) > n_distinct(cells$npi))

# Linear probability model with CR1 clinician-clustered sandwich inference.
x <- cbind(`(Intercept)` = 1, year = cells$year)
y <- as.numeric(cells$agree)
xtx_inv <- solve(crossprod(x))
beta <- drop(xtx_inv %*% crossprod(x, y))
u <- y - drop(x %*% beta)
score <- rowsum(x * u, cells$npi, reorder = FALSE)
n <- nrow(x); p <- ncol(x); g <- nrow(score)
cr1 <- (g / (g - 1)) * ((n - 1) / (n - p))
vcov_cluster <- cr1 * xtx_inv %*% crossprod(score) %*% xtx_inv
se <- sqrt(diag(vcov_cluster))[2]
crit <- qt(0.975, df = g - 1)
slope <- 100 * beta[2]
ci <- 100 * (beta[2] + c(-1, 1) * crit * se)
start_year <- min(cells$year); end_year <- max(cells$year)

annual <- cells %>% group_by(year) %>%
  summarise(n_npis = n(), n_agree = sum(agree), pct_agree = 100 * mean(agree),
            .groups = "drop")

out <- tibble(
  source = "dac_physician_compare",
  estimand = "linear trend in annual NPI-year source-to-NPPES state agreement",
  start_year = start_year,
  end_year = end_year,
  n_years = n_distinct(cells$year),
  n_npi_years = nrow(cells),
  n_npis = n_distinct(cells$npi),
  slope_pp_per_year = slope,
  ci_low = ci[1],
  ci_high = ci[2],
  absolute_change_pp = slope * (end_year - start_year),
  start_agreement_pct = annual$pct_agree[annual$year == start_year],
  end_agreement_pct = annual$pct_agree[annual$year == end_year],
  method = "linear probability model; CR1 sandwich SE clustered by NPI; t reference df=clusters-1",
  comparison_unit = "one NPI-year; agreement if DAC and NPPES state sets intersect"
)

write_with_provenance(out, "artifacts/dac_agreement_cluster_trend.csv",
                      inputs = c(nppes_path, dac_history_path,
                                 "config/state_source_audit_sources.csv"))
print(out, width = Inf)
