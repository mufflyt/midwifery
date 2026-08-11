#!/usr/bin/env Rscript
# =============================================================================
# All CNMs in the CMS Doctors & Clinicians file: education, enrollment, practice
# =============================================================================
# Extracts every certified nurse-midwife listed in DAC, one row per NPI, with
# education, Medicare enrollment and group-affiliation fields.
#
# THE SCHOOL FIELD IS NOT A NURSING SCHOOL. 1,004 of 1,222 CNM education
# entries (82%) read "... SCHOOL OF MEDICINE" or "... COLLEGE OF MEDICINE", and
# ZERO read "School of Nursing". CMS maps every clinician's school through a
# MEDICAL-school code list, so the institution is right and the suffix is CMS's
# taxonomy: a CNM listed as "University of New Mexico School of Medicine" took
# her midwifery degree in that university's College of Nursing. Published
# verbatim it reads as a midwife with an MD, so `med_sch_clean` strips the
# suffix and `med_sch_raw` is kept beside it -- the cleaning is visible, not
# baked in.
#
# DEDUPLICATION IS BY AGGREGATION, NOT BY ROW ORDER. A midwife appears once per
# practice location (the example that prompted this had three). Collapsing with
# distinct(NPI, .keep_all = TRUE) keeps whichever row sorted first, which is the
# construction that let file order decide a county's rurality and a midwife's
# coordinates elsewhere in this project. Person-level fields are checked for
# CONFLICT before collapsing, and location-level fields are summarised rather
# than sampled.
#
# Input : DAC_NationalDownloadableFile_YYYY-MM.csv
# Output: artifacts/dac_cnm_education.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})

DAC <- Sys.getenv("DAC_FILE", "DAC_NationalDownloadableFile_2026-06.csv")
if (!file.exists(DAC))
  stop(sprintf("DAC file not found: %s (set DAC_FILE)", DAC), call. = FALSE)

d <- read_csv(DAC, show_col_types = FALSE, progress = FALSE,
              col_types = cols(.default = col_character()))
cat(sprintf("DAC rows: %s | distinct NPIs: %s\n",
            format(nrow(d), big.mark = ","), format(n_distinct(d$NPI), big.mark = ",")))

# --- filter ------------------------------------------------------------------
# Accept the credential spellings a future vintage might use even though this
# one carries only "CNM"; which ones actually matched is reported below, so a
# silently empty variant cannot masquerade as "none exist".
CNM_CREDS <- c("CNM", "CM", "APRN-CNM", "APRN-CM", "APRN CNM", "CNM/APRN")
CNM_SPEC  <- "CERTIFIED NURSE MIDWIFE (CNM)"

cnm <- d %>%
  filter(pri_spec == CNM_SPEC |
           toupper(str_squish(Cred)) %in% CNM_CREDS)

matched_creds <- sort(unique(toupper(str_squish(cnm$Cred))))
cat(sprintf("credential values present: %s\n",
            paste(matched_creds[!is.na(matched_creds)], collapse = ", ")))
absent <- setdiff(CNM_CREDS, matched_creds)
if (length(absent))
  cat(sprintf("  (accepted but not present in this vintage: %s)\n",
              paste(absent, collapse = ", ")))
cat(sprintf("CNM rows: %s | distinct NPIs: %s\n",
            format(nrow(cnm), big.mark = ","), format(n_distinct(cnm$NPI), big.mark = ",")))

# --- do person-level fields actually agree within an NPI? ---------------------
person_cols <- c("Provider Last Name", "Provider First Name", "gndr", "Cred",
                 "Med_sch", "Grd_yr", "pri_spec")
conflicts <- cnm %>%
  group_by(NPI) %>%
  summarise(across(all_of(person_cols), ~ n_distinct(.x[!is.na(.x)])), .groups = "drop")
bad <- conflicts %>% filter(if_any(all_of(person_cols), ~ .x > 1))
if (nrow(bad)) {
  cat(sprintf("\nWARNING: %d NPI(s) carry conflicting person-level values across rows:\n",
              nrow(bad)))
  for (cc in person_cols) {
    n <- sum(conflicts[[cc]] > 1)
    if (n) cat(sprintf("    %-22s %d NPI(s)\n", cc, n))
  }
  cat("  The FIRST non-missing value is taken; the conflict count is written to\n")
  cat("  the output so it can be audited rather than assumed away.\n")
}

first_ok <- function(x) { x <- x[!is.na(x) & x != ""]; if (length(x)) x[1] else NA_character_ }

# --- one row per NPI ---------------------------------------------------------
# WHICH LOCATION IS "THE" LOCATION. A third of these midwives practise at more
# than one address, so collapsing to one row must choose. The rule is explicit
# and deterministic: the row with the LARGEST group (num_org_mem), ties broken
# by ZIP then address string, so the answer never depends on file order. Every
# other location survives in the companion long file -- the dedup narrows the
# view, it does not discard data.
loc_rank <- cnm %>%
  mutate(.grp = suppressWarnings(as.integer(num_org_mem))) %>%
  arrange(NPI, desc(!is.na(.grp)), desc(.grp), `ZIP Code`, adr_ln_1) %>%
  group_by(NPI) %>% mutate(.rank = row_number()) %>% ungroup()

primary <- loc_rank %>% filter(.rank == 1) %>%
  transmute(NPI,
            facility_name = `Facility Name`,
            org_pac_id, num_org_mem = suppressWarnings(as.integer(num_org_mem)),
            address_1 = adr_ln_1, address_2 = adr_ln_2,
            city = `City/Town`, state = State, zip = `ZIP Code`,
            phone = `Telephone Number`, adrs_id)

out <- cnm %>%
  group_by(NPI) %>%
  summarise(
    last_name        = first_ok(`Provider Last Name`),
    first_name       = first_ok(`Provider First Name`),
    middle_name      = first_ok(`Provider Middle Name`),
    suffix           = first_ok(suff),
    gender           = first_ok(gndr),
    credential       = first_ok(Cred),
    primary_specialty = first_ok(pri_spec),
    secondary_specialties = first_ok(sec_spec_all),
    med_sch_raw      = first_ok(Med_sch),
    grad_year        = suppressWarnings(as.integer(first_ok(Grd_yr))),
    ind_pac_id       = first_ok(Ind_PAC_ID),
    ind_enrl_id      = first_ok(Ind_enrl_ID),
    accepts_assignment = first_ok(ind_assgn),
    group_assignment = first_ok(grp_assgn),
    telehealth       = first_ok(Telehlth),
    n_practice_rows  = n(),
    n_locations      = n_distinct(paste(adr_ln_1, `City/Town`, State, `ZIP Code`)),
    n_groups         = n_distinct(org_pac_id[!is.na(org_pac_id)]),
    n_states         = n_distinct(State[!is.na(State)]),
    all_states       = paste(sort(unique(State[!is.na(State)])), collapse = ","),
    .groups = "drop") %>%
  left_join(primary, by = "NPI", relationship = "one-to-one") %>%
  # Ind_enrl_ID encodes the Medicare enrollment date: I + YYYYMMDD + sequence.
  # A second, independent career-start date -- it is not NPPES enumeration and
  # not AMCB certification -- so it is parsed out rather than left as an opaque
  # key. Anything not matching the pattern stays NA rather than being coerced.
  mutate(
    enrollment_date = suppressWarnings(as.Date(
      ifelse(grepl("^I[0-9]{8}", ind_enrl_id), substr(ind_enrl_id, 2, 9), NA_character_),
      format = "%Y%m%d")),
    enrollment_year = as.integer(format(enrollment_date, "%Y")))

# --- clean the school name ---------------------------------------------------
# Suffixes stripped in descending length so "COLLEGE OF MEDICINE" is not left as
# a trailing "INE" by an earlier match on "COLLEGE OF MED".
strip_med_suffix <- function(x) {
  y <- x
  y <- str_replace(y, regex("\\s*[,-]?\\s*SCHOOL OF MEDICINE.*$", ignore_case = TRUE), "")
  y <- str_replace(y, regex("\\s*[,-]?\\s*COLLEGE OF MEDICINE.*$", ignore_case = TRUE), "")
  y <- str_replace(y, regex("\\s*[,-]?\\s*COLLEGE OF MED\\b.*$",   ignore_case = TRUE), "")
  y <- str_replace(y, regex("\\s*[,-]?\\s*SCH OF MED\\b.*$",       ignore_case = TRUE), "")
  # Word order varies: "... MEDICAL SCHOOL" as well as "SCHOOL OF MEDICINE".
  # "MEDICAL CENTER" is deliberately NOT stripped -- SUNY Downstate Medical
  # Center is the institution's actual name, not a CMS suffix.
  y <- str_replace(y, regex("\\s*[,-]?\\s*MEDICAL SCHOOL\\b.*$",  ignore_case = TRUE), "")
  y <- str_squish(y)
  # Never return an empty string where a name existed.
  ifelse(is.na(x), NA_character_, ifelse(nzchar(y), y, x))
}
out <- out %>%
  mutate(med_sch_clean = strip_med_suffix(med_sch_raw),
         med_sch_was_medical_label = !is.na(med_sch_raw) &
           str_detect(med_sch_raw, regex("SCHOOL OF MEDICINE|COLLEGE OF MED", ignore_case = TRUE)),
         n_person_conflicts = nrow(bad))

locations <- loc_rank %>%
  transmute(NPI, location_rank = .rank,
            facility_name = `Facility Name`, org_pac_id,
            num_org_mem = suppressWarnings(as.integer(num_org_mem)),
            address_1 = adr_ln_1, address_2 = adr_ln_2,
            city = `City/Town`, state = State, zip = `ZIP Code`,
            phone = `Telephone Number`, adrs_id,
            ind_assgn, grp_assgn, Telehlth)
write_csv(locations, "artifacts/dac_cnm_locations.csv", na = "")
cat(sprintf("written: artifacts/dac_cnm_locations.csv (%s NPI-location rows)\n",
            format(nrow(locations), big.mark = ",")))

write_csv(out, "artifacts/dac_cnm_education.csv", na = "")
cat(sprintf("\nwritten: artifacts/dac_cnm_education.csv (%s CNMs, one row per NPI)\n",
            format(nrow(out), big.mark = ",")))

f <- function(x, lab) cat(sprintf("  %-40s %6s (%4.1f%%)\n", lab,
                                  format(x, big.mark = ","), 100 * x / nrow(out)))
f(sum(!is.na(out$med_sch_raw) & out$med_sch_raw != "OTHER"), "school named")
f(sum(out$med_sch_was_medical_label), "  ...labelled School/College of Medicine")
f(sum(!is.na(out$grad_year)),        "graduation year present")
f(sum(out$n_locations > 1),          "practises at >1 location")
f(sum(out$n_groups > 1),             "affiliated with >1 group")
cat(sprintf("  median group size (primary location): %s | median locations: %s\n",
            median(out$num_org_mem, na.rm = TRUE), median(out$n_locations)))
f(sum(!is.na(out$enrollment_date)), "enrollment date parsed from Ind_enrl_ID")
f(sum(out$accepts_assignment == "Y", na.rm = TRUE), "accepts Medicare assignment")
top <- sort(table(out$med_sch_clean[!is.na(out$med_sch_clean) & out$med_sch_clean != "OTHER"]),
            decreasing = TRUE)
cat("\n  most common institutions after cleaning:\n")
for (i in seq_len(min(8, length(top))))
  cat(sprintf("    %-52s %d\n", names(top)[i], top[i]))
