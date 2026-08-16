#!/usr/bin/env Rscript
#' @title Step 03: County Geography Hierarchy (exact -> unambiguous ZIP)
#'
#' @description
#' Builds two parallel county variables against the frozen Stage 2 roster, so
#' every county-level finding can be run twice and compared:
#'
#' \describe{
#'   \item{\code{county_exact}}{County from coordinate/street-level evidence
#'     ONLY. The conservative geography.}
#'   \item{\code{county_best}}{\code{county_exact}, then ZIPs that map to
#'     exactly one county. The best-supported geography.}
#' }
#'
#' Every midwife keeps \code{geo_source}, \code{geo_precision} and
#' \code{geo_ambiguity}, so any downstream analysis can restrict or stratify on
#' provenance rather than trusting a single collapsed column.
#'
#' @section What is deliberately NOT done here:
#' \itemize{
#'   \item Multi-county ZIPs stay \strong{unresolved}. Largest-land-area
#'     assignment would manufacture precision: only ~5% of the un-geocoded are
#'     materially ambiguous, so preserving that uncertainty is cheap and
#'     honest. A business-address-ratio allocation (HUD USPS crosswalk) is the
#'     right eventual answer for a practice-location estimand; population
#'     weighting answers a different question ("where residents live").
#'   \item Healthgrades is not merged -- it is its own stage, so its effect on
#'     rural ascertainment can be measured rather than assumed.
#'   \item No IPW. Ascertainment must be measured before it is corrected.
#' }
#'
#' @section Internal validation:
#' Midwives holding BOTH exact coordinates and a unique-ZIP county form a
#' validation sample for the fallback. Coverage is not evidence; AGREEMENT is.
#' If the two assignments disagree at more than a trivial rate, `county_best`
#' is not validated and the run stops short of endorsing it.
#'
#' Inputs : artifacts/frozen_stage2/midwives_with_nppes.csv,
#'          midwives_geocoded.csv, data/zcta_county_2020.txt
#' Output : midwives_geography.csv,
#'          artifacts/geography_class_counts.csv,
#'          artifacts/zip_fallback_validation.csv
#'
#' @family step-functions
#' @concept geography
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(cli); library(tigris)
})

# CYCLE 21b. Inputs recorded beside every artifact this script writes, so a
# reader can tell whether the numbers were built from the bytes still on disk.
source(file.path("R", "lib", "artifact_provenance.R"))

# Helpers shared with the other numbered scripts. Defined once: these were
# duplicated across files sourced into one environment, where load order
# decided which definition won.
source(file.path("R", "lib", "common_helpers.R"))

DATA <- "data"; ART <- "artifacts"
# Default to the guarded linkage. The earlier Stage 2 roster had no
# identifiability guard: 2,847 of its 16,743 matched rows are unmatched,
# quarantined, or assigned to a DIFFERENT NPI under the guard, and 2,368 of
# those were receiving a county. Geography must not out-run identity.
FROZEN <- Sys.getenv("STAGE2_FROZEN",
                     file.path(ART, "amcb_npi_linkage_FROZEN.csv"))
# DEFECT 3. This defaulted to "midwives_geography.csv" while the artifact the
# whole project reads is artifacts/midwives_geography_FROZEN.csv. Because the
# real name appeared nowhere in the source, grepping the repository for it found
# only readers, and it was twice concluded that NOTHING writes this artifact --
# once in a merged PR. The default is now the real path, and the name is in the
# source where a search will find it.
GEO_OUT <- Sys.getenv("STAGE3_OUT",
                      file.path(ART, "midwives_geography_FROZEN.csv"))

# WHY THIS BLOCK EXISTS. Rebuilding this artifact took hours that it should not
# have, and every hour went to one of four defects here:
#
#   1. STAGE3_COORDS defaulted to midwives_geocoded.csv, which carries GEOID for
#      23.8% of rows. The build SUCCEEDED on it and produced county_exact 28.5%
#      against a published 98.8%. A wrong default that fails is an annoyance; a
#      wrong default that succeeds publishes a wrong number.
#   2. Nothing asserted the coordinate file was fit for purpose, so the 28.5%
#      surfaced only as a puzzling result, not as an error.
#   3. STAGE3_OUT defaults to "midwives_geography.csv" while the real artifact
#      is midwives_geography_FROZEN.csv, so no search of this repository for the
#      artifact name finds the script that writes it. It was twice concluded
#      that nothing produced it.
#   4. The invocation that produced the published artifact was recorded nowhere.
#      It was recovered by comparing GEOID fill rates across candidate files
#      against a percentage quoted in the README.
COORD_CANDIDATES <- c("midwives_panel_geocoded_enhanced.csv",
                      "midwives_panel_geocoded.csv",
                      "midwives_geocoded.csv")

coord_fitness <- function(path) {
  if (!file.exists(path)) return(NULL)
  d <- suppressWarnings(readr::read_csv(path, show_col_types = FALSE,
                                        progress = FALSE))
  has_xy <- all(c("latitude", "longitude") %in% names(d))
  list(rows = nrow(d),
       xy = if (has_xy) sum(!is.na(d$latitude) & !is.na(d$longitude)) else 0L,
       geoid = if ("GEOID" %in% names(d)) sum(!is.na(d$GEOID)) else 0L)
}

if (!nzchar(Sys.getenv("STAGE3_COORDS"))) {
  report <- vapply(COORD_CANDIDATES, function(p) {
    f <- coord_fitness(p)
    if (is.null(f)) sprintf("  %-44s (absent)", p)
    else sprintf("  %-44s %6d rows, %5.1f%% with coordinates, %5.1f%% with GEOID",
                 p, f$rows, 100 * f$xy / max(f$rows, 1),
                 100 * f$geoid / max(f$rows, 1))
  }, character(1))

  stop(paste0(
    "STAGE3_COORDS is not set, and this script will not guess.\n",
    "Its historical default (midwives_geocoded.csv) is NOT the file the\n",
    "published artifact was built from, and using it yields county_exact\n",
    "near 28% instead of 99% -- a build that succeeds and is wrong.\n\n",
    "Candidates on disk:\n", paste(report, collapse = "\n"), "\n\n",
    "The published artifact was built from the file with ~99% GEOID.\n",
    "Set it explicitly, e.g.\n",
    "  STAGE2_FROZEN=artifacts/amcb_npi_linkage_FROZEN.csv \\\n",
    "  STAGE3_COORDS=midwives_panel_geocoded_enhanced.csv \\\n",
    "  STAGE3_OUT=artifacts/midwives_geography_FROZEN.csv \\\n",
    "  Rscript R/03-geography-hierarchy.R"), call. = FALSE)
}
dir.create(ART, showWarnings = FALSE)

#' Two-digit state FIPS for a USPS state code
state_fips_of <- function(x) {
  lu <- distinct(tigris::fips_codes, state, state_code)
  lu$state_code[match(x, lu$state)]
}
pad_n <- function(x, n) str_pad(as.character(x), n, "left", "0")

#' ZIP -> county with the ambiguity retained
#'
#' Returns one row per ZIP carrying the county count and, when that count is 1,
#' the county. Multi-county ZIPs deliberately carry `GEOID = NA`: the caller
#' must not be able to reach a county for them by accident.
#'
#' @return [tibble] zip5, n_county, GEOID_unique, top_land_share.
#' @keywords internal
#' @noRd
#' Connecticut ZIP -> 2022 planning region, at the analysis vintage
#'
#' CT replaced its 8 counties with 9 planning regions in 2022, so the 2020
#' ZCTA-county relationship file emits 09001/09003/... while county_base.csv
#' (tigris 2023) holds 09110/09170/.... The two do not join.
#'
#' This is fixable EXACTLY rather than approximately. Per the Census Bureau
#' (quoted in ~/isochrones/data/external/ruca_tract_mapping_ct_planning_regions.README.md):
#' "There were no geographic changes to blocks or tracts between 2020 and 2022 --
#' only the FIPS codes changed." So a 2020 tract IS a 2022 tract; only its label
#' moved. Routing ZIP -> 2020 tract -> 2022 tract -> planning region is therefore
#' a relabelling, not a spatial approximation, and it preserves the multi-county
#' detection that a hand-coded old->new county lookup could not (planning regions
#' cross old county lines, so that mapping is not 1:1).
#'
#' @return [tibble] zip5, n_county, top_land_share, GEOID_unique for CT ZIPs.
#' @keywords internal
#' @noRd
zip_county_ct_2022 <- function() {
  zt <- file.path(DATA, "zcta_tract_2020.txt")
  xw <- file.path(DATA, "ct_tract_crosswalk_2022.csv")
  if (!file.exists(zt) || !file.exists(xw)) {
    cli::cli_alert_warning("CT vintage crosswalk inputs missing; CT ZIPs stay unresolved.")
    return(tibble(zip5 = character(), n_county = integer(),
                  top_land_share = numeric(), GEOID_unique = character()))
  }

  cross <- read_csv(xw, show_col_types = FALSE, progress = FALSE) %>%
    transmute(tract20 = pad_n(tract_fips_2020, 11),
              pr_geoid = pad5(ce_fips_2022)) %>%
    # CYCLE 5. distinct(tract20, .keep_all = TRUE) silently kept whichever row
    # sorted first when a tract mapped to two planning regions. It is a no-op on
    # the current crosswalk (verified: zero such tracts), which is exactly why it
    # needed stating -- the contract never guaranteed what the data happened to
    # provide, and the CT apportionment weights are built from this.
    distinct(tract20, pr_geoid)
  if (anyDuplicated(cross$tract20)) {
    stop(sprintf("tract->planning-region crosswalk is not a function: %d tract(s) map to more than one region.",
                 sum(duplicated(cross$tract20))), call. = FALSE)
  }

  read_delim(zt, delim = "|", show_col_types = FALSE, progress = FALSE) %>%
    filter(str_starts(GEOID_TRACT_20, "09")) %>%
    transmute(zip5 = pad5(GEOID_ZCTA5_20),
              tract20 = pad_n(GEOID_TRACT_20, 11),
              land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
    # cross is guaranteed unique on tract20 by the stop() above; declaring the
    # cardinality turns that invariant into a contract dplyr enforces.
    inner_join(cross, by = "tract20", relationship = "many-to-one") %>%
    group_by(zip5, pr_geoid) %>%
    # CYCLE 5, class N1. sum(land, na.rm = TRUE) scored a tract with missing
    # ALAND as 0 square metres, shrinking a density DENOMINATOR and inflating
    # every density computed from it. A group is NA when it has no land at all,
    # and reports its observed land otherwise, with the gap counted.
    summarise(land = if (all(is.na(land))) NA_real_ else sum(land, na.rm = TRUE),
              land_tracts_missing = sum(is.na(land)),
              .groups = "drop_last") %>%
    summarise(n_county = n(),
              top_land_share = max(land) / sum(land),
              GEOID_unique = if (n() == 1L) first(pr_geoid) else NA_character_,
              .groups = "drop")
}

zip_county_unique <- function() {
  f <- file.path(DATA, "zcta_county_2020.txt")
  if (!file.exists(f)) stop("Missing ", f, call. = FALSE)
  read_delim(f, delim = "|", show_col_types = FALSE, progress = FALSE) %>%
    filter(!is.na(GEOID_ZCTA5_20), !is.na(GEOID_COUNTY_20)) %>%
    transmute(zip5 = pad5(GEOID_ZCTA5_20), GEOID = pad5(GEOID_COUNTY_20),
              land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
    group_by(zip5) %>%
    summarise(n_county = n(),
              top_land_share = max(land) / sum(land),
              GEOID_unique = if (n() == 1L) first(GEOID) else NA_character_,
              .groups = "drop") -> base_zip

  # Replace CT wholesale with the planning-region derivation; the 2020 rows for
  # CT are not merely stale, they are unjoinable.
  #
  # BUG FIX: the first cut filtered on GEOID_unique starting "09", which misses
  # CT MULTI-county ZIPs -- those carry GEOID_unique = NA, so they survived the
  # filter and were then re-added by bind_rows(). That produced duplicate zip5
  # rows, a many-to-many join, and duplicated midwives downstream. Drop by ZIP
  # KEY, not by the county value.
  ct <- zip_county_ct_2022()
  base_zip %>%
    filter(!zip5 %in% ct$zip5) %>%
    bind_rows(ct) %>%
    distinct(zip5, .keep_all = TRUE)
}


# --- Structural invariants -------------------------------------------------
# A valid ZIP became attached to the WRONG PERSON in an earlier build. These
# guards target that mechanism -- key cardinality and identity invariance --
# not just its symptom (a state mismatch), because a silent many-to-many join
# followed by row reordering can attach any field to any person.

#' Abort unless a column is a unique key
#' @keywords internal
#' @noRd
assert_unique_key <- function(df, key, what) {
  n_dup <- sum(duplicated(df[[key]]))
  if (n_dup > 0) {
    stop(sprintf("INVARIANT: '%s' is not unique in %s (%d duplicates). A person-level join on a non-unique key attaches fields to the wrong person.",
                 key, what, n_dup), call. = FALSE)
  }
  invisible(TRUE)
}

#' Abort unless row count and the person-key SET are unchanged
#'
#' Set equality, not just count: a join can drop one person and duplicate
#' another, leaving nrow() identical while the cohort silently changes.
#' @keywords internal
#' @noRd
assert_identity_preserved <- function(after, spine, key, step) {
  if (nrow(after) != nrow(spine)) {
    stop(sprintf("INVARIANT: row count changed at '%s' (%d -> %d).",
                 step, nrow(spine), nrow(after)), call. = FALSE)
  }
  if (!setequal(after[[key]], spine[[key]])) {
    stop(sprintf("INVARIANT: person-key set changed at '%s'.", step), call. = FALSE)
  }
  invisible(TRUE)
}

build_geography <- function() {
  if (!file.exists(FROZEN)) {
    stop("Frozen Stage 2 roster not found: ", FROZEN,
         ". Run the matcher and freeze before Stage 3.", call. = FALSE)
  }
  roster <- read_csv(FROZEN, show_col_types = FALSE)
  # Stale downstream inputs have bitten this pipeline twice: coordinates from
  # one roster paired with ZIPs from another (94.47% validation failure), and
  # geography from the midwifery-only linkage reported as if it described
  # nursing-tier matches (1.7% "coverage"). Record which linkage produced this
  # geography so a consumer can refuse a mismatch instead of believing it.
  linkage_sha <- if (requireNamespace("digest", quietly = TRUE))
    digest::digest(file = FROZEN, algo = "sha256") else NA_character_
  # Verify the linkage BEFORE any geography work: if the file on disk is not
  # the frozen artifact the manifest describes, nothing downstream is valid.
  mf <- file.path(ART, "linkage_manifest.json")
  if (file.exists(mf) && requireNamespace("jsonlite", quietly = TRUE)) {
    want <- jsonlite::fromJSON(mf)$linkage_sha256
    if (!is.null(want) && !identical(want, linkage_sha)) {
      stop(sprintf(paste("Stage 3 refused: %s has sha256 %s but the frozen",
                         "manifest records %s. Geography must be built from the",
                         "frozen linkage, not whatever is on disk."),
                   FROZEN, substr(linkage_sha, 1, 16), substr(want, 1, 16)),
           call. = FALSE)
    }
    cat(sprintf("linkage SHA verified against frozen manifest: %s\n",
                substr(linkage_sha, 1, 16)))
  }
  # The guarded linkage names its geography columns nppes_*; the older Stage 2
  # roster used practice_*. Accept either so this stage is not coupled to one
  # upstream vintage.
  if (!"practice_zip" %in% names(roster) && "nppes_zip" %in% names(roster)) {
    roster <- roster %>% mutate(practice_zip = nppes_zip,
                                practice_state = nppes_state)
  }
  # Carry linkage provenance so county findings can be restricted or
  # stratified on it rather than silently pooling evidence tiers.
  if (!"match_status" %in% names(roster)) roster$match_status <- NA_character_
  if (!"match_resolution" %in% names(roster)) roster$match_resolution <- NA_character_
  # Coordinates MUST come from the same address the ZIP came from, or the
  # validation compares two different practice locations for one person and
  # scores the disagreement as error.
  GEO_IN <- Sys.getenv("STAGE3_COORDS")
  geo <- read_csv(GEO_IN, show_col_types = FALSE)

  # Fitness gate. The failure this catches is not a crash -- it is a build that
  # SUCCEEDS on a coordinate file most of whose rows have no usable position,
  # and quietly reports county_exact in the twenties. Refuse rather than
  # publish, and say the number that made the decision.
  MIN_COORD_COVERAGE <- as.numeric(Sys.getenv("STAGE3_MIN_COORD_COVERAGE", "0.75"))
  cov <- if (all(c("latitude", "longitude") %in% names(geo))) {
    mean(!is.na(geo$latitude) & !is.na(geo$longitude))
  } else 0
  if (cov < MIN_COORD_COVERAGE) {
    stop(sprintf(paste0(
      "STAGE3_COORDS=%s has usable coordinates for only %.1f%% of its %s rows ",
      "(floor %.0f%%).\n",
      "  A build on this file completes and reports a county_exact rate far ",
      "below the ~99%% this pipeline achieves,\n",
      "  which reads as a finding rather than a wrong input. Point ",
      "STAGE3_COORDS at the enhanced panel file,\n",
      "  or lower STAGE3_MIN_COORD_COVERAGE deliberately if you mean to build ",
      "on partial coordinates."),
      GEO_IN, 100 * cov, format(nrow(geo), big.mark = ","),
      100 * MIN_COORD_COVERAGE), call. = FALSE)
  }
  cli::cli_alert_info("STAGE3_COORDS={GEO_IN}: {format(nrow(geo), big.mark=',')} rows, {sprintf('%.1f%%', 100*cov)} with coordinates")
  # The analysis universe. A county GEOID absent from here is unusable no
  # matter how confidently it was derived.
  cb <- read_csv(file.path(DATA, "county_base.csv"), show_col_types = FALSE,
                 col_types = cols(GEOID = col_character()))

  coords <- geo %>%
    select(certification_number, latitude, longitude, GEOID_coord = GEOID,
           quality_score, geocode_match) %>%
    # CYCLE 5. A bare distinct() resolved conflicting geocodes for one
    # certificant by row order, which can place a person in a different
    # county -- the unit of every access finding here. Stated rule now:
    # the best quality_score wins.
    arrange(certification_number, dplyr::desc(quality_score)) %>%
    distinct(certification_number, .keep_all = TRUE)

  zc <- zip_county_unique()

  # The frozen roster is the ONLY spine. Prove the key before joining on it.
  roster <- roster %>% filter(!is.na(npi))
  assert_unique_key(roster, "certification_number", "frozen roster")
  assert_unique_key(coords, "certification_number", "coordinate evidence")
  spine <- roster

  # ADDRESS-LEVEL PROVENANCE: coordinates are only admissible if the address
  # they were generated FROM matches the pinned roster address. Joining on a
  # person key alone would re-import the original defect, where coordinates
  # derived from one identity were attached to another identity's ZIP.
  if (all(c("practice_zip", "practice_state") %in% names(geo))) {
    prov <- geo %>%
      select(certification_number, geo_zip = practice_zip,
             geo_state = practice_state) %>%
      distinct(certification_number, .keep_all = TRUE)
    bad_prov <- roster %>%
      select(certification_number, practice_zip, practice_state) %>%
      inner_join(prov, by = "certification_number",
                 relationship = "many-to-one") %>%
      mutate(rz = zip5_key(practice_zip),
             gz = zip5_key(geo_zip)) %>%
      filter((!is.na(rz) & !is.na(gz) & rz != gz) |
               (!is.na(practice_state) & !is.na(geo_state) &
                  practice_state != geo_state))
    if (nrow(bad_prov) > 0) {
      # CYCLE 19. The guard is CORRECT and is deliberately not relaxed. It was
      # investigated as a candidate for being over-strict, because it aborts the
      # whole stage on any string difference between the roster ZIP/state and
      # the address the coordinates were geocoded from.
      #
      # Classified against the ZCTA-county crosswalk, the disagreements break
      # down as follows. These are the STRICT per-ZIP counts and they match
      # artifacts/invariant_address_provenance_failures.csv exactly --
      # tests/test_cycle19_address_provenance.R (T194b) checks this comment
      # against that file, because a script that reports one number and writes
      # another is worse than no evidence at all.
      #
      #   8  land in a DIFFERENT STATE
      #   2  land in the SAME county (ZIP differs, county does not)
      #   4  ZIP spans several counties and cannot place the person at all
      #
      # 14 records in total.
      #
      # THESE NUMBERS CHANGED, AND THE REASON MATTERS. This comment previously
      # reported 1,163 disagreements (390 different-state, 175 different-county
      # same-state, 171 same-county, 427 unresolvable). That measurement was
      # taken against midwives_geocoded.csv, which was the WRONG coordinate
      # base -- it carried 23.8% GEOID coverage and produced county_exact of
      # 28.5% against a published 98.8%. Rebuilt on midwives_panel_geocoded.csv
      # (16,898 rows, the accepted set), the same invariant finds 14.
      #
      # So the 1,163 was very largely an artefact of comparing against the
      # wrong geocode table, not 1,163 real address conflicts. The 14 that
      # remain are real and still worth a look: 8 of them place a certificant
      # in a different STATE, which no rounding or ZIP-boundary story explains.
      #
      # Classification uses GEOID_unique, which is NA for a ZIP spanning several
      # counties. That is deliberate: such a ZIP genuinely cannot place a
      # person, so it is reported as unresolvable rather than assigned to
      # whichever county holds the most land.
      #
      # County is the unit of every access finding here, so this invariant is
      # not a string-matching nuisance. Loosening it to "same state is fine"
      # would wave through the 8 cross-state cases, which are the worst ones.
      bad_prov <- bad_prov %>%
        dplyr::left_join(dplyr::select(zc, zip5, .cty_r = GEOID_unique),
                         by = c("rz" = "zip5"), relationship = "many-to-one") %>%
        dplyr::left_join(dplyr::select(zc, zip5, .cty_g = GEOID_unique),
                         by = c("gz" = "zip5"), relationship = "many-to-one") %>%
        dplyr::mutate(county_impact = dplyr::case_when(
          is.na(.cty_r) | is.na(.cty_g)                      ~ "unresolvable_zip",
          .cty_r == .cty_g                                   ~ "same_county",
          substr(.cty_r, 1, 2) == substr(.cty_g, 1, 2)       ~ "different_county_same_state",
          TRUE                                               ~ "different_state")) %>%
        dplyr::select(-.cty_r, -.cty_g)
      impact <- sort(table(bad_prov$county_impact), decreasing = TRUE)
      write_with_provenance(bad_prov, file.path(ART, "invariant_address_provenance_failures.csv"), inputs = prov_inputs(file.path(DATA, "county_base.csv")))
      cli::cli_alert_danger(
        "address provenance failures by county impact: {paste(sprintf('%s=%d', names(impact), as.integer(impact)), collapse=', ')}")
      stop(sprintf("INVARIANT: %d records where the coordinate source's address disagrees with the pinned roster address. Coordinates and ZIP would describe different practices. See artifacts/invariant_address_provenance_failures.csv",
                   nrow(bad_prov)), call. = FALSE)
    }
  }

  m <- roster %>%
    left_join(coords, by = "certification_number", relationship = "one-to-one") %>%
    mutate(zip5 = zip5_key(practice_zip)) %>%
    left_join(zc, by = "zip5", relationship = "many-to-one")
  assert_identity_preserved(m, spine, "certification_number", "coords + zip join")

  m <- m %>%
    mutate(
      has_exact = !is.na(GEOID_coord),
      # VINTAGE GUARD (found by the validation check below): the ZCTA-county
      # relationship file is 2020, but county_base.csv is built from tigris
      # 2023. Connecticut replaced counties with PLANNING REGIONS in 2022, so
      # the crosswalk yields 09001/09003/... while the analysis universe holds
      # 09110/09170/... Those GEOIDs describe the same ground under two
      # vintages, but they do not join, and emitting them would silently drop
      # 189 Connecticut midwives at the county merge. A unique-ZIP county that
      # is not in the analysis universe is treated as unresolved, not assigned.
      zip_in_universe = GEOID_unique %in% cb$GEOID,
      has_uniq_zip = !is.na(GEOID_unique) & zip_in_universe,

      county_exact = GEOID_coord,

      county_best = case_when(
        has_exact    ~ GEOID_coord,
        has_uniq_zip ~ GEOID_unique,
        TRUE         ~ NA_character_),

      geo_source = case_when(
        has_exact                  ~ "coordinate",
        has_uniq_zip               ~ "zip_unique",
        # BEFORE zip_multi_county: a vintage-mismatched ZIP is unambiguous in
        # the crosswalk, so it would otherwise be mislabelled "ambiguous" and
        # two very different problems would be conflated in the class counts.
        !is.na(GEOID_unique) & !zip_in_universe ~ "zip_vintage_mismatch",
        !is.na(n_county)           ~ "zip_multi_county",
        !is.na(zip5) & zip5 != "NANANANAN" ~ "zip_not_in_crosswalk",
        TRUE                       ~ "no_geography"),

      geo_precision = case_when(
        geo_source == "coordinate"  ~ "point",
        geo_source == "zip_unique"  ~ "county",
        TRUE                        ~ "none"),

      # Ambiguity is recorded even for resolved rows: a coordinate row whose ZIP
      # spans counties is still worth flagging, because it is the population
      # where a future ZIP-based method would be least trustworthy.
      geo_ambiguity = case_when(
        is.na(n_county)   ~ "zip_unmapped",
        n_county == 1     ~ "unambiguous",
        top_land_share >= 0.8 ~ "multi_county_dominant",
        TRUE              ~ "multi_county_split"))

  # --- INVARIANTS: provenance and state consistency -------------------------
  # Added after 156 validation discordances traced to a MIXED-VINTAGE build:
  # ZIPs came from a guarded linkage that reassigns 2,847 rows to a different
  # NPI, while coordinates came from pre-guard geocoding. Same certification
  # number, two different people, so the ZIP and the coordinates described
  # different practices and the disagreement was scored as fallback error.
  # These fire BEFORE any county is emitted.
  fail <- list()

  # 1. Coordinates must belong to the same address the ZIP came from. Proxy:
  #    the geocoded source must carry the same ZIP for that person.
  if ("practice_zip" %in% names(geo)) {
    zchk <- m %>%
      select(certification_number, roster_zip = practice_zip) %>%
      inner_join(geo %>% select(certification_number, geo_zip = practice_zip) %>%
                   distinct(certification_number, .keep_all = TRUE),
                 by = "certification_number", relationship = "many-to-one") %>%
      mutate(rz = zip5_key(roster_zip),
             gz = zip5_key(geo_zip)) %>%
      filter(!is.na(rz), !is.na(gz), rz != gz)
    if (nrow(zchk) > 0) {
      fail$zip_provenance <- nrow(zchk)
      cli::cli_alert_danger(
        "INVARIANT FAILED: {nrow(zchk)} rows where the geocoded source's ZIP differs from the roster ZIP -- coordinates and ZIP describe different addresses.")
    }
  }

  # 2. State consistency. A ZIP may straddle a county line; it cannot straddle
  #    two states. Any cross-state disagreement is a build fault, not a
  #    precision limit, and must not receive a county.
  m <- m %>%
    mutate(st_addr = state_fips_of(practice_state),
           st_zip  = str_sub(GEOID_unique, 1, 2),
           st_cty  = str_sub(GEOID_coord, 1, 2),
           cross_state_fail =
             (!is.na(st_addr) & !is.na(st_zip) & st_addr != st_zip) |
             (!is.na(st_addr) & !is.na(st_cty) & st_addr != st_cty) |
             (!is.na(st_zip)  & !is.na(st_cty) & st_zip  != st_cty))

  n_cross <- sum(m$cross_state_fail, na.rm = TRUE)
  if (n_cross > 0) {
    fail$cross_state <- n_cross
    cli::cli_alert_danger("INVARIANT FAILED: {n_cross} cross-state disagreements.")
    write_with_provenance(m %>% filter(cross_state_fail) %>%
                select(certification_number, npi, practice_state, practice_zip,
                       GEOID_coord, GEOID_unique, st_addr, st_zip, st_cty),
              file.path(ART, "invariant_cross_state_failures.csv"), inputs = prov_inputs(file.path(DATA, "county_base.csv")))
  }

  # Fail closed: a record failing any invariant gets NO county.
  m <- m %>% mutate(
    county_exact = if_else(cross_state_fail %in% TRUE, NA_character_, county_exact),
    county_best  = if_else(cross_state_fail %in% TRUE, NA_character_, county_best),
    geo_source   = if_else(cross_state_fail %in% TRUE, "invariant_failure", geo_source))

  if (length(fail) > 0) {
    cli::cli_alert_danger(
      "VALIDATION FAILURE -- no completeness estimate may be emitted while these are unexplained: {paste(names(fail), unlist(fail), sep='=', collapse=', ')}")
  } else {
    cli::cli_alert_success("Invariants passed: provenance and state consistency clean.")
  }

  # --- Class counts --------------------------------------------------------
  classes <- m %>%
    mutate(geo_class = case_when(
      geo_source == "coordinate"       ~ "1_exact_coordinate",
      geo_source == "zip_unique"       ~ "2_unambiguous_zip_fallback",
      geo_source == "zip_multi_county" ~ "3_ambiguous_zip_unresolved",
      geo_source == "zip_vintage_mismatch" ~ "4_zip_vintage_mismatch",
      TRUE                             ~ "5_completely_unresolved")) %>%
    count(geo_class, name = "n") %>%
    mutate(pct = round(100 * n / sum(n), 1))

  cli::cli_h2("Geography classes (frozen Stage 2 matched roster, n = {nrow(m)})")
  print(as.data.frame(classes), row.names = FALSE)
  write_with_provenance(classes, file.path(ART, "geography_class_counts.csv"), inputs = prov_inputs(file.path(DATA, "county_base.csv")))

  cli::cli_alert_info(
    "county_exact resolved: {sum(!is.na(m$county_exact))} ({round(100*mean(!is.na(m$county_exact)),1)}%)")
  cli::cli_alert_info(
    "county_best  resolved: {sum(!is.na(m$county_best))} ({round(100*mean(!is.na(m$county_best)),1)}%)")

  # --- Internal validation: does unique-ZIP county agree with coordinates? --
  # Validation uses every row with BOTH sources, including vintage-mismatched
  # ones, so the raw figure is not flattered by excluding known-hard cases.
  val <- m %>% filter(has_exact, !is.na(GEOID_unique)) %>%
    mutate(agree = GEOID_coord == GEOID_unique,
           vintage_artifact = !zip_in_universe)

  n_val <- nrow(val); n_agree <- sum(val$agree)
  pct_agree <- 100 * n_agree / n_val
  # Wilson interval: the decision hinges on this number, so report it with
  # uncertainty rather than as a point estimate.
  z <- 1.96; p <- n_agree / n_val
  den <- 1 + z^2 / n_val
  ctr <- (p + z^2 / (2 * n_val)) / den
  hw <- z * sqrt(p * (1 - p) / n_val + z^2 / (4 * n_val^2)) / den

  cli::cli_h2("ZIP-fallback validation against exact geography")
  cli::cli_alert_info("RAW agreement {n_agree}/{n_val} = {round(pct_agree,2)}% (95% CI {round(100*(ctr-hw),2)}-{round(100*(ctr+hw),2)})")
  usable <- val %>% filter(!vintage_artifact)
  cli::cli_alert_info(
    "Excluding vintage-mismatched rows (which are never assigned a county): {sum(usable$agree)}/{nrow(usable)} = {round(100*mean(usable$agree),2)}%")

  disc <- val %>% filter(!agree)
  if (nrow(disc) > 0) {
    by_rucc <- disc %>% count(geo_ambiguity, name = "n_discordant")
    by_state <- disc %>% count(practice_state, sort = TRUE, name = "n") %>% head(8)
    by_tier <- disc %>% count(.data[[if ("match_tier" %in% names(disc)) "match_tier" else
                       "match_resolution"]], sort = TRUE, name = "n")
    cli::cli_h3("Discordant cases: {nrow(disc)}")
    print(as.data.frame(by_rucc), row.names = FALSE)
    print(as.data.frame(by_tier), row.names = FALSE)
    print(as.data.frame(by_state), row.names = FALSE)
    write_with_provenance(
      disc %>% select(certification_number, npi, practice_state, practice_zip,
                      GEOID_coord, GEOID_unique, quality_score, geocode_match,
                      any_of(c("match_tier", "match_resolution")), geo_ambiguity),
      file.path(ART, "zip_fallback_discordant.csv"), inputs = prov_inputs(file.path(DATA, "county_base.csv")))
  }

  write_with_provenance(tibble(n_validation = n_val, n_agree = n_agree,
                   pct_agree = pct_agree,
                   ci_low = 100 * (ctr - hw), ci_high = 100 * (ctr + hw)),
            file.path(ART, "zip_fallback_validation.csv"), inputs = prov_inputs(file.path(DATA, "county_base.csv")))

  out <- m %>%
    mutate(source_linkage = basename(FROZEN), source_linkage_sha256 = linkage_sha) %>%
    select(certification_number, npi, match_status, match_resolution,
           source_linkage, source_linkage_sha256,
           practice_state, practice_zip,
           latitude, longitude, quality_score, geocode_match,
           county_exact, county_best, geo_source, geo_precision, geo_ambiguity,
           zip_n_county = n_county, zip_top_land_share = top_land_share)
  # Cross-state failures are QUARANTINED (county set to NA above), so isolated
  # bad source rows -- a ZIP that genuinely straddles a state line like 42223
  # (Fort Campbell KY/TN), or a keying error such as an SD address with a TX
  # ZIP -- do not block the build. A systemic rate does: that signals an
  # assembly fault of the kind that produced 104 cross-state discordances, and
  # must abort. Structural failures (cardinality, identity, address
  # provenance) always abort; they have already stop()ped above.
  CROSS_STATE_ABORT_RATE <- 0.005
  cross_rate <- (fail$cross_state %||% 0) / nrow(m)
  if (cross_rate > CROSS_STATE_ABORT_RATE) {
    stop(sprintf("ABORTING: cross-state failure rate %.3f%% exceeds %.1f%% -- systemic assembly fault, not isolated source errors.",
                 100 * cross_rate, 100 * CROSS_STATE_ABORT_RATE), call. = FALSE)
  }
  if (!is.null(fail$cross_state)) {
    cli::cli_alert_warning(
      "{fail$cross_state} cross-state rows QUARANTINED (county = NA, geo_source = invariant_failure), rate {round(100*cross_rate,3)}% -- isolated source conflicts, build proceeds.")
    fail$cross_state <- NULL
  }
  if (length(fail) > 0 && !nzchar(Sys.getenv("ALLOW_INVARIANT_FAILURES"))) {
    stop(sprintf("ABORTING before writing %s: %s. Set ALLOW_INVARIANT_FAILURES=1 only to inspect a known-bad build.",
                 GEO_OUT, paste(names(fail), unlist(fail), sep = "=", collapse = ", ")),
         call. = FALSE)
  }
  assert_identity_preserved(out, spine, "certification_number", "final output")
  # Deterministic row order before writing, same defect and same fix as
  # enrich_amcb_crosswalk_geography.R: identical inputs produced identical rows
  # in a different order, so the sha256 recorded alongside this artifact could
  # never match a rebuild. A hash that changes when nothing changed says which
  # run happened, not which data was produced.
  #
  # certification_number is the spine's key -- assert_identity_preserved()
  # immediately above guarantees one row per certificant -- so it totally
  # orders the output and needs no tie-break.
  out <- out[order(out$certification_number), , drop = FALSE]

  # DEFECT 4. The sidecar recorded county_base.csv and nothing else -- not the
  # crosswalk this artifact is a projection of, not the coordinate file that
  # decided every county in it. So "which inputs produced this?" was
  # unanswerable, and recovering the invocation meant comparing GEOID fill
  # rates across candidate files against a percentage quoted in the README.
  #
  # Both are now recorded with their SHA-256, which is what makes the
  # STAGE2_FROZEN / STAGE3_COORDS pair reconstructable from the artifact alone.
  write_with_provenance(out, GEO_OUT, na = "",
                        inputs = c(prov_inputs(file.path(DATA, "county_base.csv")),
                                   FROZEN, GEO_IN))
  cli::cli_alert_success("{GEO_OUT} written ({nrow(out)} rows)")

  # Ascertainment by linkage status: a county attached to a fuzzy or
  # unconfirmed link is not the same evidence as one attached to a uniquely
  # identified person, and pooling them hides that.
  if (any(!is.na(out$match_status))) {
    by_status <- out %>%
      group_by(match_status) %>%
      # NB: compute the percentage BEFORE rebinding the column names, or
      # summarise() sees the scalar count it just assigned and every row
      # reports 100%.
      summarise(n = n(),
                pct_best      = round(100 * mean(!is.na(county_best)), 1),
                pct_exact     = round(100 * mean(!is.na(county_exact)), 1),
                n_county_best = sum(!is.na(county_best)),
                n_county_exact = sum(!is.na(county_exact)),
                .groups = "drop") %>%
      arrange(desc(n))
    print(as.data.frame(by_status))
    write_with_provenance(by_status, file.path(ART, "geography_by_linkage_status.csv"), inputs = prov_inputs(file.path(DATA, "county_base.csv")))
  }

  # The gate the instructions asked for: coverage is not evidence, agreement is.
  if (pct_agree < 95) {
    cli::cli_alert_danger(
      "Agreement {round(pct_agree,2)}% is below 95%: ZIP fallback is NOT validated. Do not treat county_best as the primary geography until the discordance is explained.")
  } else {
    cli::cli_alert_success(
      "Agreement {round(pct_agree,2)}%: unique-ZIP county reproduces coordinate-derived county empirically, not merely by logical argument.")
  }

  invisible(list(data = out, classes = classes, agreement = pct_agree))
}

if (identical(environment(), globalenv()) && !interactive()) build_geography()
