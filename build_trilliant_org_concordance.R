#!/usr/bin/env Rscript
# =============================================================================
# Does Trilliant agree with the organization-resolution rules?
# =============================================================================
# READ-ONLY with respect to the linkage and the resolver. This script changes no
# rule, promotes no candidate, and writes nothing that any published figure
# depends on. It answers one question: for each (midwife, candidate
# organization) pair the resolver produced, does an independent claims-derived
# directory put that midwife at that organization?
#
# WHY THIS EXISTS. artifacts/org_resolution_ppv.csv marks all five rules
# `meets_threshold = FALSE` -- cross_source 0.96, multi_key 0.84, taxonomy_excl
# 0.96, telephone 0.84, zip9 1.00 (25/25). That is not five failures. The gate
# is a Wilson 95% lower bound >= 0.90 over 25 human adjudications per stratum,
# and at n = 25 even a flawless run yields 0.867. The smallest sample where
# perfection can clear the bar is 35. The gate is honest -- its header says a
# low bound means "has not been shown to meet it" -- but as sampled it can never
# promote anything, and human adjudication is the scarce resource. A machine
# reference over thousands of rows cannot replace those verdicts; it can say
# where to spend them.
#
# WHAT IS DELIBERATELY NOT EVIDENCE HERE.
#   * This is CONCORDANCE, not PPV. Trilliant agreeing does not make a rule
#     right, and it is never written into org_resolution_review_sample.csv
#     (whose column is `human_verdict`) or into org_resolution_ppv.csv.
#     report_org_resolution_ppv.R is not touched by this script.
#   * Trilliant's organization attribution is CLAIMS-DERIVED. A clinician is
#     attributed to an organization whose claim carries their NPI, which
#     includes ordering and referring roles, not only a workplace. Rows whose
#     attribution cannot bear weight are reported as `too_weak_to_judge`, never
#     counted against a rule.
#   * `active_provider = FALSE` is never evidence that an assignment is wrong.
#   * Nothing here is an employer. The repository's tests pin that word out of
#     this layer deliberately (billing is not employment; PECOS absence is not
#     independent practice). The subject is organization AFFILIATION.
#
# THE BRIDGE, AND WHY IT IS A MATCH AND NOT A JOIN. directory_provider carries
# no organization id -- only free-text practice and organization names. So a
# provider reaches an organization NPI only through the address: practice-1 is
# matched to directory_organization on ZIP5 + normalised street, and the name
# breaks ties among organizations sharing one address. That machinery is
# R/lib/trilliant_org_bridge.R, shared with build_trilliant_work_sites.R.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv    (freeze, verified)
#          artifacts/midwife_org_affiliations_candidate.csv if present, else
#          artifacts/midwife_org_links.csv          (npi x candidate org)
#          Trilliant directory_provider + directory_organization (external)
# Outputs: analysis/trilliant_org_concordance_<sha8>.csv   person-level, GITIGNORED
#          artifacts/trilliant_org_concordance_rates_<sha8>.csv    aggregate, tracked
#          artifacts/trilliant_org_concordance_controls_<sha8>.csv aggregate, tracked
#
# Source attribution, required by Trilliant ToS 2.2(b): Trilliant Health
# provider directory, snapshot 2026-06-25. ToS 2.3(i)/(iii) forbid
# redistributing derived data, so the person-level output stays gitignored.
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(readr); library(stringr); library(tidyr)
})
source(file.path("R", "lib", "common_helpers.R"))        # chr()
source(file.path("R", "lib", "medicare_duckdb.R"))       # samsung_volume_path()
source(file.path("R", "lib", "cohort_definitions.R"))    # verify_linkage_freeze(), canonical_active_primary()
source(file.path("R", "lib", "artifact_provenance.R"))   # write_with_provenance()
source(file.path("R", "lib", "address_keys.R"))          # zip5(), phone10()
source(file.path("R", "lib", "org_names.R"))             # norm_org()
source(file.path("R", "lib", "trilliant_org_bridge.R"))  # norm_street(), name_sim(), trl_read_orgs()

FROZEN <- Sys.getenv("LINKAGE_CSV", file.path("artifacts", "amcb_npi_linkage_FROZEN.csv"))
LAKE   <- { v <- Sys.getenv("TRILLIANT_LAKE", "")
            if (nzchar(v)) v else samsung_volume_path("hpt_prices/trilliant/20260721/lake/data/main") }
TRILLIANT_SNAPSHOT <- "2026-06-25"
# A practice-1 site holding under a quarter of a provider's visits is as
# consistent with an ordering or referring claim as with a workplace, so it is
# reported and never counted against a rule. Stated here, not buried in a
# case_when, because it is the one judgement call in the classification.
WEAK_VISIT_SHARE <- 0.25

db_exec("SET memory_limit='4GB'"); db_exec("SET threads=2")
set.seed(20260918)

FREEZE_SHA <- verify_linkage_freeze(FROZEN)
SHA8 <- substr(FREEZE_SHA, 1, 8)
cohort <- chr(FROZEN) |> canonical_active_primary() |> distinct(certification_number, npi)
cat(sprintf("cohort: %s ACTIVE primary-linked certificants (freeze %s)\n",
            format(nrow(cohort), big.mark = ","), SHA8))

# ---- 1. the candidates the rules produced -------------------------------------
CAND <- if (file.exists("artifacts/midwife_org_affiliations_candidate.csv"))
  "artifacts/midwife_org_affiliations_candidate.csv" else "artifacts/midwife_org_links.csv"
cand <- chr(CAND) |> filter(!is.na(org_npi), org_npi != "")
# The long candidate file names the rule; the links file carries only the key,
# so the stratum is derived the same way resolve_org_ambiguity.R does.
if (!"resolution_method" %in% names(cand)) cand$resolution_method <- NA_character_
cand <- cand |>
  mutate(review_stratum = case_when(
    !is.na(resolution_method) & resolution_method == "taxonomy_exclusion_unique" ~ "taxonomy_excl",
    !is.na(resolution_method) & str_starts(resolution_method, "cross_source") ~ "cross_source",
    !is.na(resolution_method) & resolution_method == "multi_key_agreement" ~ "multi_key",
    !is.na(resolution_method) & resolution_method == "open_payments_only_unique_address" ~ "op_fallback",
    match_key == "telephone" ~ "telephone",
    match_key == "zip9_address" ~ "zip9",
    match_key == "zip5_address" ~ "zip5_address",
    TRUE ~ "other")) |>
  semi_join(cohort, by = "npi")
cat(sprintf("candidates: %s rows over %s certificants (%s)\n",
            format(nrow(cand), big.mark = ","), format(n_distinct(cand$npi), big.mark = ","), CAND))

# ---- 2. what Trilliant says about each midwife ---------------------------------
prov <- read_parquet_duckdb(file.path(LAKE, "directory_provider", "*.parquet"), prudence = "stingy") |>
  semi_join(as_duckdb_tibble(tibble(provider_npi = as.numeric(unique(cohort$npi)))), by = "provider_npi") |>
  select(provider_npi, active_provider, primary_organization_name, provider_practices_total,
         provider_affiliated_practice_1_name, provider_affiliated_practice_1_street_address,
         provider_affiliated_practice_1_city, provider_affiliated_practice_1_state,
         provider_affiliated_practice_1_zip_code, provider_affiliated_practice_1_phone_number,
         provider_affiliated_practice_1_visits_percent_total) |>
  collect()
# duckplyr silently reorders ordinary-tibble joins unless the dplyr methods are
# put back after the lazy scans are collected; that cost an earlier script a
# 22-row pairing failure out of 655,646. Restore before any join below.
duckplyr::methods_restore()
prov <- prov |>
  transmute(npi = format(provider_npi, scientific = FALSE, trim = TRUE),
            trl_active = active_provider,
            trl_primary_org = primary_organization_name,
            trl_practices_total = provider_practices_total,
            trl_site_name = provider_affiliated_practice_1_name,
            trl_street = provider_affiliated_practice_1_street_address,
            trl_city = provider_affiliated_practice_1_city,
            trl_state = provider_affiliated_practice_1_state,
            trl_zip5 = substr(provider_affiliated_practice_1_zip_code, 1L, 5L),
            trl_phone = phone10(provider_affiliated_practice_1_phone_number),
            trl_visit_share = provider_affiliated_practice_1_visits_percent_total,
            ns = norm_street(provider_affiliated_practice_1_street_address))
cat(sprintf("Trilliant: %s of %s cohort NPIs present, %s with a practice-1 address\n",
            format(nrow(prov), big.mark = ","), format(nrow(cohort), big.mark = ","),
            format(sum(nzchar(prov$ns)), big.mark = ",")))

# ---- 3. bridge practice-1 to an organization NPI --------------------------------
sites <- prov |> filter(nzchar(ns), !is.na(trl_zip5))
orgs <- trl_read_orgs(LAKE, unique(sites$trl_zip5))
duckplyr::methods_restore()
bridged <- sites |>
  select(npi, trl_zip5, ns, trl_site_name, trl_state, trl_phone) |>
  inner_join(orgs, by = c("trl_zip5" = "oz", "ns" = "ns"), relationship = "many-to-many") |>
  # The recorded defect: directory_organization sometimes files an NPI at
  # another same-named facility's address. A candidate in another state is
  # dropped rather than ranked.
  filter(is.na(org_state) | is.na(trl_state) | org_state == trl_state) |>
  group_by(npi) |>
  mutate(n_orgs_at_address = n_distinct(org_npi),
         sim = if_else(is.na(trl_site_name) | is.na(org_name), NA_real_,
                       name_sim(trl_site_name, org_name))) |>
  arrange(desc(coalesce(sim, -1)), .by_group = TRUE) |>
  summarise(trl_org_npi = first(org_npi), trl_org_name = first(org_name),
            trl_org_phone = first(org_phone), trl_org_state = first(org_state),
            n_orgs_at_address = first(n_orgs_at_address), name_sim_best = first(sim),
            .groups = "drop")
cat(sprintf("bridged: %s midwives reach an organization NPI through their practice address\n",
            format(nrow(bridged), big.mark = ",")))

trl <- prov |> left_join(bridged, by = "npi", relationship = "one-to-one") |>
  mutate(attribution_quality = case_when(
    !nzchar(coalesce(ns, "")) & is.na(trl_primary_org) ~ "none",
    is.na(trl_org_npi) & is.na(trl_primary_org) ~ "none",
    coalesce(trl_visit_share, 1) < WEAK_VISIT_SHARE ~ "weak_visit_share",
    coalesce(n_orgs_at_address, 1L) > 1L & coalesce(name_sim_best, 0) < 0.80 ~ "weak_shared_address",
    TRUE ~ "usable"))

# ---- 4. the verdict, per candidate row ------------------------------------------
pairs <- cand |>
  left_join(trl, by = "npi", relationship = "many-to-one") |>
  mutate(
    org_name_norm = norm_org(organization_name),
    agree_npi   = !is.na(trl_org_npi) & trl_org_npi == org_npi,
    agree_name  = nzchar(org_name_norm) &
      (org_name_norm == norm_org(trl_org_name) | org_name_norm == norm_org(trl_primary_org)),
    agree_phone = !is.na(trl_phone) & !is.na(phone10(trl_org_phone)) & trl_phone == phone10(trl_org_phone),
    verdict = case_when(
      is.na(trl_active) ~ "trilliant_silent",
      attribution_quality == "none" ~ "trilliant_silent",
      attribution_quality != "usable" ~ "too_weak_to_judge",
      agree_npi | agree_name ~ "agrees",
      is.na(trl_org_npi) & is.na(trl_primary_org) ~ "trilliant_silent",
      TRUE ~ "disagrees"),
    # Circularity check: if Trilliant's address is the address the rule keyed
    # on, agreement is the same evidence twice, not a second opinion.
    same_address_as_rule = coalesce(zip5(zip) == trl_zip5 & norm_street(addr) == ns, FALSE))

# ---- 5. rates, with the same interval the PPV report uses -------------------------
wilson <- function(x, n, conf = 0.95) {
  if (n == 0) return(c(NA_real_, NA_real_))
  z <- qnorm(1 - (1 - conf) / 2); p <- x / n
  d <- 1 + z^2 / n
  c((p + z^2/(2*n) - z*sqrt((p*(1-p) + z^2/(4*n))/n))/d,
    (p + z^2/(2*n) + z*sqrt((p*(1-p) + z^2/(4*n))/n))/d)
}
rates <- pairs |>
  group_by(review_stratum) |>
  summarise(n_candidates = n(),
            n_silent = sum(verdict == "trilliant_silent"),
            n_too_weak = sum(verdict == "too_weak_to_judge"),
            n_judged = sum(verdict %in% c("agrees", "disagrees")),
            n_agree = sum(verdict == "agrees"),
            pct_same_address_as_rule = round(mean(same_address_as_rule[verdict == "agrees"]), 4),
            .groups = "drop") |>
  rowwise() |>
  mutate(concordance = if_else(n_judged > 0, n_agree / n_judged, NA_real_),
         lo = wilson(n_agree, n_judged)[1], hi = wilson(n_agree, n_judged)[2]) |>
  ungroup() |>
  arrange(desc(n_candidates))

# ---- 6. negative controls ---------------------------------------------------------
# 1. Shuffle: break the midwife-organization pairing inside each stratum. A
#    reference that still "agrees" is matching a building, not an organization.
shuffled <- pairs |> group_by(review_stratum) |>
  mutate(org_npi = sample(org_npi), organization_name = sample(organization_name)) |>
  ungroup() |>
  mutate(org_name_norm = norm_org(organization_name),
         agree = (!is.na(trl_org_npi) & trl_org_npi == org_npi) |
           (nzchar(org_name_norm) & (org_name_norm == norm_org(trl_org_name) |
                                       org_name_norm == norm_org(trl_primary_org))),
         judged = verdict %in% c("agrees", "disagrees"))
# 2. State guard: dropping it should inflate agreement. If it does not move the
#    number, the guard is inert and the recorded defect needs re-examination.
bridged_noguard <- sites |>
  select(npi, trl_zip5, ns) |>
  inner_join(orgs, by = c("trl_zip5" = "oz", "ns" = "ns"), relationship = "many-to-many") |>
  distinct(npi, org_npi)
controls <- tibble(
  control = c("observed_concordance", "shuffled_within_stratum", "state_guard_removed_extra_orgs"),
  value = c(round(sum(pairs$verdict == "agrees") / max(sum(pairs$verdict %in% c("agrees", "disagrees")), 1), 4),
            round(sum(shuffled$agree[shuffled$judged]) / max(sum(shuffled$judged), 1), 4),
            nrow(bridged_noguard) - nrow(distinct(bridged, npi, trl_org_npi))),
  note = c("share of judged candidate rows Trilliant agrees with",
           "same classifier after permuting the organization within each stratum",
           "extra (npi, org) bridge rows admitted when the state filter is removed"))

# ---- 7. write --------------------------------------------------------------------
dir.create("analysis", showWarnings = FALSE)
person_out <- file.path("analysis", sprintf("trilliant_org_concordance_%s.csv", SHA8))
write_csv(pairs |> select(certification_number, npi, org_npi, organization_name, review_stratum,
                          match_key, n_org_at_key, verdict, attribution_quality,
                          agree_npi, agree_name, agree_phone, same_address_as_rule,
                          trl_org_npi, trl_org_name, trl_primary_org, trl_site_name,
                          trl_visit_share, trl_practices_total, trl_active,
                          n_orgs_at_address, name_sim_best),
          person_out, na = "")
write_with_provenance(rates, file.path("artifacts", sprintf("trilliant_org_concordance_rates_%s.csv", SHA8)),
                      inputs = c(FROZEN, CAND))
write_with_provenance(controls, file.path("artifacts", sprintf("trilliant_org_concordance_controls_%s.csv", SHA8)),
                      inputs = c(FROZEN, CAND))
cat("\n=== concordance by rule (Trilliant Health provider directory, ", TRILLIANT_SNAPSHOT, ") ===\n", sep = "")
print(as.data.frame(rates |> mutate(across(c(concordance, lo, hi), ~ round(.x, 3)))))
cat("\n=== controls ===\n"); print(as.data.frame(controls))
cat(sprintf("\nperson-level (gitignored): %s\n", person_out))
