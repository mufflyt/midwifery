#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(stringr))

paths <- c("artifacts/worksite_address_setting_crosswalk.csv",
           "artifacts/worksite_address_setting_best_match.csv",
           "artifacts/worksite_setting_source_registry.csv")
stopifnot(all(file.exists(paths)))
d <- read.csv(paths[[1]], stringsAsFactors = FALSE, check.names = FALSE)
b <- read.csv(paths[[2]], stringsAsFactors = FALSE, check.names = FALSE)
r <- read.csv(paths[[3]], stringsAsFactors = FALSE, check.names = FALSE)
long <- read.csv("artifacts/midwife_work_sites_long.csv", stringsAsFactors = FALSE,
                 check.names = FALSE)
title_case_check <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  y <- str_to_title(str_squish(x))
  y <- gsub("\\bFqhc\\b", "FQHC", y)
  y <- gsub("\\bHrsa\\b", "HRSA", y)
  y <- gsub("\\bCms\\b", "CMS", y)
  y <- gsub("\\bCabc\\b", "CABC", y)
  y <- gsub("\\bNemhs\\b", "NEMHS", y)
  y <- gsub("\\bVa\\b", "VA", y)
  y <- gsub("\\bDod\\b", "DoD", y)
  y <- gsub("\\bIhs\\b", "IHS", y)
  y
}
required <- c("source", "facility_name", "street", "city", "state", "zip5",
              "address_key", "site_setting", "site_id", "source_url")
stopifnot(all(required %in% names(d)))
stopifnot(all(d$facility_name[!is.na(d$facility_name)] ==
              title_case_check(d$facility_name[!is.na(d$facility_name)])))
stopifnot(all(d$street[!is.na(d$street)] ==
              title_case_check(d$street[!is.na(d$street)])))
stopifnot(all(d$state[!is.na(d$state)] == toupper(d$state[!is.na(d$state)])))
us_states <- c(state.abb, "DC")
matched <- !is.na(d$site_id) & nzchar(d$site_id)
stopifnot(all(d$worksite_state[matched] %in% us_states))
stopifnot(all(b$worksite_state[!is.na(b$worksite_state)] %in% us_states))
stopifnot(nrow(d) > 10000L, nrow(b) > 1000L)
stopifnot(all(d$site_setting %in% c("Hospital", "Clinic/practice",
                                    "FQHC/community health", "Birth center",
                                    "Other facility")))
stopifnot(any(d$source == "CMS Rural Health Clinic Enrollments"))
stopifnot(any(d$source == "CMS FQHC Enrollments" &
              d$site_setting == "FQHC/community health"))
stopifnot(any(d$source == "CMS Provider of Services QIES"))
stopifnot(any(d$source == "CMS Dialysis Facility Listing"))
stopifnot(any(d$source == "HIFLD Urgent Care Facilities"))
stopifnot(any(d$source == "NPPES Type-2 organizations"))
stopifnot(any(d$source == "HRSA Health Center Service Delivery Sites"))
stopifnot(any(d$source == "CABC accredited birth centers"))
stopifnot(any(r$source == "CMS FQHC Enrollments" & r$source_status == "available"))
stopifnot(all(c("n_source_rows", "n_matched_rows") %in% names(r)))
active_requested <- c("State-licensed birth centers", "State-licensed clinic facilities",
                      "SAMHSA behavioral-health facilities", "VA facility directory",
                      "DoD/TRICARE military treatment facilities",
                      "Indian Health Service facilities")
stopifnot(all(r$source_status[match(active_requested, r$source)] !=
              "supplemental template; source-specific rows pending"))
stopifnot(all(r$n_source_rows[match(active_requested, r$source)] >= 0))

valid_coord <- is.finite(as.numeric(long$lat)) & is.finite(as.numeric(long$lon))
complete_address <- !is.na(long$street) & nzchar(str_squish(long$street)) &
  !is.na(long$city) & nzchar(str_squish(long$city)) &
  !is.na(long$state) & nzchar(str_squish(long$state)) &
  !is.na(long$zip5) & nzchar(str_squish(long$zip5))
address_only_ids <- unique(long$site_id[!valid_coord & complete_address])
stopifnot(length(address_only_ids) > 0L)
stopifnot(any(d$site_id %in% address_only_ids))
cat("OK: address-to-setting crosswalk, best-match view, and source registry validated\n")
