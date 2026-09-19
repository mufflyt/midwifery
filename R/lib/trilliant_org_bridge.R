# =============================================================================
# Bridging a Trilliant practice address to an organization NPI
# =============================================================================
#
# WHY THIS IS A LIBRARY AND NOT A SECOND COPY. build_trilliant_work_sites.R
# defined the street normalizer, the name-similarity score and the
# directory_organization reader inline, and a second consumer now needs the
# same three (the organization-rule concordance reference). A second copy is
# how two artifacts come to disagree about the same address: tighten the state
# guard or the suite-stripping in one script, and the other keeps its own
# answer while both claim to describe the same building. tests/ci_hygiene.R
# rejects a function defined at top level in two files for exactly this reason.
#
# WHAT LIVES HERE AND WHAT DOES NOT. This file owns ADDRESS AND NAME
# COMPARISON plus the raw read of directory_organization. It deliberately does
# NOT own facility classification (`org_class`, `hospital_rank`,
# birth-centre/hospital/FQHC name patterns): that cascade answers "what kind of
# place is this", which is a work-site question, and it stays in
# build_trilliant_work_sites.R with the rest of the topology.
#
# Source: Trilliant Health provider directory (organization table).
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(stringdist)
})

#' Street-suffix and directional abbreviations, applied by [norm_street()].
STREET_ABBREV <- c(
  street = "st", avenue = "ave", boulevard = "blvd", drive = "dr", road = "rd",
  lane = "ln", parkway = "pkwy", highway = "hwy", place = "pl", court = "ct",
  circle = "cir", terrace = "ter", square = "sq", plaza = "plz",
  expressway = "expy", freeway = "fwy", northeast = "ne", northwest = "nw",
  southeast = "se", southwest = "sw", north = "n", south = "s", east = "e",
  west = "w", route = "rte", "state rte" = "rte", "us hwy" = "hwy", "state hwy" = "hwy"
)

#' Normalise a street line for comparison across registries.
#'
#' Drops the suite/unit tail and punctuation and abbreviates suffixes and
#' directionals, so NPPES "2500 ENGLISH CREEK AVE STE 1000" meets Trilliant
#' "2500 English Creek Ave".
#'
#' NOTE THE DIFFERENCE FROM [norm_addr()] in R/lib/address_keys.R, which KEEPS
#' the suite because two suites are two workplaces. This one drops it, because
#' the question here is which building an organization occupies. Both are
#' correct for their own question; pick by the question, and never swap them.
#'
#' @param s character vector of street lines.
#' @return character vector, lower case, squished; `""` where the input is NA.
norm_street <- function(s) {
  s <- str_to_lower(coalesce(s, ""))
  s <- str_remove(s, "\\s*(,|\\s)\\s*(ste|suite|unit|apt|fl|floor|rm|room|bldg|building|dept|#)\\b.*$")
  s <- str_replace_all(s, "[^a-z0-9 ]", " ")
  for (w in names(STREET_ABBREV)) {
    s <- str_replace_all(s, paste0("\\b", w, "\\b"), STREET_ABBREV[[w]])
  }
  str_squish(s)
}

#' Jaro-Winkler similarity of two organization names, 0..1 (1 = identical).
#'
#' Used to choose among organizations that share one address, never to admit a
#' match on its own: a name score is a tie-breaker, in the same way
#' resolve_org_ambiguity.R's Tier C name evidence never promotes by itself.
#' @param a,b character vectors.
name_sim <- function(a, b) stringsim(str_to_lower(a), str_to_lower(b), method = "jw", p = 0.1)

#' Read directory_organization for a set of ZIP5s.
#'
#' Returns the organization's identity and location only. The caller adds
#' whatever classification it needs.
#'
#' @param lake path to the lake's data/main directory.
#' @param zips character vector of ZIP5s to restrict to; the table is 3.26M
#'   rows, of which 1,994,218 carry an organization NPI, so this is always
#'   filtered rather than collected whole.
#' @return tibble with org_npi, org_name, org_type, tax, tax_desc, oz (ZIP5),
#'   street1, ns (normalised street), org_phone, org_lat, org_lon, org_county,
#'   org_state.
trl_read_orgs <- function(lake, zips) {
  if (!requireNamespace("duckplyr", quietly = TRUE))
    stop("trl_read_orgs() needs duckplyr", call. = FALSE)
  duckplyr::read_parquet_duckdb(file.path(lake, "directory_organization", "*.parquet")) |>
    filter(!is.na(organization_zip_code), !is.na(organization_street_line_1)) |>
    # 1L / 5L, not 1 / 5: DuckDB's substr() wants whole numbers
    mutate(oz = substr(organization_zip_code, 1L, 5L)) |>
    semi_join(duckplyr::as_duckdb_tibble(tibble(oz = unique(zips))), by = "oz") |>
    select(org_npi = organization_npi, org_name = organization_name, org_type = organization_type,
           tax = organization_primary_taxonomy_code, tax_desc = organization_primary_taxonomy_description,
           oz, street1 = organization_street_line_1, org_phone = organization_phone_number,
           org_lat = organization_latitude, org_lon = organization_longitude,
           org_county = organization_county, org_state = organization_state) |>
    collect() |>
    mutate(ns = norm_street(street1))
}
