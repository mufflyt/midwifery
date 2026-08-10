#!/usr/bin/env Rscript
# =============================================================================
# Washington State certified nurse midwife license scraper
# =============================================================================
# Source: Washington Department of Health open data (Socrata)
#   Endpoint: https://data.wa.gov/resource/qxh8-f4bd
#   Credential type: "Advanced Registered Nurse Practitioner Midwife License"
#   Credential number suffix: *-CNM
#
# All 1,483 WA CNM license records (active + inactive + expired) are returned
# in a single page — no pagination needed.
#
# Fields available
#   credentialnumber   WA license number (ARNP.AP.XXXXXXXX-CNM)
#   lastname / firstname / middlename
#   status             Active | Expired | Closed | Inoperable | Inactive | …
#   birthyear          4-digit integer — present for 100% of records
#   firstissuedate     date of original licensure (MM/DD/YYYY)
#   lastissuedate      date of most recent renewal
#   expirationdate     current license expiration
#   ceduedate          CE due date
#   actiontaken        disciplinary action on record (Yes / No)
#
# Age derivation
#   birth_year  = as.integer(birthyear)          [direct — no estimation]
#   age_at_ref  = REF_YEAR - birth_year          [REF_YEAR = 2026]
#   age_plausible = age_at_ref in [22, 80]
#
# Outputs
#   artifacts/wa_cnm_licenses.csv        all records (all statuses)
#   artifacts/wa_cnm_licenses_active.csv active-only records
#   artifacts/wa_cnm_matched.csv         name-matched to AMCB cohort
#   artifacts/wa_cnm_provenance.csv      run metadata
# =============================================================================
suppressPackageStartupMessages({
  library(httr); library(jsonlite)
  library(dplyr); library(readr); library(stringr); library(tibble)
})

REF_YEAR    <- 2026L
ENDPOINT    <- "https://data.wa.gov/resource/qxh8-f4bd.json"
CRED_TYPE   <- "Advanced Registered Nurse Practitioner Midwife License"
ROSTER_FILE <- "artifacts/amcb_npi_linkage_FROZEN.csv"

cat("=== Washington State CNM license scraper ===\n")
cat(sprintf("endpoint: %s\n", ENDPOINT))
cat(sprintf("filter:   credentialtype = '%s'\n\n", CRED_TYPE))

dir.create("artifacts", showWarnings = FALSE)

# =============================================================================
# Download
# =============================================================================
cat("Downloading...\n")
resp <- tryCatch(
  GET(ENDPOINT,
      query   = list(`$where` = sprintf("credentialtype = '%s'", CRED_TYPE),
                     `$limit` = 5000L,
                     `$order` = "lastname ASC, firstname ASC"),
      timeout(60)),
  error = function(e) stop(sprintf("HTTP request failed: %s", e$message))
)

if (http_error(resp))
  stop(sprintf("HTTP %d: %s", status_code(resp),
               content(resp, as = "text", encoding = "UTF-8")))

raw <- fromJSON(content(resp, as = "text", encoding = "UTF-8"),
                simplifyDataFrame = TRUE)
cat(sprintf("downloaded: %s records\n", format(nrow(raw), big.mark = ",")))

# =============================================================================
# Clean and derive fields
# =============================================================================
wa <- raw %>%
  rename_with(tolower) %>%
  mutate(
    last_name   = str_to_title(str_squish(lastname)),
    first_name  = str_to_title(str_squish(firstname)),
    middle_name = str_to_title(str_squish(middlename)),

    last_upper  = str_to_upper(str_squish(lastname)),
    first_upper = str_to_upper(str_squish(firstname)),

    birth_year  = suppressWarnings(as.integer(birthyear)),
    age_at_ref  = if_else(!is.na(birth_year), REF_YEAR - birth_year, NA_integer_),
    age_plausible = !is.na(age_at_ref) & age_at_ref >= 22L & age_at_ref <= 80L,

    first_issue_date  = suppressWarnings(as.Date(firstissuedate,  "%m/%d/%Y")),
    last_issue_date   = suppressWarnings(as.Date(lastissuedate,   "%m/%d/%Y")),
    expiration_date   = suppressWarnings(as.Date(expirationdate,  "%m/%d/%Y")),

    license_number    = credentialnumber,
    license_status    = str_to_upper(status),
    action_taken      = str_to_upper(actiontaken),

    source = "WA_DOH_Socrata"
  ) %>%
  select(
    license_number, last_name, first_name, middle_name,
    last_upper, first_upper,
    license_status, birth_year, age_at_ref, age_plausible,
    first_issue_date, last_issue_date, expiration_date,
    action_taken, source
  )

# =============================================================================
# Summaries
# =============================================================================
cat("\nStatus distribution:\n")
wa %>% count(license_status, sort = TRUE) %>%
  mutate(pct = round(100 * n / sum(n), 1)) %>%
  { for (i in seq_len(nrow(.)))
      cat(sprintf("  %-22s %4d  (%4.1f%%)\n",
                  .[["license_status"]][i], .[["n"]][i], .[["pct"]][i]))
    . } %>% invisible()

cat(sprintf("\nBirth year coverage: %d / %d (%.1f%%)\n",
            sum(!is.na(wa$birth_year)), nrow(wa),
            100 * mean(!is.na(wa$birth_year))))

plausible_ages <- wa$age_at_ref[wa$age_plausible]
if (length(plausible_ages) > 0) {
  cat(sprintf("Age (plausible, ref %d): range %d–%d  median %d\n",
              REF_YEAR, min(plausible_ages), max(plausible_ages),
              as.integer(median(plausible_ages))))
  breaks <- c(18, 35, 45, 55, 65, 81)
  labels <- c("<35", "35–44", "45–54", "55–64", ">=65")
  tbl    <- table(cut(plausible_ages, breaks, right = FALSE, labels = labels))
  cat("Age distribution (plausible records):\n")
  for (i in seq_along(tbl))
    cat(sprintf("  %-8s %4d  (%4.1f%%)\n",
                names(tbl)[i], tbl[i], 100 * tbl[i] / sum(tbl)))
}

# =============================================================================
# Write all-records and active-only outputs
# =============================================================================
write_csv(wa, "artifacts/wa_cnm_licenses.csv", na = "")
write_csv(wa %>% filter(license_status == "ACTIVE"),
          "artifacts/wa_cnm_licenses_active.csv", na = "")
cat(sprintf("\nwritten: artifacts/wa_cnm_licenses.csv         (%d rows)\n", nrow(wa)))
cat(sprintf("written: artifacts/wa_cnm_licenses_active.csv  (%d rows)\n",
            sum(wa$license_status == "ACTIVE")))

# =============================================================================
# Match to AMCB cohort
# =============================================================================
if (file.exists(ROSTER_FILE)) {
  cat("\nMatching to AMCB cohort...\n")
  coh <- read_csv(ROSTER_FILE, show_col_types = FALSE, progress = FALSE) %>%
    filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    mutate(
      last_upper  = str_to_upper(str_trim(last_name)),
      first_upper = str_to_upper(str_squish(first_name))
    )
  cat(sprintf("cohort: %s midwives\n", format(nrow(coh), big.mark = ",")))

  # Deduplicate WA side: if same name appears more than once, keep active
  # license (or most-recent first_issue_date) to avoid fan-out
  wa_dedup <- wa %>%
    arrange(last_upper, first_upper,
            desc(license_status == "ACTIVE"),
            desc(first_issue_date)) %>%
    distinct(last_upper, first_upper, .keep_all = TRUE)

  matched <- inner_join(
    coh %>% select(certification_number, last_upper, first_upper),
    wa_dedup %>% select(license_number, last_upper, first_upper,
                        last_name, first_name, middle_name,
                        license_status, birth_year, age_at_ref, age_plausible,
                        first_issue_date, expiration_date, action_taken, source),
    by = c("last_upper", "first_upper")
  )

  # Flag ambiguous (1 cohort member → 2+ WA rows after dedup — shouldn't happen)
  ambiguous <- matched %>% count(certification_number) %>%
    filter(n > 1L) %>% pull(certification_number)
  if (length(ambiguous))
    message(sprintf("  %d certificant(s) had ambiguous name matches — excluded",
                    length(ambiguous)))
  matched <- matched %>%
    filter(!certification_number %in% ambiguous) %>%
    mutate(match_method = "name", match_confidence = 0.80)

  cat(sprintf("matched: %s of %s cohort (%.1f%%)\n",
              format(nrow(matched),  big.mark = ","),
              format(nrow(coh),      big.mark = ","),
              100 * nrow(matched) / nrow(coh)))
  cat(sprintf("  with plausible age: %s\n",
              format(sum(matched$age_plausible), big.mark = ",")))

  write_csv(matched, "artifacts/wa_cnm_matched.csv", na = "")
  cat("written: artifacts/wa_cnm_matched.csv\n")
} else {
  cat(sprintf("Roster not found (%s) — skipping cohort match\n", ROSTER_FILE))
}

# =============================================================================
# Provenance
# =============================================================================
write_csv(tibble(
  built_at          = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  endpoint          = ENDPOINT,
  credential_type   = CRED_TYPE,
  ref_year          = REF_YEAR,
  total_records     = nrow(wa),
  active_records    = sum(wa$license_status == "ACTIVE"),
  birth_year_pct    = round(100 * mean(!is.na(wa$birth_year)), 1),
  age_plausible_n   = sum(wa$age_plausible, na.rm = TRUE),
  age_median        = as.integer(median(plausible_ages))
), "artifacts/wa_cnm_provenance.csv")
cat("written: artifacts/wa_cnm_provenance.csv\n")
cat("done.\n")
