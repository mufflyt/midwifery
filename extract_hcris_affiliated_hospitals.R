#!/usr/bin/env Rscript
# =============================================================================
# HCRIS cost-report attributes for the hospitals our midwives are affiliated to
# =============================================================================
# Joins the CCNs produced by extract_dac_facility_affiliations.R to the CMS
# Healthcare Cost Report Information System (HCRIS) hospital file (form 2552-10),
# Worksheet S-3 Part I.
#
# WHAT S-3 DOES *NOT* HAVE: OBSTETRIC BEDS. I previously said HCRIS carries
# obstetric bed counts on worksheet S-3. It does not. S-3 Part I has no
# obstetrics line at all -- routine obstetric beds are folded into "Adults and
# Pediatrics" (line 01400), exactly as POS has no obstetric bed count. Checked
# directly: no S-3 line reports obstetrics, and the only obstetric text
# anywhere in the FY2023 alpha file is 197 free-text cost-center names on
# Worksheet A-6 reclassifications, which is not a bed count.
#
# WHAT IT DOES HAVE: NURSERY (line 01300). Newborn discharges are a direct
# measure of delivery volume -- arguably the better variable for a midwifery
# study than a bed count, since it counts births rather than capacity. It is
# named for what it is and not relabelled "obstetric".
#
# SILENCE IS NOT A ZERO. Only 37.7% of FY2023 hospitals report any nursery
# figure. A hospital with no nursery line has not reported "no births"; it has
# reported nothing. Hospitals without a value are held as NA, never 0, so a
# non-delivering hospital is not manufactured out of a missing row.
#
# COLUMN INDICES ARE 0-BASED. HCRIS files are headerless and DuckDB names such
# columns column00, column01, ... An off-by-one here (reading field 3 as the
# CCN because it is "the third field") silently returns zero joined rows rather
# than an error -- it did on the first run of this script.
#
# Inputs : artifacts/dac_facility_affiliations.csv
#          /Volumes/MufflySamsung/HCRIS/hosp10/fy<YYYY>/  (HCRIS_DIR, HCRIS_FY)
# Output : artifacts/hcris_affiliated_hospitals_fy<YYYY>.csv  (hospital-level)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr); library(tibble)
})

FY  <- Sys.getenv("HCRIS_FY", "2023")
source(file.path("R", "lib", "medicare_duckdb.R"))
DIR <- Sys.getenv("HCRIS_DIR", "")
if (!nzchar(DIR))
  DIR <- samsung_volume_path(file.path("HCRIS", "hosp10", paste0("fy", FY)))
rpt_f  <- file.path(DIR, sprintf("HOSP10_%s_rpt.csv",  FY))
nmrc_f <- file.path(DIR, sprintf("HOSP10_%s_nmrc.csv", FY))
for (f in c(rpt_f, nmrc_f)) {
  if (!file.exists(f))
    stop(sprintf(paste0("HCRIS input not found: %s. Download HOSP10FY%s.zip ",
                        "from downloads.cms.gov/files/hcris and unzip it, or ",
                        "set HCRIS_DIR / HCRIS_FY."), f, FY), call. = FALSE)
}

AFF <- "artifacts/dac_facility_affiliations.csv"
if (!file.exists(AFF))
  stop("Run extract_dac_facility_affiliations.R first: this needs its CCNs.",
       call. = FALSE)

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("
  CREATE VIEW r AS SELECT column00 AS rpt, column02 AS ccn,
                          column05 AS fy_begin, column06 AS fy_end
    FROM read_csv_auto('%s', header=false, all_varchar=true)", rpt_f))
dbExecute(con, sprintf("
  CREATE VIEW n AS SELECT * FROM read_csv_auto('%s', header=false,
    columns={'rpt':'BIGINT','wksht':'VARCHAR','line':'VARCHAR',
             'clmn':'VARCHAR','val':'DOUBLE'})", nmrc_f))

# S-3 Part I: line 01300 = nursery, 01400 = total hospital.
# clmn 00200 = beds, 00600 = patient days, 00700 = discharges.
hosp <- dbGetQuery(con, "
  SELECT r.ccn,
         MAX(CASE WHEN n.line='01300' AND n.clmn='00700' THEN n.val END) AS nursery_discharges,
         MAX(CASE WHEN n.line='01300' AND n.clmn='00600' THEN n.val END) AS nursery_days,
         MAX(CASE WHEN n.line='01400' AND n.clmn='00200' THEN n.val END) AS total_beds,
         MAX(CASE WHEN n.line='01400' AND n.clmn='00600' THEN n.val END) AS total_patient_days,
         MAX(CASE WHEN n.line='01400' AND n.clmn='00700' THEN n.val END) AS total_discharges
    FROM r INNER JOIN n ON CAST(n.rpt AS VARCHAR) = r.rpt
   WHERE n.wksht='S300001'
   GROUP BY 1")
cat(sprintf("HCRIS FY%s hospitals: %s | reporting a nursery figure: %s (%.1f%%)\n",
            FY, format(nrow(hosp), big.mark = ","),
            format(sum(!is.na(hosp$nursery_discharges)), big.mark = ","),
            100 * mean(!is.na(hosp$nursery_discharges))))

aff  <- chr_ccn <- read_csv(AFF, show_col_types = FALSE, progress = FALSE,
                            col_types = cols(.default = col_character()))
ccns <- unique(aff$ccn[!is.na(aff$ccn)])
out  <- tibble(ccn = ccns) %>% left_join(hosp, by = "ccn")

cat(sprintf("\naffiliated hospitals: %s\n", format(length(ccns), big.mark = ",")))
cat(sprintf("  matched to an HCRIS FY%s cost report: %s (%.1f%%)\n", FY,
            format(sum(!is.na(out$total_beds)), big.mark = ","),
            100 * mean(!is.na(out$total_beds))))
cat(sprintf("  with a nursery discharge count:       %s (%.1f%%)\n",
            format(sum(!is.na(out$nursery_discharges)), big.mark = ","),
            100 * mean(!is.na(out$nursery_discharges))))
cat("\nnursery discharges (annual newborn volume):\n")
print(summary(out$nursery_discharges))

f <- file.path("artifacts", sprintf("hcris_affiliated_hospitals_fy%s.csv", FY))
write_csv(out, f, na = "")
cat(sprintf("\nwritten: %s\n", f))
