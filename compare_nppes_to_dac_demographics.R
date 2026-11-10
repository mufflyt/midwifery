#!/usr/bin/env Rscript
# =============================================================================
# NPPES vs DAC on the NON-GEOGRAPHIC fields: sex, credential, telephone
# =============================================================================
# Every cross-source audit in this project compares STATE -- build_state_source_audit.R,
# build_cross_source_comparison.R, compare_pecos_to_nppes_address.R. Geography is
# not the only field two sources both claim. NPPES and DAC each independently
# record a clinician's sex, her credential and her practice telephone, and those
# have never been compared here.
#
# THE TWO FILES MUST BE THE SAME VINTAGE, AND THAT IS ENFORCED, NOT ASSERTED IN
# A COMMENT. The first version of this script hardcoded the November 2025 NPPES
# bulk file against DAC 2026-07 and merely DESCRIBED the eight-month gap in its
# header. Two things were wrong with that. A header comment is not a check: point
# NPPES_CSV at the March 2024 file and the prose silently becomes a lie. And the
# gap was avoidable -- an NPPES file dated 2026-08-09 was already on the volume,
# one month from the DAC snapshot instead of eight. So this script now PICKS the
# NPPES vintage nearest the DAC vintage out of the archive, reports the gap in
# months, and STOPS if it exceeds MAX_GAP_MONTHS.
#
# WHAT CAN AND CANNOT BE VERIFIED FROM THE DATA ITSELF differs by source, and
# pretending otherwise would be the same mistake one level down:
#
#   NPPES  The FILENAME is the vintage -- npidata_pfile_20050523-20260809.csv
#          is the 2026-08-09 release -- and nothing in the data can confirm it.
#          "Last Update Date" is NOT a file date: it is the day THAT PROVIDER
#          last edited her own NPPES record. A midwife who has not logged in
#          since 2012 carries 2012 in a 2026 file, so the column says nothing
#          about the release. It supports exactly ONE inference, in one
#          direction: no record may be NEWER than the file that contains it, so
#          a newer record FALSIFIES the filename. It can never verify it. The
#          check below is therefore a falsification test, not a confirmation.
#   DAC    Nothing to check at all. The national downloadable file has
#          THIRTY-ONE columns and NOT ONE of them is a date -- verified against
#          the header, not assumed. Its vintage is knowable only from the
#          filename, corroborated by file mtime.
#
# LAST UPDATE DATE EARNS ITS PLACE ELSEWHERE, as a per-provider staleness
# measure rather than a file-level one. If a midwife's NPPES record was last
# touched in 2012 and her DAC row is from 2026-07, a telephone disagreement
# between them is the expected outcome, not a finding -- NPPES is simply holding
# a fourteen-year-old phone number. Agreement is therefore also reported BANDED
# BY RECORD AGE, which turns "do these sources disagree" into the more useful
# "does disagreement track how stale the self-reported side is". Same principle
# as mm_record_staleness.R, which build_state_source_audit.R's header already
# cites: a record's own last-updated date is what tells you which year its
# information applies to.
#
# WHAT IS ACTUALLY COMPARABLE IS NARROWER THAN THE COLUMN LISTS SUGGEST, and the
# reasons differ per field:
#
#   sex        Both carry it, one character. DAC uses F/M/U; NPPES uses F/M and
#              blank. U IS NOT A THIRD SEX, it is DAC's missing marker, so it is
#              counted as missing rather than as a disagreement -- otherwise
#              every U becomes a false mismatch and the agreement rate is a
#              measure of DAC's missingness wearing the name "disagreement".
#   credential DAC's Cred is ONE controlled code (MD, CSW, CNM). NPPES's
#              "Provider Credential Text" is FREE TEXT -- "CNM", "C.N.M.",
#              "MSN, CNM, APRN", "CNM/WHNP". Comparing the strings would read as
#              catastrophic disagreement that is pure formatting, so both sides
#              go through normalize_credential_class() (credential_compatibility.R),
#              the canonical normalizer this project already uses for linkage.
#              Raw-string equality is reported BESIDE it to size the gap.
#   telephone  Both carry 10 bare digits. But DAC is ONE ROW PER PRACTICE
#              LOCATION and NPPES publishes ONE practice location, so a midwife
#              with four DAC sites has up to four phones and NPPES names one.
#              Equality against an arbitrary DAC row would book a true match as
#              a mismatch. Reported two ways, the same split the Medicaid source
#              in build_cross_source_comparison.R uses: equals her PRIMARY DAC
#              phone, and falls anywhere INSIDE her DAC phone set.
#
# CMS RENAMED THE SEX COLUMN, so neither side's name is hardcoded. NPPES called
# it "Provider Gender Code" through March 2024 and "Provider Sex Code" by
# November 2025 (verified on both files). A script pinned to either spelling
# reads NULL on the other vintage and reports 0% fill as though the data were
# missing. Both sides resolve their columns by availability and PRINT what they
# resolved, the same pick() pattern extract_dac_midwives.R uses for the
# lst_nm -> "Provider Last Name" rename.
#
# Inputs : DAC_FILE  (env; default DAC_NationalDownloadableFile_2026-07.csv)
#          NPPES_CSV (env; default: nearest vintage in the NPPES archive)
#          NPPES_ARCHIVE / COHORT / MAX_GAP_MONTHS (env, all defaulted)
# Outputs: artifacts/nppes_vs_dac_field_agreement.csv    (one row per field)
#          artifacts/nppes_vs_dac_field_disagreements.csv (NPI-level, for triage)
#          artifacts/nppes_vs_dac_vintage.csv             (what was paired, and the gap)
#          artifacts/nppes_vs_dac_agreement_by_record_age.csv (staleness gradient)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr); library(stringr)
  library(digest)   # cache key: the NPI set's identity, not its size
})
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source("credential_compatibility.R")   # normalize_credential_class(): the canonical one
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()

MAX_GAP_MONTHS <- as.numeric(Sys.getenv("MAX_GAP_MONTHS", "6"))

# --- vintages ---------------------------------------------------------------
#' DAC vintage, from the filename only
#'
#' The file has no date column, so there is nothing to cross-check against.
#' Returns the first of the named month, which is the resolution CMS publishes at.
dac_vintage <- function(path) {
  m <- str_match(basename(path), "(20[0-9]{2})[-_]?([01][0-9])")
  if (is.na(m[1, 1]))
    stop(sprintf(paste0("cannot read a vintage out of the DAC filename: %s\n",
                        "  The DAC file carries no date column, so the name is the only\n",
                        "  source of its vintage. Rename it DAC_..._YYYY-MM.csv."),
                 basename(path)), call. = FALSE)
  as.Date(sprintf("%s-%s-01", m[1, 2], m[1, 3]))
}

#' NPPES vintage, from the end date in the filename
nppes_vintage <- function(path) {
  m <- str_match(basename(path), "-(20[0-9]{2})([01][0-9])([0-3][0-9])\\.csv$")
  if (is.na(m[1, 1])) return(as.Date(NA))
  as.Date(sprintf("%s-%s-%s", m[1, 2], m[1, 3], m[1, 4]))
}

DAC <- Sys.getenv("DAC_FILE", "DAC_NationalDownloadableFile_2026-07.csv")
if (!file.exists(DAC)) stop(sprintf("DAC file not found: %s", DAC), call. = FALSE)
dac_v <- dac_vintage(DAC)

ARCHIVE <- Sys.getenv("NPPES_ARCHIVE", "")
if (!nzchar(ARCHIVE))
  ARCHIVE <- tryCatch(samsung_volume_path("nppes_historical_downloads"),
                      error = function(e) "")

NPPES <- Sys.getenv("NPPES_CSV", "")
if (!nzchar(NPPES)) {
  # NEAREST VINTAGE, NOT A HARDCODED PATH. This is the whole point: the archive
  # holds ~30 NPPES vintages, and which one belongs next to a given DAC file is
  # a function of the DAC file's date, not of what someone typed once.
  cands <- c(Sys.glob(file.path(ARCHIVE, "npidata_pfile_*.csv")),
             Sys.glob(file.path(ARCHIVE, "*", "npidata_pfile_*.csv")),
             Sys.glob(file.path(ARCHIVE, "*", "npidata_2*.csv")))
  cands <- cands[!grepl("header|fileheader", cands, ignore.case = TRUE)]
  if (!length(cands))
    stop(sprintf("no NPPES bulk files under %s; set NPPES_CSV.", ARCHIVE), call. = FALSE)
  vt <- as.Date(vapply(cands, function(p) as.character(nppes_vintage(p)), ""))
  keep <- !is.na(vt)
  cands <- cands[keep]; vt <- vt[keep]
  # Deduplicate: the archive keeps the same vintage under both extracted_YYYY/
  # and NPPES_Data_Dissemination_Month_YYYY/. Largest file wins on a tie so a
  # truncated copy never beats the complete one.
  ord <- order(vt, -file.size(cands))
  cands <- cands[ord]; vt <- vt[ord]
  dup <- duplicated(vt)
  cands <- cands[!dup]; vt <- vt[!dup]
  NPPES <- cands[which.min(abs(as.numeric(vt - dac_v)))]
}
if (!file.exists(NPPES)) stop(sprintf("NPPES file not found: %s", NPPES), call. = FALSE)
nppes_v <- nppes_vintage(NPPES)

gap_months <- if (is.na(nppes_v)) NA_real_ else
  as.numeric(nppes_v - dac_v) / 30.44
cat(sprintf("DAC   : %s  (vintage %s, from FILENAME -- file has no date column)\n",
            DAC, format(dac_v, "%Y-%m")))
cat(sprintf("NPPES : %s  (vintage %s)\n", NPPES, format(nppes_v, "%Y-%m-%d")))
cat(sprintf("vintage gap: %.1f months (limit %.1f)\n", gap_months, MAX_GAP_MONTHS))
if (is.na(gap_months) || abs(gap_months) > MAX_GAP_MONTHS)
  stop(sprintf(paste0("NPPES and DAC are %.1f months apart, over the %.1f-month limit.\n",
                      "  Pair a closer NPPES vintage, or raise MAX_GAP_MONTHS deliberately\n",
                      "  if you mean to measure across that gap."),
               gap_months, MAX_GAP_MONTHS), call. = FALSE)

COHORT <- Sys.getenv("COHORT", "artifacts/amcb_npi_linkage_FROZEN.csv")
if (!file.exists(COHORT)) stop(sprintf("cohort not found: %s", COHORT), call. = FALSE)
cohort <- read_csv(COHORT, col_types = cols(.default = "c"), progress = FALSE)
npis <- unique(trimws(cohort$npi[!is.na(cohort$npi) & nzchar(trimws(cohort$npi))]))
cat(sprintf("cohort NPIs: %s\n", format(length(npis), big.mark = ",")))

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# DuckDB spills to R's per-session tempdir by default, and that directory can be
# gone by the time a long background run needs it -- this script died on
# "Failed to create directory .../RtmphST6P3/duckdb/temp" before reading a byte.
tmp_dir <- Sys.getenv("DUCKDB_TEMP_DIR", file.path(getwd(), ".duckdb_temp"))
dir.create(tmp_dir, showWarnings = FALSE, recursive = TRUE)
dbExecute(con, sprintf("SET temp_directory = %s", dbQuoteString(con, tmp_dir)))
dbWriteTable(con, "cohort_npi", data.frame(npi = npis, stringsAsFactors = FALSE),
             overwrite = TRUE)

# --- resolve column names on each side, by availability ----------------------
pick <- function(have, ..., what) {
  hit <- c(...)[c(...) %in% have]
  if (!length(hit)) stop(sprintf("%s: none of %s present", what,
                                 paste(c(...), collapse = ", ")), call. = FALSE)
  hit[1]
}
nppes_src <- sprintf("read_csv_auto(%s, all_varchar = TRUE, sample_size = -1)",
                     dbQuoteString(con, NPPES))
nhave <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", nppes_src)))
n_sex  <- pick(nhave, "Provider Sex Code", "Provider Gender Code", what = "NPPES sex")
n_cred <- pick(nhave, "Provider Credential Text", what = "NPPES credential")
n_ocrd <- pick(nhave, "Provider Other Credential Text", what = "NPPES other credential")
n_tel  <- pick(nhave, "Provider Business Practice Location Address Telephone Number",
               what = "NPPES telephone")
n_upd  <- pick(nhave, "Last Update Date", what = "NPPES last update")
cat(sprintf("NPPES columns resolved: sex=%s | cred=%s | tel=%s | updated=%s\n",
            n_sex, n_cred, n_tel, n_upd))

dac_src <- sprintf("read_csv_auto(%s, all_varchar = TRUE, sample_size = -1,
                                  normalize_names = TRUE, encoding = 'latin-1')",
                   dbQuoteString(con, DAC))
dhave <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", dac_src)))
d_sex <- pick(dhave, "gndr", "gender", what = "DAC sex")
d_crd <- pick(dhave, "cred", what = "DAC credential")
d_tel <- pick(dhave, "telephone_number", what = "DAC telephone")
cat(sprintf("DAC   columns resolved: sex=%s | cred=%s | tel=%s\n", d_sex, d_crd, d_tel))
# Confirm in the data what the header comment claims: DAC carries no date.
dac_date_cols <- grep("date|year|updat", dhave, ignore.case = TRUE, value = TRUE)
cat(sprintf("DAC   date-like columns: %s\n",
            if (length(dac_date_cols)) paste(dac_date_cols, collapse = ", ")
            else "NONE (vintage is filename-only, as documented)"))

# --- NPPES side: one row per NPI --------------------------------------------
# Entity Type Code = 1 is an individual; organisations have no sex or credential.
# THE COHORT PULL IS CACHED, keyed by NPPES vintage and by a digest of the NPI
# SET ITSELF. Scanning 11.6 GB takes ~11 minutes and a typo in a mutate()
# downstream should not cost that twice.
#
# THE KEY WAS length(npis), AND THAT WAS A BUG. A freeze that swaps one NPI for
# another -- which is exactly what the 129 reassignments in
# audit_linkage_arms_3way.R are -- leaves the COUNT unchanged, so the new run
# would be served the old cohort's records: it would compare a member the
# cohort no longer has and silently omit the one it gained. The count is not an
# identity. The sorted, deduplicated NPI set hashed to 16 hex characters is,
# and it costs one digest of a 17k-element vector.
cache <- file.path(tmp_dir, sprintf("nppes_cohort_%s_n%d_%s.parquet",
                                    format(nppes_v, "%Y%m%d"), length(npis),
                                    substr(digest(sort(unique(npis)), algo = "sha256"), 1, 16)))
if (file.exists(cache)) {
  nppes <- dbGetQuery(con, sprintf("SELECT * FROM read_parquet(%s)",
                                   dbQuoteString(con, cache)))
  cat(sprintf("NPPES cohort pull reused from cache: %s rows (%s)\n",
              format(nrow(nppes), big.mark = ","), basename(cache)))
} else {
cat("scanning NPPES (one pass, ~11 min) ...\n")
t0 <- Sys.time()
nppes <- dbGetQuery(con, sprintf('
  SELECT TRIM(n."NPI")                              AS npi,
         UPPER(TRIM(COALESCE(n.%s, \'\')))          AS sex_nppes,
         UPPER(TRIM(COALESCE(n.%s, \'\')))          AS cred_nppes,
         UPPER(TRIM(COALESCE(n.%s, \'\')))          AS cred_other,
         REGEXP_REPLACE(COALESCE(n.%s, \'\'), \'[^0-9]\', \'\', \'g\') AS tel_nppes,
         TRIM(COALESCE(n.%s, \'\'))                 AS last_update
    FROM %s n
    JOIN cohort_npi c ON TRIM(n."NPI") = c.npi
   WHERE TRIM(n."Entity Type Code") = \'1\'',
  dbQuoteIdentifier(con, n_sex), dbQuoteIdentifier(con, n_cred),
  dbQuoteIdentifier(con, n_ocrd), dbQuoteIdentifier(con, n_tel),
  dbQuoteIdentifier(con, n_upd), nppes_src))
cat(sprintf("  NPPES rows for cohort NPIs: %s (%.1f min)\n",
            format(nrow(nppes), big.mark = ","),
            as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  dbWriteTable(con, "nppes_pull", nppes, overwrite = TRUE)
  invisible(dbExecute(con, sprintf("COPY nppes_pull TO %s (FORMAT PARQUET)",
                                   dbQuoteString(con, cache))))
  cat(sprintf("  cached -> %s\n", basename(cache)))
}
stopifnot(!any(duplicated(nppes$npi)))

# FALSIFICATION TEST ONLY. max(Last Update Date) is the newest PROVIDER EDIT in
# the cohort, not the release date, so it cannot confirm the filename -- it can
# only contradict it, because no record can postdate the file holding it.
upd <- suppressWarnings(as.Date(nppes$last_update, tryFormats = c("%m/%d/%Y", "%Y-%m-%d")))
nppes$record_age_years <- as.numeric(nppes_v - upd) / 365.25
max_upd <- suppressWarnings(max(upd, na.rm = TRUE))
if (is.finite(as.numeric(max_upd)) && max_upd > nppes_v + 31) {
  warning(sprintf(paste0("NPPES file %s holds a record edited %s, AFTER the release its ",
                         "filename claims (%s). No record can postdate its own file, so ",
                         "the file is mislabelled."),
                  basename(NPPES), format(max_upd, "%Y-%m-%d"), format(nppes_v, "%Y-%m-%d")),
          call. = FALSE)
  cat("NPPES filename FALSIFIED by record dates (see warning)\n")
} else {
  cat(sprintf(paste0("NPPES filename not contradicted: newest cohort record edit %s <= ",
                     "release %s.\n  (This does NOT confirm the vintage -- Last Update Date ",
                     "is a per-provider edit date.)\n"),
              format(max_upd, "%Y-%m-%d"), format(nppes_v, "%Y-%m-%d")))
}
cat(sprintf("NPPES record staleness among cohort: median %.1f years, %.0f%% older than 5 years\n",
            median(nppes$record_age_years, na.rm = TRUE),
            100 * mean(nppes$record_age_years > 5, na.rm = TRUE)))

# --- DAC side: one row per NPI-location, collapsed ---------------------------
# Sex and credential are asserted once per clinician, so they should be constant
# across her location rows; that is CHECKED below rather than assumed. Telephone
# is genuinely per-location and stays a set.
cat("scanning DAC ...\n")
dac_rows <- dbGetQuery(con, sprintf('
  SELECT TRIM(d."npi")                              AS npi,
         UPPER(TRIM(COALESCE(d.%s, \'\')))          AS sex,
         UPPER(TRIM(COALESCE(d.%s, \'\')))          AS cred,
         REGEXP_REPLACE(COALESCE(d.%s, \'\'), \'[^0-9]\', \'\', \'g\') AS tel
    FROM %s d
    JOIN cohort_npi c ON TRIM(d."npi") = c.npi',
  dbQuoteIdentifier(con, d_sex), dbQuoteIdentifier(con, d_crd),
  dbQuoteIdentifier(con, d_tel), dac_src))
cat(sprintf("  DAC rows for cohort NPIs: %s across %s NPIs\n",
            format(nrow(dac_rows), big.mark = ","),
            format(n_distinct(dac_rows$npi), big.mark = ",")))

incon <- dac_rows %>% group_by(npi) %>%
  summarise(n_sex = n_distinct(sex[nzchar(sex)]),
            n_cred = n_distinct(cred[nzchar(cred)]), .groups = "drop")
cat(sprintf("  DAC self-consistency: %s NPIs with >1 sex, %s with >1 credential\n",
            format(sum(incon$n_sex > 1), big.mark = ","),
            format(sum(incon$n_cred > 1), big.mark = ",")))

dac <- dac_rows %>%
  group_by(npi) %>%
  summarise(sex_dac = { v <- sex[nzchar(sex)]; if (length(v)) v[1] else "" },
            cred_dac = { v <- cred[nzchar(cred)]; if (length(v)) v[1] else "" },
            tel_set = list(unique(tel[nchar(tel) == 10])),
            n_sites = n(), .groups = "drop") %>%
  mutate(n_phones = vapply(tel_set, length, integer(1)))
# "Primary" DAC phone = the modal one across her location rows (ties numerically,
# so a rerun is reproducible), NOT whichever row sorted first.
modal <- dac_rows %>% filter(nchar(tel) == 10) %>% count(npi, tel) %>%
  arrange(npi, desc(n), tel) %>% group_by(npi) %>% slice(1) %>% ungroup() %>%
  select(npi, tel_modal = tel)
dac <- dac %>% left_join(modal, by = "npi") %>%
  mutate(tel_primary = coalesce(tel_modal, "")) %>% select(-tel_modal)

# --- join and score ---------------------------------------------------------
# normalize_credential_class() is scalar by contract, so it is applied per
# element rather than being handed a vector (which would silently return a
# single "UNKNOWN" for the whole column).
cls <- function(x) vapply(x, function(s)
  normalize_credential_class(if (nzchar(s)) s else NA_character_), "", USE.NAMES = FALSE)

# EVERY COLUMN IS NAMED AT THE SOURCE, and the join takes no suffix argument.
# suffix= renames only COLLIDING names, which is a trap when one side has been
# aggregated: sex and cred collided and became sex_nppes/sex_dac as intended,
# but the DAC phone had already been folded into tel_set/tel_primary, so `tel`
# did not collide, stayed `tel`, and `tel_nppes` was never created -- 11 minutes
# into the run. Explicit aliases cannot fail that way.
both <- inner_join(nppes, dac, by = "npi") %>%
  mutate(
    cred_nppes_all = str_squish(paste(cred_nppes, cred_other)),
    cls_nppes = cls(cred_nppes_all),
    cls_dac   = cls(cred_dac),
    # DAC's U is a MISSING marker, not a third value.
    sex_dac_v   = ifelse(sex_dac %in% c("F", "M"), sex_dac, NA_character_),
    sex_nppes_v = ifelse(sex_nppes %in% c("F", "M"), sex_nppes, NA_character_),
    tel_nppes_v = ifelse(nchar(tel_nppes) == 10, tel_nppes, NA_character_),
    tel_dac_v   = ifelse(nchar(tel_primary) == 10, tel_primary, NA_character_),
    tel_in_set  = mapply(function(a, s) !is.na(a) && a %in% s,
                         tel_nppes_v, tel_set, SIMPLIFY = TRUE, USE.NAMES = FALSE))
cat(sprintf("\ncohort NPIs present in BOTH NPPES and DAC: %s\n",
            format(nrow(both), big.mark = ",")))

score <- function(label, a, b, note = "") {
  ok <- !is.na(a) & !is.na(b)
  data.frame(field = label,
             n_both_sources = nrow(both),
             n_nppes_filled = sum(!is.na(a)), n_dac_filled = sum(!is.na(b)),
             n_comparable = sum(ok),
             n_agree = sum(ok & a == b),
             pct_agree = if (sum(ok)) round(100 * mean((a == b)[ok]), 1) else NA_real_,
             note = note, stringsAsFactors = FALSE)
}
summ <- bind_rows(
  score("sex (F/M; DAC U counted missing)", both$sex_nppes_v, both$sex_dac_v),
  score("credential class (normalized)", both$cls_nppes, both$cls_dac,
        "both sides via normalize_credential_class()"),
  score("credential raw string", ifelse(nzchar(both$cred_nppes_all), both$cred_nppes_all, NA),
        ifelse(nzchar(both$cred_dac), both$cred_dac, NA),
        "shown to size the formatting gap, not as a finding"),
  score("telephone vs DAC primary site", both$tel_nppes_v, both$tel_dac_v),
  data.frame(field = "telephone anywhere in DAC phone set",
             n_both_sources = nrow(both),
             n_nppes_filled = sum(!is.na(both$tel_nppes_v)),
             n_dac_filled = sum(both$n_phones > 0),
             n_comparable = sum(!is.na(both$tel_nppes_v) & both$n_phones > 0),
             n_agree = sum(both$tel_in_set),
             pct_agree = round(100 * sum(both$tel_in_set) /
                               sum(!is.na(both$tel_nppes_v) & both$n_phones > 0), 1),
             note = "containment, the measure that does not collapse multi-site midwives",
             stringsAsFactors = FALSE)) %>%
  mutate(nppes_vintage = format(nppes_v, "%Y-%m-%d"),
         dac_vintage = format(dac_v, "%Y-%m"),
         vintage_gap_months = round(gap_months, 1))
print(as.data.frame(summ), row.names = FALSE)
# All three tracked outputs record the SAME three inputs -- the two source
# files and the cohort -- because every rate below is a statement about that
# triple. Swap any one of them and the numbers are about something else.
PROV_INPUTS <- c(NPPES, DAC, COHORT)
write_with_provenance(summ, "artifacts/nppes_vs_dac_field_agreement.csv",
                      inputs = PROV_INPUTS, na = "")

write_with_provenance(data.frame(
  source = c("NPPES", "DAC"),
  file = c(basename(NPPES), basename(DAC)),
  vintage = c(format(nppes_v, "%Y-%m-%d"), format(dac_v, "%Y-%m")),
  vintage_source = c("filename end date (not confirmable from the data)",
                     "filename ONLY -- file carries no date column"),
  newest_record_edit = c(if (is.finite(as.numeric(max_upd))) format(max_upd, "%Y-%m-%d") else NA,
                         NA),
  newest_record_edit_meaning = c(paste("newest PROVIDER EDIT in cohort; falsifies the filename",
                                       "if later than it, cannot confirm it"), NA),
  file_mtime = format(c(file.mtime(NPPES), file.mtime(DAC)), "%Y-%m-%d"),
  gap_months = round(gap_months, 1),
  stringsAsFactors = FALSE), "artifacts/nppes_vs_dac_vintage.csv",
  inputs = PROV_INPUTS, na = "")

# Disagreement banded by how stale the NPPES record is. If the gradient is flat,
# staleness is not driving disagreement; if it climbs, much of the "conflict" is
# just NPPES holding an older answer than DAC.
bands <- both %>%
  mutate(band = cut(record_age_years, c(-Inf, 1, 3, 5, 10, Inf),
                    labels = c("<1y", "1-3y", "3-5y", "5-10y", "10y+"))) %>%
  filter(!is.na(band)) %>%
  group_by(band) %>%
  summarise(n_npis = n(),
            tel_comparable = sum(!is.na(tel_nppes_v) & n_phones > 0),
            tel_pct_in_dac_set = round(100 * sum(tel_in_set) /
                                       pmax(1, sum(!is.na(tel_nppes_v) & n_phones > 0)), 1),
            cred_comparable = sum(cls_nppes != "UNKNOWN" & cls_dac != "UNKNOWN"),
            cred_pct_agree = round(100 * sum(cls_nppes == cls_dac &
                                             cls_nppes != "UNKNOWN" & cls_dac != "UNKNOWN") /
                                   pmax(1, sum(cls_nppes != "UNKNOWN" & cls_dac != "UNKNOWN")), 1),
            .groups = "drop")
cat("\nagreement by NPPES record age (staleness of the self-reported side):\n")
print(as.data.frame(bands), row.names = FALSE)
write_with_provenance(bands, "artifacts/nppes_vs_dac_agreement_by_record_age.csv",
                      inputs = PROV_INPUTS, na = "")

disagree <- both %>%
  mutate(sex_disagrees = !is.na(sex_nppes_v) & !is.na(sex_dac_v) & sex_nppes_v != sex_dac_v,
         cred_class_disagrees = cls_nppes != cls_dac &
           cls_nppes != "UNKNOWN" & cls_dac != "UNKNOWN",
         tel_disagrees = !is.na(tel_nppes_v) & n_phones > 0 & !tel_in_set) %>%
  filter(sex_disagrees | cred_class_disagrees | tel_disagrees) %>%
  select(npi, sex_nppes, sex_dac, cred_nppes_all, cred_dac, cls_nppes, cls_dac,
         tel_nppes, tel_primary, n_phones, n_sites, last_update, record_age_years,
         sex_disagrees, cred_class_disagrees, tel_disagrees)
write_csv(disagree, "artifacts/nppes_vs_dac_field_disagreements.csv", na = "")
cat(sprintf("\n%s NPIs disagree on at least one field -> artifacts/nppes_vs_dac_field_disagreements.csv\n",
            format(nrow(disagree), big.mark = ",")))

cat("\ncredential class cross-tab (NPPES rows x DAC cols):\n")
print(table(NPPES = both$cls_nppes, DAC = both$cls_dac))
cat("\nDAC credential codes among cohort midwives, top 10:\n")
print(head(sort(table(both$cred_dac[nzchar(both$cred_dac)]), decreasing = TRUE), 10))
cat("\nNPPES credential text among cohort midwives, top 10:\n")
print(head(sort(table(both$cred_nppes_all[nzchar(both$cred_nppes_all)]), decreasing = TRUE), 10))
