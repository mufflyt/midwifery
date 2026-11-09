#!/usr/bin/env Rscript

path <- "artifacts/worksite_address_resolution.csv"
queue <- "artifacts/worksite_address_resolution_unresolved.csv"
stopifnot(file.exists(path), file.exists(queue))
d <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
q <- read.csv(queue, stringsAsFactors = FALSE, check.names = FALSE)
required <- c("site_id", "address_key", "resolved_site_name", "resolution_status",
              "confidence", "resolution_source", "source_url", "name_status",
              "setting_status")
stopifnot(all(required %in% names(d)))
stopifnot(nrow(d) > 10000L, nrow(q) < nrow(d))
stopifnot(any(d$address_key == "301 KNAPP ST WOLF POINT MT 59201" &
              d$resolved_site_name == "NEMHS - Listerud Rural Health Clinic" &
              d$resolved_site_setting == "Clinic/practice"))
stopifnot(all(d$resolution_status %in% c("resolved", "unresolved")))
stopifnot(all(q$resolution_status == "unresolved"))
stopifnot(all(d$name_status %in% c("resolved", "unresolved")))
stopifnot(all(d$setting_status %in% c("evidence-supported", "fallback", "missing")))
stopifnot(all(d$name_status == "unresolved" & d$setting_status != "missing" |
              d$name_status == "resolved"))
non_us_states <- c("AA", "AE", "AP", "AS", "GU", "MP", "PR", "VI",
                   "OKINAWA PREFECTURE", "RHINELAND-PFALZ")
us_states <- c(state.abb, "DC")
stopifnot(!any(!is.na(d$state) & nzchar(d$state) & !d$state %in% us_states))
excluded_path <- "artifacts/midwife_work_sites_excluded_non_workplace.csv"
stopifnot(file.exists(excluded_path))
excluded <- read.csv(excluded_path, stringsAsFactors = FALSE, check.names = FALSE)
stopifnot(any(excluded$state %in% non_us_states))
stopifnot(all(excluded$exclusion_reason %in% c(
  "outside_us_military_or_territory_code",
  "outside_us_nonstate_value",
  "non_workplace_facility_type")))
stopifnot(all(excluded$state[excluded$exclusion_reason ==
                               "outside_us_military_or_territory_code"] %in% non_us_states))
stopifnot(any(excluded$exclusion_reason == "outside_us_nonstate_value"))
cat("OK: work-site address resolution table and unresolved queue validated\n")
