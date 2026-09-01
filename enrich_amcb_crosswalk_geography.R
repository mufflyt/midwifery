#!/usr/bin/env Rscript
# =============================================================================
# AMCB -> NPI crosswalk: NPPES geography and taxonomy, appended SEPARATELY
# =============================================================================
#
# WHY THIS IS A SEPARATE SCRIPT AND A SEPARATE ARTIFACT.
#
# The crosswalk answers "which NPI is this AMCB certificant?". This script
# answers "where does that NPI practice?". Keeping them apart is the whole
# point: if geography and identity live in one file built by one pass, a wrong
# state is indistinguishable from a wrong person. With the crosswalk frozen
# first, a geography error can be corrected by rerunning ONLY this script, and
# a linkage error cannot masquerade as a geography error.
#
# PRACTICE AND MAILING ARE KEPT DISTINCT AND NEITHER SUBSTITUTES FOR THE OTHER.
# NPPES mailing addresses are frequently billing services, employers or PO
# boxes in another state entirely. Coalescing mailing into a missing practice
# address would silently relocate midwives, so a missing practice address stays
# missing and is reported as such.
#
# VINTAGE. Practice geography in the crosswalk itself comes from the temporal
# panel (the most recent snapshot in which that NPI appears, 2007-2025), so for
# someone last seen in 2014 it is their last observed location. THIS script
# reads the single most recent dissemination file, which only covers NPIs still
# present in it. Both are published, and nppes_geo_source records which is
# which, because a current address and a ten-year-old address must never be
# read as the same measurement.
#
# Run: Rscript enrich_amcb_crosswalk_geography.R
#   CROSSWALK_IN   crosswalk to enrich (default: the current c5guard crosswalk)
#   GEO_OUT        output (default artifacts/amcb_npi_geography.csv)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(digest)
  library(jsonlite)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)

# The filename carries the panel definition and year window deliberately: the
# matcher refuses to write an artifact whose name does not encode every
# dimension that can change the linkage, after two A/B arms silently
# overwrote each other. Downstream defaults must honour the same convention.
# A STALE DEFAULT IS A SILENT WRONG ANSWER (2026-08-10). This pointed at the
# translit crosswalk, which two later builds superseded -- the component
# strategy added 164 matches and the class-5 guard removed 8. Running without
# CROSSWALK_IN therefore produced geography for a linkage nobody was using, and
# nothing in the output said so. The default now names the current crosswalk,
# and the guard below refuses to run against one the matcher has superseded.
CROSSWALK <- Sys.getenv(
  "CROSSWALK_IN",
  "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv")
GEO_OUT   <- Sys.getenv("GEO_OUT", "artifacts/amcb_npi_geography.csv")
source(file.path("R", "lib", "medicare_duckdb.R"))
ROOT      <- Sys.getenv("NPPES_HISTORY", "")
if (!nzchar(ROOT)) ROOT <- samsung_volume_path("nppes_historical_downloads")
stopifnot(file.exists(CROSSWALK), dir.exists(ROOT))

# Refuse to silently enrich a superseded linkage. If a newer crosswalk exists
# beside the requested one, say so rather than producing geography that looks
# current and is not.
local({
  peers <- list.files("artifacts",
                      pattern = "^amcb_npi_crosswalk_.*_panel-.*\\.csv$",
                      full.names = TRUE)
  peers <- peers[!grepl("\\.manifest\\.json$", peers)]
  newer <- peers[file.mtime(peers) > file.mtime(CROSSWALK)]
  if (length(newer)) {
    warning(sprintf(paste0(
      "A NEWER crosswalk exists than the one being enriched.\n",
      "  enriching: %s\n  newer    : %s\n",
      "  Set CROSSWALK_IN deliberately if this is intended."),
      basename(CROSSWALK), paste(basename(newer), collapse = ", ")),
      call. = FALSE, immediate. = TRUE)
  }
})

# The taxonomy set is CLOSED: build_midwife_panel.R admits exactly these ten
# codes, so descriptions come from that definition rather than an external NUCC
# release that could drift out of step with the panel.
TAX_DESC <- c(
  "367A00000X" = "Certified Nurse Midwife",
  "176B00000X" = "Midwife",
  "363LW0102X" = "Nurse Practitioner, Women's Health",
  "363LX0001X" = "Nurse Practitioner, Obstetrics & Gynecology",
  "363L00000X" = "Nurse Practitioner",
  "363LA2200X" = "Nurse Practitioner, Adult Health",
  "163WW0101X" = "Registered Nurse, Women's Health",
  "163W00000X" = "Registered Nurse",
  "367500000X" = "Certified Registered Nurse Anesthetist",
  "364SW0102X" = "Clinical Nurse Specialist, Women's Health")
MIDWIFE_TAX <- c("367A00000X", "176B00000X")

xw <- read_csv(CROSSWALK, col_types = cols(.default = "c"))
stopifnot("npi" %in% names(xw))
npis <- unique(xw$npi[!is.na(xw$npi) & nzchar(xw$npi)])
cat(sprintf("crosswalk: %s rows, %s distinct matched NPIs\n",
            format(nrow(xw), big.mark = ","), format(length(npis), big.mark = ",")))

# Most recent dissemination file available.
files <- list.files(ROOT, pattern = "^npidata(_pfile)?_[0-9]{8}-[0-9]{8}\\.csv$",
                    recursive = TRUE, full.names = TRUE)
files <- files[!grepl("fileheader", files, ignore.case = TRUE)]
snap <- as.Date(sub("^.*-([0-9]{8})\\.csv$", "\\1", basename(files)), "%Y%m%d")
f <- files[which.max(snap)]
snap_date <- max(snap)
cat(sprintf("NPPES bulk file: %s (vintage %s)\n", basename(f), snap_date))

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# normalize_names = TRUE gives snake_case; resolve against the real header
# rather than assuming, because column names drift across releases.
reader <- sprintf(
  "read_csv_auto('%s', all_varchar = TRUE, sample_size = 1000,
                 normalize_names = TRUE, encoding = 'utf-8', ignore_errors = true)", f)
have <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", reader)))
pick <- function(...) { o <- c(...); h <- o[o %in% have]; if (length(h)) h[1] else NA }

col <- list(
  npi    = pick("npi"),
  pa1    = pick("provider_first_line_business_practice_location_address"),
  pa2    = pick("provider_second_line_business_practice_location_address"),
  pcity  = pick("provider_business_practice_location_address_city_name"),
  pstate = pick("provider_business_practice_location_address_state_name"),
  pzip   = pick("provider_business_practice_location_address_postal_code"),
  ma1    = pick("provider_first_line_business_mailing_address"),
  mcity  = pick("provider_business_mailing_address_city_name"),
  mstate = pick("provider_business_mailing_address_state_name"),
  mzip   = pick("provider_business_mailing_address_postal_code"),
  enum   = pick("provider_enumeration_date"),
  upd    = pick("last_update_date"),
  deact  = pick("npi_deactivation_date"))
missing_cols <- names(col)[vapply(col, is.na, logical(1))]
if (length(missing_cols)) {
  stop(sprintf("bulk file lacks expected columns: %s",
               paste(missing_cols, collapse = ", ")), call. = FALSE)
}

tax_cols <- grep("^healthcare_provider_taxonomy_code_[0-9]+$", have, value = TRUE)
sw_cols  <- grep("^healthcare_provider_primary_taxonomy_switch_[0-9]+$", have, value = TRUE)
stopifnot(length(tax_cols) > 0)
cat(sprintf("taxonomy slots in file: %d\n", length(tax_cols)))

# Pull the whole row set for our NPIs, then choose the taxonomy in R where the
# preference order is explicit and reviewable rather than buried in SQL.
sel <- function(nm, as) sprintf("TRIM(%s) AS %s", col[[nm]], as)
sql <- sprintf(
  "SELECT %s AS npi, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
   FROM %s WHERE %s IN ('%s')",
  col$npi,
  sel("pa1", "practice_address_1"), sel("pa2", "practice_address_2"),
  sel("pcity", "practice_city"), sel("pstate", "practice_state"),
  sprintf("SUBSTR(TRIM(%s), 1, 5) AS practice_zip", col$pzip),
  sel("ma1", "mailing_address_1"), sel("mcity", "mailing_city"),
  sel("mstate", "mailing_state"),
  sprintf("SUBSTR(TRIM(%s), 1, 5) AS mailing_zip", col$mzip),
  sel("enum", "nppes_enumeration_date"), sel("upd", "nppes_last_update_date"),
  sel("deact", "nppes_deactivation_date"),
  paste(sprintf("TRIM(%s) AS %s", c(tax_cols, sw_cols), c(tax_cols, sw_cols)),
        collapse = ", "),
  reader, col$npi, paste(npis, collapse = "','"))

t0 <- Sys.time()
geo <- dbGetQuery(con, sql)
cat(sprintf("bulk rows returned: %s (%.0fs)\n", format(nrow(geo), big.mark = ","),
            as.numeric(difftime(Sys.time(), t0, units = "secs"))))

# --- Taxonomy selection ------------------------------------------------------
# Preference, in order, and recorded so a reviewer can see which rule fired:
#   1. a MIDWIFERY code (367A/176B), primary switch = Y
#   2. any midwifery code
#   3. the primary-switch code, if it is one of the ten panel codes
#   4. any panel code
# Codes outside the panel set are ignored: this is the crosswalk's taxonomy
# evidence, not a general specialty summary.
tax_mat <- as.matrix(geo[, tax_cols, drop = FALSE])
sw_mat  <- as.matrix(geo[, sw_cols,  drop = FALSE])
if (ncol(sw_mat) != ncol(tax_mat)) sw_mat <- matrix("", nrow(tax_mat), ncol(tax_mat))

choose_tax <- function(i) {
  codes <- tax_mat[i, ]; sw <- sw_mat[i, ]
  keep <- !is.na(codes) & nzchar(codes)
  codes <- codes[keep]; sw <- sw[keep]
  in_panel <- codes %in% names(TAX_DESC)
  is_mid   <- codes %in% MIDWIFE_TAX
  is_pri   <- !is.na(sw) & toupper(sw) == "Y"
  if (any(is_mid & is_pri))  return(c(codes[which(is_mid & is_pri)[1]], "midwifery_primary"))
  if (any(is_mid))           return(c(codes[which(is_mid)[1]],          "midwifery_secondary"))
  if (any(in_panel & is_pri))return(c(codes[which(in_panel & is_pri)[1]],"panel_primary"))
  if (any(in_panel))         return(c(codes[which(in_panel)[1]],        "panel_secondary"))
  c(NA_character_, "no_panel_taxonomy")
}
picked <- if (nrow(geo)) {
  t(vapply(seq_len(nrow(geo)), choose_tax, character(2)))
} else {
  matrix(character(0), 0, 2)
}

geo_out <- geo %>%
  select(-all_of(c(tax_cols, sw_cols))) %>%
  mutate(taxonomy_code = picked[, 1],
         taxonomy_selection_rule = picked[, 2],
         taxonomy_description = unname(TAX_DESC[taxonomy_code]),
         nppes_geo_source = sprintf("nppes_bulk_%s", format(snap_date, "%Y%m%d")),
         nppes_geo_vintage = as.character(snap_date),
         # An explicit statement that these are different measurements. The
         # counts below say how often they disagree; the flag says which rows.
         practice_mailing_state_differs = !is.na(practice_state) &
           !is.na(mailing_state) & nzchar(practice_state) & nzchar(mailing_state) &
           practice_state != mailing_state)

stopifnot(!any(duplicated(geo_out$npi)))
# Deterministic row order before writing. Identical inputs -- the same
# crosswalk sha and the same NPPES bulk vintage -- produced identical ROWS in a
# different ORDER on every run, so the artifact_sha256 this script records a few
# lines below could never match a rebuild. A hash that changes when nothing
# changed records which run happened, not which data was produced, and every
# provenance chain that cites this artifact inherits that.
#
# npi is the artifact's unique key -- verified, not assumed: 17,054 rows,
# 17,054 distinct npi, no NA -- so it totally orders the rows and no tie-break
# is needed.
#
# NOTE for anyone comparing against the pre-fix manifest: this deliberately
# changes the serialization, so the new hash will NOT reproduce the historical
# one. The content is the same set of rows; the bytes are not. The old hash
# cannot be validated by any rebuild, which is the defect being fixed rather
# than a discrepancy to explain away.
geo_out <- geo_out[order(geo_out$npi), , drop = FALSE]

write_csv(geo_out, GEO_OUT, na = "")

manifest <- list(
  artifact = basename(GEO_OUT),
  artifact_sha256 = digest::digest(file = GEO_OUT, algo = "sha256"),
  artifact_rows = nrow(geo_out),
  crosswalk = basename(CROSSWALK),
  crosswalk_sha256 = digest::digest(file = CROSSWALK, algo = "sha256"),
  nppes_bulk_file = basename(f),
  nppes_bulk_vintage = as.character(snap_date),
  source_script_sha256 = digest::digest(file = "enrich_amcb_crosswalk_geography.R",
                                        algo = "sha256"),
  columns = names(geo_out))
write_json(manifest, paste0(GEO_OUT, ".manifest.json"), auto_unbox = TRUE, pretty = TRUE)

# --- Report ------------------------------------------------------------------
nn <- length(npis)
pctf <- function(k) sprintf("%s (%.1f%%)", format(k, big.mark = ","), 100 * k / max(nn, 1))
cat("\n============ NPPES geography ============\n")
cat(sprintf("matched NPIs in crosswalk       : %s\n", format(nn, big.mark = ",")))
cat(sprintf("present in %s bulk file  : %s\n", format(snap_date, "%Y-%m"),
            pctf(nrow(geo_out))))
cat(sprintf("  absent (left NPPES / deactivated): %s\n",
            pctf(nn - nrow(geo_out))))
cat(sprintf("practice state populated        : %s\n",
            pctf(sum(!is.na(geo_out$practice_state) & nzchar(geo_out$practice_state)))))
cat(sprintf("practice address_1 populated    : %s\n",
            pctf(sum(!is.na(geo_out$practice_address_1) & nzchar(geo_out$practice_address_1)))))
cat(sprintf("practice address_2 populated    : %s\n",
            pctf(sum(!is.na(geo_out$practice_address_2) & nzchar(geo_out$practice_address_2)))))
cat(sprintf("mailing state populated         : %s\n",
            pctf(sum(!is.na(geo_out$mailing_state) & nzchar(geo_out$mailing_state)))))
cat(sprintf("practice state != mailing state : %s  <- why they are NOT interchangeable\n",
            pctf(sum(geo_out$practice_mailing_state_differs, na.rm = TRUE))))
cat(sprintf("deactivated in this release     : %s\n",
            pctf(sum(!is.na(geo_out$nppes_deactivation_date) &
                       nzchar(geo_out$nppes_deactivation_date)))))
cat("\ntaxonomy selection rule:\n")
print(as.data.frame(count(geo_out, taxonomy_selection_rule, sort = TRUE)))
cat("\ntaxonomy code:\n")
print(as.data.frame(count(geo_out, taxonomy_code, taxonomy_description, sort = TRUE)))
cat(sprintf("\nsaved: %s\n", normalizePath(GEO_OUT)))
