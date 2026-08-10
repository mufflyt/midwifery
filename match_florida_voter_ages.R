#!/usr/bin/env Rscript
# =============================================================================
# Florida Voter Registration DOB Matcher & 3-Stage Disambiguation Engine (R)
# =============================================================================
#
# Constraints & Directives:
#   - Age Boundaries: Exclude ages < 22 years OR > 80 years (22 <= age <= 80).
#   - Disambiguation Tiers:
#       1. Tier 1: Unambiguous Unique Name (N_voter == 1 in FL, Confidence = 1.00)
#       2. Tier 2: Geographically Disambiguated (N_voter > 1, City/ZIP Match, Confidence = 0.95)
#       3. Tier 3: Ambiguous Collisions Excluded (N_voter > 1, Unresolved -> Excluded)
#
# Inputs:
#   - Cohort: artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv
#   - FL Voter File: artifacts/fl_voter_extract.csv (or .txt / .gz)
#
# Outputs:
#   - artifacts/florida_voter_license_ages.csv
#   - artifacts/florida_voter_license_ages_provenance.csv
# =============================================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(purrr)
})

REF_YEAR <- 2026L
MIN_AGE  <- 22L
MAX_AGE  <- 80L

cat("=== Florida Voter Registration DOB Extractor & Matcher (R) ===\n")
cat(sprintf("Age Boundary Constraint: %d <= Age <= %d years\n", MIN_AGE, MAX_AGE))

# --- 1. Load AMCB Cohort Roster ---------------------------------------------
roster_candidates <- c(
  "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv",
  "artifacts/amcb_npi_linkage_FROZEN.csv",
  "midwives.csv"
)
roster_path <- roster_candidates[file.exists(roster_candidates)][1]

if (is.na(roster_path))
  stop("Cohort roster file not found.", call. = FALSE)

cat(sprintf("Loading cohort roster: %s\n", roster_path))
raw_coh <- read_csv(roster_path, show_col_types = FALSE, progress = FALSE)

coh <- raw_coh
if ("status" %in% names(coh)) coh <- coh %>% filter(status == "ACTIVE")
if ("linkage_tier" %in% names(coh)) coh <- coh %>% filter(linkage_tier == "primary_midwifery")

coh <- coh %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    certification_number = as.character(certification_number),
    last_upper  = str_to_upper(str_trim(last_name)),
    first_upper = str_to_upper(str_squish(first_name)),
    last_clean  = str_remove_all(last_upper, "[^A-Z]"),
    first_token = str_to_upper(map_chr(str_split(first_upper, "\\s+"), 1)),
    nppes_city_clean = if ("nppes_city" %in% names(.)) str_to_upper(str_trim(nppes_city)) else NA_character_,
    nppes_zip_clean  = if ("nppes_zip" %in% names(.)) str_sub(as.character(nppes_zip), 1, 5) else NA_character_
  ) %>%
  filter(!is.na(last_upper), last_upper != "", !is.na(first_upper), first_upper != "")

cat(sprintf("Cohort: %s ACTIVE primary-linked midwives\n",
            format(nrow(coh), big.mark = ",")))

fl_coh <- coh %>% filter(nppes_state == "FL")
cat(sprintf("  Florida-Practicing Midwives in Cohort: %s\n", format(nrow(fl_coh), big.mark = ",")))

# --- 2. Check for Florida Voter Registration Data File -----------------------
fl_data_paths <- c(
  "artifacts/fl_voter_extract.csv",
  "artifacts/fl_voter_extract.txt",
  "artifacts/fl_voter_extract.csv.gz",
  "artifacts/fl_voter_extract.txt.gz",
  "fl_voter_extract.csv"
)

fl_file <- fl_data_paths[file.exists(fl_data_paths)][1]

if (is.na(fl_file)) {
  cat("\n[Notice]: Local Florida Voter File extract not found in default path (artifacts/fl_voter_extract.csv).\n")
  cat("  To process Florida voter registration DOBs:\n")
  cat("  1. Place the Florida DOS Division of Elections extract file at: artifacts/fl_voter_extract.csv\n")
  cat("  2. Re-run: ./match_florida_voter_ages.R\n\n")

  # Generate template artifact & provenance log
  dir.create("artifacts", showWarnings = FALSE)
  write_csv(tibble(
    certification_number = character(), last_name = character(), first_name = character(),
    state_source = character(), voter_dob = character(), fl_birth_year = integer(),
    fl_age_at_ref = numeric(), fl_age_plausible = logical(), match_method = character(),
    match_confidence = numeric(), voter_freq_in_fl = integer(), voter_city = character(), voter_zip = character()
  ), "artifacts/florida_voter_license_ages.csv")

  write_csv(tibble(
    built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    ref_year = REF_YEAR, min_age_constraint = MIN_AGE, max_age_constraint = MAX_AGE,
    status = "Pending_Florida_Extract_File"
  ), "artifacts/florida_voter_license_ages_provenance.csv")

  cat("Template artifacts generated.\n")
  quit(status = 0)
}

cat(sprintf("\nProcessing Florida Voter File: %s\n", fl_file))

# Stream & process Florida voter file
fl_voters <- read_csv(fl_file, show_col_types = FALSE, progress = FALSE)

# Normalize column names
names(fl_voters) <- str_to_upper(str_trim(names(fl_voters)))

# Extract key columns
idx_last  <- names(fl_voters)[str_detect(names(fl_voters), "LAST_NAME|LASTNAME|LAST|LNAME")][1]
idx_first <- names(fl_voters)[str_detect(names(fl_voters), "FIRST_NAME|FIRSTNAME|FIRST|FNAME")][1]
idx_dob   <- names(fl_voters)[str_detect(names(fl_voters), "DATE_OF_BIRTH|BIRTH_DATE|DOB|BIRTHDATE")][1]
idx_city  <- names(fl_voters)[str_detect(names(fl_voters), "CITY|RESIDENTIAL_CITY")][1]
idx_zip   <- names(fl_voters)[str_detect(names(fl_voters), "ZIP|ZIP_CODE|POSTAL")][1]

if (is.na(idx_last) || is.na(idx_first) || is.na(idx_dob))
  stop("Required columns (LAST_NAME, FIRST_NAME, DATE_OF_BIRTH) not found in Florida voter file.", call. = FALSE)

cat(sprintf("Mapping Florida columns: Last='%s', First='%s', DOB='%s'\n", idx_last, idx_first, idx_dob))

fl_voters <- fl_voters %>%
  rename(
    LAST_NAME     = !!sym(idx_last),
    FIRST_NAME    = !!sym(idx_first),
    DATE_OF_BIRTH = !!sym(idx_dob)
  ) %>%
  mutate(
    last_upper  = str_to_upper(str_trim(LAST_NAME)),
    first_upper = str_to_upper(str_squish(FIRST_NAME)),
    birth_year  = suppressWarnings(as.integer(str_extract(DATE_OF_BIRTH, "[0-9]{4}"))),
    voter_age   = REF_YEAR - birth_year,
    voter_city  = if (!is.na(idx_city)) str_to_upper(str_trim(.data[[idx_city]])) else NA_character_,
    voter_zip   = if (!is.na(idx_zip)) str_sub(str_trim(as.character(.data[[idx_zip]])), 1, 5) else NA_character_
  ) %>%
  filter(
    !is.na(last_upper), last_upper != "",
    !is.na(first_upper), first_upper != "",
    !is.na(birth_year),
    voter_age >= MIN_AGE, voter_age <= MAX_AGE  # Enforce 22 <= Age <= 80 boundary
  )

cat(sprintf("Florida Voters Filtered (%d <= Age <= %d): %s\n",
            MIN_AGE, MAX_AGE, format(nrow(fl_voters), big.mark = ",")))

# --- 3. 3-Stage Disambiguation Engine ---------------------------------------
cat("\n=== Executing 3-Stage Disambiguation Engine in R (Florida) ===\n")

voter_counts <- fl_voters %>%
  count(last_upper, first_upper, name = "voter_freq_in_fl")

candidate_joins <- inner_join(
  coh,
  fl_voters,
  by = c("last_upper", "first_upper")
) %>%
  left_join(voter_counts, by = c("last_upper", "first_upper"))

cat(sprintf("Candidate matches generated: %s\n", format(nrow(candidate_joins), big.mark = ",")))

# Tier 1: Unambiguous Unique Name (voter_freq_in_fl == 1)
tier1 <- candidate_joins %>%
  filter(voter_freq_in_fl == 1) %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    match_method     = "unambiguous_unique_name",
    match_confidence = 1.00
  )

remaining_coh <- coh %>% filter(!certification_number %in% tier1$certification_number)

# Tier 2: Geographic Disambiguation (voter_freq_in_fl > 1, match on City or ZIP)
candidate_geo <- candidate_joins %>%
  filter(certification_number %in% remaining_coh$certification_number) %>%
  mutate(
    city_match = !is.na(nppes_city_clean) & !is.na(voter_city) &
                 (voter_city == nppes_city_clean | str_detect(voter_city, fixed(nppes_city_clean)) | str_detect(nppes_city_clean, fixed(voter_city))),
    zip_match  = !is.na(nppes_zip_clean) & !is.na(voter_zip) & voter_zip == nppes_zip_clean,
    geo_hit    = city_match | zip_match
  ) %>%
  filter(geo_hit)

geo_counts <- candidate_geo %>% count(certification_number, name = "n_geo_hits")
tier2_valid <- geo_counts %>% filter(n_geo_hits == 1) %>% pull(certification_number)

tier2 <- candidate_geo %>%
  filter(certification_number %in% tier2_valid) %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    match_method     = "geo_disambiguated_name",
    match_confidence = 0.95
  )

matched <- bind_rows(tier1, tier2) %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    state_source     = "FL_Voter",
    voter_dob        = DATE_OF_BIRTH,
    fl_birth_year    = birth_year,
    fl_age_at_ref    = REF_YEAR - birth_year,
    fl_age_plausible = fl_age_at_ref >= MIN_AGE & fl_age_at_ref <= MAX_AGE
  )

excluded_n <- n_distinct(candidate_joins$certification_number) - nrow(matched)

cat("\nDisambiguation Statistics (Florida R Engine):\n")
cat(sprintf("  Tier 1 Unambiguous Unique Name (100%% confidence, N_voter=1) : %s\n",
            format(nrow(tier1), big.mark = ",")))
cat(sprintf("  Tier 2 Geographically Disambiguated (95%% confidence, City/Zip): %s\n",
            format(nrow(tier2), big.mark = ",")))
cat(sprintf("  Tier 3 Ambiguous Collisions Excluded (0%% risk)               : %s\n",
            format(excluded_n, big.mark = ",")))
cat(sprintf("  Total High-Confidence Verified Matches Written               : %s\n",
            format(nrow(matched), big.mark = ",")))

# --- 4. Save Outputs ---------------------------------------------------------
dir.create("artifacts", showWarnings = FALSE)
out_file <- "artifacts/florida_voter_license_ages.csv"

matched_out <- matched %>%
  select(certification_number, last_name, first_name, state_source,
         voter_dob, fl_birth_year, fl_age_at_ref, fl_age_plausible,
         match_method, match_confidence, voter_freq_in_fl,
         voter_city, voter_zip)

write_csv(matched_out, out_file, na = "")
cat(sprintf("\nWritten: %s\n", out_file))

prov_file <- "artifacts/florida_voter_license_ages_provenance.csv"
write_csv(tibble(
  built_at            = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  ref_year            = REF_YEAR,
  min_age_constraint  = MIN_AGE,
  max_age_constraint  = MAX_AGE,
  fl_voters_processed = nrow(fl_voters),
  cohort_n            = nrow(coh),
  tier1_unique_n      = nrow(tier1),
  tier2_geodis_n      = nrow(tier2),
  excluded_collisions = excluded_n,
  total_matched_n     = nrow(matched)
), prov_file, na = "")

cat(sprintf("Written: %s\n", prov_file))
cat("\n=== Done. ===\n")
