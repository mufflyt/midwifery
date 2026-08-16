#!/usr/bin/env Rscript
#' @title Which evidence arm sees which midwife, and who does Medicare miss
#'
#' @description
#' The PECOS panel answered a narrower question than it appeared to. It covers
#' 9,467 of 17,054 resolved midwives; the other 7,587 have no Medicare
#' reassignment on file at any snapshot. Nothing derived from PECOS generalises
#' to the certified workforce until we know who those 7,587 are.
#'
#' This builds two things:
#'
#'   1. A SOURCE-COVERAGE MATRIX. One row per resolved NPI, one logical column
#'      per evidence arm, plus a count and a class. Answers "which sources can
#'      see this person at all", separately from "what do they say".
#'
#'   2. A MISSINGNESS COMPARISON. PECOS-visible vs PECOS-invisible on
#'      covariates measured INDEPENDENTLY of PECOS -- state, rurality,
#'      certification decade, age, taxonomy, delivery-claim evidence, and every
#'      other arm's coverage. Reported as standardized mean differences, not
#'      p-values: at n = 17,054 everything is significant and nothing is
#'      thereby important.
#'
#' @section Why standardized differences and not tests:
#' The question is not "is the difference nonzero" -- with this n it always is.
#' The question is "is it big enough to change how a PECOS-derived conclusion
#' should be framed". |SMD| >= 0.1 is the conventional threshold for imbalance
#' worth carrying into an interpretation, and it does not move with n.
#'
#' @section Absent is not negative:
#' A FALSE in an arm column means THAT ARM DID NOT SEE THIS PERSON. It does not
#' mean the person has no birth-center affiliation, no hospital, no employer.
#' Several arms here are known-partial by construction (CABC covers accredited
#' birth centres only; Open Payments covers those who received industry
#' payments). Reading a FALSE as a substantive negative is the single most
#' available way to misuse this file, so `arm_is_partial` records which arms
#' cannot support that reading even in principle.
#'
#' Inputs : the resolved AMCB->NPI crosswalk plus every per-person arm artifact
#' Outputs: artifacts/affiliation_coverage_matrix.csv        (person-level, gitignored)
#'          artifacts/affiliation_coverage_summary.csv       (tracked, suppressed)
#'          artifacts/pecos_missingness_comparison.csv       (tracked, suppressed)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))

OUT      <- "artifacts/affiliation_coverage_matrix.csv"
OUT_SUM  <- "artifacts/affiliation_coverage_summary.csv"
OUT_CMP  <- "artifacts/pecos_missingness_comparison.csv"

rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)

# --- the spine: every resolved midwife ---------------------------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$|\\.provenance\\.json$", cw)]
if (!length(cw)) stop("no AMCB->NPI crosswalk in artifacts/", call. = FALSE)
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]

spine <- rd(cw) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  distinct(certification_number = amcb_id, npi)
cli::cli_alert_info("spine: {format(nrow(spine), big.mark = ',')} resolved midwives from {basename(cw)}")

# --- arm registry ------------------------------------------------------------
# Each arm names its file, its key column, and whether a FALSE in it can be read
# as a substantive negative. `partial = TRUE` means it cannot: the source itself
# only ever covered a subpopulation.
ARMS <- tibble::tribble(
  ~arm,                       ~file,                                                        ~key,                    ~partial,
  "pecos_reassignment",       "artifacts/midwife_reassignment_panel.csv",                    "midwife_npi",           FALSE,
  "care_compare_group",       "artifacts/midwife_organization_panel.csv",                    "midwife_npi",           FALSE,
  "dac_facility_affiliation", "artifacts/dac_facility_affiliations.csv",                     "npi",                   FALSE,
  "hospital_affiliation",     "artifacts/midwife_hospital_affiliations.csv",                 "npi",                   FALSE,
  "birth_center_cabc",        "artifacts/cabc_matched_midwives_final.csv",                   "npi",                   TRUE,
  "birth_center_aabc",        "artifacts/aabc_matched_birth_center_midwives.csv",            "npi",                   TRUE,
  "birth_center_freestanding","artifacts/freestanding_birth_center_midwives_expanded.csv",   "npi",                   TRUE,
  "open_payments_org",        "artifacts/cohort_midwives_open_payments_type2_organizations.csv", "midwife_npi",       TRUE
)

seen_in_arm <- function(file, key) {
  if (!file.exists(file)) { cli::cli_alert_warning("absent, arm scored NA: {file}"); return(NULL) }
  d <- rd(file)
  if (!key %in% names(d)) {
    cli::cli_alert_danger("{file}: no column {key}; arm scored NA")
    return(NULL)
  }
  v <- trimws(d[[key]])
  unique(v[!is.na(v) & nzchar(v)])
}

cli::cli_h2("Arms")
mat <- spine
arm_status <- list()
for (i in seq_len(nrow(ARMS))) {
  a <- ARMS$arm[i]
  npis <- seen_in_arm(ARMS$file[i], ARMS$key[i])
  if (is.null(npis)) {
    # An arm that could not be read is NA everywhere, never FALSE. FALSE would
    # assert that the arm looked and found nothing.
    mat[[a]] <- NA
    arm_status[[a]] <- "unavailable"
  } else {
    mat[[a]] <- mat$npi %in% npis
    arm_status[[a]] <- "read"
    cli::cli_alert_success("{a}: sees {format(sum(mat[[a]]), big.mark = ',')} of {format(nrow(mat), big.mark = ',')} ({round(100*mean(mat[[a]]),1)}%)")
  }
}

arm_cols  <- ARMS$arm[vapply(ARMS$arm, function(a) identical(arm_status[[a]], "read"), logical(1))]
# Only arms whose FALSE is interpretable count toward "no evidence".
strong_cols <- intersect(arm_cols, ARMS$arm[!ARMS$partial])

mat <- mat %>%
  mutate(n_arms_seeing = rowSums(across(all_of(arm_cols)), na.rm = TRUE),
         pecos_visible = .data$pecos_reassignment %in% TRUE,
         any_strong_arm = rowSums(across(all_of(strong_cols)), na.rm = TRUE) > 0,
         coverage_class = case_when(
           n_arms_seeing >= 3L ~ "multi_source",
           n_arms_seeing == 2L ~ "two_source",
           n_arms_seeing == 1L ~ "single_source",
           TRUE                ~ "no_organization_evidence"))

cli::cli_h2("Coverage")
print(as.data.frame(count(mat, coverage_class, sort = TRUE)), row.names = FALSE)
cli::cli_alert_info("PECOS-visible: {format(sum(mat$pecos_visible), big.mark = ',')}; PECOS-invisible: {format(sum(!mat$pecos_visible), big.mark = ',')}")

inv <- mat %>% filter(!pecos_visible)
cli::cli_alert_info("of the PECOS-invisible, seen by SOME arm: {format(sum(inv$n_arms_seeing > 0), big.mark = ',')} ({round(100*mean(inv$n_arms_seeing > 0),1)}%)")
cli::cli_alert_info("of the PECOS-invisible, seen by NO arm at all: {format(sum(inv$n_arms_seeing == 0), big.mark = ',')}")

write_with_provenance(mat, OUT, na = "", inputs = prov_inputs(c(cw, ARMS$file[ARMS$arm %in% arm_cols])))
cli::cli_alert_success("wrote {OUT}")

# --- covariates measured independently of PECOS ------------------------------
cli::cli_h2("Covariates")
cov <- mat %>% select(certification_number, npi, pecos_visible, n_arms_seeing,
                      all_of(arm_cols))

geo <- if (file.exists("artifacts/amcb_npi_geography.csv")) {
  rd("artifacts/amcb_npi_geography.csv") %>%
    distinct(npi, .keep_all = TRUE) %>%
    transmute(npi,
              practice_state = practice_state,
              taxonomy_description = taxonomy_description,
              nppes_enumeration_year = substr(nppes_enumeration_date, 1, 4),
              practice_mailing_state_differs = practice_mailing_state_differs)
} else NULL

fourway <- if (file.exists("artifacts/cohort_membership_four_way.csv")) {
  rd("artifacts/cohort_membership_four_way.csv") %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    transmute(certification_number, rucc_cat, cert_decade, status)
} else NULL

ages <- if (file.exists("artifacts/amcb_calibrated_ages.csv")) {
  rd("artifacts/amcb_calibrated_ages.csv") %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    transmute(certification_number,
              final_age = suppressWarnings(as.numeric(final_age)),
              age_is_imputed = is_imputed %in% c("TRUE", "true", "1"))
} else NULL

deliv <- if (file.exists("artifacts/cohort_midwives_cpt_delivery_attenders.csv")) {
  rd("artifacts/cohort_midwives_cpt_delivery_attenders.csv") %>%
    filter(!is.na(npi), nzchar(npi)) %>%
    distinct(npi) %>% mutate(delivery_claim_evidence = TRUE)
} else NULL

for (d in list(geo, ages, fourway, deliv)) {
  if (is.null(d)) next
  by <- intersect(names(d), c("npi", "certification_number"))[1]
  cov <- left_join(cov, d, by = by, relationship = "many-to-one")
}
cov <- cov %>% mutate(delivery_claim_evidence = coalesce(delivery_claim_evidence, FALSE))

# --- standardized differences ------------------------------------------------
# Cohen's d for continuous, and for a binary/categorical level the SMD on the
# proportion, both on the pooled-SD scale so they are comparable.
smd_binary <- function(p1, p0, n1, n0) {
  s <- sqrt((p1 * (1 - p1) + p0 * (1 - p0)) / 2)
  if (!is.finite(s) || s == 0) return(NA_real_)
  (p1 - p0) / s
}
smd_cont <- function(x1, x0) {
  x1 <- x1[is.finite(x1)]; x0 <- x0[is.finite(x0)]
  if (length(x1) < 2L || length(x0) < 2L) return(NA_real_)
  s <- sqrt((stats::var(x1) + stats::var(x0)) / 2)
  if (!is.finite(s) || s == 0) return(NA_real_)
  (mean(x1) - mean(x0)) / s
}

vis <- cov$pecos_visible
n1 <- sum(vis); n0 <- sum(!vis)

rows <- list()
add <- function(variable, level, v1, v0, smd, type) {
  rows[[length(rows) + 1L]] <<- tibble::tibble(
    variable = variable, level = level,
    pecos_visible_value = v1, pecos_invisible_value = v0,
    smd = smd, type = type)
}

# binary / logical covariates, including every other arm's coverage
bin_vars <- c(arm_cols, "delivery_claim_evidence", "age_is_imputed")
bin_vars <- setdiff(intersect(bin_vars, names(cov)), "pecos_reassignment")
for (v in bin_vars) {
  x <- cov[[v]] %in% TRUE
  p1 <- mean(x[vis]); p0 <- mean(x[!vis])
  add(v, "TRUE", p1, p0, smd_binary(p1, p0, n1, n0), "binary")
}

# continuous
if ("final_age" %in% names(cov)) {
  a <- suppressWarnings(as.numeric(cov$final_age))
  add("final_age", "mean", mean(a[vis], na.rm = TRUE), mean(a[!vis], na.rm = TRUE),
      smd_cont(a[vis], a[!vis]), "continuous")
}
if ("nppes_enumeration_year" %in% names(cov)) {
  y <- suppressWarnings(as.numeric(cov$nppes_enumeration_year))
  add("nppes_enumeration_year", "mean", mean(y[vis], na.rm = TRUE), mean(y[!vis], na.rm = TRUE),
      smd_cont(y[vis], y[!vis]), "continuous")
}
add("n_other_arms_seeing", "mean",
    mean(cov$n_arms_seeing[vis] - 1), mean(cov$n_arms_seeing[!vis]),
    smd_cont(cov$n_arms_seeing[vis] - 1, cov$n_arms_seeing[!vis]), "continuous")

# categorical: one SMD per level
for (v in intersect(c("rucc_cat", "cert_decade", "status", "taxonomy_description"), names(cov))) {
  lv <- sort(unique(cov[[v]][!is.na(cov[[v]])]))
  # A level held by fewer than 11 people cannot be published, and an SMD on a
  # handful of people is noise besides.
  for (l in lv) {
    x <- cov[[v]] %in% l
    if (sum(x) < 11L) next
    p1 <- mean(x[vis]); p0 <- mean(x[!vis])
    add(v, l, p1, p0, smd_binary(p1, p0, n1, n0), "categorical")
  }
}

cmp <- bind_rows(rows) %>%
  mutate(abs_smd = abs(smd),
         imbalanced = !is.na(abs_smd) & abs_smd >= 0.1) %>%
  arrange(desc(abs_smd))

cli::cli_h2("PECOS-visible ({format(n1, big.mark = ',')}) vs PECOS-invisible ({format(n0, big.mark = ',')})")
cat("  standardized mean differences, |SMD| >= 0.1 flagged\n\n")
print(as.data.frame(cmp %>% filter(imbalanced) %>%
                      mutate(across(where(is.numeric), ~round(.x, 3))) %>%
                      select(variable, level, pecos_visible_value,
                             pecos_invisible_value, smd)), row.names = FALSE)
n_imb <- sum(cmp$imbalanced)
cat(sprintf("\n  %d of %d comparisons imbalanced at |SMD| >= 0.1.\n", n_imb, nrow(cmp)))
if (n_imb == 0L) {
  cat("  No covariate separates the two groups materially. That does NOT make\n")
  cat("  the missingness ignorable -- it makes it unexplained by what we measured.\n\n")
} else {
  cat("  Medicare affiliation missingness is NONRANDOM on these covariates.\n")
  cat("  Any PECOS-derived workforce statement must be framed as applying to\n")
  cat("  the Medicare-billing subpopulation, not the certified workforce.\n\n")
}

write_with_provenance(cmp, OUT_CMP, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_CMP}")

# --- tracked coverage summary ------------------------------------------------
summ <- mat %>%
  count(pecos_visible, coverage_class, name = "n_midwives") %>%
  mutate(suppressed = n_midwives < 11,
         n_midwives = if_else(suppressed, NA_integer_, n_midwives)) %>%
  arrange(pecos_visible, coverage_class)

arm_summ <- tibble::tibble(
  pecos_visible = NA, coverage_class = paste0("arm:", ARMS$arm),
  n_midwives = vapply(ARMS$arm, function(a)
    if (identical(arm_status[[a]], "read")) as.integer(sum(mat[[a]], na.rm = TRUE)) else NA_integer_,
    integer(1)),
  suppressed = FALSE) %>%
  mutate(suppressed = !is.na(n_midwives) & n_midwives < 11,
         n_midwives = if_else(suppressed, NA_integer_, n_midwives))

write_with_provenance(bind_rows(summ, arm_summ), OUT_SUM, na = "",
                      inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_SUM} (cells under 11 suppressed)")
