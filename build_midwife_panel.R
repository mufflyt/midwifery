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

ROOT <- Sys.getenv("NPPES_HISTORY", "")
if (!nzchar(ROOT)) {
  # Sourced only on this branch: NPPES_HISTORY is always set by the test
  # harness, and nothing else in this file assumes the repo root as cwd.
  source(file.path("R", "lib", "medicare_duckdb.R"))
  ROOT <- samsung_volume_path("nppes_historical_downloads")
}
stopifnot(dir.exists(ROOT))

# A CNM must hold RN licensure, so enumerating under a nursing or women's
# health taxonomy instead of a midwifery one is a registration choice, not a
# different profession -- we hit exactly that case (a CNM enumerated as a
# Women's Health NP). Restricting the panel to 367A/176B therefore hides real
# midwives. Nursing codes are included and LABELLED, so the matcher can weigh
# them as weaker evidence rather than treating all candidates alike.
MIDWIFE_TAX <- c("367A00000X", "176B00000X")

# WHY THERE ARE TWO SCOPES (2026-08-30).
#
# The enumerated NURSING_TAX below is 4 of the ~14 Nurse Practitioner codes, 2
# of the ~30 Registered Nurse codes and 1 of the Clinical Nurse Specialist
# codes. The reasoning that admitted nursing codes at all -- a CNM holds RN
# licensure and may enumerate under either profession -- does not stop at the
# four NP specialties someone happened to list. A CNM who also holds a Family
# NP credential and enumerated under 363LF0000X, or who is recorded as a
# Maternal Newborn RN under 163WM0102X, is not in this pool by ANY route. She
# cannot be found by a better name rule, a wider blocking key or a relaxed
# veto; she is not in the candidate universe at all.
#
# Audited against the frozen linkage: 1,282 of the 2,108 "no candidate" rows
# have their exact surname present in the NARROW pool but no candidate, and 63
# have neither name anywhere in it. How much of that gap is taxonomy scope
# rather than name matching was UNMEASURABLE without this second pool.
#
# scope = "narrow" reproduces the published panel EXACTLY and stays the
# default, because it defines the primary midwifery tier in a frozen cohort.
# scope = "wide" takes every specialty in the three nursing families and exists
# to MEASURE the ceiling, not to replace the primary panel. Prefix families,
# not a longer hand-list: the hand-list is what drifted.
PANEL_SCOPE <- Sys.getenv("PANEL_TAX_SCOPE", "narrow")
if (!PANEL_SCOPE %in% c("narrow", "wide")) {
  stop(sprintf("PANEL_TAX_SCOPE must be 'narrow' or 'wide', got '%s'",
               PANEL_SCOPE), call. = FALSE)
}
# 363L Nurse Practitioner | 163W Registered Nurse | 364S Clinical Nurse Specialist
WIDE_TAX_PREFIX <- c("363L", "163W", "364S")
WIDE_TAX_EXACT  <- c(MIDWIFE_TAX, "367500000X")   # + CRNA, as before

NURSING_TAX <- c("363LW0102X",  # Women's Health NP
                 "363LX0001X",  # OB-GYN NP
                 "363L00000X",  # Nurse Practitioner
                 "363LA2200X",  # Adult Health NP
                 "163WW0101X",  # RN, Women's Health
                 "163W00000X",  # Registered Nurse
                 "367500000X",  # Certified Registered Nurse Anesthetist
                 "364SW0102X")  # CNS, Women's Health
PANEL_TAX <- c(MIDWIFE_TAX, NURSING_TAX)

#' SQL predicate selecting the panel's taxonomy scope, for one code expression.
#'
#' ONE definition, used by BOTH readers. The classic and reshaped paths each
#' built their own `IN (...)` clause from PANEL_TAX; widening the scope in one
#' and not the other would produce a panel whose composition depended on which
#' release format a year happened to ship in -- a difference that looks exactly
#' like a real change in the workforce.
panel_tax_predicate <- function(expr) {
  if (PANEL_SCOPE == "narrow") {
    return(sprintf("UPPER(TRIM(%s)) IN ('%s')", expr,
                   paste(PANEL_TAX, collapse = "','")))
  }
  parts <- c(sprintf("UPPER(TRIM(%s)) LIKE '%s%%'", expr, WIDE_TAX_PREFIX),
             sprintf("UPPER(TRIM(%s)) IN ('%s')", expr,
                     paste(WIDE_TAX_EXACT, collapse = "','")))
  paste0("(", paste(parts, collapse = " OR "), ")")
}
cat(sprintf("taxonomy scope: %s\n", PANEL_SCOPE))

files <- list.files(ROOT, pattern = "^npidata(_pfile)?_[0-9]{8}-[0-9]{8}\\.csv$",
                    recursive = TRUE, full.names = TRUE)
files <- files[!grepl("fileheader", files, ignore.case = TRUE)]
kind  <- rep("classic", length(files))

# One snapshot per year: the earliest in each year, so gaps are visible rather
# than silently filled by a second snapshot of a year we already have.
snap_date <- sub(".*-([0-9]{8})\\.csv$", "\\1", basename(files))
snap_year <- as.integer(substr(snap_date, 1, 4))

# NBER stopped publishing the flat npidata_ format after 2024 and reshapes
# newer snapshots into per-field files under byvar/. A year with no classic
# file but a nber_reshaped_<year>/byvar/ directory is handled by a separate
# code path below (process_reshaped_year()) that reconstructs the same row
# shape from those per-field files.
reshaped_dirs <- list.dirs(ROOT, recursive = FALSE)
reshaped_dirs <- reshaped_dirs[grepl("^nber_reshaped_[0-9]{4}$", basename(reshaped_dirs))]
for (rd in reshaped_dirs) {
  ry <- as.integer(sub("^nber_reshaped_", "", basename(rd)))
  byvar_files <- list.files(file.path(rd, "byvar"), pattern = "_[0-9]{6}\\.csv$", full.names = FALSE)
  rm_str <- if (length(byvar_files)) sub(".*_([0-9]{6})\\.csv$", "\\101", byvar_files[1]) else sprintf("%d0101", ry)
  files <- c(files, rd); snap_date <- c(snap_date, rm_str); snap_year <- c(snap_year, ry)
  kind <- c(kind, "reshaped")
}

ord <- order(snap_date)                     # order ONCE, then subset together
files <- files[ord]; snap_date <- snap_date[ord]; snap_year <- snap_year[ord]; kind <- kind[ord]
keep <- !duplicated(snap_year)
files <- files[keep]; snap_date <- snap_date[keep]; snap_year <- snap_year[keep]; kind <- kind[keep]

cat(sprintf("%d yearly snapshots: %s\n", length(files),
            paste(range(snap_year), collapse = "-")))

#' Build the panel rows for one reshaped (post-2024, per-field) NBER snapshot
#' @keywords internal
#' @noRd
process_reshaped_year <- function(con, dir, year, snap_date_str, midwife_tax) {
  byvar_dir <- file.path(dir, "byvar")
  field_file <- function(field) {
    hits <- list.files(byvar_dir, pattern = sprintf("^%s_[0-9]{6}\\.csv$", field), full.names = TRUE)
    if (length(hits)) hits[1] else NA_character_
  }
  tax_files <- Filter(Negate(is.na), sapply(sprintf("ptaxcode%d", 1:15), field_file))
  entity_f  <- field_file("entity")
  if (!length(tax_files) || is.na(entity_f)) {
    cat(sprintf("  [reshaped %d] missing entity or taxonomy byvar files -- skipped\n", year))
    return(NULL)
  }
  # ignore_errors=true: real NBER byvar exports contain individually malformed
  # rows (an unescaped comma inside an unquoted name, a place name with commas
  # that breaks strict column-count sniffing) -- confirmed against the real
  # 2025 files, where pfname and plocstatename each aborted the whole read on
  # one bad row otherwise. These are structural row defects, not an encoding
  # mismatch (2025-era NBER exports are UTF-8, so no dual-encoding probe is
  # needed here the way the classic path needs one for pre-2018 files).
  csv <- function(path) sprintf("read_csv_auto('%s', all_varchar = TRUE, ignore_errors = true)", path)

  # Filter to matching NPIs FIRST -- these files are individually small, but a
  # full outer join across all attribute fields before filtering would not be.
  tax_union <- paste(sprintf(
    "SELECT npi, UPPER(TRIM(%s)) AS code FROM %s",
    names(tax_files), sapply(tax_files, csv)), collapse = " UNION ALL ")
  tax_hits <- dbGetQuery(con, sprintf(
    "SELECT npi, code FROM (%s) WHERE %s", tax_union, panel_tax_predicate("code")))
  if (!nrow(tax_hits)) {
    cat(sprintf("  [reshaped %d] 0 rows matched PANEL_TAX -- skipped\n", year))
    return(NULL)
  }
  duckdb::duckdb_register(con, "rs_npis", data.frame(npi = unique(tax_hits$npi)))
  duckdb::duckdb_register(con, "rs_tax_hits", tax_hits)

  left <- function(field, as_name, transform = "UPPER(TRIM(%s))") {
    f <- field_file(field)
    if (is.na(f)) return(sprintf("NULL AS %s", as_name))
    alias <- paste0("j_", field)
    list(join = sprintf("LEFT JOIN %s %s ON %s.npi = n.npi", csv(f), alias, alias),
         select = sprintf(paste0(transform, " AS %s"), paste0(alias, ".", field), as_name))
  }
  parts <- list(
    left("plname", "last_name"), left("pfname", "first_name"),
    left("pmname", "middle_name"), left("pcredential", "credential"),
    left("plocline1", "practice_address"), left("ploccityname", "practice_city"),
    left("plocstatename", "practice_state"),
    left("ploczip", "practice_zip", "SUBSTR(TRIM(%s), 1, 5)"),
    left("npideactdate", "deactivation_date", "TRIM(%s)"))
  # entity is REQUIRED (filtered on below), so it does not go through left()'s
  # NULL-tolerant path -- a missing entity file already returned NULL above.
  joins   <- c(sprintf("LEFT JOIN %s j_entity ON j_entity.npi = n.npi", csv(entity_f)),
               vapply(parts, function(p) if (is.list(p)) p$join else NA_character_, character(1)))
  joins   <- joins[!is.na(joins)]
  selects <- vapply(parts, function(p) if (is.list(p)) p$select else p, character(1))

  sql <- sprintf(
    "SELECT n.npi, %s,
            CASE WHEN EXISTS (SELECT 1 FROM rs_tax_hits h WHERE h.npi = n.npi AND h.code IN ('%s'))
                 THEN 'midwife' ELSE 'nursing' END AS tax_class,
            '%s' AS tax_scope,
            %d AS snapshot_year, '%s' AS snapshot_date
     FROM rs_npis n
     %s
     -- The reshaped NBER export spells entity type out ('Individual' /
     -- 'Organization'), not the classic format's numeric code ('1' / '2').
     -- Confirmed against the real 2025 file -- '1' matched nothing and
     -- silently zeroed the whole snapshot.
     WHERE UPPER(TRIM(j_entity.entity)) = 'INDIVIDUAL'",
    paste(selects, collapse = ", "), paste(midwife_tax, collapse = "','"),
    PANEL_SCOPE, year, snap_date_str, paste(joins, collapse = "\n     "))
  dbGetQuery(con, sql)
}

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

out_path <- Sys.getenv(
  "MIDWIFE_PANEL_OUT",
  # The scope is in the FILENAME. Both panels are legitimate and they are not
  # interchangeable; a wide panel sitting at midwife_panel.csv would be picked
  # up silently by match_amcb_to_npi.R and change the published cohort.
  if (PANEL_SCOPE == "wide") "midwife_panel_wide.csv" else "midwife_panel.csv")
cat(sprintf("output: %s\n", out_path))
RESUME <- !identical(Sys.getenv("PANEL_REBUILD"), "1")
lock <- paste0(out_path, ".lock")
# The lock must record WHO holds it, or a killed build leaves a stale file that
# blocks every future run and looks identical to a live one.
if (file.exists(lock)) {
  holder <- tryCatch(as.integer(readLines(lock, warn = FALSE)[1]), error = function(e) NA)
  # BUG FIX: nzchar(NA_character_) is TRUE, not NA -- ps returning nothing for a
  # dead PID makes system(intern=TRUE) return character(0), so out[1] is
  # NA_character_ and nzchar() of that silently read as "alive". Every dead PID
  # (not just out-of-range ones) was permanently wedging future runs.
  ps_out <- suppressWarnings(system(sprintf("ps -p %d -o pid=", holder),
                                    intern = TRUE, ignore.stderr = TRUE))
  alive <- !is.na(holder) && length(ps_out) > 0 && nzchar(ps_out[1])
  if (isTRUE(alive)) {
    stop(sprintf(paste("%s is held by running process %d. Two builders append",
                       "to the same file and interleave into a corrupt panel."),
                 lock, holder), call. = FALSE)
  }
  message(sprintf("[panel] clearing stale lock from dead process %s",
                  ifelse(is.na(holder), "<unknown>", holder)))
  unlink(lock)
}
writeLines(as.character(Sys.getpid()), lock)
on.exit(unlink(lock), add = TRUE)
done_years <- integer(0)
if (RESUME && file.exists(out_path)) {
  done_years <- unique(as.integer(read.csv(out_path, colClasses = "character")$snapshot_year))
  cat(sprintf("resuming: %s already present\n", paste(sort(done_years), collapse = ", ")))
} else if (file.exists(out_path)) {
  unlink(out_path)
}
first <- !file.exists(out_path)

for (k in seq_along(files)) {
  if (snap_year[k] %in% done_years) next
  f <- files[k]

  if (kind[k] == "reshaped") {
    t0 <- Sys.time()
    rows <- tryCatch(process_reshaped_year(con, f, snap_year[k], snap_date[k], MIDWIFE_TAX),
                     error = function(e) {cat("  ERR:", substr(conditionMessage(e), 1, 90),
                                              "\n"); NULL})
    if (is.null(rows) || !nrow(rows)) next
    write.table(rows, out_path, sep = ",", row.names = FALSE, na = "",
                col.names = first, append = !first, qmethod = "double")
    first <- FALSE
    cat(sprintf("  [%d/%d] %s (reshaped) -> %s rows (%s midwife, %s nursing) (%.0fs)\n",
                k, length(files), snap_year[k], format(nrow(rows), big.mark = ","),
                format(sum(rows$tax_class == "midwife"), big.mark = ","),
                format(sum(rows$tax_class == "nursing"), big.mark = ","),
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))
    next
  }

  # Column names drift across releases; resolve against the actual header.
  # Two settings here are load-bearing, both learned the hard way:
  #
  #   sample_size stays small -- all_varchar = TRUE means there are no types to
  #   infer, and sample_size = -1 forced a full multi-GB scan that failed
  #   outright on every release from 2018 onward.
  #
  #   encoding is per file, not global. Releases up to 2017 are latin-1 and
  #   abort as UTF-8; releases from 2018 are UTF-8 and abort as latin-1. A
  #   single hardcoded value silently loses one era or the other.
  reader <- function(enc, ignore_errors = TRUE) sprintf(
    "read_csv_auto('%s', all_varchar = TRUE, sample_size = 1000,
                   normalize_names = TRUE, encoding = '%s', ignore_errors = %s)",
    f, enc, if (ignore_errors) "true" else "false")
  # BUG FIX: `LIMIT 0` never reads a body row, so the header (always plain
  # ASCII) "succeeds" under utf-8 regardless of the file's real encoding --
  # the latin-1 branch below was dead code. Detecting encoding requires
  # decoding actual rows, and that decode must NOT use ignore_errors=true:
  # with it set, a wrong encoding doesn't throw, it just silently drops every
  # row that contains a non-ASCII byte. Probe strictly first, then read the
  # header (and later the full file) with ignore_errors=true for genuinely
  # malformed rows unrelated to encoding.
  src <- NULL; have <- character(0)
  for (enc in c("utf-8", "latin-1")) {
    # A bounded sample, not the full file: DuckDB stops reading once the LIMIT
    # is satisfied, so this stays cheap. Not exhaustive -- a file whose only
    # non-ASCII byte falls after row 50,000 would still misdetect -- but a
    # random 50k-row sample makes a silent miss very unlikely without paying
    # for a full extra pass over a multi-GB file just to pick an encoding.
    probe_ok <- tryCatch({
      dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 50000", reader(enc, ignore_errors = FALSE)))
      TRUE
    }, error = function(e) FALSE)
    if (!probe_ok) next
    cols <- tryCatch(names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", reader(enc)))),
                     error = function(e) character(0))
    if (length(cols)) { src <- reader(enc); have <- cols; break }
  }
  if (is.null(src)) have <- character(0)
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

  # BUG FIX: every other string field is normalised via UPPER(TRIM(...)) below,
  # but the taxonomy columns feeding this WHERE clause were compared raw. A
  # taxonomy code stored lowercase (or with incidental whitespace) failed the
  # exact IN(...) match and the row silently vanished -- no error, no count.
  where_tax <- paste(vapply(tax, panel_tax_predicate, character(1)),
                     collapse = " OR ")
  # Which slot matched decides the evidence tier downstream.
  mid_expr <- paste(sprintf("UPPER(TRIM(%s)) IN ('%s')", tax, paste(MIDWIFE_TAX, collapse = "','")),
                    collapse = " OR ")
  sel <- function(nm, as) if (is.na(col[[nm]])) sprintf("NULL AS %s", as)
                          else sprintf("UPPER(TRIM(%s)) AS %s", col[[nm]], as)

  sql <- sprintf("SELECT %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                         CASE WHEN (%s) THEN 'midwife' ELSE 'nursing' END AS tax_class,
                         '%s' AS tax_scope,
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
                 mid_expr, PANEL_SCOPE, snap_year[k], snap_date[k], src, where_tax,
                 # BUG FIX: every other field is UPPER(TRIM(...))'d before
                 # comparison; this one compared the raw value, so incidental
                 # whitespace (" 1") silently failed the match and dropped
                 # every row in the snapshot with no error.
                 if (is.na(col$ent)) "" else sprintf(" AND TRIM(%s) = '1'", col$ent))

  t0 <- Sys.time()
  rows <- tryCatch(dbGetQuery(con, sql),
                   error = function(e) {cat("  ERR:", substr(conditionMessage(e), 1, 90),
                                            "\n"); NULL})
  if (is.null(rows) || !nrow(rows)) next
  write.table(rows, out_path, sep = ",", row.names = FALSE, na = "",
              col.names = first, append = !first, qmethod = "double")
  first <- FALSE
  cat(sprintf("  [%d/%d] %s -> %s rows (%s midwife, %s nursing) (%.0fs)\n",
              k, length(files), snap_year[k], format(nrow(rows), big.mark = ","),
              format(sum(rows$tax_class == "midwife"), big.mark = ","),
              format(sum(rows$tax_class == "nursing"), big.mark = ","),
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

# BUG FIX: every prior year could be skipped (unrecognised schema, encoding
# probe failure, or every row filtered out) and `first` would still be TRUE --
# out_path is never created in that case, and an unconditional read.csv()
# crashed uncaught instead of reporting the zero-row outcome cleanly.
if (!file.exists(out_path)) {
  stop("No rows were written to ", out_path, " -- every input file was either ",
       "unreadable, schema-unrecognised, or produced zero matching rows. ",
       "Check the per-file messages above.", call. = FALSE)
}
panel <- read.csv(out_path, colClasses = "character")
cat(sprintf("\npanel: %s rows, %s distinct NPIs, %s distinct (NPI, surname) pairs\n",
            format(nrow(panel), big.mark = ","),
            format(length(unique(panel$npi)), big.mark = ","),
            format(nrow(unique(panel[, c("npi", "last_name")])), big.mark = ",")))
changed <- aggregate(last_name ~ npi, panel, function(x) length(unique(x)))
cat(sprintf("NPIs appearing under more than one surname: %s\n",
            format(sum(changed$last_name > 1), big.mark = ",")))
