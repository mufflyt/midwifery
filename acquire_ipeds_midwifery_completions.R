#!/usr/bin/env Rscript

# =============================================================================
# IPEDS nurse-midwifery completions, 2015-2024, for the 12 target institutions
#
# Acquires IPEDS Completions (C{year}_A) from NCES, extracts CIP 51.3807
# (Nurse-Midwifery/Nursing Midwifery) for the target UNITIDs, and reports which
# institutions IPEDS can and cannot supply a midwifery denominator for.
#
# ---------------------------------------------------------------------------
# TWO FINDINGS THAT CONSTRAIN THIS AUDIT
#
# 1. AWARD YEAR 2025 DOES NOT EXIST. C2025_A.zip returns 404 at NCES, with no
#    _rv or provisional variant. IPEDS has not released it. The audit window is
#    therefore 2015-2024, not 2015-2025.
#
# 2. FIVE OF THE TWELVE INSTITUTIONS REPORT NO 51.3807 AT ALL. UAB, Georgetown,
#    Michigan, Minnesota and Columbia have zero completions under the
#    nurse-midwifery CIP in every year 2015-2024. Their midwifery graduates are
#    folded into 51.3801 (Registered Nursing), alongside hundreds of
#    non-midwifery graduates -- Georgetown 2022 reports 245 master's completions
#    under 51.3801 and none under 51.3807.
#
#    For those five, an IPEDS-derived midwifery denominator is not merely
#    missing, it is unobtainable at CIP granularity. A "deficit" cannot be
#    computed for them from IPEDS, and any figure attributed to IPEDS for those
#    schools came from somewhere else.
#
# Award levels are kept SEPARATE rather than summed. 07 is master's and 08 is
# post-master's certificate; the post-master's certificate is a real entry route
# into nurse-midwifery (Frontier reports 5-21 a year), so collapsing the two
# hides a pathway while counting only 07 undercounts graduates.
#
# AWLEVEL is zero-padded ("07") through 2022 and unpadded ("7") from 2023, so it
# is normalised before use.
#
# The REVISED file (_rv) is preferred wherever the archive carries one; it
# supersedes the provisional release. 2024 has no revision yet.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
artifact_dir <- file.path("artifacts", "ipeds")
raw_dir <- file.path("data", "raw", "ipeds")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

YEARS <- 2015:2024
CIP_NURSE_MIDWIFERY <- "51.3807"
CIP_REGISTERED_NURSING <- "51.3801"

INSTITUTIONS <- tibble::tribble(
  ~unitid,  ~institution,
  "100663", "University of Alabama at Birmingham",
  "131496", "Georgetown University",
  "139658", "Emory University",
  "156727", "Frontier Nursing University",
  "170976", "University of Michigan",
  "174066", "University of Minnesota",
  "190150", "Columbia University",
  "196255", "SUNY Downstate Health Sciences University",
  "201885", "University of Cincinnati",
  "209490", "Oregon Health & Science University",
  "215062", "University of Pennsylvania",
  "221999", "Vanderbilt University"
)


# -------------------------------------------------------------------------
# 1. Acquire
# -------------------------------------------------------------------------

ipeds_url <- function(year) {
  sprintf("https://nces.ed.gov/ipeds/datacenter/data/C%d_A.zip", year)
}

acquire_year <- function(year) {

  destination <- file.path(raw_dir, sprintf("C%d_A.zip", year))

  if (file.exists(destination) && file.size(destination) > 1e6) {
    return(destination)
  }

  base::message("[DOWNLOAD] ", ipeds_url(year))
  ok <- tryCatch({
    utils::download.file(ipeds_url(year), destination, mode = "wb", quiet = TRUE)
    TRUE
  }, error = function(e) FALSE)

  if (!ok || !file.exists(destination) || file.size(destination) < 1e6) {
    base::message("[DOWNLOAD] ", year, " unavailable at NCES")
    return(NA_character_)
  }

  destination
}

archives <- tibble::tibble(award_year = YEARS) |>
  mutate(archive = vapply(.data$award_year, acquire_year, character(1))) |>
  filter(!is.na(.data$archive))

base::message("[ACQUIRE] ", nrow(archives), " of ", length(YEARS),
              " award years available")


# -------------------------------------------------------------------------
# 2. Extract, preferring the revised file
# -------------------------------------------------------------------------

read_year <- function(award_year, archive) {

  members <- utils::unzip(archive, list = TRUE)$Name
  revised <- grep("_rv\\.csv$", members, value = TRUE, ignore.case = TRUE)
  member <- if (length(revised)) revised[[1]] else members[[1]]

  base::message("[EXTRACT] ", award_year, "  ", member)

  connection <- unz(archive, member)
  raw <- read_csv(connection, col_types = cols(.default = col_character()),
                  progress = FALSE)

  raw |>
    filter(.data$UNITID %in% INSTITUTIONS$unitid,
           stringr::str_starts(.data$CIPCODE, stringr::fixed("51.38"))) |>
    transmute(
      award_year = award_year,
      unitid = .data$UNITID,
      cipcode = .data$CIPCODE,
      majornum = .data$MAJORNUM,
      # "07" through 2022, "7" from 2023.
      award_level = stringr::str_pad(.data$AWLEVEL, 2, pad = "0"),
      completions = suppressWarnings(as.integer(.data$CTOTALT)),
      source_file = member,
      source_sha256 = sha256_of(archive)
    )
}

nursing <- purrr::pmap_dfr(archives, read_year) |>
  left_join(INSTITUTIONS, by = "unitid")

midwifery <- nursing |> filter(.data$cipcode == CIP_NURSE_MIDWIFERY)

write_with_provenance(
  midwifery,
  file.path(artifact_dir,
            paste0("ipeds_midwifery_completions_2015_2024_", timestamp, ".csv")),
  inputs = archives$archive
)


# -------------------------------------------------------------------------
# 3. Which institutions can IPEDS actually answer for?
# -------------------------------------------------------------------------

coverage <- INSTITUTIONS |>
  left_join(
    midwifery |>
      group_by(.data$unitid) |>
      summarise(years_with_51_3807 = dplyr::n_distinct(.data$award_year),
                total_completions = sum(.data$completions, na.rm = TRUE),
                .groups = "drop"),
    by = "unitid"
  ) |>
  left_join(
    nursing |>
      filter(.data$cipcode == CIP_REGISTERED_NURSING) |>
      group_by(.data$unitid) |>
      summarise(completions_51_3801 = sum(.data$completions, na.rm = TRUE),
                .groups = "drop"),
    by = "unitid"
  ) |>
  mutate(
    years_with_51_3807 = coalesce(.data$years_with_51_3807, 0L),
    total_completions = coalesce(.data$total_completions, 0L),
    # An institution reporting nothing under the midwifery CIP while reporting
    # heavily under general nursing has folded its midwives into 51.3801. IPEDS
    # cannot separate them, so no midwifery denominator exists.
    ipeds_denominator_available = .data$years_with_51_3807 > 0L
  ) |>
  arrange(desc(.data$ipeds_denominator_available), .data$institution)

write_csv(
  coverage,
  file.path(artifact_dir,
            paste0("ipeds_cip_coverage_by_institution_", timestamp, ".csv"))
)

by_level <- midwifery |>
  group_by(.data$institution, .data$award_year) |>
  summarise(
    masters_07 = sum(.data$completions[.data$award_level == "07"], na.rm = TRUE),
    post_masters_08 = sum(.data$completions[.data$award_level == "08"], na.rm = TRUE),
    other_levels = sum(.data$completions[!.data$award_level %in% c("07", "08")],
                       na.rm = TRUE),
    total = sum(.data$completions, na.rm = TRUE),
    .groups = "drop"
  )

write_csv(
  by_level,
  file.path(artifact_dir,
            paste0("ipeds_midwifery_by_award_level_", timestamp, ".csv"))
)

base::message("")
base::message("==================================================================")
base::message("IPEDS NURSE-MIDWIFERY COMPLETIONS (CIP 51.3807), 2015-2024")
base::message("==================================================================")
base::message(sprintf("%-44s %6s %8s %10s", "institution", "years", "total", "51.3801"))
for (i in seq_len(nrow(coverage))) {
  base::message(sprintf(
    "%-44s %6d %8s %10s%s",
    substr(coverage$institution[[i]], 1, 44),
    coverage$years_with_51_3807[[i]],
    format(coverage$total_completions[[i]], big.mark = ","),
    format(coalesce(coverage$completions_51_3801[[i]], 0L), big.mark = ","),
    if (coverage$ipeds_denominator_available[[i]]) "" else "   <- NO IPEDS DENOMINATOR"
  ))
}
base::message("------------------------------------------------------------------")
base::message("Award year 2025: not released by NCES; window is 2015-2024.")
base::message("Artifacts: ", artifact_dir)
base::message("==================================================================")
