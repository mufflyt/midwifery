#!/usr/bin/env Rscript
# =============================================================================
# Trilliant identity experiment, step 0: a slim NPPES cache
# =============================================================================
# The evidence experiment asks, for each Trilliant field, whether it says
# anything NPPES does not. That needs NPPES's own values for every candidate
# NPI: names, the recorded former surname, credential, sex, enumeration date,
# taxonomies and self-reported license numbers. The national file is 11.6 GB
# and 330 columns, so this reads it once and keeps the ~70 columns needed, for
# individual (entity type 1) NPIs only.
#
# Input : NPPES_PFILE  (default: the 2026-08-09 dissemination on the Samsung volume)
# Output: analysis/trilliant_identity_nppes_slim.parquet   (gitignored: *.parquet)
#
# NPPES is public data; nothing Trilliant-derived is written here.
# =============================================================================
suppressPackageStartupMessages({ library(duckplyr); library(dplyr) })

PFILE <- Sys.getenv("NPPES_PFILE", "/Volumes/MufflySamsung 1/npidata_pfile_20050523-20260809.csv")
OUT <- "analysis/trilliant_identity_nppes_slim.parquet"
if (!file.exists(PFILE)) stop("no NPPES file at ", PFILE, call. = FALSE)

db_exec("SET memory_limit='5GB'")
db_exec("SET threads=3")

slot <- function(stem, new) setNames(paste0(stem, "_", 1:15), paste0(new, "_", 1:15))
keep <- c(npi = "NPI", entity_type = "Entity Type Code",
          last = "Provider Last Name (Legal Name)", first = "Provider First Name",
          middle = "Provider Middle Name", suffix = "Provider Name Suffix Text",
          credential = "Provider Credential Text",
          other_last = "Provider Other Last Name", other_first = "Provider Other First Name",
          other_middle = "Provider Other Middle Name", other_last_type = "Provider Other Last Name Type Code",
          practice_state = "Provider Business Practice Location Address State Name",
          practice_zip = "Provider Business Practice Location Address Postal Code",
          enumeration_date = "Provider Enumeration Date",
          deactivation_date = "NPI Deactivation Date", reactivation_date = "NPI Reactivation Date",
          sex = "Provider Sex Code",
          slot("Healthcare Provider Taxonomy Code", "taxonomy"),
          slot("Provider License Number", "license"),
          slot("Provider License Number State Code", "license_state"),
          slot("Healthcare Provider Primary Taxonomy Switch", "primary_switch"))

read_csv_duckdb(PFILE, options = list(all_varchar = TRUE, header = TRUE)) |>
  select(all_of(keep)) |>
  filter(entity_type == "1") |>
  select(-entity_type) |>
  compute_parquet(OUT)

n <- read_parquet_duckdb(OUT) |> count() |> collect()
cat(sprintf("wrote %s: %s individual NPIs\n", OUT, format(n$n, big.mark = ",")))
