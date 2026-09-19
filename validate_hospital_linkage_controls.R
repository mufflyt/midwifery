#!/usr/bin/env Rscript
# =============================================================================
# The hospital-linkage negative controls, run rather than asserted
# =============================================================================
# docs/TECHNICAL_APPENDIX_HOSPITAL_LINKAGE.md states a negative control --
# "direct clinician NPI to hospital organization NPI equality (npi ==
# hospital_npi), near zero (0 matches)" -- and cites
# artifacts/ob_hospitals_geocoded.csv beside it. That artifact has no NPI
# column of any kind; its hospital identifier is prvdr_num, the CCN. So the
# control could not be evaluated from the artifact named next to it.
#
# WHY A TRUE CLAIM STILL NEEDED FIXING. The claim is almost certainly right:
# CMS Type 1 (individual) and Type 2 (organization) NPIs are disjoint by
# construction, so zero matches is what should happen. That is exactly the
# problem. A negative control exists to be RUN, and a "0" nobody can reproduce
# is an assertion wearing a control's clothing -- it is the one check in the
# tier table whose job is to fail loudly if the two identifier spaces were ever
# conflated, and as written it would not. See issue #232.
#
# THREE CONTROLS, NOT ONE, because the tier table joins on two different
# identifier spaces and each deserves its own check:
#
#   NC1  no cohort NPI appears as a CCN in the Tier 2 co-location pool
#        (ob_hospitals_geocoded.csv$prvdr_num). This is the control restated in
#        terms of what the cited artifact actually holds, and it runs from
#        tracked files alone.
#   NC2  no cohort NPI appears as a CCN in the Tier 1 affiliation output
#        (dac_facility_affiliations.csv$ccn). Tracked; guards the primary join.
#   NC3  no cohort Type 1 NPI appears among hospital Type 2 organization NPIs.
#        This is the control AS ORIGINALLY STATED, pointed at sources that
#        carry organization NPIs: the NPI<->CCN crosswalk and the CMS hospital
#        enrollment files under HPT_PRICES. Those live on an external volume
#        and are not in any checkout, so this control reports SKIPPED with the
#        path it looked for, rather than passing vacuously.
#
# A SKIP IS NOT A PASS. Each control records its own status, and the artifact
# carries the row count each one was evaluated over, so a control that saw
# nothing cannot read as a control that found nothing.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          artifacts/ob_hospitals_geocoded.csv
#          artifacts/dac_facility_affiliations.csv
#          $HPT_PRICES/reference/npi_ccn_crosswalk.csv          (optional)
#          $HPT_PRICES/reference/cms_enrollments/Hospital_Enrollments_*.csv (optional)
# Output : artifacts/hospital_linkage_negative_controls.csv
#
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))   # samsung_volume_path()

LINKAGE <- "artifacts/amcb_npi_linkage_FROZEN.csv"
OB      <- "artifacts/ob_hospitals_geocoded.csv"
DAC     <- "artifacts/dac_facility_affiliations.csv"
OUT     <- "artifacts/hospital_linkage_negative_controls.csv"

if (!file.exists(LINKAGE))
  stop(sprintf("%s not found; this control needs the person-level freeze.", LINKAGE),
       call. = FALSE)

# --- the cohort's NPIs, as character ------------------------------------------
# read as character throughout: an NPI read as a double and printed back is how
# an identifier comparison silently stops matching.
link <- read_csv(LINKAGE, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = "c"))
cohort <- canonical_active_primary(link)
cohort_npi <- unique(trimws(cohort$npi))
cohort_npi <- cohort_npi[nzchar(cohort_npi)]
cat(sprintf("cohort NPIs (ACTIVE, primary-linked): %s\n",
            format(length(cohort_npi), big.mark = ",")))

#' One control's result row.
#'
#' @param id,question,source description of what was checked and against what.
#' @param ids character vector of hospital-side identifiers, or NULL to SKIP.
#' @param skip_detail why it was skipped, when `ids` is NULL.
control <- function(id, question, source, ids, skip_detail = NA_character_) {
  if (is.null(ids)) {
    return(tibble(control = id, question = question, source = source,
                  n_cohort_npi = length(cohort_npi), n_hospital_ids = NA_integer_,
                  n_collisions = NA_integer_, status = "SKIPPED",
                  detail = skip_detail))
  }
  ids <- unique(trimws(as.character(ids)))
  ids <- ids[!is.na(ids) & nzchar(ids)]
  hits <- intersect(cohort_npi, ids)
  tibble(control = id, question = question, source = source,
         n_cohort_npi = length(cohort_npi), n_hospital_ids = length(ids),
         n_collisions = length(hits),
         status = if (length(hits) == 0L) "PASS" else "FAIL",
         detail = if (length(hits) == 0L) "no cohort NPI appears in this identifier space"
                  else paste("collides:", paste(head(hits, 10), collapse = ";")))
}

rows <- list()

# --- NC1: Tier 2's own identifier space --------------------------------------
rows[["NC1"]] <- if (file.exists(OB)) {
  ob <- read_csv(OB, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = "c"))
  if (!"prvdr_num" %in% names(ob))
    stop(sprintf("%s has no prvdr_num column; columns are: %s", OB,
                 paste(names(ob), collapse = ", ")), call. = FALSE)
  control("NC1", "does any cohort NPI appear as a hospital CCN?",
          paste0(OB, "$prvdr_num"), ob$prvdr_num)
} else {
  control("NC1", "does any cohort NPI appear as a hospital CCN?",
          paste0(OB, "$prvdr_num"), NULL, sprintf("%s absent", OB))
}

# --- NC2: Tier 1's own identifier space --------------------------------------
rows[["NC2"]] <- if (file.exists(DAC)) {
  dac <- read_csv(DAC, show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = "c"))
  control("NC2", "does any cohort NPI appear as an affiliation CCN?",
          paste0(DAC, "$ccn"), dac$ccn)
} else {
  control("NC2", "does any cohort NPI appear as an affiliation CCN?",
          paste0(DAC, "$ccn"), NULL, sprintf("%s absent", DAC))
}

# --- NC3: the control as the appendix states it ------------------------------
# Type 1 (individual) against Type 2 (organization). The crosswalk and the CMS
# enrollment extracts are the two sources in this project that carry hospital
# ORGANIZATION NPIs; ob_hospitals_geocoded.csv carries none, which is the
# defect this script exists to correct.
hpt <- Sys.getenv("HPT_PRICES", "")
if (!nzchar(hpt)) hpt <- tryCatch(samsung_volume_path("hpt_prices", must_exist = FALSE),
                                  error = function(e) NA_character_)
org_npi <- NULL
skip_why <- NA_character_
if (is.na(hpt) || !nzchar(hpt)) {
  skip_why <- "HPT_PRICES not set and no Samsung volume hpt_prices mount found"
} else {
  xwalk <- file.path(hpt, "reference", "npi_ccn_crosswalk.csv")
  enroll <- Sys.glob(file.path(hpt, "reference", "cms_enrollments",
                               "Hospital_Enrollments_*.csv"))
  parts <- list()
  # tryCatch, not file.exists: on macOS a volume can be mounted and still deny
  # the read (TCC), and "present but unreadable" must not report as PASS.
  read_col <- function(path, col) {
    tryCatch(read_csv(path, show_col_types = FALSE, progress = FALSE,
                      col_types = cols(.default = "c"))[[col]],
             error = function(e) {
               # basename only: this string lands in a tracked artifact, and an
               # absolute /Volumes/... path resolves for nobody else and drifts
               # with macOS's mount naming.
               skip_why <<- sprintf("%s unreadable (%s)", basename(path),
                                    conditionMessage(e))
               NULL
             })
  }
  if (file.exists(xwalk)) parts$xwalk <- read_col(xwalk, "npi")
  for (e in enroll) parts[[basename(e)]] <- read_col(e, "NPI")
  parts <- Filter(Negate(is.null), parts)
  if (length(parts)) {
    org_npi <- unlist(parts, use.names = FALSE)
  } else if (is.na(skip_why)) {
    skip_why <- sprintf("no organization-NPI source under %s/reference", hpt)
  }
}
rows[["NC3"]] <- control(
  "NC3", "does any cohort Type 1 NPI appear as a hospital Type 2 organization NPI?",
  "$HPT_PRICES/reference: npi_ccn_crosswalk.csv + cms_enrollments/Hospital_Enrollments_*.csv",
  org_npi, skip_why)

out <- bind_rows(rows)
print(as.data.frame(out))

write_with_provenance(out, OUT,
                      inputs = c(LINKAGE, OB, DAC)[file.exists(c(LINKAGE, OB, DAC))])
cat(sprintf("\nwritten: %s\n", OUT))

failed <- out$status == "FAIL"
if (any(failed)) {
  stop(sprintf(paste0(
    "%d negative control(s) FAILED: %s.\n",
    "  A cohort NPI turning up in a hospital identifier space means the Type 1 and\n",
    "  Type 2 spaces have been conflated somewhere upstream, and every tier in\n",
    "  docs/TECHNICAL_APPENDIX_HOSPITAL_LINKAGE.md rests on their separation."),
    sum(failed), paste(out$control[failed], collapse = ", ")), call. = FALSE)
}
skipped <- out$status == "SKIPPED"
if (any(skipped))
  cat(sprintf("\nNOTE: %d control(s) SKIPPED (%s) -- a skip is not a pass.\n",
              sum(skipped), paste(out$control[skipped], collapse = ", ")))
