#!/usr/bin/env Rscript

# =============================================================================
# 2013 DAC vs 2013 NPPES: a disagreement audit
#
# Compares each 2013 Physician Compare CNM record against the SAME-YEAR NPPES
# dissemination (April 2013), not against current NPPES. Comparing a 2013
# identity to a 2026 identity would attribute thirteen years of genuine drift
# to source disagreement.
#
# This is an AUDIT. It changes no canonical AMCB -> NPI linkage and no matcher.
# It answers one question: where do two contemporaneous federal sources
# disagree about the same provider, and by how much?
#
# ---------------------------------------------------------------------------
# THE TIMING CAVEAT, QUANTIFIED
#
# The NPPES dissemination is April 2013; the DAC snapshots are June and
# September 2013, a 2-5 month offset. Some disagreement is therefore real
# change, not source error. The June-vs-September comparison measures that
# floor directly: over one quarter, practice ZIP is only 92.2% stable and
# hospital affiliation 89.5%, while last name is 99.9% stable. So a few
# percent of address disagreement is expected from timing alone, and
# essentially none of the name disagreement is.
#
# Inputs:
#   artifacts/cms_physician_compare/physician_compare_2013_manifest.csv
#   data/raw/nppes/2013/NPPES_Data_Dissemination_Apr_2013.zip  (auto-acquired)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
artifact_dir <- file.path("artifacts", "cms_physician_compare")
nppes_dir <- file.path("data", "raw", "nppes", "2013")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(nppes_dir, recursive = TRUE, showWarnings = FALSE)

NPPES_URL <- paste0("https://data.nber.org/nppes/zip-orig/",
                    "NPPES_Data_Dissemination_Apr_2013.zip")
NPPES_ZIP <- file.path(nppes_dir, "NPPES_Data_Dissemination_Apr_2013.zip")
NPPES_MEMBER <- "npidata_20050523-20130407.csv"
NPPES_EXTRACT <- file.path(nppes_dir, "nppes_2013_cnm_extract.csv")

BROWSER_UA <- paste(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

# NPPES taxonomy for Advanced Practice Midwife, i.e. a CNM. Recorded as a
# constant because the audit turns on it: only about two thirds of providers
# CMS labels "CERTIFIED NURSE MIDWIFE" in DAC carry it in NPPES.
TAXONOMY_CNM <- "367A00000X"
TAXONOMY_MIDWIFE_LAY <- "176B00000X"

# NPPES "Provider Other Last Name Type Code": 1 = Former Name,
# 2 = Professional Name, 3 = Doing Business As, 4 = Maiden Name, 5 = Other.
OTHER_NAME_TYPES <- c("1" = "former_name", "2" = "professional_name",
                      "3" = "doing_business_as", "4" = "maiden_name",
                      "5" = "other")


# -------------------------------------------------------------------------
# 1. The DAC side: person-level, per snapshot
# -------------------------------------------------------------------------

manifest_path <- file.path(artifact_dir, "physician_compare_2013_manifest.csv")
if (!file.exists(manifest_path)) {
  stop("Run acquire_physician_compare_2013.R first.", call. = FALSE)
}
manifest <- read_csv(manifest_path, show_col_types = FALSE)

person_files <- sort(list.files(
  artifact_dir, pattern = "^dac_person_snapshot_2013_.*\\.csv$", full.names = TRUE
))
if (length(person_files) == 0L) {
  stop("Run build_dac_identity_spine_2013.R first.", call. = FALSE)
}

dac <- read_csv(person_files[[length(person_files)]],
                col_types = cols(.default = col_character()))

base::message("[DAC] ", format(nrow(dac), big.mark = ","),
              " person-snapshot rows; ",
              format(dplyr::n_distinct(dac$npi), big.mark = ","), " distinct NPIs")

cnm_npis <- sort(unique(dac$npi))


# -------------------------------------------------------------------------
# 2. The NPPES side: acquire, then stream-filter
# -------------------------------------------------------------------------

if (!file.exists(NPPES_ZIP) || file.size(NPPES_ZIP) < 1e8) {
  base::message("[NPPES] Downloading ", NPPES_URL)
  utils::download.file(NPPES_URL, NPPES_ZIP, mode = "wb", quiet = FALSE,
                       headers = c("User-Agent" = BROWSER_UA))
}

stopifnot(file.exists(NPPES_ZIP))

# The member CSV is 4.82 GB uncompressed. It is never written to disk: unzip
# streams it through a FIFO into DuckDB, which keeps only the rows joining to
# the CNM NPI list. Extracting it first would need 4.8 GB of free space for a
# file we discard immediately.
if (!file.exists(NPPES_EXTRACT) || file.size(NPPES_EXTRACT) < 1000) {

  base::message("[NPPES] Stream-filtering ", NPPES_MEMBER,
                " to ", length(cnm_npis), " NPIs (nothing is extracted to disk)")

  npi_list_file <- tempfile(fileext = ".csv")
  writeLines(cnm_npis, npi_list_file)

  fifo_path <- tempfile(fileext = ".fifo")
  system2("mkfifo", c("-m", "600", shQuote(fifo_path)))

  on.exit(unlink(c(fifo_path, npi_list_file)), add = TRUE)

  system2("unzip", c("-p", shQuote(NPPES_ZIP), shQuote(NPPES_MEMBER)),
          stdout = fifo_path, wait = FALSE)

  sql <- sprintf("
    create temp table want as
      select column0::varchar as npi
      from read_csv('%s', header=false, all_varchar=true);
    copy (
      select n.\"NPI\" as npi,
             n.\"Provider Last Name (Legal Name)\" as nppes_last_name,
             n.\"Provider First Name\" as nppes_first_name,
             n.\"Provider Middle Name\" as nppes_middle_name,
             n.\"Provider Credential Text\" as nppes_credential,
             n.\"Provider Other Last Name\" as nppes_other_last_name,
             n.\"Provider Other First Name\" as nppes_other_first_name,
             n.\"Provider Other Last Name Type Code\" as nppes_other_last_name_type,
             n.\"Provider Gender Code\" as nppes_gender,
             n.\"Provider First Line Business Practice Location Address\" as nppes_address_1,
             n.\"Provider Business Practice Location Address City Name\" as nppes_city,
             n.\"Provider Business Practice Location Address State Name\" as nppes_state,
             n.\"Provider Business Practice Location Address Postal Code\" as nppes_zip,
             n.\"Healthcare Provider Taxonomy Code_1\" as nppes_taxonomy_1,
             n.\"Provider Enumeration Date\" as nppes_enumeration_date,
             n.\"Last Update Date\" as nppes_last_update,
             n.\"NPI Deactivation Date\" as nppes_deactivation_date
      from read_csv('%s', all_varchar=true, ignore_errors=true) n
      join want w on w.npi = n.\"NPI\"
    ) to '%s' (header true);",
    npi_list_file, fifo_path, NPPES_EXTRACT)

  system2("duckdb", c("-c", shQuote(sql)))
}

nppes <- read_csv(NPPES_EXTRACT, col_types = cols(.default = col_character()))

base::message("[NPPES] ", format(nrow(nppes), big.mark = ","), " matched rows")

write_csv(
  tibble::tibble(
    source = "NBER mirror of CMS NPPES dissemination",
    snapshot = "2013-04",
    source_url = NPPES_URL,
    local_path = NPPES_ZIP,
    bytes = file.size(NPPES_ZIP),
    sha256 = sha256_of(NPPES_ZIP),
    member = NPPES_MEMBER,
    extract_path = NPPES_EXTRACT,
    extract_sha256 = sha256_of(NPPES_EXTRACT),
    acquired_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  ),
  file.path(artifact_dir, "nppes_2013_provenance.csv")
)


# -------------------------------------------------------------------------
# 3. Normalisation, kept deliberately shallow
# -------------------------------------------------------------------------

# Upper-case, strip punctuation and collapse whitespace. Nothing more: no
# nickname table, no transliteration, no fuzzy distance. The point is to count
# genuine disagreement, and an aggressive normaliser hides exactly the
# disagreement this audit exists to measure.
audit2013_norm <- function(x) {
  x |>
    toupper() |>
    stringr::str_replace_all("[^A-Z0-9 ]", " ") |>
    stringr::str_squish() |>
    dplyr::na_if("")
}

audit2013_zip5 <- function(x) stringr::str_sub(stringr::str_remove_all(x, "\\D"), 1, 5)

joined <- dac |>
  left_join(nppes, by = "npi") |>
  mutate(
    dac_last = audit2013_norm(.data$last_name),
    dac_first = audit2013_norm(.data$first_name),
    nppes_last = audit2013_norm(.data$nppes_last_name),
    nppes_first = audit2013_norm(.data$nppes_first_name),
    other_last = audit2013_norm(.data$nppes_other_last_name),

    last_name_agrees = .data$dac_last == .data$nppes_last,
    first_name_agrees = .data$dac_first == .data$nppes_first,
    # A DAC surname that matches NPPES's OTHER last name rather than the legal
    # one is the maiden/former-name bridge. This is the mechanism that would
    # rescue an AMCB record filed under a prior surname.
    last_name_matches_other = !is.na(.data$other_last) &
      .data$dac_last == .data$other_last,

    state_agrees = audit2013_norm(.data$practice_state) == audit2013_norm(.data$nppes_state),
    zip5_agrees = audit2013_zip5(.data$practice_zip) == audit2013_zip5(.data$nppes_zip),

    nppes_is_cnm_taxonomy = .data$nppes_taxonomy_1 == TAXONOMY_CNM,
    nppes_is_any_midwife_taxonomy = .data$nppes_taxonomy_1 %in%
      c(TAXONOMY_CNM, TAXONOMY_MIDWIFE_LAY),
    nppes_credential_says_cnm = stringr::str_detect(
      toupper(coalesce(.data$nppes_credential, "")), "CNM"
    ),
    other_last_name_type_label = dplyr::recode(
      coalesce(.data$nppes_other_last_name_type, ""), !!!OTHER_NAME_TYPES,
      .default = NA_character_
    )
  )

audit_path <- file.path(
  artifact_dir, paste0("dac_nppes_2013_disagreement_", timestamp, ".csv")
)
write_with_provenance(joined, audit_path,
                      inputs = c(NPPES_EXTRACT, manifest$local_path))


# -------------------------------------------------------------------------
# 4. Report
# -------------------------------------------------------------------------

# One row per NPI, so a provider present in both snapshots is not counted
# twice. Snapshot-invariant fields make this safe.
# The left_join above can fan out when NPPES holds more than one row for an
# NPI, so the surviving row is chosen by position unless an order is stated.
# If the snapshot-invariance claim above holds, this arrange() changes nothing;
# if it ever does change a rate, the claim was wrong and that is worth seeing.
per_npi <- joined |>
  arrange(.data$npi, .data$nppes_last, .data$nppes_first) |>
  distinct(.data$npi, .keep_all = TRUE)

rate <- function(flag, label, data = per_npi) {
  v <- data[[flag]]
  comparable <- sum(!is.na(v))
  agree <- sum(v, na.rm = TRUE)
  tibble::tibble(
    check = label,
    comparable = comparable,
    agree = agree,
    agree_pct = if (comparable == 0L) NA_character_
                else sprintf("%.1f%%", 100 * agree / comparable),
    not_comparable = sum(is.na(v))
  )
}

summary_table <- dplyr::bind_rows(
  rate("last_name_agrees", "DAC last name = NPPES legal last name"),
  rate("first_name_agrees", "DAC first name = NPPES first name"),
  rate("state_agrees", "DAC practice state = NPPES state"),
  rate("zip5_agrees", "DAC ZIP5 = NPPES ZIP5"),
  rate("nppes_is_cnm_taxonomy", "NPPES taxonomy = 367A00000X (CNM)"),
  rate("nppes_is_any_midwife_taxonomy", "NPPES taxonomy = any midwife code"),
  rate("nppes_credential_says_cnm", "NPPES credential text contains CNM")
)

other_name_table <- per_npi |>
  filter(!is.na(.data$other_last)) |>
  count(.data$other_last_name_type_label, name = "n") |>
  arrange(desc(.data$n))

rescue <- per_npi |>
  filter(!is.na(.data$last_name_agrees), !.data$last_name_agrees)

rescued_by_other <- sum(rescue$last_name_matches_other, na.rm = TRUE)

write_csv(summary_table,
          file.path(artifact_dir,
                    paste0("dac_nppes_2013_agreement_summary_", timestamp, ".csv")))
write_csv(other_name_table,
          file.path(artifact_dir,
                    paste0("dac_nppes_2013_other_name_types_", timestamp, ".csv")))

base::message("")
base::message("========================================")
base::message("2013 DAC vs 2013 NPPES DISAGREEMENT AUDIT")
base::message("========================================")
base::message(sprintf("%-42s %10s %8s %8s %s",
                      "check", "comparable", "agree", "pct", "n/a"))
for (i in seq_len(nrow(summary_table))) {
  base::message(sprintf("%-42s %10s %8s %8s %s",
                        summary_table$check[[i]],
                        format(summary_table$comparable[[i]], big.mark = ","),
                        format(summary_table$agree[[i]], big.mark = ","),
                        summary_table$agree_pct[[i]],
                        format(summary_table$not_comparable[[i]], big.mark = ",")))
}
base::message("----------------------------------------")
base::message("NPPES 'other last name' present: ",
              format(sum(!is.na(per_npi$other_last)), big.mark = ","),
              " of ", format(nrow(per_npi), big.mark = ","))
for (i in seq_len(nrow(other_name_table))) {
  base::message(sprintf("   %-22s %s",
                        coalesce(other_name_table$other_last_name_type_label[[i]], "(unlabelled)"),
                        format(other_name_table$n[[i]], big.mark = ",")))
}
base::message("----------------------------------------")
base::message("Surname disagreements: ", format(nrow(rescue), big.mark = ","))
base::message("  ...resolved by NPPES other last name: ", rescued_by_other)
base::message("----------------------------------------")
base::message("Audit: ", audit_path)
base::message("========================================")
