#!/usr/bin/env Rscript
# =============================================================================
# Audit the geocoding run: coordinates complete vs provenance complete
# =============================================================================
#
# These are two separate questions. The cascade reused a date-only run_id from
# an earlier 25-address smoke test, so the attempt log rejected rows violating
# UNIQUE(run_id, address_hash, attempt_order). Coordinates are unaffected --
# they are written to geocoding_cache, a different table -- but the provenance
# record for this run may be incomplete, and "non-fatal" is not the same as
# "auditable". This quantifies exactly what was lost.
#
# Reconciles every one of the queued addresses, and reports geocoder
# provenance (provider, status, attempt order) rather than bare coordinates.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})

QUEUE  <- "artifacts/panel_geocode_queue.csv"
RESULT <- "artifacts/panel_geocode_results.csv"
CACHE  <- Sys.getenv("GEOCODING_CACHE_PATH",
                     path.expand("~/isochrones/data/geocoding_cache.duckdb"))
RUN_ID <- Sys.getenv("AUDIT_RUN_ID", paste0("amcb_midwifery_", format(Sys.Date())))

q <- read_csv(QUEUE, show_col_types = FALSE)
r <- read_csv(RESULT, show_col_types = FALSE)

key_of <- function(street, city, state, zip)
  sprintf("%s|%s|%s|%s", tolower(coalesce(street, "NA")), tolower(coalesce(city, "NA")),
          coalesce(state, "NA"), coalesce(zip, "NA"))
q <- q %>% mutate(address_hash = key_of(nppes_practice_address, nppes_city,
                                        nppes_state, nppes_zip))

con <- dbConnect(duckdb::duckdb(), CACHE, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cache <- dbGetQuery(con, "SELECT address_hash, latitude, longitude,
                          geocoder_provenance, quality_score, created_at
                          FROM geocoding_cache WHERE latitude IS NOT NULL")
log_run <- dbGetQuery(con, sprintf(
  "SELECT address_hash, attempt_order, provider, status, error_code, candidates_n
   FROM geocoding_attempt_log WHERE run_id = '%s'", RUN_ID))

cat("=========== 1. ADDRESS ACCOUNTING ===========\n")
n_q <- nrow(q); n_uniq <- n_distinct(q$address_hash)
cat(sprintf("queued addresses               : %s\n", format(n_q, big.mark = ",")))
cat(sprintf("  distinct address hashes      : %s\n", format(n_uniq, big.mark = ",")))
cat(sprintf("  duplicate hashes in queue    : %s\n", format(n_q - n_uniq, big.mark = ",")))

# Resolution status comes from the RUN RESULTS, not from a cache join. Newer
# cache writes key on MD5(normalized_address + geocoder_version) while the
# seeded rows use the pipe format, so joining on the pipe hash silently reports
# every freshly geocoded address as unresolved -- which is exactly what it did.
# Join on the address FIELDS, not the hash. The cascade recomputes
# address_hash with its own normalisation, so 749 of 6,793 hashes differ
# between queue and results -- a hash join silently loses them and understates
# resolution. The fields are the stable key.
res <- r %>%
  transmute(nppes_practice_address = geocode_address_1, nppes_city = geocode_city,
            nppes_state = geocode_state, nppes_zip = geocode_zip,
            latitude = lat, longitude = lon,
            geocoder_provenance = geocode_source,
            result_hash = address_hash,
            match_type = if ("match_type" %in% names(r)) match_type else NA_character_) %>%
  distinct(nppes_practice_address, nppes_city, nppes_state, nppes_zip, .keep_all = TRUE)

qq <- q %>% distinct(address_hash, .keep_all = TRUE) %>%
  left_join(res, by = c("nppes_practice_address", "nppes_city",
                        "nppes_state", "nppes_zip")) %>%
  # "pre-existing" means the cascade satisfied it from cache rather than a live
  # call: the run's own hit metrics are the authority for that.
  left_join(cache %>% select(address_hash, created_at), by = "address_hash") %>%
  mutate(resolved = !is.na(latitude),
         pre_existing = resolved & !is.na(created_at) & as.Date(created_at) < Sys.Date())
cat(sprintf("\ncache hit BEFORE this run      : %s\n",
            format(sum(qq$pre_existing, na.rm = TRUE), big.mark = ",")))
cat(sprintf("geocoded DURING this run       : %s\n",
            format(sum(qq$resolved & !qq$pre_existing, na.rm = TRUE), big.mark = ",")))
cat(sprintf("unresolved / failed            : %s\n", format(sum(!qq$resolved), big.mark = ",")))
tot <- sum(qq$pre_existing, na.rm = TRUE) +
       sum(qq$resolved & !qq$pre_existing, na.rm = TRUE) + sum(!qq$resolved)
cat(sprintf("---------------------------------\nreconciles to distinct queued  : %s of %s  %s\n",
            format(tot, big.mark = ","), format(n_uniq, big.mark = ","),
            if (tot == n_uniq) "OK" else "MISMATCH"))
stopifnot(tot == n_uniq)

cat("\n=========== 2. PROVENANCE COMPLETENESS ===========\n")
logged <- n_distinct(log_run$address_hash)
attempted <- sum(qq$resolved)
logged_resolved <- sum(qq$resolved & qq$address_hash %in% log_run$address_hash)
cat(sprintf("addresses with attempt-log rows: %s\n", format(logged, big.mark = ",")))
cat(sprintf("addresses resolved             : %s\n", format(attempted, big.mark = ",")))
cat(sprintf("  logged but unresolved        : %s\n",
            format(max(0, logged - attempted), big.mark = ",")))
cat(sprintf("resolved WITH an attempt-log row: %s\n", format(logged_resolved, big.mark = ",")))
cat(sprintf("resolved WITHOUT a log record  : %s (provenance gap)\n",
            format(attempted - logged_resolved, big.mark = ",")))
if (nrow(log_run)) {
  cat("\nattempt log by provider/status:\n")
  print(as.data.frame(count(log_run, provider, status, sort = TRUE)))
  cat("\nfallback visible (attempt_order > 1):\n")
  print(as.data.frame(count(filter(log_run, attempt_order > 1), provider, status)))
}
cat("\ncoordinates carry provenance regardless, from geocoding_cache:\n")
print(as.data.frame(count(filter(qq, resolved), geocoder_provenance, sort = TRUE)))

# --- provider path: what actually happened to each address ------------------
# A bare provider count cannot distinguish "Census answered" from "Census
# failed and ArcGIS rescued it", and the second is exactly the history the
# rejected log rows would have destroyed.
paths <- log_run %>%
  arrange(address_hash, attempt_order) %>%
  group_by(address_hash) %>%
  summarise(
    census_tried   = any(grepl("Census", provider, ignore.case = TRUE)),
    census_ok      = any(grepl("Census", provider, ignore.case = TRUE) &
                           grepl("success|ok", status, ignore.case = TRUE)),
    arcgis_tried   = any(grepl("ArcGIS", provider, ignore.case = TRUE)),
    arcgis_ok      = any(grepl("ArcGIS", provider, ignore.case = TRUE) &
                           grepl("success|ok", status, ignore.case = TRUE)),
    n_attempts     = n(), .groups = "drop")

pathed <- qq %>%
  # The attempt log keys on the pipe-style hash built from the QUEUE fields
  # (6,543 of 6,597 log hashes match those, versus 5,964 for the results
  # file's recomputed hash), so join on that or the gap is a join artifact.
  left_join(paths, by = "address_hash") %>%
  mutate(provider_path = case_when(
    pre_existing & is.na(n_attempts)          ~ "cache hit, no new attempt",
    is.na(n_attempts) & resolved              ~ "resolved, NO attempt log (provenance gap)",
    is.na(n_attempts) & !resolved             ~ "unresolved, no attempt log",
    census_ok                                 ~ "Census success",
    census_tried & !census_ok & arcgis_ok     ~ "Census fail -> ArcGIS success",
    census_tried & !census_ok & !arcgis_ok    ~ "Census fail -> ArcGIS fail",
    arcgis_ok                                 ~ "ArcGIS success (no Census attempt)",
    TRUE                                      ~ "other"))

cat("\n=========== 3. PROVIDER PATH ===========\n")
pp <- pathed %>% count(provider_path, sort = TRUE) %>%
  mutate(pct = round(100 * n / sum(n), 1))
print(as.data.frame(pp))
cat(sprintf("total: %s (must equal %s distinct queued)\n",
            format(sum(pp$n), big.mark = ","), format(n_uniq, big.mark = ",")))
stopifnot(sum(pp$n) == n_uniq)

gap <- pathed %>% filter(provider_path == "resolved, NO attempt log (provenance gap)")
if (nrow(gap)) {
  cat("\nprovenance-gap rows by winning provider (from cache):\n")
  print(as.data.frame(count(gap, geocoder_provenance, sort = TRUE)))
  cat("  ^ where this is ArcGIS, a prior Census failure is unrecoverable.\n")
  write_csv(gap %>% select(nppes_practice_address, nppes_city, nppes_state,
                           nppes_zip, address_hash, geocoder_provenance),
            "artifacts/geocode_provenance_gap.csv", na = "")
  cat("  rerun list written: artifacts/geocode_provenance_gap.csv\n")
}

cat(sprintf("\nVERDICT: coordinates %s | provenance %s\n",
            if (sum(!qq$resolved) == 0) "COMPLETE" else
              sprintf("PARTIAL (%s unresolved)", format(sum(!qq$resolved), big.mark = ",")),
            if (attempted <= logged) "COMPLETE" else
              sprintf("INCOMPLETE (%s addresses lack attempt rows)",
                      format(attempted - logged, big.mark = ","))))

write_csv(pathed %>% select(provider_path, nppes_practice_address, nppes_city,
                            nppes_state, nppes_zip, address_hash, latitude,
                            longitude, geocoder_provenance, resolved),
          "artifacts/geocode_provenance_audit.csv", na = "")
cat("audit written: artifacts/geocode_provenance_audit.csv\n")
