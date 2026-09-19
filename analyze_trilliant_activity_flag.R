#!/usr/bin/env Rscript
# =============================================================================
# Does Trilliant's active_provider flag mean a midwife is seeing patients?
# =============================================================================
# Trilliant's provider directory (snapshot 2026-06-25) carries an undocumented
# boolean, active_provider. Patient-panel fields are populated only when it is
# TRUE, which suggests it comes from claims. Nothing in the lake defines it, so
# this script tests it against three things it should agree with:
#
#   1. AMCB status. Every primary-linked certificant, whatever the status.
#      DECEASED and RETIRED certificants are negative controls: they should
#      almost never be flagged active.
#   2. Time since leaving. For RETIRED, LAPSED and DECEASED certificants, the
#      share still flagged active by the year their certification expired --
#      how long the flag lags a stop in practice.
#   3. Recency of Medicare billing. For ACTIVE certificants, the share flagged
#      active by the last year they billed Medicare Part B or D (2013-2023), or
#      never (fewer than 11 beneficiaries in every year is indistinguishable
#      from not billing; see match_medicare_partb_partd.R).
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv   (person-level; the manifest's
#            freeze unless ALLOW_FREEZE_SHA256 names another on purpose)
#          Trilliant lake directory_provider       (external volume)
#          Medicare warehouse, Part B + Part D     (external volume)
# Output : artifacts/trilliant_activity_validation_<freeze sha8>.csv  (aggregate)
#          The freeze's hash is in the NAME, so a run against one freeze never
#          overwrites the evidence from another.
#
# R and dplyr throughout; the Medicare tables are read through dbplyr.
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(dbplyr); library(DBI); library(duckdb)
  library(readr); library(stringr); library(purrr)
})
source(file.path("R", "lib", "common_helpers.R"))       # chr()
source(file.path("R", "lib", "medicare_duckdb.R"))      # duckdb_connect(), samsung_volume_path(), resolve_midwifery_duckdb()
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()
source(file.path("R", "lib", "cohort_definitions.R"))   # verify_linkage_freeze()

FROZEN <- file.path(Sys.getenv("MIDWIFERY_ARTIFACTS", "artifacts"), "amcb_npi_linkage_FROZEN.csv")
FROZEN_SHA256 <- verify_linkage_freeze(FROZEN)
LAKE <- { v <- Sys.getenv("TRILLIANT_LAKE", ""); if (nzchar(v)) v else
          samsung_volume_path("hpt_prices/trilliant/20260721/lake/data/main") }
TRILLIANT_SNAPSHOT <- "2026-06-25"
OUT <- file.path("artifacts", sprintf("trilliant_activity_validation_%s.csv", substr(FROZEN_SHA256, 1, 8)))

# ---- every primary-linked certificant, any status ------------------------------
linkage <- chr(FROZEN)
linked <- linkage |>
  filter(linkage_tier == "primary_midwifery", !is.na(npi), npi != "")
conflict <- linked |> group_by(certification_number) |> filter(n_distinct(npi) > 1L) |> ungroup()
if (nrow(conflict)) stop(nrow(conflict), " rows give one certificant two NPIs; resolve before counting.", call. = FALSE)
linked <- linked |>
  arrange(certification_number) |>
  filter(!duplicated(certification_number)) |>
  transmute(certification_number, npi, status,
            expiration_year = suppressWarnings(as.integer(str_extract(expiration_date, "\\d{4}$"))))

# ---- Trilliant's flag ------------------------------------------------------------
flag <- read_parquet_duckdb(file.path(LAKE, "directory_provider", "*.parquet")) |>
  select(provider_npi, active_provider) |>
  semi_join(as_duckdb_tibble(tibble(provider_npi = as.numeric(linked$npi))), by = "provider_npi") |>
  collect() |>
  transmute(npi = as.character(provider_npi), active_provider)
linked <- linked |>
  left_join(flag, by = "npi", relationship = "one-to-one") |>
  mutate(in_trilliant = !is.na(active_provider),
         # Not in the directory counts as not active: absent is not evidence of practice.
         flagged_active = coalesce(active_provider, FALSE))

activity_tally <- function(d, analysis, level) {
  d |> group_by(level = {{ level }}) |>
    summarise(n = n(), n_in_trilliant = sum(in_trilliant), n_flagged_active = sum(flagged_active),
              .groups = "drop") |>
    mutate(analysis = analysis, level = as.character(level))
}

by_status <- activity_tally(linked, "1_by_amcb_status", status)

left_practice <- linked |> filter(status %in% c("RETIRED", "LAPSED", "DECEASED"))
by_exit <- left_practice |>
  mutate(band = case_when(is.na(expiration_year) ~ "expiry unknown",
                          expiration_year <= 2016 ~ "expired 2016 or earlier",
                          expiration_year <= 2019 ~ "expired 2017-2019",
                          expiration_year <= 2022 ~ "expired 2020-2022",
                          TRUE ~ "expired 2023 or later")) |>
  group_split(status) |>
  map_dfr(\(d) activity_tally(d, paste0("2_", tolower(d$status[1]), "_by_certification_expiry"), band))

# ---- last Medicare billing year, ACTIVE certificants ------------------------------
con <- duckdb_connect(resolve_midwifery_duckdb(), read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
tabs <- dbListTables(con)
part_b <- sort(grep("^medicare_part_b_[0-9]{4}$", tabs, value = TRUE))
part_d <- sort(grep("^medicare_part_d_[0-9]{4}_standardized$", tabs, value = TRUE))
yr <- function(t) as.integer(str_extract(t, "[0-9]{4}"))
if (!identical(yr(part_b), yr(part_d)))
  stop("Part B and Part D cover different years; the recency comparison needs one window.", call. = FALSE)
active <- linked |> filter(status == "ACTIVE")
cohort_db <- copy_to(con, tibble(npi = active$npi), "activity_cohort_npi", temporary = TRUE, overwrite = TRUE)
years_billed <- c(
  map(part_b, \(t) tbl(con, t) |> transmute(npi = as.character(Rndrng_NPI), year = !!yr(t))),
  map(part_d, \(t) tbl(con, t) |> transmute(npi = as.character(npi_char), year = !!yr(t)))) |>
  reduce(union_all) |>
  semi_join(cohort_db, by = "npi") |>
  group_by(npi) |>
  summarise(last_medicare_year = max(year, na.rm = TRUE), .groups = "drop") |>
  collect()
by_medicare <- active |>
  left_join(years_billed, by = "npi", relationship = "one-to-one") |>
  mutate(band = if_else(is.na(last_medicare_year), "never (or under 11 beneficiaries every year)",
                        as.character(last_medicare_year))) |>
  activity_tally("3_active_by_last_medicare_year", band)

out <- bind_rows(by_status, by_exit, by_medicare) |>
  mutate(pct_flagged_active = 100 * n_flagged_active / n,
         frozen_sha256 = FROZEN_SHA256, trilliant_snapshot = TRILLIANT_SNAPSHOT,
         medicare_years = sprintf("%d-%d", min(yr(part_b)), max(yr(part_b)))) |>
  select(analysis, level, n, n_in_trilliant, n_flagged_active, pct_flagged_active,
         frozen_sha256, trilliant_snapshot, medicare_years) |>
  arrange(analysis, level)

write_with_provenance(out, OUT, na = "")
cat("wrote", OUT, "\n")
print(out |> select(analysis, level, n, n_flagged_active, pct_flagged_active), n = Inf, width = 160)
