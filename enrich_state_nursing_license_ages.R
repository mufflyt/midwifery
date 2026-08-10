#!/usr/bin/env Rscript
# =============================================================================
# State nursing license age enrichment for the ACTIVE certified-midwife cohort
# =============================================================================
# Queries public nursing license Socrata endpoints from states whose boards
# publish birth year or a first-issue date from which age can be estimated.
#
# States included
# ---------------
# WA  Washington DOH       data.wa.gov/resource/qxh8-f4bd
#       credential: Midwife & ARNP licenses
#       birth_year field present directly (gold-standard)
#
# IL  Illinois IDFPR        data.illinois.gov/resource/pzzh-kp68
#       credential: Certified Professional Midwife, APRN, Full Practice APRN
#       birth_year derived: original_issue_year - APRN_ISSUE_AGE_OFFSET
#       (CNMs typically earn APRN licensure ~27 years old; offset ±3 y uncertainty)
#
# Outputs
#   artifacts/state_nursing_license_ages.csv
#   artifacts/state_nursing_license_ages_provenance.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tibble)
  library(httr);  library(jsonlite); library(purrr)
})

REF_YEAR             <- 2026L
APRN_ISSUE_AGE_OFFSET <- 27L   # typical age at first APRN/CNM licensure
PAGE_SIZE            <- 50000L

ROSTER_CANDIDATES <- c(
  "artifacts/amcb_npi_linkage_FROZEN.csv",
  "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv",
  "midwives.csv"
)
ROSTER <- ROSTER_CANDIDATES[file.exists(ROSTER_CANDIDATES)][1]

cat(sprintf("=== State Nursing License Age Enrichment (Ref Year: %d) ===\n", REF_YEAR))

if (is.na(ROSTER) || !file.exists(ROSTER))
  stop("Cohort roster not found in artifacts/ or project root.", call. = FALSE)

cat(sprintf("Using roster file: %s\n", ROSTER))

raw_coh <- read_csv(ROSTER, show_col_types = FALSE, progress = FALSE)

coh <- raw_coh
if ("status" %in% names(coh)) {
  coh <- coh %>% filter(status == "ACTIVE")
}
if ("linkage_tier" %in% names(coh)) {
  coh <- coh %>% filter(linkage_tier == "primary_midwifery")
}

coh <- coh %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    last_upper  = str_to_upper(str_trim(last_name)),
    first_upper = str_to_upper(str_squish(first_name)),
    last_clean  = str_remove_all(last_upper, "[^A-Z]"),
    first_token = str_to_upper(map_chr(str_split(first_upper, "\\s+"), 1))
  )

cat(sprintf("Cohort: %s ACTIVE primary-linked midwives\n",
            format(nrow(coh), big.mark = ",")))

# ---------------------------------------------------------------------------
# State configuration table — Comprehensive Midwife & APRN Queries
# ---------------------------------------------------------------------------
STATE_CONFIGS <- list(

  WA = list(
    label        = "Washington DOH (Midwife & ARNP)",
    endpoint     = "https://data.wa.gov/resource/qxh8-f4bd.json",
    where_clause = "upper(credentialtype) LIKE '%MIDWIF%' OR upper(credentialtype) LIKE '%ADVANCED REGISTERED NURSE PRACTITIONER%'",
    first_col    = "firstname",
    last_col     = "lastname",
    issue_col    = "firstissuedate",
    birth_col    = "birthyear",      # direct birth year
    state_abbr   = "WA"
  ),

  IL = list(
    label        = "Illinois IDFPR (Midwife & APRN)",
    endpoint     = "https://data.illinois.gov/resource/pzzh-kp68.json",
    where_clause = "upper(description) LIKE '%MIDWIF%' OR upper(description) LIKE '%ADVANCED PRACTICE%' OR upper(description) LIKE '%FULL PRACTICE AUTHORITY%' OR upper(license_type) LIKE '%MIDWIFERY%'",
    first_col    = "first_name",
    last_col     = "last_name",
    issue_col    = "original_issue_date",
    birth_col    = NA_character_,   # derive from issue year
    state_abbr   = "IL"
  )

)

# ---------------------------------------------------------------------------
# Generic paginated Socrata downloader
# ---------------------------------------------------------------------------
fetch_socrata <- function(endpoint, where_clause) {
  all_rows <- list()
  offset   <- 0L
  page     <- 1L
  repeat {
    url <- modify_url(endpoint, query = list(
      `$where`  = where_clause,
      `$limit`  = PAGE_SIZE,
      `$offset` = offset,
      `$order`  = ":id"
    ))
    resp <- tryCatch(GET(url, timeout(120)), error = function(e) NULL)
    if (is.null(resp) || http_error(resp)) {
      warning(sprintf("fetch_socrata: HTTP error at offset %d", offset))
      break
    }
    batch <- tryCatch(
      fromJSON(content(resp, as = "text", encoding = "UTF-8"),
               simplifyDataFrame = TRUE),
      error = function(e) NULL
    )
    if (is.null(batch) || nrow(batch) == 0L) break
    all_rows[[page]] <- batch
    offset <- offset + nrow(batch)
    page   <- page + 1L
    cat(sprintf("    page %d: %s rows (total %s)\n",
                page - 1L,
                format(nrow(batch), big.mark = ","),
                format(offset, big.mark = ",")))
    if (nrow(batch) < PAGE_SIZE) break
    Sys.sleep(0.5)
  }
  if (length(all_rows) == 0L) return(tibble())
  bind_rows(all_rows)
}

# ---------------------------------------------------------------------------
# Process each state
# ---------------------------------------------------------------------------
state_results <- map(names(STATE_CONFIGS), function(st) {
  cfg <- STATE_CONFIGS[[st]]
  cat(sprintf("\n--- %s: %s ---\n", st, cfg$label))
  cat(sprintf("  endpoint: %s\n", cfg$endpoint))

  raw <- fetch_socrata(cfg$endpoint, cfg$where_clause)
  if (nrow(raw) == 0L) {
    warning(sprintf("%s: no rows returned", st))
    return(NULL)
  }
  cat(sprintf("  downloaded: %s rows\n", format(nrow(raw), big.mark = ",")))

  # Rename to standard columns
  raw <- raw %>% rename_with(tolower)
  first_col <- tolower(cfg$first_col)
  last_col  <- tolower(cfg$last_col)
  issue_col <- if (!is.na(cfg$issue_col)) tolower(cfg$issue_col) else NA_character_
  birth_col <- if (!is.na(cfg$birth_col)) tolower(cfg$birth_col) else NA_character_

  df <- raw %>%
    mutate(
      state_source = st,
      last_upper   = str_to_upper(str_squish(.data[[last_col]])),
      first_upper  = str_to_upper(str_squish(.data[[first_col]])),
      last_clean   = str_remove_all(last_upper, "[^A-Z]"),
      first_token  = str_to_upper(map_chr(str_split(first_upper, "\\s+"), 1)),

      # Birth year: from direct field or derived from issue year
      snl_birth_year = {
        if (!is.na(birth_col) && birth_col %in% names(.)) {
          suppressWarnings(as.integer(.data[[birth_col]]))
        } else if (!is.na(issue_col) && issue_col %in% names(.)) {
          iy <- suppressWarnings(
            as.integer(str_extract(.data[[issue_col]], "\\d{4}"))
          )
          iy - APRN_ISSUE_AGE_OFFSET
        } else {
          NA_integer_
        }
      },

      # Age at REF_YEAR
      snl_age_at_ref   = if_else(!is.na(snl_birth_year),
                                 REF_YEAR - snl_birth_year, NA_integer_),
      snl_age_plausible = !is.na(snl_age_at_ref) &
                          snl_age_at_ref >= 22L & snl_age_at_ref <= 80L,

      # Issue year for provenance
      snl_issue_year = if (!is.na(issue_col) && issue_col %in% names(.))
        suppressWarnings(as.integer(str_extract(.data[[issue_col]], "\\d{4}")))
      else NA_integer_,

      # Birth year source flag
      birth_year_source = if (!is.na(birth_col) && birth_col %in% names(.))
        "direct" else "derived_from_issue_year"
    ) %>%
    select(state_source, last_upper, first_upper, last_clean, first_token,
           snl_birth_year, snl_age_at_ref, snl_age_plausible,
           snl_issue_year, birth_year_source) %>%
    filter(!is.na(last_upper), last_upper != "",
           !is.na(first_upper), first_upper != "")

  cat(sprintf("  valid name rows: %s\n", format(nrow(df), big.mark = ",")))
  cat(sprintf("  with plausible age: %s\n",
              format(sum(df$snl_age_plausible), big.mark = ",")))
  df
})

nursing_all <- bind_rows(keep(state_results, ~ !is.null(.x)))
cat(sprintf("\nAll state databases combined: %s rows\n",
            format(nrow(nursing_all), big.mark = ",")))

# ---------------------------------------------------------------------------
# Multi-Tiered Matching to AMCB Cohort
# ---------------------------------------------------------------------------

# Deduplicate nursing state data: prefer direct birth year and plausible age
nursing_dedup <- nursing_all %>%
  arrange(last_upper, first_upper,
          desc(birth_year_source == "direct"),
          desc(snl_age_plausible),
          desc(snl_issue_year))

# Tier 1: Exact last + first name
m_tier1 <- inner_join(
  coh %>% select(certification_number, last_upper, first_upper, last_clean, first_token),
  nursing_dedup %>% select(state_source, last_upper, first_upper,
                           snl_birth_year, snl_age_at_ref,
                           snl_age_plausible, snl_issue_year,
                           birth_year_source) %>% distinct(last_upper, first_upper, .keep_all = TRUE),
  by = c("last_upper", "first_upper")
) %>% mutate(match_method = "exact_name", match_confidence = 1.00)

unmatched_coh <- coh %>% filter(!certification_number %in% m_tier1$certification_number)

# Tier 2: Token match (clean last name + first token)
m_tier2 <- inner_join(
  unmatched_coh %>% select(certification_number, last_clean, first_token),
  nursing_dedup %>% select(state_source, last_clean, first_token,
                           snl_birth_year, snl_age_at_ref,
                           snl_age_plausible, snl_issue_year,
                           birth_year_source) %>% distinct(last_clean, first_token, .keep_all = TRUE),
  by = c("last_clean", "first_token")
) %>% mutate(match_method = "token_name", match_confidence = 0.90)

matched <- bind_rows(m_tier1, m_tier2) %>%
  distinct(certification_number, .keep_all = TRUE)

cat(sprintf("\nTotal matched certificants: %s of %s (%.1f%%)\n",
            format(nrow(matched), big.mark = ","),
            format(nrow(coh),     big.mark = ","),
            100 * nrow(matched) / nrow(coh)))

# State match summary
cat("\nMatched Certificants by State Source:\n")
print(as.data.frame(matched %>% count(state_source, name = "matches")))

# Coverage against primary WA and IL resident cohort
if ("nppes_state" %in% names(coh)) {
  wa_res <- coh %>% filter(nppes_state == "WA")
  il_res <- coh %>% filter(nppes_state == "IL")
  
  wa_match <- sum(wa_res$certification_number %in% matched$certification_number)
  il_match <- sum(il_res$certification_number %in% matched$certification_number)
  
  cat(sprintf("\nWA Cohort Residents Matched: %d / %d (%.1f%%)\n",
              wa_match, nrow(wa_res), 100 * wa_match / nrow(wa_res)))
  cat(sprintf("IL Cohort Residents Matched: %d / %d (%.1f%%)\n",
              il_match, nrow(il_res), 100 * il_match / nrow(il_res)))
}

cat(sprintf("\nWith plausible age: %s\n",
            format(sum(matched$snl_age_plausible), big.mark = ",")))
cat(sprintf("  direct birth year: %s  derived: %s\n",
            sum(matched$birth_year_source == "direct"),
            sum(matched$birth_year_source == "derived_from_issue_year")))

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
dir.create("artifacts", showWarnings = FALSE)
out_file <- "artifacts/state_nursing_license_ages.csv"
write_csv(matched, out_file, na = "")
cat(sprintf("\nwritten: %s\n", out_file))

write_csv(tibble(
  built_at           = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  ref_year           = REF_YEAR,
  aprn_issue_age_offset = APRN_ISSUE_AGE_OFFSET,
  states_queried     = paste(names(STATE_CONFIGS), collapse = ", "),
  nursing_rows_raw   = nrow(nursing_all),
  cohort_n           = nrow(coh),
  matched_n          = nrow(matched),
  tier1_exact_n      = nrow(m_tier1),
  tier2_token_n      = nrow(m_tier2),
  plausible_age_n    = sum(matched$snl_age_plausible),
  direct_birth_year  = sum(matched$birth_year_source == "direct"),
  derived_birth_year = sum(matched$birth_year_source == "derived_from_issue_year")
), "artifacts/state_nursing_license_ages_provenance.csv")

cat("written: artifacts/state_nursing_license_ages_provenance.csv\n")
cat("done.\n")
