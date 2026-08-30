#!/usr/bin/env Rscript
#' @title Step 07: Four-way cohort composition comparison
#'
#' @description
#' The final cohort is not simply "better matched" than Stage 2 — it is
#' DIFFERENTLY SELECTED. It differs through four movement groups: records
#' RETAINED from Stage 2, records NEWLY LINKED/RESOLVED into it, records
#' INCLUDED WITHOUT A FINAL NPI, and records REMOVED. If those movements are
#' geographically skewed, the linkage refactor changes the workforce geography
#' on its own, before any geocoding step. This compares the four groups on
#' characteristics observable for everyone.
#'
#' Group sizes are DERIVED AT RUNTIME, exclusively from SHA-pinned Stage-2 and
#' final-linkage snapshots, and must never be assumed from a prior run.
#'
#' @section Why four groups and not three:
#' Cohort entrants are split on whether a final NPI is actually present in the
#' authoritative linkage. Pooling them would blend a linkage improvement with a
#' possible inclusion defect, and if the no-NPI entrants are geographically
#' skewed they would contaminate exactly the rural signal under investigation.
#' Whether that group is empty is an EMPIRICAL QUESTION answered by the pinned
#' data, not a premise.
#'
#' A caution learned the hard way: the geography artifact derives its `npi`
#' from the linkage file and keeps only rows that have one, so it shows 100%
#' NPI presence BY CONSTRUCTION. Comparing it against a linkage file of a
#' different vintage produced three mutually incompatible counts for the same
#' people. Both snapshots must come from the same pinned vintage, and the
#' authoritative source for `final_npi` is the linkage producer
#' (reconcile_linkage.R), never a downstream geography file.
#'
#' @section Inputs are frozen:
#' Reads only artifacts/frozen_stage2/ and artifacts/frozen_cohort/ — the same
#' inputs the cohort-flow accounting used. No mutable pipeline output is read
#' (see the freeze-before-analysis rule in R/05-stage-progression.R).
#'
#' @section Rurality:
#' Derived from the practice ZIP for EVERY group via the Census ZCTA-county
#' crosswalk, so it is observable regardless of geocoding success. Using a
#' geocoded county would condition on the outcome and make the removed group
#' incomparable.
#'
#' Output : artifacts/cohort_membership_four_way.csv,
#'          artifacts/composition_{status,credential,decade,state,rucc}.csv,
#'          artifacts/no_final_npi_provenance.csv
#'
#' @family step-functions
#' @concept cohort-flow
#' @author Tyler Muffly, MD + Claude Code
#' @export

# Canonical banding + date rules. Inline copies of the RUCC case_when and the
# positional cert_decade parse lived here until cycle 2; see R/lib/table1_bands.R.
source(file.path("R", "lib", "table1_bands.R"))

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(cli)
})

# CYCLE 21b. Inputs recorded beside every artifact this script writes, so a
# reader can tell whether the numbers were built from the bytes still on disk.
source(file.path("R", "lib", "artifact_provenance.R"))

# Helpers shared with the other numbered scripts. Defined once: these were
# duplicated across files sourced into one environment, where load order
# decided which definition won.
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "zip_county_crosswalk.R"))
source(file.path("R", "lib", "ct_county_crosswalk.R"))

ART <- "artifacts"; DATA <- "data"
STAGE2 <- file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")
COHORT <- file.path(ART, "frozen_cohort", "analytic_cohort.csv")
FROZEN_GEO <- file.path(ART, "frozen_cohort", "midwives_geography_guarded.csv")
LINKAGE <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")


#' n/N (%) by group for one characteristic, with a max-vs-min effect size
#'
#' Effect size rather than a p-value: group sizes here span orders of
#' magnitude, so almost any difference is "significant", which says more about
#' sample size than about whether the cohort composition actually moved.
#' @keywords internal
#' @noRd
compose <- function(df, var) {
  tab <- df %>%
    filter(!is.na(.data[[var]])) %>%
    count(group, level = .data[[var]], name = "n") %>%
    group_by(group) %>% mutate(N = sum(n), pct = 100 * n / N) %>% ungroup()

  wide <- tab %>%
    select(level, group, pct) %>%
    pivot_wider(names_from = group, values_from = pct, values_fill = 0)

  gcols <- setdiff(names(wide), "level")
  wide$max_minus_min_pp <- apply(wide[gcols], 1, function(r) max(r) - min(r))
  list(long = tab, wide = wide %>% arrange(desc(max_minus_min_pp)))
}

build_composition <- function() {
  s2 <- chr(STAGE2)
  final <- chr(COHORT)
  link <- if (file.exists(LINKAGE)) chr(LINKAGE) %>%
    distinct(certification_number, .keep_all = TRUE) else NULL

  s2_cohort <- s2$certification_number[!is.na(s2$npi)]
  fin_cohort <- final$certification_number

  fin_npi <- if (!is.null(link)) {
    setNames(link$npi, link$certification_number)[fin_cohort]
  } else rep(NA_character_, length(fin_cohort))

  retained <- intersect(s2_cohort, fin_cohort)
  added    <- setdiff(fin_cohort, s2_cohort)
  removed  <- setdiff(s2_cohort, fin_cohort)
  added_npi <- fin_npi[added]
  resolved <- added[!is.na(added_npi)]
  no_npi   <- added[is.na(added_npi)]

  # --- Assertions ----------------------------------------------------------
  # STRUCTURAL ONLY. Literal group sizes were removed as assertions on
  # 2026-08-08: they came from one transient state of a mutable linkage file,
  # and hard-coding them makes the script enforce a previous answer instead of
  # discovering the reproducible one. The same set of cohort entrants yielded
  # three mutually incompatible "without final NPI" counts depending on which
  # file and vintage was read. Sizes are OUTPUTS of the pinned data; only set
  # identities and disjointness are asserted.
  stopifnot(
    length(retained) + length(resolved) + length(no_npi) == length(fin_cohort),
    length(retained) + length(removed) == length(s2_cohort),
    length(resolved) + length(no_npi) == length(added),
    length(intersect(retained, resolved)) == 0,
    length(intersect(retained, no_npi)) == 0,
    length(intersect(retained, removed)) == 0,
    length(intersect(resolved, no_npi)) == 0,
    length(intersect(resolved, removed)) == 0,
    length(intersect(no_npi, removed)) == 0)
  cli::cli_alert_success("Groups disjoint. retained {length(retained)} + resolved {length(resolved)} + no_npi {length(no_npi)} = {length(fin_cohort)}; stage2 {length(s2_cohort)} = retained + removed {length(removed)}")

  membership <- bind_rows(
    tibble(certification_number = retained, group = "1_retained"),
    tibble(certification_number = resolved, group = "2_newly_npi_resolved"),
    tibble(certification_number = no_npi,   group = "3_in_cohort_no_final_npi"),
    tibble(certification_number = removed,  group = "4_removed"))

  # --- Characteristics, from the frozen Stage-2 roster ---------------------
  chars <- s2 %>%
    select(certification_number, status, certification, certification_date,
           practice_state, practice_zip, s2_npi = npi,
           s2_decision = match_decision, any_of("match_tier"))

  link_cols <- if (is.null(link)) tibble(certification_number = character()) else
    link %>% select(certification_number, final_npi = npi,
                    any_of(c("npi_match_method", "npi_match_resolution")))

  # Rurality: same ZIP-based source for all four groups.
  # Was an inline copy that omitted the !is.na(GEOID_ZCTA5_20) filter the
  # other copies carried, so every ZIP-less midwife joined a single NA-keyed
  # row and was published as Yukon-Koyukuk, Alaska. See R/lib/zip_county_crosswalk.R.
  zc <- zip_county_dominant(file.path(DATA, "zcta_county_2020.txt"))
  cb <- read_csv(file.path(DATA, "county_base.csv"), show_col_types = FALSE,
                 col_types = cols(GEOID = col_character()))

  # BACKFILL 1 -- an address that was never fetched is not a missing address.
  # Stage-2 addresses were pulled from NPPES keyed on the STAGE-2 NPI, and the
  # newly-NPI-resolved group is defined by not having had one. Every member of
  # that group therefore arrived here with no practice ZIP and no state, and all
  # 1,545 of them were published as "Unknown" rurality -- 100% of the group,
  # which is the shape of a join that did not happen rather than of data that
  # does not exist. They carry a FINAL NPI, and the frozen geography artifact
  # holds a practice ZIP for every one.
  #
  # Still a ZIP, so the rule at the top of this file is intact: rurality is
  # derived from the practice ZIP for every group, not from a geocoded county,
  # and remains observable regardless of geocoding success. The `4_removed`
  # group is unaffected -- it holds a stage-2 NPI by definition and already had
  # an address -- so this makes the four-way comparison more balanced, not less.
  geo_zip <- if (file.exists(FROZEN_GEO)) {
    chr(FROZEN_GEO) %>%
      distinct(certification_number, .keep_all = TRUE) %>%
      transmute(certification_number,
                geo_zip = ifelse(is.na(practice_zip) | !nzchar(trimws(practice_zip)),
                                 NA_character_, practice_zip),
                geo_state = ifelse(is.na(practice_state) | !nzchar(trimws(practice_state)),
                                   NA_character_, practice_state))
  } else NULL

  d <- membership %>%
    left_join(chars, by = "certification_number", relationship = "many-to-one") %>%
    left_join(link_cols, by = "certification_number", relationship = "many-to-one")

  if (!is.null(geo_zip)) {
    has_zip <- function(x) !is.na(x) & nzchar(trimws(x))
    before <- sum(!has_zip(d$practice_zip))
    d <- d %>%
      left_join(geo_zip, by = "certification_number", relationship = "many-to-one") %>%
      mutate(zip_backfilled = !has_zip(practice_zip) & !is.na(geo_zip),
             practice_zip = if_else(has_zip(practice_zip), practice_zip, geo_zip),
             # STATE TOO. The same 1,545 records lacked a state, and the effect
             # there was worse than a visible "Unknown": compose() filters NA
             # before it computes N, so the entire group was dropped from
             # composition_practice_state.csv rather than shown as missing. A
             # reader comparing the retained and removed groups would not see
             # that a third group had gone.
             state_backfilled = !has_zip(practice_state) & !is.na(geo_state),
             practice_state = if_else(has_zip(practice_state), practice_state, geo_state)) %>%
      select(-geo_zip, -geo_state)
    cli::cli_alert_info(
      "backfilled from the frozen geography: {sum(d$zip_backfilled)} practice ZIP(s) of {before} missing, {sum(d$state_backfilled)} practice state(s)")
  } else {
    d$zip_backfilled <- FALSE; d$state_backfilled <- FALSE
  }

  d <- d %>%
    mutate(zip5 = zip5_key(practice_zip),
           cert_decade = band_cert_decade(certification_date)) %>%
    left_join(zc, by = "zip5", relationship = "many-to-one")

  # BACKFILL 2 -- Connecticut, where the failure is a vintage boundary and not a
  # missing address. The relationship file is 2020 and reports CT under its
  # legacy counties; county_base.csv is 2023 and reports planning regions. They
  # describe the same ground and do not join, so every Connecticut ZIP produced
  # a county with no RUCC. ct_zip_to_region() goes ZIP -> tract -> region, which
  # is exact because tracts nest, and resolves a spanning ZIP by the same
  # dominant-land-area rule used for counties above.
  ct <- ct_zip_to_region()
  if (!is.null(ct)) {
    d <- d %>%
      left_join(rename(ct, ct_geoid = GEOID), by = "zip5",
                relationship = "many-to-one") %>%
      mutate(ct_rescued = !is.na(ct_geoid) & (is.na(GEOID) | substr(GEOID, 1, 2) == "09"),
             GEOID = if_else(ct_rescued, ct_geoid, GEOID)) %>%
      select(-ct_geoid)
    cli::cli_alert_info(
      "Connecticut ZIPs mapped to a 2022 planning region: {sum(d$ct_rescued)} record(s)")
  } else {
    d$ct_rescued <- FALSE
    cli::cli_alert_warning("Connecticut crosswalk absent; CT records will carry no RUCC.")
  }

  d <- d %>%
    left_join(select(cb, GEOID, rucc_2023), by = "GEOID", relationship = "many-to-one") %>%
    mutate(rucc_cat = coalesce(
      band_rurality(rucc_2023, RURALITY_LABELS_COHORT), "Unknown"))

  write_with_provenance(d %>% select(certification_number, group, s2_decision, s2_npi,
                         final_npi, any_of(c("npi_match_method",
                                             "npi_match_resolution")),
                         status, certification, cert_decade, practice_state,
                         rucc_cat),
            file.path(ART, "cohort_membership_four_way.csv"), na = "", inputs = prov_inputs("county_base.csv", "zcta_county_2020.txt", file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "frozen_cohort", "midwives_geography_guarded.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))

  cli::cli_h2("Group sizes")
  print(as.data.frame(count(d, group, name = "n")), row.names = FALSE)

  for (v in c("rucc_cat", "status", "certification", "cert_decade")) {
    r <- compose(d, v)
    cli::cli_h3(v)
    print(as.data.frame(r$wide %>% mutate(across(where(is.numeric), ~ round(.x, 1)))),
          row.names = FALSE)
    write_with_provenance(r$long, file.path(ART, sprintf("composition_%s.csv", v)), inputs = prov_inputs("county_base.csv", "zcta_county_2020.txt", file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "frozen_cohort", "midwives_geography_guarded.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
  }

  # n/N detail for rurality, the question that matters most here.
  cli::cli_h3("Rurality n/N (%) by group")
  rn <- d %>% filter(rucc_cat != "Unknown") %>%
    count(group, rucc_cat, name = "n") %>%
    group_by(group) %>% mutate(N = sum(n), pct = round(100 * n / N, 1)) %>%
    ungroup() %>%
    mutate(n_over_N = sprintf("%d/%d (%.1f%%)", n, N, pct)) %>%
    select(group, rucc_cat, n_over_N) %>%
    pivot_wider(names_from = group, values_from = n_over_N)
  print(as.data.frame(rn), row.names = FALSE)

  # --- Missingness ledger --------------------------------------------------
  # WHY THIS EXISTS. compose() drops NA before it computes N, so a variable that
  # is missing for a whole group does not appear as missing -- the group simply
  # is not in the artifact. That is how composition_practice_state.csv came to be
  # published without its second group at all, and nobody noticed, because
  # nothing in the file said a group was expected.
  #
  # rucc_cat escaped only because it coalesces to "Unknown", which made the
  # missingness visible as a 100% row. That row is what a reader eventually
  # asked about. This ledger says the same thing for every variable, whether or
  # not it happens to have an Unknown level.
  LEDGER_VARS <- c("rucc_cat", "status", "certification", "cert_decade",
                   "practice_state")
  grp_sizes <- count(d, group, name = "group_n")
  ledger <- lapply(LEDGER_VARS, function(v) {
    d %>%
      group_by(group) %>%
      summarise(variable = v,
                n_observed = sum(!is.na(.data[[v]]) & nzchar(as.character(.data[[v]]))),
                .groups = "drop") %>%
      left_join(grp_sizes, by = "group") %>%
      mutate(n_missing = group_n - n_observed,
             pct_missing = 100 * n_missing / group_n,
             # A group that is ~entirely one level is a join, not a finding --
             # but a group with ZERO observed values is a different fact and
             # must not report the same number a genuine 100%-concentrated
             # group would. NA says "no observed values to characterize";
             # a hardcoded 100 here would sit next to n_observed = 0 and read
             # as "100% of this group is one level" when there is no level at
             # all -- the exact group|variable combination this ledger exists
             # to flag (see the WHY THIS EXISTS note above) would report its
             # OWN most misleading column with the same confident-looking
             # value a real concentration would.
             top_level_pct = vapply(group, function(g) {
               x <- d[[v]][d$group == g]
               x <- x[!is.na(x) & nzchar(as.character(x))]
               if (!length(x)) NA_real_ else 100 * max(table(x)) / length(x)
             }, numeric(1))) %>%
      select(variable, group, group_n, n_observed, n_missing, pct_missing,
             top_level_pct)
  }) %>% bind_rows() %>% arrange(variable, group)

  cli::cli_h2("Missingness ledger")
  print(as.data.frame(ledger %>%
    mutate(across(where(is.numeric), ~ round(.x, 1)))), row.names = FALSE)
  write_with_provenance(ledger, file.path(ART, "composition_missingness_ledger.csv"),
                        inputs = prov_inputs("county_base.csv", "zcta_county_2020.txt",
                          file.path(ART, "frozen_cohort", "analytic_cohort.csv"),
                          file.path(ART, "frozen_cohort", "midwives_geography_guarded.csv"),
                          file.path(ART, "amcb_npi_linkage_FROZEN.csv"),
                          file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))

  st <- compose(d, "practice_state")
  write_with_provenance(st$long, file.path(ART, "composition_practice_state.csv"), inputs = prov_inputs("county_base.csv", "zcta_county_2020.txt", file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "frozen_cohort", "midwives_geography_guarded.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))

  # --- Provenance audit of the no-final-NPI entrants -----------------------
  geo <- if (file.exists(FROZEN_GEO)) chr(FROZEN_GEO) else NULL
  aud <- d %>% filter(group == "3_in_cohort_no_final_npi")
  if (!is.null(geo)) {
    aud <- aud %>% left_join(
      geo %>% select(certification_number, county_best, geo_source, geo_precision,
                     geo_npi = npi),
      by = "certification_number", relationship = "many-to-one")
  }
  aud <- aud %>%
    mutate(has_zip = !is.na(practice_zip) & nzchar(practice_zip),
           has_county = if ("county_best" %in% names(.)) !is.na(county_best) else NA)

  cli::cli_h2("Cohort entrants without a final NPI (n = {nrow(aud)})")
  cli::cli_h3("by prior state")
  print(as.data.frame(count(aud, s2_decision, name = "n", sort = TRUE)), row.names = FALSE)
  cli::cli_h3("by AMCB status")
  print(as.data.frame(count(aud, status, name = "n", sort = TRUE)), row.names = FALSE)
  cli::cli_alert_info("with a practice ZIP: {sum(aud$has_zip)} of {nrow(aud)}")
  if ("county_best" %in% names(aud)) {
    cli::cli_alert_info("with county_best: {sum(aud$has_county, na.rm = TRUE)} of {nrow(aud)}")
    cli::cli_h3("geo_source")
    print(as.data.frame(count(aud, geo_source, name = "n", sort = TRUE)), row.names = FALSE)
    cli::cli_h3("NPI carried in the geography file despite none in the linkage")
    print(as.data.frame(aud %>% summarise(
      geo_npi_present = sum(!is.na(geo_npi)), geo_npi_absent = sum(is.na(geo_npi)))),
      row.names = FALSE)
  }
  write_with_provenance(aud, file.path(ART, "no_final_npi_provenance.csv"), na = "", inputs = prov_inputs("county_base.csv", "zcta_county_2020.txt", file.path(ART, "frozen_cohort", "analytic_cohort.csv"), file.path(ART, "frozen_cohort", "midwives_geography_guarded.csv"), file.path(ART, "amcb_npi_linkage_FROZEN.csv"), file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")))
  cli::cli_alert_success("artifacts/no_final_npi_provenance.csv written")

  invisible(d)
}

if (identical(environment(), globalenv()) && !interactive()) build_composition()
