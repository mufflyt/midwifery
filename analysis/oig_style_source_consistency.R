#!/usr/bin/env Rscript
# =============================================================================
# OIG-style completeness and consistency audit, six practice-location sources
# =============================================================================
# Question: when no source is truth, how well do the practice-location sources
# for the frozen ACTIVE cohort agree with each other?
#
# Modelled on HHS OIG OEI-07-09-00440 (May 2013), which compared NPPES and
# PECOS for accuracy, completeness and consistency. OIG's accuracy arm needed
# providers to verify their own records; there is no such arm here, so this
# reports only what needs no truth:
#   1. completeness by source and field -- record absent, field blank, field
#      populated but malformed, and usable are kept apart;
#   2. pairwise consistency of practice state and ZIP5 under OIG's any-match
#      rule for sources that list several locations (strict same-set rate
#      alongside), with "missing in one source" counted separately from
#      "both populated but different";
#   3. the error floor a disagreement implies;
#   4. which source is the lone dissenter when every other source agrees.
#
# Not redone here: state-only pairwise agreement across 10 sources
# (build_state_source_pairwise_audit.R), per-NPI consensus and tier flow
# (build_cross_source_comparison.R), year-by-year agreement against NPPES and
# the lead-lag timing work (docs/TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md).
# Those replace OIG's two-snapshot timing check.
#
# One cross-section, mixed vintages: Open Payments is program year 2024, the
# other five are 2026 pulls. Each source's vintage is in the completeness
# table, and every pair involving Open Payments carries that gap.
#
# ERROR FLOOR. If two sources disagree for a midwife, at least one of them is
# wrong for her. With disagreement rate d among n compared midwives, the worse
# of the two is wrong for at least d/2 of those n. That needs no truth, but it
# is only a floor: two sources can agree and both be wrong.
#
# LINEAGE. DAC is built from PECOS enrollment, so DAC-PECOS agreement is not
# two independent votes (flag `shared_lineage_cms_enrollment`), and the
# odd-one-out table has a variant that counts that lineage once. Doximity and
# Healthgrades may seed profiles from NPPES (`possible_nppes_seeding`). PECOS
# affiliations carry the practice location of the organization a midwife
# reassigned billing to -- the same mechanism OIG's Appendix A blames for its
# 88.6% practice-ZIP mismatch -- so PECOS ZIP disagreement is partly
# structural.
#
# Inputs (gitignored, person-level; read under DATA_ROOT):
#   artifacts/cohort_midwives_tier1_tier2_bon_validated.csv   frame: distinct npi
#   artifacts/amcb_npi_linkage_FROZEN.csv                     certification_number -> npi
#   artifacts/amcb_npi_geography.csv                          NPPES
#   artifacts/midwife_pecos_organization_affiliations.csv     PECOS
#   artifacts/dac_cnm_locations.csv                           DAC, every ranked location
#   artifacts/cohort_midwives_open_payments_general_2024.csv  Open Payments 2024
#   artifacts/doximity_public_matched.csv                     Doximity
#   healthgrades_midwives.csv                                 Healthgrades
# Outputs (aggregate only, no person-level rows; under OUT_DIR):
#   oig_style_field_dictionary.csv
#   oig_style_completeness.csv
#   oig_style_pairwise_consistency.csv
#   oig_style_odd_one_out.csv
#
# Run from the repository root:
#   Rscript analysis/oig_style_source_consistency.R [DATA_ROOT] [OUT_DIR]
# DATA_ROOT: argument 1, else MIDWIFERY_DATA_ROOT, else ".".
# OUT_DIR:   argument 2, else OIG_OUT_DIR, else "artifacts".
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(mysteryroster)})

source(file.path("R", "analysis_args.R"))               # arg_or()
source(file.path("R", "lib", "clean_state.R"))          # clean_state()
source(file.path("R", "lib", "address_agreement_compare.R"))  # shape_address()
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()

data_root <- arg_or(1, "MIDWIFERY_DATA_ROOT", ".")
out_dir   <- arg_or(2, "OIG_OUT_DIR", "artifacts")
AUDIT_YEAR <- 2026L
ATTRIBUTES <- c("practice_state", "practice_zip5")

INPUTS <- c(
  cohort        = "artifacts/cohort_midwives_tier1_tier2_bon_validated.csv",
  crosswalk     = "artifacts/amcb_npi_linkage_FROZEN.csv",
  nppes         = "artifacts/amcb_npi_geography.csv",
  pecos         = "artifacts/midwife_pecos_organization_affiliations.csv",
  dac           = "artifacts/dac_cnm_locations.csv",
  open_payments = "artifacts/cohort_midwives_open_payments_general_2024.csv",
  doximity      = "artifacts/doximity_public_matched.csv",
  healthgrades  = "healthgrades_midwives.csv"
)
VINTAGE <- c(
  nppes = "NPPES 2026 pull", pecos = "PECOS organization affiliations (current artifact)",
  dac = "DAC 2026 pull", open_payments = "Open Payments program year 2024",
  doximity = "Doximity 2026 scrape", healthgrades = "Healthgrades 2026 scrape"
)
in_path <- function(key) file.path(data_root, INPUTS[[key]])
missing_in <- names(INPUTS)[!file.exists(file.path(data_root, INPUTS))]
if (length(missing_in)) {
  stop("missing input(s) under ", data_root, ": ",
       paste(INPUTS[missing_in], collapse = ", "), call. = FALSE)
}
rd <- function(key) read_csv(in_path(key), col_types = cols(.default = "c"), progress = FALSE)

# --- frame and crosswalk ------------------------------------------------------
# The cohort repeats an NPI for dual certification records; people are
# counted once, by npi.
cohort <- rd("cohort")
frame_npi <- sort(unique(trimws(cohort$npi[!is.na(cohort$npi) & nzchar(trimws(cohort$npi))])))
N_FRAME <- length(frame_npi)

xwalk <- rd("crosswalk") %>%
  transmute(certification_number = trimws(certification_number), npi = trimws(npi)) %>%
  filter(!is.na(certification_number), !is.na(npi), nzchar(npi)) %>%
  distinct()
if (anyDuplicated(xwalk$certification_number)) {
  stop("crosswalk maps a certification_number to more than one npi", call. = FALSE)
}
via_crosswalk <- function(df) {
  df %>% mutate(certification_number = trimws(certification_number)) %>%
    inner_join(xwalk, by = "certification_number")
}

# --- sources ------------------------------------------------------------------
# One row per (npi, listed location). `*_populated` is read from the raw
# column; `state`/`zip5` keep only well-formed values (clean_state(), five
# digits), so a populated-but-malformed field is visible as the gap between
# the two.
# A ZIP stored as a number loses its leading zero: PECOS affiliations carry
# four- and eight-digit ZIPs, and the first five characters of an eight-digit
# ZIP+4 are not its ZIP5. Restore the zero before shape_address() takes ZIP5.
pad_zip_digits <- function(x) {
  d <- gsub("[^0-9]", "", x)
  w <- ifelse(nchar(d) %in% 3:4, 5L, ifelse(nchar(d) %in% 6:8, 9L, nchar(d)))
  out <- paste0(strrep("0", pmax(0L, w - nchar(d))), d)
  ifelse(is.na(x) | !nzchar(d), x, out)
}

load_source <- function(df, npi_col, state_col, city_col, zip_col, zip_mode = "substr") {
  raw_pop <- function(col) { v <- trimws(df[[col]]); !is.na(v) & nzchar(v) }
  if (zip_mode == "substr") df[[zip_col]] <- pad_zip_digits(df[[zip_col]])
  s <- shape_address(df, npi_col = npi_col, state_col = state_col, city_col = city_col,
                     zip_col = zip_col, zip_mode = zip_mode)
  s %>%
    mutate(npi = trimws(npi),
           state_populated = raw_pop(state_col),
           zip5_populated = raw_pop(zip_col),
           state = clean_state(state),
           zip5 = ifelse(!is.na(zip5) & grepl("^[0-9]{5}$", zip5), zip5, NA_character_),
           row_order = seq_len(n())) %>%
    filter(npi %in% frame_npi) %>%
    select(npi, state_populated, zip5_populated, state, zip5, row_order)
}

hg_raw <- rd("healthgrades")
# Only hg_status == "ok" is a matched profile. "no_search_hit" found nobody and
# "rejected_name_or_credential" found the wrong person; both are an absent
# record, not a record with blank fields.
hg_raw <- hg_raw[hg_raw$hg_status %in% "ok", ]

dac_raw <- rd("dac")
dac_raw <- dac_raw[order(dac_raw$NPI, suppressWarnings(as.integer(dac_raw$location_rank))), ]

sources <- list(
  nppes = load_source(rd("nppes"), "npi", "practice_state", "practice_city", "practice_zip"),
  pecos = load_source(rd("pecos"), "midwife_npi", "practice_state", "practice_city", "practice_zip"),
  dac = load_source(dac_raw, "NPI", "state", "city", "zip"),
  open_payments = load_source(rd("open_payments"), "npi", "recipient_state", "recipient_city", "recipient_zip"),
  doximity = load_source(via_crosswalk(rd("doximity")), "npi", "state", "city", "city_zip",
                         zip_mode = "trailing5"),
  healthgrades = load_source(via_crosswalk(hg_raw), "npi", "hg_state", "hg_city", "hg_zip")
)
SOURCES <- names(sources)

# --- field dictionary -----------------------------------------------------------
dictionary <- attribute_field_dictionary(
  data.frame(attribute = ATTRIBUTES,
             definition = c("Two-letter practice state (clean_state())",
                            "First five digits of the practice ZIP"),
             location_role = "practice", normalizer = c("state_abb", "zip5")),
  sources = SOURCES,
  lineage_groups = list(cms_enrollment = c("pecos", "dac"))
)

# --- 1. completeness -------------------------------------------------------------
per_npi <- bind_rows(lapply(SOURCES, function(s) {
  sources[[s]] %>% group_by(npi) %>%
    summarise(practice_state_populated = any(state_populated),
              practice_zip5_populated = any(zip5_populated),
              practice_state_n_valid = n_distinct(state, na.rm = TRUE),
              practice_zip5_n_valid = n_distinct(zip5, na.rm = TRUE),
              .groups = "drop") %>%
    mutate(source = s)
}))

completeness <- bind_rows(lapply(SOURCES, function(s) bind_rows(lapply(ATTRIBUTES, function(a) {
  d <- per_npi[per_npi$source == s, ]
  pop <- d[[paste0(a, "_populated")]]; nv <- d[[paste0(a, "_n_valid")]]
  n_present <- nrow(d)
  tibble(source = s, vintage = VINTAGE[[s]], attribute = a, n_frame = N_FRAME,
         n_record_present = n_present,
         n_record_absent = N_FRAME - n_present,
         n_field_blank = sum(!pop),
         n_field_malformed = sum(pop & nv == 0),
         n_usable = sum(nv > 0),
         n_multiple_values = sum(nv > 1),
         pct_record_present = round(100 * n_present / N_FRAME, 1),
         pct_usable_of_present = if (n_present) round(100 * sum(nv > 0) / n_present, 1) else NA_real_)
}))))
stopifnot(with(completeness, n_record_present == n_field_blank + n_field_malformed + n_usable))

# --- 2. pairwise consistency ------------------------------------------------------
set_input <- function(attr_col, out_name) {
  lapply(sources, function(d) {
    v <- d[!is.na(d[[attr_col]]), c("npi", attr_col)]
    names(v) <- c("npi", out_name)
    v$year <- AUDIT_YEAR
    distinct(v)
  })
}
set_rows <- list(
  practice_state = attribute_set_agreement(set_input("state", "practice_state"), "practice_state"),
  practice_zip5  = attribute_set_agreement(set_input("zip5", "practice_zip5"), "practice_zip5")
)

# OIG's "inconsistent on at least one field", over the two fields here: of the
# midwives both sources give a usable state AND ZIP5 for, how many agree on both.
both_fields <- inner_join(
  set_rows$practice_state[, c("id", "source_a", "source_b", "any_shared", "same_set")],
  set_rows$practice_zip5[, c("id", "source_a", "source_b", "any_shared", "same_set")],
  by = c("id", "source_a", "source_b"), suffix = c("_state", "_zip")
) %>%
  mutate(year = AUDIT_YEAR,
         any_shared = any_shared_state & any_shared_zip,
         same_set = same_set_state & same_set_zip)

summaries <- bind_rows(
  attribute_set_agreement_summary(set_rows$practice_state) %>% mutate(attribute = "practice_state"),
  attribute_set_agreement_summary(set_rows$practice_zip5) %>% mutate(attribute = "practice_zip5"),
  attribute_set_agreement_summary(both_fields) %>% mutate(attribute = "practice_state_and_zip5")
)

pair_lineage <- function(a, b) {
  p <- paste(sort(c(a, b)), collapse = "|")
  if (p == "dac|pecos") return("shared_lineage_cms_enrollment")
  if (p %in% c("doximity|nppes", "healthgrades|nppes")) return("possible_nppes_seeding")
  "separately_collected"
}

# Where each midwife falls for one pair and one field. Record presence comes
# first, so "absent from a source" and "present with a blank or malformed
# field" are never merged into disagreement.
pair_coverage <- function(a, b, attr) {
  usable <- function(s) {
    d <- per_npi[per_npi$source == s, ]
    if (attr == "practice_state_and_zip5") {
      setNames(d$practice_state_n_valid > 0 & d$practice_zip5_n_valid > 0, d$npi)
    } else setNames(d[[paste0(attr, "_n_valid")]] > 0, d$npi)
  }
  ua <- usable(a); ub <- usable(b)
  both <- intersect(names(ua), names(ub))
  tibble(n_record_both = length(both),
         n_record_a_only = length(setdiff(names(ua), names(ub))),
         n_record_b_only = length(setdiff(names(ub), names(ua))),
         n_usable_both = sum(ua[both] & ub[both]),
         n_usable_a_only = sum(ua[both] & !ub[both]),
         n_usable_b_only = sum(!ua[both] & ub[both]),
         n_usable_neither = sum(!ua[both] & !ub[both]))
}

pairs <- combn(SOURCES, 2, simplify = FALSE)
pairwise <- bind_rows(lapply(c(ATTRIBUTES, "practice_state_and_zip5"), function(attr) {
  bind_rows(lapply(pairs, function(p) {
    cov <- pair_coverage(p[1], p[2], attr)
    s <- summaries[summaries$attribute == attr &
                     ((summaries$source_a == p[1] & summaries$source_b == p[2]) |
                        (summaries$source_a == p[2] & summaries$source_b == p[1])), ]
    if (nrow(s) > 1) stop("duplicate summary row for ", paste(p, collapse = "/"), call. = FALSE)
    n_cmp <- if (nrow(s)) s$n_compared else 0L
    if (n_cmp != cov$n_usable_both) {
      stop(sprintf("%s %s/%s: set agreement compared %d, coverage says %d usable on both",
                   attr, p[1], p[2], n_cmp, cov$n_usable_both), call. = FALSE)
    }
    tibble(attribute = attr, source_a = p[1], source_b = p[2],
           lineage = pair_lineage(p[1], p[2])) %>%
      bind_cols(cov) %>%
      mutate(n_any_shared = if (nrow(s)) s$n_any_shared else 0L,
             n_same_set = if (nrow(s)) s$n_same_set else 0L)
  }))
}))

ci_any  <- wilson_ci(pairwise$n_any_shared, pairwise$n_usable_both)
ci_same <- wilson_ci(pairwise$n_same_set, pairwise$n_usable_both)
pct <- function(x, n) ifelse(n > 0, round(100 * x / n, 1), NA_real_)
pairwise <- pairwise %>%
  mutate(pct_any_shared = pct(n_any_shared, n_usable_both),
         any_shared_ci_low = round(100 * ci_any$ci_low, 1),
         any_shared_ci_high = round(100 * ci_any$ci_high, 1),
         pct_same_set = pct(n_same_set, n_usable_both),
         same_set_ci_low = round(100 * ci_same$ci_low, 1),
         same_set_ci_high = round(100 * ci_same$ci_high, 1),
         n_disagree = n_usable_both - n_any_shared,
         pct_disagree = pct(n_disagree, n_usable_both),
         # floor on the worse source's error among the compared midwives,
         # and the same floor taken from the lower end of the disagreement CI
         error_floor_pct = round(pct_disagree / 2, 1),
         error_floor_ci_low = round((100 - any_shared_ci_high) / 2, 1),
         reportable = n_usable_both >= 30)

# --- 3. odd one out ---------------------------------------------------------------
# attribute_odd_one_out() needs one value per source, so a multi-location
# source contributes its most frequent usable value (ties: DAC's lowest
# location_rank, otherwise first listed). This is a stricter view than the
# any-match pairwise rule above, and is labelled as such.
primary_value <- function(d, col) {
  d <- d[!is.na(d[[col]]), ]
  if (!nrow(d)) return(d[0, c("npi", col)])
  d %>% group_by(npi, value = .data[[col]]) %>%
    summarise(n = n(), first_row = min(row_order), .groups = "drop") %>%
    arrange(npi, desc(n), first_row) %>%
    distinct(npi, .keep_all = TRUE) %>%
    transmute(npi, year = AUDIT_YEAR, !!col := value)
}
odd_table <- function(src_names, variant) {
  bind_rows(lapply(c(practice_state = "state", practice_zip5 = "zip5"), function(col) {
    srcs <- lapply(sources[src_names], primary_value, col = col)
    recs <- attribute_odd_one_out(srcs, attribute = col)
    attr_name <- if (col == "state") "practice_state" else "practice_zip5"
    structure_rows <- recs %>% count(label = as.character(structure), name = "n") %>%
      mutate(row_type = "structure", n_eligible = nrow(recs))
    rate_rows <- attribute_odd_one_out_rate(recs) %>%
      transmute(label = source, n = n_odd_one_out, n_eligible, row_type = "source_odd_one_out")
    bind_rows(structure_rows, rate_rows) %>%
      mutate(variant = variant, attribute = attr_name,
             pct = round(100 * n / n_eligible, 1)) %>%
      select(variant, attribute, row_type, label, n, n_eligible, pct)
  }))
}
odd <- bind_rows(
  odd_table(SOURCES, "all_six_sources"),
  odd_table(setdiff(SOURCES, "dac"), "cms_enrollment_lineage_once")
)

# --- write ------------------------------------------------------------------------
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
inputs <- file.path(data_root, INPUTS)
write_with_provenance(dictionary, file.path(out_dir, "oig_style_field_dictionary.csv"), inputs = inputs)
write_with_provenance(completeness, file.path(out_dir, "oig_style_completeness.csv"), inputs = inputs)
write_with_provenance(pairwise, file.path(out_dir, "oig_style_pairwise_consistency.csv"), inputs = inputs)
write_with_provenance(odd, file.path(out_dir, "oig_style_odd_one_out.csv"), inputs = inputs)

# --- console summary and one OIG-shaped paragraph ---------------------------------
cat(sprintf("\nFrame: %d distinct NPIs\n\n-- completeness --\n", N_FRAME))
print(as.data.frame(completeness[, c("source", "attribute", "n_record_present", "n_field_blank",
                                     "n_field_malformed", "n_usable", "n_multiple_values")]))
cat("\n-- pairwise consistency (any-match) --\n")
print(as.data.frame(pairwise[, c("attribute", "source_a", "source_b", "lineage", "n_usable_both",
                                 "pct_any_shared", "any_shared_ci_low", "any_shared_ci_high",
                                 "pct_same_set", "error_floor_pct")]))
cat("\n-- odd one out --\n")
print(as.data.frame(odd))

coverage <- expand.grid(id = frame_npi, source = c("nppes", "pecos"), stringsAsFactors = FALSE)
coverage$year <- AUDIT_YEAR
coverage$record_present <- paste(coverage$source, coverage$id) %in% paste(per_npi$source, per_npi$npi)
coverage$record_status <- ifelse(coverage$record_present, "present", "not_in_source")
claims <- bind_rows(lapply(c("nppes", "pecos"), function(s) {
  d <- sources[[s]][sources[[s]]$zip5_populated, ]
  tibble(npi = d$npi, year = AUDIT_YEAR, source = s, attribute = "practice_zip5", value = "populated")
}))
presence <- attribute_record_presence(
  coverage, dictionary[dictionary$source %in% c("nppes", "pecos") & dictionary$attribute == "practice_zip5", ],
  data.frame(year = AUDIT_YEAR, source = c("nppes", "pecos"), attribute = "practice_zip5",
             field_available = TRUE),
  claims
)
zip_summary <- attribute_set_agreement_summary(set_rows$practice_zip5)
cat("\n-- results paragraph (NPPES vs PECOS, practice ZIP) --\n")
cat(strwrap(attribute_oig_audit_prose(presence, zip_summary, year = AUDIT_YEAR,
                                      source_a = "nppes", source_b = "pecos",
                                      attribute = "practice_zip5",
                                      attribute_label = "practice ZIP codes")), sep = "\n")
