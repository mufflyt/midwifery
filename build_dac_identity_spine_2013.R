#!/usr/bin/env Rscript

# =============================================================================
# A longitudinal DAC identity spine, starting with 2013
#
# Produces one row per NPI x snapshot_date, preserving raw identity and
# affiliation fields. Affiliations are NOT collapsed: a provider with several
# rows in one snapshot keeps all of them, because the repeated rows are what
# carry the historical group PAC IDs and hospital CCNs.
#
#   5,296 midwife ROWS in 2013-06 are not 5,296 people. The person-level
#   denominator is 2,393 unique NPIs.
#
# Then a person-level June-vs-September comparison, which exists to answer one
# question: how much does a provider's recorded identity drift across three
# months of the same year? That is the floor for what "normal" drift looks
# like, and it is measured rather than assumed.
#
# This script DOES NOT touch the AMCB -> NPI canonical linkage and does not
# change any matcher. It writes only to artifacts/cms_physician_compare/.
#
# Input:  artifacts/cms_physician_compare/physician_compare_2013_manifest.csv
#         (written by acquire_physician_compare_2013.R)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
artifact_dir <- file.path("artifacts", "cms_physician_compare")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

manifest_path <- file.path(artifact_dir, "physician_compare_2013_manifest.csv")

if (!file.exists(manifest_path)) {
  stop("Manifest not found. Run acquire_physician_compare_2013.R first.",
       call. = FALSE)
}

manifest <- read_csv(manifest_path, show_col_types = FALSE)

base::message("[MANIFEST] ", nrow(manifest), " snapshot(s): ",
              paste(format(manifest$snapshot_date), collapse = ", "))


# -------------------------------------------------------------------------
# 1. The 2013 column vocabulary, stated once
# -------------------------------------------------------------------------

# The 2013 schema is NOT the modern one. It has 50 columns to today's 31, and
# the names differ throughout: "Primary specialty" vs pri_spec, "Organization
# legal name" vs "Facility Name", "Group Practice PAC ID" vs org_pac_id.
#
# It also carries something the modern National Downloadable File no longer
# does: "Claims based hospital affiliation CCN/LBN 1-10", inline. CMS later
# moved affiliation into a separate Facility Affiliation file. For 2013 the
# hospital link is free.
#
# Mapping to canonical names here means the spine's schema is stable even as
# upstream column names change across years.
DAC_2013_COLUMNS <- c(
  npi                  = "NPI",
  individual_pac_id    = "PAC ID",
  enrollment_id        = "Professional Enrollment ID",
  last_name            = "Last Name",
  first_name           = "First Name",
  middle_name          = "Middle Name",
  suffix               = "Suffix",
  gender               = "Gender",
  credential           = "Credential",
  medical_school       = "Medical school name",
  graduation_year      = "Graduation year",
  primary_specialty    = "Primary specialty",
  secondary_specialty_1 = "Secondary specialty 1",
  secondary_specialty_2 = "Secondary specialty 2",
  secondary_specialty_3 = "Secondary specialty 3",
  secondary_specialty_4 = "Secondary specialty 4",
  all_secondary_specialties = "All secondary specialties",
  group_practice_name  = "Organization legal name",
  group_pac_id         = "Group Practice PAC ID",
  group_member_count   = "Number of Group Practice members",
  practice_address_1   = "Line 1 Street Address",
  practice_address_2   = "Line 2 Street Address",
  practice_city        = "City",
  practice_state       = "State",
  practice_zip         = "Zip Code",
  hospital_ccn_1       = "Claims based hospital affiliation CCN 1",
  hospital_lbn_1       = "Claims based hospital affiliation LBN 1",
  hospital_ccn_2       = "Claims based hospital affiliation CCN 2",
  hospital_lbn_2       = "Claims based hospital affiliation LBN 2",
  hospital_ccn_3       = "Claims based hospital affiliation CCN 3",
  hospital_lbn_3       = "Claims based hospital affiliation LBN 3",
  hospital_ccn_4       = "Claims based hospital affiliation CCN 4",
  hospital_lbn_4       = "Claims based hospital affiliation LBN 4",
  hospital_ccn_5       = "Claims based hospital affiliation CCN 5",
  hospital_lbn_5       = "Claims based hospital affiliation LBN 5",
  accepts_assignment   = "Professional accepts Medicare Assignment"
)

# Verified against 2013-06: the ONLY values carrying midwife terminology are
# "CERTIFIED NURSE MIDWIFE" in Primary specialty (5,075 rows) and "CNM" in
# Credential (2,257 rows), with no secondary-specialty hits. Note the absent
# "(CNM)" suffix -- the modern file says "CERTIFIED NURSE MIDWIFE (CNM)", so an
# equality test against today's string returns zero. Credential alone
# contributes 54 NPIs the specialty field misses, which is why both are used.
CNM_PRIMARY_SPECIALTY <- "CERTIFIED NURSE MIDWIFE"
CNM_CREDENTIAL <- "CNM"


# -------------------------------------------------------------------------
# 2. Build the spine: one row per NPI x snapshot_date x source row
# -------------------------------------------------------------------------

dac_spine_read_snapshot <- function(snapshot_date, local_path, sha256, ...) {

  base::message("[READ] ", basename(local_path))

  # All-character on purpose: NPIs, PAC IDs, CCNs and ZIPs are identifiers, not
  # numbers. Type guessing drops leading zeros and can coerce a mixed column.
  raw <- read_csv(local_path, col_types = cols(.default = col_character()),
                  progress = FALSE)

  present <- DAC_2013_COLUMNS[DAC_2013_COLUMNS %in% names(raw)]

  missing <- setdiff(names(DAC_2013_COLUMNS), names(present))
  if (length(missing)) {
    base::message("[READ]   absent from this snapshot: ",
                  paste(missing, collapse = ", "))
  }

  cnm_rows <- raw[[present[["primary_specialty"]]]] == CNM_PRIMARY_SPECIALTY |
    raw[[present[["credential"]]]] == CNM_CREDENTIAL
  cnm_rows[is.na(cnm_rows)] <- FALSE

  base::message("[READ]   ", format(nrow(raw), big.mark = ","), " rows; ",
                format(sum(cnm_rows), big.mark = ","), " midwife rows")

  raw[cnm_rows, present, drop = FALSE] |>
    rlang::set_names(names(present)) |>
    mutate(
      snapshot_date = as.Date(snapshot_date),
      source_file = basename(local_path),
      source_sha256 = sha256,
      .before = 1
    )
}


spine <- purrr::pmap_dfr(manifest, dac_spine_read_snapshot)

# Affiliations stay uncollapsed; this is the row multiplicity, recorded so a
# reader never mistakes rows for people.
row_multiplicity <- spine |>
  count(.data$snapshot_date, .data$npi, name = "rows_in_snapshot") |>
  count(.data$snapshot_date, .data$rows_in_snapshot, name = "n_npis")

spine_path <- file.path(
  artifact_dir, paste0("dac_identity_spine_2013_", timestamp, ".csv")
)
write_with_provenance(spine, spine_path, inputs = manifest$local_path)

write_csv(
  row_multiplicity,
  file.path(artifact_dir,
            paste0("dac_identity_spine_2013_row_multiplicity_", timestamp, ".csv"))
)

base::message("[SPINE] ", format(nrow(spine), big.mark = ","),
              " rows x ", ncol(spine), " columns")


# -------------------------------------------------------------------------
# 3. Person-level view within each snapshot
# -------------------------------------------------------------------------

# One row per NPI per snapshot. Multi-valued fields are collapsed to a sorted,
# de-duplicated set so a comparison across snapshots is order-insensitive: a
# provider whose two hospital CCNs swap position between June and September has
# not changed affiliation, and must not be scored as though they had.
dac_spine_collapse_set <- function(x) {
  v <- unique(x[!is.na(x) & nzchar(x)])
  if (length(v) == 0L) return(NA_character_)
  paste(sort(v), collapse = "|")
}

ccn_columns <- grep("^hospital_ccn_", names(spine), value = TRUE)

person <- spine |>
  mutate(hospital_ccn_set = apply(across(all_of(ccn_columns)), 1, dac_spine_collapse_set)) |>
  group_by(.data$snapshot_date, .data$npi) |>
  summarise(
    first_name = dac_spine_collapse_set(.data$first_name),
    middle_name = dac_spine_collapse_set(.data$middle_name),
    last_name = dac_spine_collapse_set(.data$last_name),
    suffix = dac_spine_collapse_set(.data$suffix),
    credential = dac_spine_collapse_set(.data$credential),
    gender = dac_spine_collapse_set(.data$gender),
    primary_specialty = dac_spine_collapse_set(.data$primary_specialty),
    medical_school = dac_spine_collapse_set(.data$medical_school),
    graduation_year = dac_spine_collapse_set(.data$graduation_year),
    group_pac_id = dac_spine_collapse_set(.data$group_pac_id),
    group_practice_name = dac_spine_collapse_set(.data$group_practice_name),
    practice_state = dac_spine_collapse_set(.data$practice_state),
    practice_zip = dac_spine_collapse_set(.data$practice_zip),
    hospital_ccn_set = dac_spine_collapse_set(.data$hospital_ccn_set),
    n_rows = dplyr::n(),
    .groups = "drop"
  )

person_path <- file.path(
  artifact_dir, paste0("dac_person_snapshot_2013_", timestamp, ".csv")
)
write_with_provenance(person, person_path, inputs = manifest$local_path)


# -------------------------------------------------------------------------
# 4. June vs September comparison
# -------------------------------------------------------------------------

snapshots <- sort(unique(person$snapshot_date))

if (length(snapshots) < 2L) {

  base::message("[COMPARE] Only one snapshot present; comparison skipped.")
  comparison <- tibble::tibble()

} else {

  early <- snapshots[[1]]
  late <- snapshots[[length(snapshots)]]

  a <- person |> filter(.data$snapshot_date == early) |> select(-"snapshot_date")
  b <- person |> filter(.data$snapshot_date == late) |> select(-"snapshot_date")

  # Compared only where BOTH snapshots carry a value. A field that is blank in
  # one month is a reporting gap, not a change, and scoring it as a change
  # would inflate every drift rate.
  changed <- function(x, y) {
    ifelse(is.na(x) | is.na(y), NA, x != y)
  }

  comparison <- full_join(a, b, by = "npi", suffix = c("_jun", "_sep")) |>
    transmute(
      npi = .data$npi,
      june_present = .data$npi %in% a$npi,
      september_present = .data$npi %in% b$npi,
      name_changed = changed(
        paste(.data$first_name_jun, .data$middle_name_jun, .data$last_name_jun),
        paste(.data$first_name_sep, .data$middle_name_sep, .data$last_name_sep)
      ),
      last_name_changed = changed(.data$last_name_jun, .data$last_name_sep),
      credential_changed = changed(.data$credential_jun, .data$credential_sep),
      specialty_changed = changed(.data$primary_specialty_jun, .data$primary_specialty_sep),
      practice_state_changed = changed(.data$practice_state_jun, .data$practice_state_sep),
      practice_zip_changed = changed(.data$practice_zip_jun, .data$practice_zip_sep),
      group_pac_changed = changed(.data$group_pac_id_jun, .data$group_pac_id_sep),
      hospital_affiliation_changed = changed(.data$hospital_ccn_set_jun,
                                             .data$hospital_ccn_set_sep)
    )

  comparison_path <- file.path(
    artifact_dir, paste0("dac_person_comparison_2013_", timestamp, ".csv")
  )
  write_with_provenance(comparison, comparison_path, inputs = manifest$local_path)
}


# -------------------------------------------------------------------------
# 5. Report
# -------------------------------------------------------------------------

dac_spine_pct <- function(numerator, denominator) {
  if (denominator == 0L) return(NA_character_)
  sprintf("%.1f%%", 100 * numerator / denominator)
}

# Among providers in BOTH snapshots, the share whose field is identical. NA
# (one side blank) is excluded from the denominator and reported separately, so
# "identical" never silently absorbs a missing value.
stable_share <- function(flag) {
  both <- comparison |> filter(.data$june_present, .data$september_present)
  v <- both[[flag]]
  comparable <- sum(!is.na(v))
  identical_n <- sum(!is.na(v) & !v)
  tibble::tibble(
    field = sub("_changed$", "", flag),
    comparable = comparable,
    identical = identical_n,
    identical_pct = dac_spine_pct(identical_n, comparable),
    not_comparable = sum(is.na(v))
  )
}

if (nrow(comparison) > 0L) {

  june_n <- sum(comparison$june_present)
  sept_n <- sum(comparison$september_present)
  both_n <- sum(comparison$june_present & comparison$september_present)
  union_n <- nrow(comparison)

  overlap <- tibble::tibble(
    metric = c("june_unique_cnm_npis", "september_unique_cnm_npis",
               "intersection", "union", "june_only", "september_only",
               "jaccard_overlap"),
    value = c(
      format(june_n, big.mark = ","),
      format(sept_n, big.mark = ","),
      format(both_n, big.mark = ","),
      format(union_n, big.mark = ","),
      format(june_n - both_n, big.mark = ","),
      format(sept_n - both_n, big.mark = ","),
      sprintf("%.3f", both_n / union_n)
    )
  )

  stability <- purrr::map_dfr(
    c("name_changed", "last_name_changed", "credential_changed",
      "specialty_changed", "practice_state_changed", "practice_zip_changed",
      "group_pac_changed", "hospital_affiliation_changed"),
    stable_share
  )

  write_csv(
    overlap,
    file.path(artifact_dir,
              paste0("dac_2013_overlap_summary_", timestamp, ".csv"))
  )
  write_csv(
    stability,
    file.path(artifact_dir,
              paste0("dac_2013_field_stability_", timestamp, ".csv"))
  )

  base::message("")
  base::message("========================================")
  base::message("2013 DAC SPINE: JUNE vs SEPTEMBER")
  base::message("========================================")
  for (i in seq_len(nrow(overlap))) {
    base::message(sprintf("%-28s %s", overlap$metric[[i]], overlap$value[[i]]))
  }
  base::message("----------------------------------------")
  base::message("Field stability among NPIs in both snapshots:")
  base::message(sprintf("%-24s %10s %10s %9s %s",
                        "field", "comparable", "identical", "pct", "not_comp"))
  for (i in seq_len(nrow(stability))) {
    base::message(sprintf("%-24s %10s %10s %9s %s",
                          stability$field[[i]],
                          format(stability$comparable[[i]], big.mark = ","),
                          format(stability$identical[[i]], big.mark = ","),
                          stability$identical_pct[[i]],
                          format(stability$not_comparable[[i]], big.mark = ",")))
  }
  base::message("----------------------------------------")
  base::message("Spine:      ", spine_path)
  base::message("Person:     ", person_path)
  base::message("Comparison: ", comparison_path)
  base::message("========================================")
}
