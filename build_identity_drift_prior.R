#!/usr/bin/env Rscript

# =============================================================================
# Empirical identity drift, 2013 -> 2026, on two populations
#
# Produces two drift tables:
#
#   deterministic_identity_set  every pair keyed by EXACT NPI carried natively
#                               by both sources. No name comparison is used to
#                               form a pair, so nothing a name matcher believes
#                               can influence what drift looks like.
#
#   current_matcher_set         the subset whose NPI also appears in the AMCB
#                               tracked roster. That NPI was assigned by the
#                               production name matcher, so this population is
#                               potentially SELECTED by it.
#
# Only the deterministic set may inform a mysterynpi prior. The matcher set is
# a descriptive sensitivity analysis. If the two distributions differ
# materially, the deterministic set controls.
#
# ---------------------------------------------------------------------------
# WHY THE DETERMINISTIC SET IS KEYED THIS WAY
#
# A deterministic AMCB -> NPI link does not exist in this repository, and this
# is structural rather than an oversight: AMCB publishes no NPI, so every
# AMCB -> NPI link must pass through a name at some point. Verified:
#
#   * every roster link is `exact_last_first` (11,026) or
#     `exact_last_first_initial` (67) -- name-based by construction;
#   * all four documented evidence classes are name comparisons
#     (exact first+last with middle, without middle, last+initial, fuzzy last);
#   * the state-board harvests take the NPI FROM the roster and then search the
#     board BY NAME, so they add no independent identifier;
#   * the adjudicated truth set is infrastructure only -- 327 planned rows with
#     empty verdict columns, and the instrument/reviews/resolution files are
#     not on disk.
#
# So the deterministic population is defined the way the request's own list
# permits: "historical DAC <-> historical NPPES exact NPI". DAC and NPPES both
# carry NPI natively. Following one NPI from 2013 DAC to 2026 DAC involves no
# name matching whatsoever, and the population is defined by CMS's own CNM
# designation rather than by anything this repository's matcher decided.
#
# This measures attribute drift for a person whose identity is fixed by
# construction. That is exactly what a prior needs, and it is uncontaminated.
#
# Inputs:
#   artifacts/cms_physician_compare/dac_person_snapshot_2013_*.csv
#   artifacts/cms_physician_compare/nppes_2013_cnm_extract (former-name signal)
#   data/raw/cms_physician_compare/2026/DAC_NationalDownloadableFile_2026-08.csv
#   artifacts/tracked_roster_active_primary_linked.csv (membership ONLY)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
artifact_dir <- file.path("artifacts", "cms_physician_compare")

DAC_2026 <- file.path("data", "raw", "cms_physician_compare", "2026",
                      "DAC_NationalDownloadableFile_2026-08.csv")
NPPES_EXTRACT <- file.path("data", "raw", "nppes", "2013",
                           "nppes_2013_cnm_extract.csv")
ROSTER <- file.path("artifacts", "tracked_roster_active_primary_linked.csv")

stopifnot(file.exists(DAC_2026), file.exists(ROSTER))


# -------------------------------------------------------------------------
# 1. 2013 identity, one row per NPI
# -------------------------------------------------------------------------

person_files <- sort(list.files(
  artifact_dir, pattern = "^dac_person_snapshot_2013_.*\\.csv$", full.names = TRUE
))
if (length(person_files) == 0L) {
  stop("Run build_dac_identity_spine_2013.R first.", call. = FALSE)
}

drift_norm <- function(x) {
  x |>
    toupper() |>
    stringr::str_replace_all("[^A-Z0-9 ]", " ") |>
    stringr::str_squish() |>
    dplyr::na_if("")
}

drift_zip5 <- function(x) {
  out <- stringr::str_sub(stringr::str_remove_all(x, "\\D"), 1, 5)
  dplyr::na_if(out, "")
}

# CMS RENAMED SPECIALTY VALUES BETWEEN 2013 AND 2026, and the rename is not a
# change in the provider. 2013 says "CERTIFIED NURSE MIDWIFE"; 2026 says
# "CERTIFIED NURSE MIDWIFE (CNM)", which normalises to "... CNM". Left alone
# this scored 748 of 807 apparent specialty changes -- 98.2% drift, almost all
# of it vocabulary. Canonicalising first brings it to the real rate.
#
# Only exact, verified CMS renamings belong here. Anything broader would start
# concealing genuine specialty change, which is the opposite of the point.
SPECIALTY_SYNONYMS <- c(
  "CERTIFIED NURSE MIDWIFE CNM" = "CERTIFIED NURSE MIDWIFE",
  "CERTIFIED CLINICAL NURSE SPECIALIST CNS" = "CERTIFIED CLINICAL NURSE SPECIALIST",
  "CERTIFIED REGISTERED NURSE ANESTHETIST CRNA" = "CERTIFIED REGISTERED NURSE ANESTHETIST"
)

canon_specialty <- function(x) {
  parts <- stringr::str_split(x, "\\|")
  vapply(parts, function(v) {
    if (length(v) == 1L && is.na(v[[1]])) return(NA_character_)
    v <- dplyr::coalesce(SPECIALTY_SYNONYMS[v], v)
    paste(sort(unique(v)), collapse = "|")
  }, character(1))
}

# Where June and September disagree, the LATER snapshot is taken as the 2013
# identity. Taking the earlier one would count three months of within-2013
# drift as part of the thirteen-year drift being measured.
dac_2013 <- read_csv(person_files[[length(person_files)]],
                     col_types = cols(.default = col_character())) |>
  mutate(snapshot_date = as.Date(.data$snapshot_date)) |>
  arrange(.data$npi, .data$snapshot_date) |>
  group_by(.data$npi) |>
  slice_tail(n = 1) |>
  ungroup() |>
  transmute(
    npi = .data$npi,
    first_2013 = drift_norm(.data$first_name),
    middle_2013 = drift_norm(.data$middle_name),
    last_2013 = drift_norm(.data$last_name),
    credential_2013 = drift_norm(.data$credential),
    state_2013 = drift_norm(.data$practice_state),
    zip_2013 = drift_zip5(.data$practice_zip),
    org_2013 = drift_norm(.data$group_pac_id),
    specialty_2013 = canon_specialty(drift_norm(.data$primary_specialty))
  )

base::message("[2013] ", format(nrow(dac_2013), big.mark = ","), " CNM NPIs")


# -------------------------------------------------------------------------
# 2. 2026 identity for the same NPIs, keyed by NPI alone
# -------------------------------------------------------------------------

drift_collapse_set <- function(x) {
  v <- unique(x[!is.na(x) & nzchar(x)])
  if (length(v) == 0L) return(NA_character_)
  paste(sort(v), collapse = "|")
}

base::message("[2026] Scanning ", basename(DAC_2026))

dac_2026_raw <- read_csv(
  DAC_2026,
  col_types = cols(.default = col_character()),
  col_select = c("NPI", "Provider First Name", "Provider Middle Name",
                 "Provider Last Name", "Cred", "State", "ZIP Code",
                 "org_pac_id", "pri_spec"),
  progress = FALSE
) |>
  filter(.data$NPI %in% dac_2013$npi)

dac_2026 <- dac_2026_raw |>
  group_by(npi = .data$NPI) |>
  summarise(
    first_2026 = drift_collapse_set(drift_norm(.data$`Provider First Name`)),
    middle_2026 = drift_collapse_set(drift_norm(.data$`Provider Middle Name`)),
    last_2026 = drift_collapse_set(drift_norm(.data$`Provider Last Name`)),
    credential_2026 = drift_collapse_set(drift_norm(.data$Cred)),
    state_2026 = drift_collapse_set(drift_norm(.data$State)),
    zip_2026 = drift_collapse_set(drift_zip5(.data$`ZIP Code`)),
    org_2026 = drift_collapse_set(drift_norm(.data$org_pac_id)),
    specialty_2026 = canon_specialty(drift_collapse_set(drift_norm(.data$pri_spec))),
    .groups = "drop"
  )

base::message("[2026] ", format(nrow(dac_2026), big.mark = ","),
              " of the 2013 CNM NPIs still present in 2026 DAC")


# -------------------------------------------------------------------------
# 3. The former-surname signal, kept as its own field
# -------------------------------------------------------------------------

# NPPES "Provider Other Last Name" with its type code is a DIRECT prior-name
# assertion by CMS, not an inferred difference between two observations. It is
# carried separately for that reason: a matcher should be able to treat "CMS
# says this person formerly used surname X" as evidence in its own right.
former <- if (file.exists(NPPES_EXTRACT)) {
  read_csv(NPPES_EXTRACT, col_types = cols(.default = col_character())) |>
    transmute(
      npi = .data$npi,
      other_surname_2013 = drift_norm(.data$nppes_other_last_name),
      other_surname_type_2013 = .data$nppes_other_last_name_type
    )
} else {
  tibble::tibble(npi = character(), other_surname_2013 = character(),
                 other_surname_type_2013 = character())
}


# -------------------------------------------------------------------------
# 4. Join and flag drift
# -------------------------------------------------------------------------

roster_npis <- read_csv(ROSTER, col_types = cols(.default = col_character()))$npi |>
  stringr::str_trim() |>
  unique()

changed <- function(x, y) ifelse(is.na(x) | is.na(y), NA, x != y)

drift <- dac_2013 |>
  inner_join(dac_2026, by = "npi") |>
  left_join(former, by = "npi") |>
  mutate(
    first_name_change = changed(.data$first_2013, .data$first_2026),
    middle_name_change = changed(.data$middle_2013, .data$middle_2026),
    last_name_change = changed(.data$last_2013, .data$last_2026),
    former_surname_present = !is.na(.data$other_surname_2013),
    credential_change = changed(.data$credential_2013, .data$credential_2026),
    state_change = changed(.data$state_2013, .data$state_2026),
    zip_change = changed(.data$zip_2013, .data$zip_2026),
    organization_change = changed(.data$org_2013, .data$org_2026),
    specialty_change = changed(.data$specialty_2013, .data$specialty_2026),
    in_current_matcher_set = .data$npi %in% roster_npis
  )

drift_path <- file.path(
  artifact_dir, paste0("identity_drift_2013_2026_", timestamp, ".csv")
)
write_with_provenance(drift, drift_path, inputs = c(DAC_2026, ROSTER))


# -------------------------------------------------------------------------
# 5. Drift tables
# -------------------------------------------------------------------------

FIELDS <- c(
  first_name_change = "first-name change",
  middle_name_change = "middle-name change",
  last_name_change = "last-name change",
  former_surname_present = "other/former surname present",
  credential_change = "credential change",
  state_change = "state change",
  zip_change = "ZIP change",
  organization_change = "organization change",
  specialty_change = "taxonomy/specialty change"
)

drift_table <- function(data, population) {
  purrr::imap_dfr(FIELDS, function(label, flag) {
    v <- data[[flag]]
    denominator <- sum(!is.na(v))
    numerator <- sum(v, na.rm = TRUE)
    tibble::tibble(
      population = population,
      field = label,
      N = nrow(data),
      numerator = numerator,
      denominator = denominator,
      pct = if (denominator == 0L) NA_real_ else 100 * numerator / denominator
    )
  })
}

deterministic <- drift_table(drift, "deterministic_identity_set")
matcher <- drift_table(filter(drift, .data$in_current_matcher_set),
                       "current_matcher_set")

comparison <- deterministic |>
  select("field", det_N = "N", det_num = "numerator",
         det_den = "denominator", det_pct = "pct") |>
  left_join(
    matcher |> select("field", mat_N = "N", mat_num = "numerator",
                      mat_den = "denominator", mat_pct = "pct"),
    by = "field"
  ) |>
  mutate(difference_pp = .data$mat_pct - .data$det_pct)

write_csv(bind_rows(deterministic, matcher),
          file.path(artifact_dir,
                    paste0("identity_drift_tables_", timestamp, ".csv")))
write_csv(comparison,
          file.path(artifact_dir,
                    paste0("identity_drift_comparison_", timestamp, ".csv")))

base::message("")
base::message("==================================================================")
base::message("IDENTITY DRIFT 2013 -> 2026")
base::message("==================================================================")
base::message("deterministic_identity_set  N = ",
              format(nrow(drift), big.mark = ","),
              "   (NPI-keyed, no name matching)")
base::message("current_matcher_set         N = ",
              format(sum(drift$in_current_matcher_set), big.mark = ","),
              "   (AMCB roster subset, name-matched)")
base::message("------------------------------------------------------------------")
base::message(sprintf("%-30s %16s %16s %8s",
                      "field", "deterministic", "matcher", "diff_pp"))
for (i in seq_len(nrow(comparison))) {
  base::message(sprintf(
    "%-30s %7s/%-7s %5s  %7s/%-7s %5s  %+7.1f",
    comparison$field[[i]],
    format(comparison$det_num[[i]], big.mark = ","),
    format(comparison$det_den[[i]], big.mark = ","),
    sprintf("%.1f%%", comparison$det_pct[[i]]),
    format(comparison$mat_num[[i]], big.mark = ","),
    format(comparison$mat_den[[i]], big.mark = ","),
    sprintf("%.1f%%", comparison$mat_pct[[i]]),
    comparison$difference_pp[[i]]
  ))
}
base::message("------------------------------------------------------------------")
base::message("Prior source: deterministic_identity_set ONLY.")
base::message("Artifacts: ", drift_path)
base::message("==================================================================")
