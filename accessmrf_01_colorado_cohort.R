#!/usr/bin/env Rscript

#' @title Colorado CNM target cohort for the AccessMRF pilot
#'
#' @description
#' Step 1 of 8. Builds the denominator every later step is measured against:
#' currently active-primary Colorado midwives from the canonical AMCB -> NPI
#' linkage. 406 NPIs across 89 practice ZIPs (404 CNM, 2 CM).
#'
#' Reads the canonical roster and never modifies it. The roster's own
#' construction is out of scope here; this script only selects and projects.
#'
#' @section Geography comes from NPPES, never from the MRF:
#' A Transparency in Coverage `provider_group` carries `npi` and `tin` and
#' nothing else -- no address, city, state or ZIP. Any state assignment
#' inferred from MRF contents would be fabricated.
#'
#' This is not hypothetical. A Kaiser file named `KFHP_CO-COMMERCIAL` was found
#' to contain 321 Colorado midwives *and* 237 Californian, 143 Oregonian, 89
#' Marylander and 86 Washingtonian ones. The state token in a filename
#' identifies the PLAN's state, not the providers' state. Every geographic
#' statement in this pipeline therefore resolves through NPPES on NPI.
#'
#' @section What `canonical_cohort_flag` is for:
#' It is `TRUE` on every row, by construction -- membership in the canonical
#' active-primary linkage IS the cohort definition. It is carried explicitly so
#' a downstream join can never silently admit a non-canonical NPI without the
#' column going `NA`.
#'
#' @section Inputs and outputs:
#' Reads `artifacts/tracked_roster_active_primary_linked.csv`.
#' Writes `artifacts/accessmrf/colorado_cnm_cohort.csv` (with provenance
#' sidecar) and `..._summary.csv`.
#'
#' @family accessmrf
#' @concept provider-billing-graph
#' @seealso `accessmrf_02_payer_market.R` for the market denominator.
#' @keywords internal

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

artifact_dir <- file.path("artifacts", "accessmrf")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

ROSTER <- file.path("artifacts", "tracked_roster_active_primary_linked.csv")
TARGET_STATE <- "CO"

roster <- read_csv(ROSTER, col_types = cols(.default = col_character()))

cohort <- roster |>
  filter(.data$status == "ACTIVE",
         !is.na(.data$npi),
         .data$nppes_state == TARGET_STATE) |>
  transmute(
    npi = str_trim(.data$npi),
    amcb_id = .data$amcb_id,
    first_name = .data$first_name,
    last_name = .data$last_name,
    name = str_squish(paste(.data$first_name, .data$last_name)),
    credential = .data$certification,
    practice_state = .data$nppes_state,
    practice_zip = str_sub(str_pad(.data$nppes_zip, 5, pad = "0"), 1, 5),
    practice_city = .data$nppes_city,
    # TRUE for every row here: membership in the canonical active-primary
    # linkage IS the cohort definition. Carried explicitly so a downstream
    # join can never silently mix in a non-canonical NPI.
    canonical_cohort_flag = TRUE
  ) |>
  # Sort BEFORE de-duplicating: arranging afterwards orders the survivors but
  # leaves the CHOICE of survivor to row order, which is exactly the ambiguity
  # the .keep_all sweep exists to catch. Two certificants sharing one NPI is a
  # real (contested) case in this linkage, so the tiebreak is made explicit --
  # lowest amcb_id wins -- and the output ordering is restored afterwards.
  arrange(.data$npi, .data$amcb_id) |>
  distinct(.data$npi, .keep_all = TRUE) |>
  arrange(.data$last_name, .data$first_name)

stopifnot(!any(duplicated(cohort$npi)))

cohort_path <- file.path(artifact_dir, "colorado_cnm_cohort.csv")
write_with_provenance(cohort, cohort_path, inputs = ROSTER)

summary_table <- cohort |>
  count(.data$credential, name = "n") |>
  arrange(desc(.data$n))

write_csv(summary_table,
          file.path(artifact_dir, "colorado_cnm_cohort_summary.csv"))

base::message("========================================")
base::message("COLORADO CNM COHORT")
base::message("========================================")
base::message("canonical active-primary NPIs: ",
              format(nrow(cohort), big.mark = ","))
for (i in seq_len(nrow(summary_table))) {
  base::message(sprintf("   %-28s %s", summary_table$credential[[i]],
                        format(summary_table$n[[i]], big.mark = ",")))
}
base::message("distinct practice ZIPs: ",
              dplyr::n_distinct(cohort$practice_zip, na.rm = TRUE))
base::message("----------------------------------------")
base::message("Cohort: ", cohort_path)
base::message("========================================")
