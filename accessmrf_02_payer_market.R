#!/usr/bin/env Rscript

#' @title Colorado commercial payer market, enumerated before any download
#'
#' @description
#' Step 2 of 8. Establishes the market denominator. Pulling arbitrary AccessMRF
#' sources tells you how many midwives you found; it cannot tell you what
#' fraction of the market you looked at, and without that a midwife's absence
#' means nothing at all.
#'
#' Enrollment comes from the CMS Medical Loss Ratio Public Use File, which every
#' commercial issuer must file: issuer x state x market-segment life-years.
#' Colorado commercial life-years = individual + small group + large group.
#'
#' @section Result:
#' Colorado's insured commercial market is unusually concentrated -- five payer
#' groups reach 98.2% of life-years, and 99.4% has a reachable AccessMRF source:
#'
#' \preformatted{
#'   KAISER FOUNDATION GRP    369,058   36.0%    36.0% cumulative
#'   Elevance Hlth Inc Grp    292,530   28.5%    64.6%
#'   UNITEDHEALTH GRP         197,588   19.3%    83.9%
#'   Cigna Hlth Grp           129,318   12.6%    96.5%
#'   CVS Health Group          17,707    1.7%    98.2%
#' }
#'
#' @section What this denominator is NOT:
#' MLR covers INSURED commercial business only. Self-funded (ASO) employer
#' plans are absent from it, and they are a large share of large-group lives --
#' while the MRFs themselves DO include self-funded plans. So a payer's share
#' here understates the members whose care it administers. Read every figure as
#' "share of insured commercial life-years", never "share of people".
#'
#' Life-years are also not member counts, and reporting is by issuer legal
#' entity; `group_affiliation` rolls those into the parent group, which is the
#' level a provider network actually operates at.
#'
#' @section Why the MLR `_yearly` columns and not `_total`:
#' The `cmm_*_total` columns are empty in this release; enrollment lives in
#' `cmm_*_yearly`. Reading the wrong one silently produces a table of zeros
#' rather than an error.
#'
#' @section Payer-name matching is regex, and is written out for audit:
#' MLR reports legal entities ("KAISER FOUNDATION GRP"); AccessMRF lists brands
#' ("Kaiser Permanente"). The mapping is therefore pattern-based and every
#' resulting pair is written to `colorado_payer_source_mapping.csv` so it can be
#' checked by hand. This is the step where one wrong guess silently drops a
#' third of the market.
#'
#' @section Inputs and outputs:
#' Downloads the CMS MLR PUF to `data/raw/accessmrf/` (gitignored). Writes
#' `artifacts/accessmrf/colorado_payer_market.csv` (with provenance sidecar),
#' `colorado_payer_source_mapping.csv` and `accessmrf_sources_index.csv`.
#'
#' @family accessmrf
#' @concept provider-billing-graph
#' @seealso `accessmrf_04_saturation.R`, which consumes this market table.
#' @keywords internal

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(jsonlite)
})

source(file.path("R", "lib", "artifact_provenance.R"))

artifact_dir <- file.path("artifacts", "accessmrf")
raw_dir <- file.path("data", "raw", "accessmrf")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

TARGET_STATE <- "CO"
MLR_YEAR <- 2024
MLR_URL <- sprintf("https://www.cms.gov/files/zip/mlr-public-use-file-%d.zip", MLR_YEAR)
MLR_ZIP <- file.path(raw_dir, sprintf("mlr-public-use-file-%d.zip", MLR_YEAR))
ACCESSMRF_SOURCES <- "https://www.accessmrf.com/api/sources"


# -------------------------------------------------------------------------
# 1. CMS MLR: who sells commercial insurance in Colorado, and how much
# -------------------------------------------------------------------------

if (!file.exists(MLR_ZIP) || file.size(MLR_ZIP) < 1e6) {
  base::message("[MLR] Downloading ", MLR_URL)
  utils::download.file(MLR_URL, MLR_ZIP, mode = "wb", quiet = TRUE)
}

read_member <- function(member) {
  read_csv(unz(MLR_ZIP, member), col_types = cols(.default = col_character()),
           progress = FALSE)
}

header <- read_member("MR_Submission_Template_Header.csv")
part12 <- read_member("Part1_2_Summary_Data_Premium_Claims.csv")

# The `_total` columns are empty in this release; enrollment lives in
# `_yearly`. Reading the wrong one silently yields a table of zeros.
enrollment <- part12 |>
  filter(.data$row_lookup_code == "NUMBER_OF_LIFE_YEARS") |>
  transmute(
    mr_submission_template_id = .data$mr_submission_template_id,
    life_years =
      coalesce(suppressWarnings(as.numeric(.data$cmm_individual_yearly)), 0) +
      coalesce(suppressWarnings(as.numeric(.data$cmm_small_group_yearly)), 0) +
      coalesce(suppressWarnings(as.numeric(.data$cmm_large_group_yearly)), 0)
  )

market <- header |>
  filter(.data$business_state == TARGET_STATE) |>
  select("mr_submission_template_id", "company_name", "group_affiliation",
         "hios_issuer_id", "federal_ein") |>
  inner_join(enrollment, by = "mr_submission_template_id") |>
  mutate(payer_group = coalesce(na_if(str_squish(.data$group_affiliation), ""),
                                .data$company_name)) |>
  group_by(payer_group = .data$payer_group) |>
  summarise(commercial_enrollment_estimate = sum(.data$life_years),
            issuers = dplyr::n(),
            .groups = "drop") |>
  filter(.data$commercial_enrollment_estimate > 0) |>
  arrange(desc(.data$commercial_enrollment_estimate)) |>
  mutate(
    enrollment_source = sprintf("CMS MLR PUF %d (life-years, ind+SG+LG)", MLR_YEAR),
    enrollment_year = MLR_YEAR,
    market_share = .data$commercial_enrollment_estimate /
      sum(.data$commercial_enrollment_estimate),
    cumulative_market_share = cumsum(.data$market_share)
  )


# -------------------------------------------------------------------------
# 2. AccessMRF: which of them publish MRFs we can actually read
# -------------------------------------------------------------------------

sources <- fromJSON(ACCESSMRF_SOURCES)$sources |> as_tibble()

write_csv(sources, file.path(artifact_dir, "accessmrf_sources_index.csv"))

# Matched on regex rather than name equality: MLR reports legal entities
# ("KAISER FOUNDATION GRP") and AccessMRF lists brands ("Kaiser Permanente").
# Every mapping is written to the artifact so it can be checked by hand --
# this is the step where a wrong guess silently drops a third of the market.
PAYER_PATTERNS <- c(
  "KAISER FOUNDATION GRP" = "kaiser",
  "Elevance Hlth Inc Grp" = "anthem|elevance",
  "UNITEDHEALTH GRP" = "^united healthcare$",
  "Cigna Hlth Grp" = "^cigna$",
  "CVS Health Group" = "^aetna cvs",
  "Denver Health Medical Plan, Inc." = "denver health",
  "HUMANA GRP" = "^humana",
  "IHC Inc Grp" = "^ihc|independence holding"
)

match_sources <- function(payer_group) {
  # Single-bracket lookup: `[[` raises on an unmatched name, and most Colorado
  # issuers (dental, life, stop-loss carriers) have no MRF source by design.
  pattern <- unname(PAYER_PATTERNS[payer_group])
  if (length(pattern) == 0L || is.na(pattern)) return(tibble::tibble())
  hits <- sources |>
    filter(str_detect(.data$displayName, regex(pattern, ignore_case = TRUE)))
  if (nrow(hits) == 0L) return(tibble::tibble())
  hits |>
    transmute(payer_group = payer_group,
              accessmrf_source_id = .data$sourceId,
              accessmrf_slug = .data$slug,
              accessmrf_display_name = .data$displayName,
              files_available = .data$numFiles,
              total_compressed_bytes = .data$totalCompressedSize,
              latest_index_date = .data$latestIndexDate,
              mrf_status = .data$status)
}

mapped <- purrr::map_dfr(market$payer_group, match_sources)

payer_table <- market |>
  left_join(
    mapped |>
      group_by(.data$payer_group) |>
      summarise(
        accessmrf_source_id = paste(.data$accessmrf_source_id, collapse = "|"),
        accessmrf_slugs = paste(.data$accessmrf_slug, collapse = "|"),
        accessmrf_sources = dplyr::n(),
        files_available = sum(.data$files_available, na.rm = TRUE),
        total_compressed_bytes = sum(.data$total_compressed_bytes, na.rm = TRUE),
        .groups = "drop"
      ),
    by = "payer_group"
  ) |>
  mutate(
    colorado_relevant = TRUE,
    accessmrf_sources = coalesce(.data$accessmrf_sources, 0L),
    mrf_available = .data$accessmrf_sources > 0L
  ) |>
  select("payer_group", "commercial_enrollment_estimate", "enrollment_source",
         "enrollment_year", "market_share", "cumulative_market_share",
         "colorado_relevant", "mrf_available", "accessmrf_sources",
         "accessmrf_source_id", "accessmrf_slugs", "files_available",
         "total_compressed_bytes", "issuers")

write_with_provenance(
  payer_table,
  file.path(artifact_dir, "colorado_payer_market.csv"),
  inputs = MLR_ZIP
)
write_csv(mapped, file.path(artifact_dir, "colorado_payer_source_mapping.csv"))

reachable <- payer_table |> filter(.data$mrf_available)

base::message("")
base::message("======================================================================")
base::message("COLORADO COMMERCIAL MARKET (CMS MLR ", MLR_YEAR, ")")
base::message("======================================================================")
base::message(sprintf("%-34s %10s %7s %7s %8s", "payer group", "life-yrs",
                      "share", "cum", "files"))
for (i in seq_len(nrow(payer_table))) {
  base::message(sprintf(
    "%-34s %10s %6.1f%% %6.1f%% %8s%s",
    substr(payer_table$payer_group[[i]], 1, 34),
    format(round(payer_table$commercial_enrollment_estimate[[i]]), big.mark = ","),
    100 * payer_table$market_share[[i]],
    100 * payer_table$cumulative_market_share[[i]],
    format(coalesce(payer_table$files_available[[i]], 0L), big.mark = ","),
    if (payer_table$mrf_available[[i]]) "" else "   <- NO MRF SOURCE"
  ))
}
base::message("----------------------------------------------------------------------")
base::message("Payer groups with an AccessMRF source: ", nrow(reachable), " of ",
              nrow(payer_table))
base::message("Insured commercial share reachable:    ",
              sprintf("%.1f%%", 100 * sum(reachable$market_share)))
base::message("======================================================================")
