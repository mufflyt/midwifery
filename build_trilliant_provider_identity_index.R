#!/usr/bin/env Rscript
# =============================================================================
# A complete identity index over Trilliant's provider directory
# =============================================================================
# One row for EVERY individual NPI in lake.directory_provider (7,518,635; one
# row per NPI, checked), not just the certificants already linked. The index
# keeps each identity field raw and adds the normalised form the AMCB linkage
# compares on, so a candidate search over the whole directory uses exactly the
# keys match_amcb_to_npi.R uses:
#
#   last_key          mysterynpi::blank_na(last, fold_hyphens = TRUE)
#   given_key         mysterynpi::split_given(first)$given
#   middle_from_given the tokens split_given() moves out of a fused first name
#   middle_key        mysterynpi::blank_na(middle); a consumer joins it with
#                     middle_from_given, as the AMCB side does
#   first_init        the first letter of given_key
#
# plus classes for specialty (trl_taxonomy_class) and credential
# (classify_credentials), the NPPES-style sex code, and the DAC-cleaned school.
# Claims-derived fields (active flag, practice 1, patient panel) ride along
# unscored, as context; see R/lib/trilliant_identity.R for why they are not
# identity evidence.
#
# Every key is computed ONCE per distinct raw value in R and joined back in
# DuckDB, so the 7.5M rows never materialise in R.
#
# Inputs : Trilliant lake directory_provider parquet (external volume;
#          TRILLIANT_LAKE overrides)
# Outputs: artifacts/trilliant_provider_identity_index.parquet   (person-level,
#            licensed; gitignored by *.parquet)
#          artifacts/trilliant_provider_identity_index.manifest.json (gitignored)
#          artifacts/trilliant_provider_identity_coverage.csv      (aggregate, tracked)
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(readr); library(tibble)
})
# duckplyr is for the lazy parquet and CSV scans. Attaching it also routes dplyr
# verbs on ORDINARY data frames through DuckDB, whose joins do not keep row
# order (measured 2026-09-14: a left_join of a shuffled 50,000-row tibble came
# back reordered). The first runs of the experiment paired 22 of 655,646
# candidates with another row's profession that way. Restore dplyr's methods so
# in-memory frames keep dplyr's semantics; duckplyr frames keep their own.
invisible(duckplyr::methods_restore())
source(file.path("R", "lib", "medicare_duckdb.R"))       # samsung_volume_path()
source(file.path("R", "lib", "artifact_provenance.R"))   # write_with_provenance()
source(file.path("R", "lib", "training_institution.R"))  # strip_med_suffix()
source(file.path("R", "lib", "trilliant_demographics.R"))# trl_sex_code(), trl_school_clean()
source("credential_compatibility.R")                     # classify_credentials()
source(file.path("R", "lib", "trilliant_identity.R"))

LAKE <- { v <- Sys.getenv("TRILLIANT_LAKE", ""); if (nzchar(v)) v else
          samsung_volume_path("hpt_prices/trilliant/20260721/lake/data/main") }
TRILLIANT_SNAPSHOT <- "2026-06-25"
SRC <- sort(Sys.glob(file.path(LAKE, "directory_provider", "*.parquet")))
if (!length(SRC)) stop("no directory_provider parquet under ", LAKE, call. = FALSE)
OUT <- file.path("artifacts", "trilliant_provider_identity_index.parquet")
OUT_MANIFEST <- sub("\\.parquet$", ".manifest.json", OUT)
OUT_COVERAGE <- file.path("artifacts", "trilliant_provider_identity_coverage.csv")

dp <- read_parquet_duckdb(SRC)
n_rows <- dp |> count() |> collect() |> pull(n)
n_npi <- dp |> distinct(provider_npi) |> count() |> collect() |> pull(n)
if (n_rows != n_npi) stop(sprintf("directory_provider has %s rows but %s NPIs; the index assumes one row per NPI",
                                  n_rows, n_npi), call. = FALSE)
cat(sprintf("directory_provider: %s rows, one per NPI\n", format(n_rows, big.mark = ",")))

# ---- one lookup per raw field, computed on distinct values ----------------------
# select(all_of()) rather than distinct(.data[[col]]): duckplyr translates the first, not the second.
distinct_values <- function(col) dp |> select(all_of(col)) |> distinct() |> collect() |> pull(1)
blank <- function(x) { x[is.na(x)] <- ""; x }

last_lk <- tibble(provider_last_name = distinct_values("provider_last_name")) |>
  mutate(last_key = blank(mysterynpi::blank_na(provider_last_name, fold_hyphens = TRUE)))
first_lk <- tibble(provider_first_name = distinct_values("provider_first_name"))
sg <- mysterynpi::split_given(first_lk$provider_first_name)
first_lk <- first_lk |>
  mutate(given_key = blank(sg$given), middle_from_given = blank(sg$middle_from_given),
         first_init = substr(given_key, 1, 1))
middle_lk <- tibble(provider_middle_name = distinct_values("provider_middle_name")) |>
  mutate(middle_key = blank(mysterynpi::blank_na(provider_middle_name)))
cred_lk <- tibble(provider_credential = distinct_values("provider_credential")) |>
  mutate(credential_class = trl_credential_class(provider_credential))
spec_lk <- tibble(provider_primary_specialty_code = distinct_values("provider_primary_specialty_code")) |>
  mutate(specialty_class = trl_taxonomy_class(provider_primary_specialty_code))
sex_lk <- tibble(provider_gender = distinct_values("provider_gender")) |>
  mutate(sex_code = trl_sex_code(provider_gender))
school_lk <- tibble(provider_medical_school_name = distinct_values("provider_medical_school_name")) |>
  mutate(school_clean = trl_school_clean(provider_medical_school_name))
cat(sprintf("keys: %s surnames, %s first names, %s middle names, %s credentials, %s specialties\n",
            nrow(last_lk), nrow(first_lk), nrow(middle_lk), nrow(cred_lk), nrow(spec_lk)))

lk <- function(x) as_duckdb_tibble(x)
index <- dp |>
  left_join(lk(last_lk), by = "provider_last_name") |>
  left_join(lk(first_lk), by = "provider_first_name") |>
  left_join(lk(middle_lk), by = "provider_middle_name") |>
  left_join(lk(cred_lk), by = "provider_credential") |>
  left_join(lk(spec_lk), by = "provider_primary_specialty_code") |>
  left_join(lk(sex_lk), by = "provider_gender") |>
  left_join(lk(school_lk), by = "provider_medical_school_name") |>
  mutate(midwife_pool = coalesce(specialty_class == "midwife", FALSE) | coalesce(credential_class == "midwife", FALSE),
         nursing_pool = midwife_pool | coalesce(specialty_class == "nursing", FALSE) |
           coalesce(credential_class == "nursing", FALSE)) |>
  select(provider_npi,
         # identity, raw
         provider_first_name, provider_middle_name, provider_last_name, provider_suffix,
         provider_credential, provider_gender, provider_primary_specialty_code,
         provider_primary_specialty_description, provider_specialty_classification,
         provider_medical_school_name, provider_medical_school_graduation_year,
         # identity, normalised
         last_key, given_key, middle_key, middle_from_given, first_init,
         credential_class, specialty_class, sex_code, school_clean, midwife_pool, nursing_pool,
         # context only: claims-derived or derived from graduation year; never scored
         provider_estimated_age, active_provider, primary_organization_name, provider_practices_total,
         provider_affiliated_practice_1_name, provider_affiliated_practice_1_city,
         provider_affiliated_practice_1_state, provider_affiliated_practice_1_zip_code,
         provider_affiliated_practice_1_visits_percent_total,
         panel_median_age, panel_percent_female, panel_percent_age_20_44, panel_percent_age_65_84)

tmp <- paste0(OUT, ".tmp")
unlink(tmp)
invisible(compute_parquet(index, tmp))
written <- read_parquet_duckdb(tmp) |> count() |> collect() |> pull(n)
if (written != n_rows) stop(sprintf("index wrote %s rows, expected %s", written, n_rows), call. = FALSE)
stopifnot(file.rename(tmp, OUT))

jsonlite::write_json(list(
  artifact = basename(OUT), rows = n_rows, trilliant_snapshot = TRILLIANT_SNAPSHOT,
  source_files = basename(SRC), source_bytes = unname(file.size(SRC)),
  builder = "build_trilliant_provider_identity_index.R",
  builder_sha256 = digest::digest(file = "build_trilliant_provider_identity_index.R", algo = "sha256"),
  library_sha256 = digest::digest(file = file.path("R", "lib", "trilliant_identity.R"), algo = "sha256"),
  mysterynpi = as.character(utils::packageVersion("mysterynpi")),
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")), OUT_MANIFEST, auto_unbox = TRUE, pretty = TRUE)
cat("wrote", OUT, "\n")

# ---- coverage: every field, in the whole directory and in the midwifery pool -----
ix <- read_parquet_duckdb(OUT)
fields <- c("provider_first_name", "provider_middle_name", "provider_last_name", "provider_credential",
            "provider_primary_specialty_code", "sex_code", "provider_medical_school_name", "school_clean",
            "provider_medical_school_graduation_year", "provider_affiliated_practice_1_state",
            "primary_organization_name", "provider_affiliated_practice_1_name", "panel_median_age")
coverage_in <- function(d, population) {
  tot <- d |> count() |> collect() |> pull(n)
  bind_rows(lapply(fields, function(f) {
    n_present <- d |> filter(!is.na(!!rlang::sym(f))) |> count() |> collect() |> pull(n)
    tibble(population = population, field = f, n = tot, n_present = n_present)
  }))
}
# Counted per raw value in DuckDB (606 of them), classified in R: duckplyr
# cannot translate case_when().
school_mix <- function(d, population) {
  d |> count(provider_medical_school_name) |> collect() |>
    mutate(school_value = case_when(is.na(provider_medical_school_name) ~ "absent",
                                    provider_medical_school_name == "Other" ~ "placeholder 'Other'",
                                    TRUE ~ "named institution")) |>
    group_by(school_value) |> summarise(n_present = sum(n), .groups = "drop") |>
    transmute(population, field = paste0("provider_medical_school_name: ", school_value),
              n = sum(n_present), n_present)
}
coverage <- bind_rows(
  coverage_in(ix, "all individual NPIs"),
  coverage_in(filter(ix, midwife_pool), "midwifery specialty or credential"),
  school_mix(ix, "all individual NPIs"),
  school_mix(filter(ix, midwife_pool), "midwifery specialty or credential")) |>
  mutate(pct_present = round(100 * n_present / n, 2), trilliant_snapshot = TRILLIANT_SNAPSHOT)
write_with_provenance(coverage, OUT_COVERAGE, na = "")
cat("wrote", OUT_COVERAGE, "\n")
print(coverage, n = Inf, width = 160)
