#!/usr/bin/env Rscript
# =============================================================================
# Trilliant identity experiment, step 1: what is in directory_provider?
# =============================================================================
# One row per column of Trilliant's provider directory (snapshot 2026-06-25,
# lake 20260721): type, non-missing N, distinct N, the most common values, and
# what the column could do for AMCB -> NPI identity resolution. Counted twice:
# over the whole directory, and over the NPIs the freeze links to AMCB
# certificants in the primary (midwifery-taxonomy) tier, because a field that
# is well filled for physicians can be empty or meaningless for midwives.
#
# A second table gives the value distributions that matter for midwives:
# credential, gender, specialty, school, graduation year against AMCB
# certification year, practice count, the active flag, and whether the patient
# panel and practice are present.
#
# Inputs : LINKAGE_CSV   the linkage freeze (person-level, gitignored)
#          TRILLIANT_LAKE  lake data/main directory (default: Samsung volume)
# Outputs: analysis/trilliant_identity_inventory.csv          (gitignored)
#          analysis/trilliant_identity_inventory_cnm_values.csv (gitignored)
#
# Trilliant ToS 2.3(i)/(iii) forbid redistributing derived data, so every
# output lands under analysis/*.csv, which .gitignore excludes. Person
# identifiers (names, NPI, street, phone, coordinates) are never printed as
# examples. Source: Trilliant Health provider directory.
# =============================================================================
suppressPackageStartupMessages({ library(duckplyr); library(dplyr); library(readr); library(tidyr) })
source(file.path("R", "analysis_args.R"))       # arg_or()
source(file.path("R", "lib", "medicare_duckdb.R"))  # samsung_volume_path()

LINKAGE <- arg_or(1, "LINKAGE_CSV")
LAKE <- arg_or(2, "TRILLIANT_LAKE", samsung_volume_path("hpt_prices/trilliant/20260721/lake/data/main"))
OUT <- "analysis/trilliant_identity_inventory.csv"
OUT_VALUES <- "analysis/trilliant_identity_inventory_cnm_values.csv"

db_exec("SET memory_limit='5GB'")
db_exec("SET threads=3")

trl <- read_parquet_duckdb(file.path(LAKE, "directory_provider", "*.parquet"), prudence = "stingy")

linkage <- read_csv(LINKAGE, col_types = cols(.default = "c"), guess_max = Inf)
cnm <- linkage |>
  filter(linkage_tier == "primary_midwifery", !is.na(npi)) |>
  distinct(npi, certification_date)
cnm_npis <- as_duckdb_tibble(tibble(provider_npi = as.numeric(unique(cnm$npi))))
trl_cnm <- trl |> semi_join(cnm_npis, by = "provider_npi")

# ---- what each column could do ----------------------------------------------
PERSON_ID <- c("provider_npi", "provider_id", "provider_first_name", "provider_middle_name",
               "provider_last_name", "provider_affiliated_practice_1_street_address",
               "provider_affiliated_practice_1_phone_number",
               "provider_affiliated_practice_1_latitude", "provider_affiliated_practice_1_longitude")
USE <- tribble(
  ~column,                                        ~evidence_class, ~likely_identity_use,
  "provider_npi",                                 "key",        "join key to NPPES and the linkage; unique per row (7,518,635 rows = 7,518,635 NPIs)",
  "provider_id",                                  "key",        "Trilliant's internal id; one per NPI; no identity content",
  "active_provider",                              "contextual", "claims-derived activity; lags a stop in practice by years; FALSE is never evidence of a wrong identity",
  "provider_first_name",                          "identity",   "given-name agreement (blocking + scoring); check whether it is NPPES's value",
  "provider_middle_name",                         "identity",   "middle-name agreement; most discriminating name field when both sides record one",
  "provider_last_name",                           "identity",   "surname agreement (blocking + scoring), incl. component and maiden-as-middle rescue",
  "provider_suffix",                              "identity",   "generational suffix; rare for this cohort",
  "provider_credential",                          "identity",   "credential compatibility with CNM/CM (physician = contradiction)",
  "provider_estimated_age",                       "none",       "NOT a measurement: estimated_age + graduation_year = 2052 for every midwife; redundant with graduation year",
  "provider_gender",                              "identity",   "sex; weak in a ~99% female cohort, a MALE value against a female roster name is a contradiction candidate",
  "provider_medical_school_name",                 "identity",   "CMS DAC medical-school string; 'Other' or NA for most CNMs; can only name a university with a medical school",
  "provider_medical_school_graduation_year",      "identity",   "compare with AMCB certification year",
  "provider_primary_specialty_code",              "identity",   "NUCC taxonomy; midwife vs NP vs RN vs physician compatibility",
  "provider_primary_specialty_description",       "identity",   "label of the taxonomy code",
  "provider_specialty_classification",            "identity",   "coarser specialty grouping",
  "primary_organization_name",                    "contextual", "employer or group; plausibility only, never identity",
  "provider_practices_total",                     "contextual", "count of claims-attributed practices",
  "panel_median_age",                             "contextual", "claims-derived patient age; a midwife's panel is reproductive-age",
  "panel_percent_age_0_19",                       "contextual", "panel age band",
  "panel_percent_age_20_44",                      "contextual", "panel age band; the midwifery-plausible band",
  "panel_percent_age_45_64",                      "contextual", "panel age band",
  "panel_percent_age_65_84",                      "contextual", "panel age band",
  "panel_percent_age_85_plus",                    "contextual", "panel age band",
  "panel_percent_female",                         "contextual", "panel sex mix; a midwife's panel is almost all female",
  "panel_percent_male",                           "contextual", "panel sex mix",
  "provider_affiliated_practice_1_name",          "contextual", "top practice by visit share (basic tier names practice 1 only)",
  "provider_affiliated_practice_1_street_address","contextual", "practice geography",
  "provider_affiliated_practice_1_city",          "contextual", "practice geography",
  "provider_affiliated_practice_1_county",        "contextual", "practice geography",
  "provider_affiliated_practice_1_state",         "contextual", "practice state; AMCB records no state, so compare only with a board license state or the NPI's own NPPES state",
  "provider_affiliated_practice_1_zip_code",      "contextual", "practice ZIP",
  "provider_affiliated_practice_1_latitude",      "contextual", "practice geography",
  "provider_affiliated_practice_1_longitude",     "contextual", "practice geography",
  "provider_affiliated_practice_1_phone_number",  "contextual", "practice phone",
  "provider_affiliated_practice_1_visits_percent_total", "contextual", "share of the provider's visits at practice 1; the only attribution-quality signal in this tier (no claim-role field)"
)

# ---- per-column counts ---------------------------------------------------------
col_types <- vapply(collect(head(trl, 0L)), function(v) class(v)[1], "")
column_stats <- function(tbl, col, scope) {
  is_chr <- col_types[[col]] == "character"
  s <- tbl |>
    rename(v = all_of(col)) |>
    summarise(n_rows = n(),
              n_nonmissing = sum(as.integer(!is.na(v))),
              n_distinct = n_distinct(v)) |>
    collect()
  s$n_blank <- if (is_chr) {
    tbl |> rename(v = all_of(col)) |> filter(!is.na(v), v == "") |> count() |> collect() |> pull(n)
  } else 0L
  ex <- if (col %in% PERSON_ID) "[person identifier: not shown]" else {
    top <- tbl |> rename(v = all_of(col)) |> filter(!is.na(v)) |>
      count(v) |> arrange(desc(n)) |> head(5L) |> collect()
    paste(sprintf("%s (%s)", as.character(top$v), format(top$n, big.mark = ",", trim = TRUE)), collapse = " | ")
  }
  tibble(scope = scope, column = col, type = col_types[[col]],
         n_rows = s$n_rows, n_nonmissing = s$n_nonmissing - s$n_blank,
         pct_nonmissing = round(100 * (s$n_nonmissing - s$n_blank) / s$n_rows, 1),
         n_distinct = s$n_distinct, example_values = ex)
}
inv <- bind_rows(
  lapply(names(col_types), column_stats, tbl = trl, scope = "all_directory"),
  lapply(names(col_types), column_stats, tbl = trl_cnm, scope = "amcb_primary_linked_npis")
) |>
  left_join(USE, by = "column")
write_csv(inv, OUT)
cat(sprintf("known CNM/CM NPIs: %s linked, %s found in the directory\n",
            format(nrow(cnm_npis |> collect()), big.mark = ","),
            format(inv$n_rows[inv$scope == "amcb_primary_linked_npis"][1], big.mark = ",")))

# ---- value distributions among known CNM/CM NPIs --------------------------------
v <- trl_cnm |>
  select(provider_npi, provider_credential, provider_gender, provider_primary_specialty_code,
         provider_primary_specialty_description, provider_specialty_classification,
         provider_medical_school_name, provider_medical_school_graduation_year,
         provider_estimated_age, provider_practices_total, active_provider,
         panel_median_age, provider_affiliated_practice_1_state,
         provider_affiliated_practice_1_visits_percent_total) |>
  collect() |>
  mutate(npi = as.character(provider_npi)) |>
  left_join(cnm |> mutate(cert_year = as.integer(substr(certification_date, 4, 7))) |>
              group_by(npi) |> summarise(cert_year = min(cert_year), .groups = "drop"), by = "npi")
tab <- function(x, field, top = 25L) {
  tibble(value = as.character(x)) |>
    mutate(value = coalesce(value, "<NA>")) |>
    count(value, sort = TRUE) |>
    mutate(field = field, share = round(n / sum(n), 4)) |>
    head(top)
}
gdiff <- v$provider_medical_school_graduation_year - v$cert_year
vals <- bind_rows(
  tab(v$provider_credential, "provider_credential"),
  tab(v$provider_gender, "provider_gender"),
  tab(paste(v$provider_primary_specialty_code, v$provider_primary_specialty_description, sep = " | "),
      "provider_primary_specialty"),
  tab(v$provider_specialty_classification, "provider_specialty_classification"),
  tab(v$provider_medical_school_name, "provider_medical_school_name"),
  tab(cut(gdiff, c(-Inf, -11, -4, -2, -1, 0, 1, 3, 10, Inf),
          labels = c("<=-11", "-10..-4", "-3..-2", "-1", "0", "1", "2..3", "4..10", ">=11")),
      "grad_year_minus_amcb_cert_year"),
  tab(v$provider_estimated_age + v$provider_medical_school_graduation_year, "estimated_age_plus_grad_year"),
  tab(v$provider_practices_total, "provider_practices_total"),
  tab(v$active_provider, "active_provider"),
  tab(case_when(!is.na(v$panel_median_age) & !is.na(v$provider_affiliated_practice_1_state) ~ "panel+practice",
                !is.na(v$panel_median_age) ~ "panel only",
                !is.na(v$provider_affiliated_practice_1_state) ~ "practice only",
                TRUE ~ "neither"), "panel_practice_presence"),
  tab(cut(v$provider_affiliated_practice_1_visits_percent_total, c(-Inf, 0.1, 0.25, 0.5, 0.75, 0.999, Inf),
          labels = c("<=10%", "10-25%", "25-50%", "50-75%", "75-99.9%", "100%")),
      "practice_1_visit_share")
) |>
  select(field, value, n, share)
write_csv(vals, OUT_VALUES)
cat("wrote", OUT, "and", OUT_VALUES, "\n")
