#!/usr/bin/env Rscript
# =============================================================================
# State nursing board age enrichment for the ACTIVE certified-midwife cohort
# =============================================================================
# Queries public nursing license Socrata endpoints from states whose boards
# publish birth year or a first-issue date from which age can be estimated.
#
# States included
# ---------------
# WA  Washington DOH       data.wa.gov/resource/qxh8-f4bd
#       credential: "Advanced Registered Nurse Practitioner License"
#       birth_year field present directly (gold-standard)
#
# IL  Illinois IDFPR        data.illinois.gov/resource/pzzh-kp68
#       credential: "ADVANCED PRACTICE REGISTERED NURSE"
#       birth_year derived: original_issue_year - APRN_ISSUE_AGE_OFFSET
#       (CNMs typically earn APRN licensure ~27 years old; offset ±3 y uncertainty)
#
# Adding more states
# ------------------
#   Append an entry to STATE_CONFIGS below.  Required keys:
#     endpoint, where_clause, first_name_col, last_name_col,
#     issue_date_col (or NA), birth_year_col (or NA)
#
# Matching strategy (same two-pass as enrich_doximity_cnm_ages.R)
#   Pass 1 — last + first (uppercased, whitespace-collapsed) exact token match
#   Ambiguous matches (same name → multiple license rows) excluded.
#
# Age derivation
#   WA: birth_year from license record; age = REF_YEAR - birth_year
#   IL: birth_year = issue_year - APRN_ISSUE_AGE_OFFSET; age computed same way
#
# Plausibility gate: 22 ≤ age ≤ 80 at REF_YEAR
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
ROSTER               <- "artifacts/amcb_npi_linkage_FROZEN.csv"

cat(sprintf("State nursing license age enrichment (ref year %d)\n", REF_YEAR))

# ---------------------------------------------------------------------------
# Guard: cohort roster
# ---------------------------------------------------------------------------
if (!file.exists(ROSTER))
  stop(sprintf("Cohort roster not found: %s", ROSTER), call. = FALSE)

coh <- read_csv(ROSTER, show_col_types = FALSE, progress = FALSE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(
    last_upper  = str_to_upper(str_trim(last_name)),
    first_upper = str_to_upper(str_squish(first_name))
  )
cat(sprintf("cohort: %s ACTIVE primary-linked midwives\n",
            format(nrow(coh), big.mark = ",")))

# ---------------------------------------------------------------------------
# State configuration table
# ---------------------------------------------------------------------------
STATE_CONFIGS <- list(

  WA = list(
    label        = "Washington DOH (ARNP)",
    endpoint     = "https://data.wa.gov/resource/qxh8-f4bd.json",
    where_clause = "credentialtype = 'Advanced Registered Nurse Practitioner License'",
    first_col    = "firstname",
    last_col     = "lastname",
    issue_col    = "firstissuedate",
    birth_col    = "birthyear",      # direct birth year — use as-is
    state_abbr   = "WA"
  ),

  IL = list(
    label        = "Illinois IDFPR (APRN)",
    endpoint     = "https://data.illinois.gov/resource/pzzh-kp68.json",
    where_clause = "description = 'ADVANCED PRACTICE REGISTERED NURSE'",
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
    select(state_source, last_upper, first_upper,
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
cat(sprintf("\nAll states combined: %s rows\n",
            format(nrow(nursing_all), big.mark = ",")))

# ---------------------------------------------------------------------------
# Match to AMCB cohort — last + first name
# ---------------------------------------------------------------------------
# Deduplicate nursing data: one row per name (prefer direct birth_year)
nursing_dedup <- nursing_all %>%
  arrange(last_upper, first_upper,
          desc(birth_year_source == "direct"),
          desc(snl_age_plausible)) %>%
  distinct(last_upper, first_upper, .keep_all = TRUE)

matched <- inner_join(
  coh %>% select(certification_number, last_upper, first_upper),
  nursing_dedup %>% select(state_source, last_upper, first_upper,
                           snl_birth_year, snl_age_at_ref,
                           snl_age_plausible, snl_issue_year,
                           birth_year_source),
  by = c("last_upper", "first_upper")
)

# Exclude ambiguous: same certification_number matched multiple rows
ambiguous <- matched %>% count(certification_number) %>%
  filter(n > 1L) %>% pull(certification_number)
if (length(ambiguous))
  message(sprintf("  %d certificant(s) matched multiple nursing rows — excluded",
                  length(ambiguous)))
matched <- matched %>%
  filter(!certification_number %in% ambiguous) %>%
  mutate(match_method = "name", match_confidence = 0.80)

cat(sprintf("\ntotal matched: %s of %s (%.1f%%)\n",
            format(nrow(matched), big.mark = ","),
            format(nrow(coh),     big.mark = ","),
            100 * nrow(matched) / nrow(coh)))
cat(sprintf("  with plausible age: %s\n",
            format(sum(matched$snl_age_plausible), big.mark = ",")))
cat(sprintf("  direct birth year: %s  derived: %s\n",
            sum(matched$birth_year_source == "direct"),
            sum(matched$birth_year_source == "derived_from_issue_year")))

if (any(matched$snl_age_plausible, na.rm = TRUE)) {
  ages <- matched$snl_age_at_ref[matched$snl_age_plausible]
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

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
dir.create("artifacts", showWarnings = FALSE)
out_file <- "artifacts/state_nursing_license_ages.csv"
write_csv(matched, out_file, na = "")
cat(sprintf("written: %s\n", out_file))

write_csv(tibble(
  built_at           = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  ref_year           = REF_YEAR,
  aprn_issue_age_offset = APRN_ISSUE_AGE_OFFSET,
  states_queried     = paste(names(STATE_CONFIGS), collapse = ", "),
  nursing_rows_raw   = nrow(nursing_all),
  nursing_rows_dedup = nrow(nursing_dedup),
  cohort_n           = nrow(coh),
  matched_n          = nrow(matched),
  ambiguous_excluded = length(ambiguous),
  plausible_age_n    = sum(matched$snl_age_plausible),
  direct_birth_year  = sum(matched$birth_year_source == "direct"),
  derived_birth_year = sum(matched$birth_year_source == "derived_from_issue_year")
), "artifacts/state_nursing_license_ages_provenance.csv")

cat("written: artifacts/state_nursing_license_ages_provenance.csv\n")
cat("done.\n")
