#!/usr/bin/env Rscript

long <- read.csv("artifacts/midwife_work_sites_long.csv",
                 stringsAsFactors = FALSE, check.names = FALSE)
excluded <- read.csv("artifacts/midwife_work_sites_excluded_non_workplace.csv",
                     stringsAsFactors = FALSE, check.names = FALSE)
required <- c("military_base_flag", "military_base_reason", "military_base_source")
stopifnot(all(required %in% names(long)), all(required %in% names(excluded)))
stopifnot(all(long$military_base_flag %in% c(TRUE, FALSE)))
stopifnot(all(excluded$military_base_flag %in% c(TRUE, FALSE)))
stopifnot(any(long$military_base_flag))
stopifnot(all(long$military_base_reason[long$military_base_flag] %in% c(
  "military_postal_code", "military_zip", "dod_tricare_facility_source",
  "curated_military_facility_name")))
stopifnot(all(long$military_base_source[long$military_base_flag] %in% c(
  "military_postal_code", "isochrones_curated_military_zip",
  "DoD/TRICARE facility source", "curated_military_facility_name")))

# Ordinary civilian places with "Fort" in the name must not be treated as bases.
fort_collins <- grepl("FORT COLLINS", toupper(long$site_name), fixed = TRUE)
stopifnot(any(fort_collins), !any(long$military_base_flag[fort_collins]))
cat("OK: high-confidence military-base flag validated\n")
