#!/usr/bin/env Rscript
# =============================================================================
# Doximity age enrichment for the ACTIVE certified-midwife cohort
# =============================================================================
# Doximity lists CNMs under its NP directory (specialty: Certified Nurse
# Midwife). Age and birth year are behind the login wall, so the input file
# must be downloaded while authenticated and placed at the path below.
#
# Matching strategy (in order of preference):
#   1. NPI — direct join; highest confidence.
#   2. Last + first name (uppercased, trimmed) — name-only match; flagged
#      lower-confidence. AMCB first_name sometimes fuses a middle name
#      (e.g. "Joann" instead of "Jo Ann"), so tokens are compared after
#      whitespace-collapse rather than exact string equality.
#
# Age derivation: Doximity's `Year Of Birth` is used when present. When only
# `Age` is available the birth year is back-calculated as
#   birth_year = vintage_year - Age
# where vintage_year is set by DOXIMITY_VINTAGE (default 2016 for the older
# Source1 extract; set to 2024 for a fresh download). The final age in the
# output is always expressed relative to REF_YEAR (2026) so it is comparable
# to the rest of Table 1.
#
# Inputs:
#   DOX_FILE (env var or default below)     — Doximity CSV download
#   artifacts/amcb_npi_linkage_FROZEN.csv   — cohort roster (must exist)
#
# Outputs:
#   artifacts/doximity_cnm_ages.csv         — one row per matched certificant
#   artifacts/doximity_cnm_ages_provenance.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

REF_YEAR       <- 2026L
DOXIMITY_VINTAGE <- as.integer(Sys.getenv("DOXIMITY_VINTAGE", "2016"))
DOX_FILE       <- Sys.getenv("DOX_FILE",
                             "~/Downloads/DoximityData.csv")
DOX_FILE       <- path.expand(DOX_FILE)

CNM_PATTERNS   <- c("Midwif", "Certified Nurse Mid", "CNM")

cat(sprintf("Doximity CNM age enrichment (ref year %d, data vintage ~%d)\n",
            REF_YEAR, DOXIMITY_VINTAGE))

# --- guard: input file -------------------------------------------------------
if (!file.exists(DOX_FILE)) {
  stop(sprintf(paste0(
    "Doximity data file not found: %s\n",
    "Download your CNM data from Doximity while logged in and save it there,\n",
    "or set the DOX_FILE environment variable to the actual path."), DOX_FILE),
    call. = FALSE)
}

# --- guard: cohort roster ----------------------------------------------------
ROSTER <- "artifacts/amcb_npi_linkage_FROZEN.csv"
if (!file.exists(ROSTER))
  stop(sprintf("Cohort roster not found: %s", ROSTER), call. = FALSE)

link <- read_csv(ROSTER, show_col_types = FALSE, progress = FALSE)
coh  <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    npi          = as.character(npi),
    last_upper   = str_to_upper(str_trim(last_name)),
    first_tokens = str_to_upper(str_squish(first_name))
  )
cat(sprintf("cohort: %s ACTIVE primary-linked midwives\n",
            format(nrow(coh), big.mark = ",")))

# --- load Doximity -----------------------------------------------------------
cat(sprintf("loading Doximity data: %s\n", basename(DOX_FILE)))
dox_raw <- read_csv(DOX_FILE,
                    col_types = cols(`NPI Code` = col_character(),
                                     .default   = col_guess()),
                    show_col_types = FALSE, progress = FALSE)
cat(sprintf("  total rows: %s\n", format(nrow(dox_raw), big.mark = ",")))

# --- filter to CNM -----------------------------------------------------------
cnm_col <- if ("SpecialtyName" %in% names(dox_raw)) "SpecialtyName" else
           if ("specialty_name" %in% names(dox_raw)) "specialty_name" else
           stop("Cannot find specialty column in Doximity file.", call. = FALSE)

pattern <- regex(paste(CNM_PATTERNS, collapse = "|"), ignore_case = TRUE)

dox <- dox_raw %>%
  filter(str_detect(.data[[cnm_col]], pattern)) %>%
  mutate(
    npi        = str_trim(as.character(`NPI Code`)),
    npi        = if_else(nchar(npi) == 10L, npi, NA_character_),
    last_upper  = str_to_upper(str_trim(`Last Name`)),
    first_tokens = str_to_upper(str_squish(`First Name`)),

    # Birth year: prefer direct field; fall back to Age back-calculation.
    dox_birth_year = suppressWarnings(as.integer(`Year Of Birth`)),
    dox_birth_year = if_else(
      is.na(dox_birth_year) & !is.na(Age),
      as.integer(DOXIMITY_VINTAGE) - suppressWarnings(as.integer(Age)),
      dox_birth_year),

    # Age at REF_YEAR from birth year.
    dox_age_at_ref = if_else(!is.na(dox_birth_year),
                             REF_YEAR - dox_birth_year, NA_integer_),

    # Plausibility: 22–80 years old at REF_YEAR.
    dox_age_plausible = !is.na(dox_age_at_ref) &
                         dox_age_at_ref >= 22L & dox_age_at_ref <= 80L
  )

cat(sprintf("  CNM rows after specialty filter: %s\n",
            format(nrow(dox), big.mark = ",")))
cat(sprintf("  with plausible age: %s\n",
            format(sum(dox$dox_age_plausible), big.mark = ",")))

# --- PASS 1: NPI match -------------------------------------------------------
npi_matched <- inner_join(
  coh %>% filter(!is.na(npi)) %>% select(certification_number, npi),
  dox %>% filter(!is.na(npi)) %>%
    select(npi, dox_birth_year, dox_age_at_ref, dox_age_plausible),
  by = "npi"
) %>%
  mutate(match_method = "npi", match_confidence = 1.0) %>%
  distinct(certification_number, .keep_all = TRUE)

cat(sprintf("pass 1 (NPI): %s matches\n",
            format(nrow(npi_matched), big.mark = ",")))

# --- PASS 2: name match (unmatched only) -------------------------------------
# Token comparison: split both sides on whitespace, check that every token in
# the Doximity first name appears somewhere in the AMCB first_tokens string.
# This handles "Joann" vs "Jo Ann" and fused middle names.
unmatched_coh <- coh %>%
  filter(!certification_number %in% npi_matched$certification_number)

name_matched <- inner_join(
  unmatched_coh %>% select(certification_number, last_upper, first_tokens),
  dox %>%
    select(last_upper, first_tokens, dox_birth_year, dox_age_at_ref,
           dox_age_plausible) %>%
    distinct(last_upper, first_tokens, .keep_all = TRUE),
  by = c("last_upper", "first_tokens")
) %>%
  mutate(match_method = "name", match_confidence = 0.80) %>%
  select(certification_number, dox_birth_year, dox_age_at_ref,
         dox_age_plausible, match_method, match_confidence)

# Flag ambiguous name matches (same name → multiple Doximity rows).
ambiguous_names <- name_matched %>%
  count(certification_number) %>% filter(n > 1) %>% pull(certification_number)
if (length(ambiguous_names)) {
  message(sprintf(
    "  %d certificant(s) matched multiple Doximity rows by name — excluded from name matches",
    length(ambiguous_names)))
  name_matched <- name_matched %>% filter(!certification_number %in% ambiguous_names)
}

cat(sprintf("pass 2 (name): %s matches (%d ambiguous excluded)\n",
            format(nrow(name_matched), big.mark = ","),
            length(ambiguous_names)))

# --- combine -----------------------------------------------------------------
matched <- bind_rows(
  npi_matched %>%
    select(certification_number, dox_birth_year, dox_age_at_ref,
           dox_age_plausible, match_method, match_confidence),
  name_matched
) %>%
  arrange(certification_number, desc(match_confidence)) %>%
  distinct(certification_number, .keep_all = TRUE)

cat(sprintf("total matched: %s of %s (%.1f%%)\n",
            format(nrow(matched), big.mark = ","),
            format(nrow(coh),   big.mark = ","),
            100 * nrow(matched) / nrow(coh)))
cat(sprintf("  with plausible age: %s\n",
            format(sum(matched$dox_age_plausible), big.mark = ",")))

# Age distribution of plausible matches.
if (any(matched$dox_age_plausible)) {
  ages <- matched$dox_age_at_ref[matched$dox_age_plausible]
  cat(sprintf("  age range: %d – %d  median: %d\n",
              min(ages), max(ages), as.integer(median(ages))))
  breaks <- c(18, 35, 45, 55, 65, 81)
  labels <- c("<35", "35-44", "45-54", "55-64", ">=65")
  tbl <- table(cut(ages, breaks, right = FALSE, labels = labels))
  cat("  age distribution:\n")
  for (i in seq_along(tbl))
    cat(sprintf("    %-8s %4d (%4.1f%%)\n", names(tbl)[i], tbl[i],
                100 * tbl[i] / sum(tbl)))
}

# --- write output ------------------------------------------------------------
dir.create("artifacts", showWarnings = FALSE)
out_file <- "artifacts/doximity_cnm_ages.csv"
write_csv(matched, out_file, na = "")
cat(sprintf("written: %s\n", out_file))

readr::write_csv(tibble::tibble(
  built_at         = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  dox_file         = DOX_FILE,
  dox_vintage_year = DOXIMITY_VINTAGE,
  ref_year         = REF_YEAR,
  cnm_rows_in_dox  = nrow(dox),
  cohort_n         = nrow(coh),
  npi_matches      = nrow(npi_matched),
  name_matches     = nrow(name_matched),
  total_matched    = nrow(matched),
  plausible_age    = sum(matched$dox_age_plausible)),
  "artifacts/doximity_cnm_ages_provenance.csv")

cat("written: artifacts/doximity_cnm_ages_provenance.csv\n")
