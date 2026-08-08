#!/usr/bin/env Rscript
# =============================================================================
# Build a midwife temporal panel from historical NPPES snapshots
# =============================================================================
#
# The live NPI Registry only knows who is enumerated TODAY. That is why our
# match rate collapses with certification status -- 85% of ACTIVE certificants
# match, but only 49% of LAPSED and 14% of DECEASED ones, because those people
# are simply no longer in the registry to be found.
#
# The historical dissemination files still contain them. Scanning one snapshot
# per year recovers two things nothing else gives us:
#
#   1. Midwives who have since left the registry, with the practice address
#      they had while enrolled.
#   2. SURNAME HISTORY. The same NPI appears under different last names across
#      snapshots, which in a cohort that is ~99% women -- many certified
#      decades ago -- is the single largest cause of non-match. Maiden and
#      married names both become blockable keys.
#
# The NBER temporal panel (temporal_all_years_fixed) is NOT usable here: it is
# scoped to OB/GYN and contains exactly 3 midwives.
#
# Output: midwife_panel.csv (one row per NPI per snapshot per name variant)
# =============================================================================

suppressPackageStartupMessages({library(DBI); library(duckdb)})

ROOT <- Sys.getenv("NPPES_HISTORY",
                   "/Volumes/MufflySamsung/nppes_historical_downloads")
stopifnot(dir.exists(ROOT))

MIDWIFE_TAX <- c("367A00000X", "176B00000X")

files <- list.files(ROOT, pattern = "^npidata(_pfile)?_[0-9]{8}-[0-9]{8}\\.csv$",
                    recursive = TRUE, full.names = TRUE)
files <- files[!grepl("fileheader", files, ignore.case = TRUE)]

# One snapshot per year: the earliest in each year, so gaps are visible rather
# than silently filled by a second snapshot of a year we already have.
snap_date <- sub(".*-([0-9]{8})\\.csv$", "\\1", basename(files))
snap_year <- as.integer(substr(snap_date, 1, 4))
ord <- order(snap_date)                     # order ONCE, then subset together
files <- files[ord]; snap_date <- snap_date[ord]; snap_year <- snap_year[ord]
keep <- !duplicated(snap_year)
files <- files[keep]; snap_date <- snap_date[keep]; snap_year <- snap_year[keep]

cat(sprintf("%d yearly snapshots: %s\n", length(files),
            paste(range(snap_year), collapse = "-")))

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

out_path <- "midwife_panel.csv"
lock <- paste0(out_path, ".lock")
if (file.exists(lock)) {
  stop(sprintf(paste("%s exists -- another build is writing %s.",
                     "Two builders append to the same file and interleave into",
                     "a corrupt panel. Remove the lock if no build is running."),
               lock, out_path), call. = FALSE)
}
file.create(lock)
on.exit(unlink(lock), add = TRUE)
if (file.exists(out_path)) unlink(out_path)
first <- TRUE

for (k in seq_along(files)) {
  f <- files[k]
  # Column names drift across releases; resolve against the actual header.
  src <- sprintf("read_csv_auto('%s', all_varchar = TRUE, sample_size = -1,
                                 normalize_names = TRUE, encoding = 'latin-1',
                                 ignore_errors = true)", f)
  have <- tryCatch(names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", src))),
                   error = function(e) character(0))
  if (!length(have)) { cat(sprintf("  [%d/%d] %s -- unreadable, skipped\n",
                                   k, length(files), basename(f))); next }

  pick <- function(...) { o <- c(...); h <- o[o %in% have]; if (length(h)) h[1] else NA }
  col <- list(
    npi   = pick("npi"),
    last  = pick("provider_last_name_legal_name", "provider_last_name_legal_name_"),
    first = pick("provider_first_name"),
    mid   = pick("provider_middle_name"),
    cred  = pick("provider_credential_text"),
    st1   = pick("provider_first_line_business_practice_location_address"),
    city  = pick("provider_business_practice_location_address_city_name"),
    state = pick("provider_business_practice_location_address_state_name"),
    zip   = pick("provider_business_practice_location_address_postal_code"),
    ent   = pick("entity_type_code"),
    deact = pick("npi_deactivation_date"))
  tax <- grep("^healthcare_provider_taxonomy_code_[0-9]+$", have, value = TRUE)
  if (is.na(col$npi) || is.na(col$last) || !length(tax)) {
    cat(sprintf("  [%d/%d] %s -- schema not recognised, skipped\n",
                k, length(files), basename(f))); next
  }

  where_tax <- paste(sprintf("%s IN ('%s')", tax, paste(MIDWIFE_TAX, collapse = "','")),
                     collapse = " OR ")
  sel <- function(nm, as) if (is.na(col[[nm]])) sprintf("NULL AS %s", as)
                          else sprintf("UPPER(TRIM(%s)) AS %s", col[[nm]], as)

  sql <- sprintf("SELECT %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                         %d AS snapshot_year, '%s' AS snapshot_date
                  FROM %s WHERE (%s)%s",
                 sprintf("%s AS npi", col$npi),
                 sel("last", "last_name"), sel("first", "first_name"),
                 sel("mid", "middle_name"), sel("cred", "credential"),
                 sel("st1", "practice_address"), sel("city", "practice_city"),
                 sel("state", "practice_state"),
                 if (is.na(col$zip)) "NULL AS practice_zip"
                 else sprintf("SUBSTR(TRIM(%s), 1, 5) AS practice_zip", col$zip),
                 if (is.na(col$deact)) "NULL AS deactivation_date"
                 else sprintf("TRIM(%s) AS deactivation_date", col$deact),
                 snap_year[k], snap_date[k], src, where_tax,
                 if (is.na(col$ent)) "" else sprintf(" AND %s = '1'", col$ent))

  t0 <- Sys.time()
  rows <- tryCatch(dbGetQuery(con, sql),
                   error = function(e) {cat("  ERR:", substr(conditionMessage(e), 1, 90),
                                            "\n"); NULL})
  if (is.null(rows) || !nrow(rows)) next
  write.table(rows, out_path, sep = ",", row.names = FALSE, na = "",
              col.names = first, append = !first, qmethod = "double")
  first <- FALSE
  cat(sprintf("  [%d/%d] %s -> %s midwives (%.0fs)\n", k, length(files), snap_year[k],
              format(nrow(rows), big.mark = ","),
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

panel <- read.csv(out_path, colClasses = "character")
cat(sprintf("\npanel: %s rows, %s distinct NPIs, %s distinct (NPI, surname) pairs\n",
            format(nrow(panel), big.mark = ","),
            format(length(unique(panel$npi)), big.mark = ","),
            format(nrow(unique(panel[, c("npi", "last_name")])), big.mark = ",")))
changed <- aggregate(last_name ~ npi, panel, function(x) length(unique(x)))
cat(sprintf("NPIs appearing under more than one surname: %s\n",
            format(sum(changed$last_name > 1), big.mark = ",")))
