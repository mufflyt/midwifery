#!/usr/bin/env Rscript
# =============================================================================
# Shared provider definitions for the obstetric workforce comparisons
# =============================================================================
# WHY THIS FILE EXISTS. The first district analysis compared midwives to the
# ABOG SUBSPECIALIST cohort (MFM/REI/GO/FPMRS/MIGS/CFP/PAG). That comparison is
# not meaningful: a gynecologic oncologist or a reproductive endocrinologist
# does not provide routine intrapartum care, so a midwife-to-subspecialist ratio
# does not describe the workforce attending births. Two defensible comparators
# replace it:
#
#   GENERALIST  general OB/GYN diplomates -- the clinically correct comparator
#               for midwives, since both attend routine births.
#   MFM         maternal-fetal medicine only -- the one subspecialty that IS
#               involved in intrapartum care, as the referral tier above both.
#
# The remaining subspecialties (REI, GO, FPMRS, MIGS, CFP, PAG) are loaded but
# should NOT be summed with midwives into an "obstetric workforce" total.
#
# GENERALIST COVERAGE IS PARTIAL AND THE SHORTFALL IS NOT RANDOM.
# canonical_abog_npi_LATEST.csv holds 50,556 generalists; only 28,512 have been
# geocoded (56.4%). The ungeocoded lack a usable practice address, which
# correlates with certification vintage and practice setting -- so generalist
# counts are a FLOOR, and district-level generalist rates are downward-biased by
# an unknown, non-uniform amount. Every consumer of these counts must say so.
# AHRF's county md_nf_obgyn_gen_23 is a complete count and should be preferred
# wherever county geography suffices.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

ISO <- path.expand("~/isochrones")

load_generalists <- function(verbose = TRUE) {
  # The canonical ABOG roster is the DENOMINATOR: every generalist who should
  # have a coordinate, so that missingness is measurable rather than implied by
  # whatever happens to be in a geocoded file.
  roster <- read_csv(file.path(ISO, "canonical_abog_npi_LATEST.csv"),
                     show_col_types = FALSE) %>%
    filter(subspecialty == "Generalist") %>%
    mutate(npi = as.character(npi)) %>%
    distinct(npi, .keep_all = TRUE)

  # Two existing geocode outputs, in quality order. The dedicated general-OB
  # run is preferred where it exists; the 80k cohort file fills the rest. No
  # geocoder is invoked here -- these coordinates were produced by the project's
  # own geocoding pipeline and are reused, not regenerated.
  f <- file.path(ISO, "data/04-geocode/output",
                 "geocoded_general_obgyns_20260227_131734_fixed.csv")
  stopifnot(file.exists(f))
  primary <- read_csv(f, show_col_types = FALSE) %>%
    filter(!is.na(lat), !is.na(lon)) %>%
    mutate(npi = as.character(npi)) %>%
    distinct(npi, .keep_all = TRUE) %>%
    transmute(npi, lat, lon, coord_source = "general_obgyn_geocode")

  k <- readRDS(file.path(ISO, "data/entire_80k_cohort_geocoded.rds")) %>%
    filter(!is.na(latitude), !is.na(longitude)) %>%
    mutate(npi = as.character(npi)) %>%
    distinct(npi, .keep_all = TRUE) %>%
    transmute(npi, lat = latitude, lon = longitude,
              # city_centroid is a materially weaker geocode than a rooftop or
              # street match; it is kept but labelled so a sensitivity analysis
              # can exclude it.
              coord_source = paste0("cohort80k:", geocode_method))

  # Third and weakest tier: city centroids for generalists no real geocode
  # covers. Included so district counts are complete, but tagged so any
  # travel-time or precision-sensitive use can drop them with one filter.
  cc_f <- "artifacts/generalist_residual_city_centroids.csv"
  cc <- if (file.exists(cc_f)) {
    read_csv(cc_f, show_col_types = FALSE) %>%
      mutate(npi = as.character(npi)) %>%
      transmute(npi, lat = latitude, lon = longitude, coord_source = "city_centroid")
  } else NULL

  coords <- bind_rows(primary,
                      k  %>% filter(!npi %in% primary$npi),
                      cc %>% filter(!npi %in% primary$npi, !npi %in% k$npi))
  x <- roster %>% inner_join(coords, by = "npi")

  # The two ABOG sources disagree about 88 physicians: canonical labels them
  # "Generalist" while the curated subspecialist cohort lists them with a
  # subspecialty (32 of them MFM). Left alone they would be counted twice --
  # once in n_general_obgyn and once in n_mfm -- and birth_attendants would be
  # inflated. The subspecialist cohort wins, because it was built from billing
  # and procedure evidence of what the physician actually practises, whereas the
  # canonical label is a certification default. Removing them from the
  # generalist side keeps the two groups disjoint.
  sub_npi <- readRDS(file.path(ISO, "artifacts/isochrones/step_2.5_final_cohort.rds")) %>%
    as_tibble() %>% pull(npi) %>% as.character()
  n_dup <- sum(x$npi %in% sub_npi)
  if (n_dup && verbose)
    cat(sprintf("[generalists] removed %s also present in the subspecialist cohort\n",
                n_dup))
  x <- x %>% filter(!npi %in% sub_npi)
  if (verbose) {
    n_miss <- nrow(roster) - nrow(x)
    cat(sprintf("[generalists] roster %s | coordinates %s (%.1f%%) | missing %s\n",
                nrow(roster), nrow(x), 100 * nrow(x) / nrow(roster), n_miss))
    print(x %>% count(coord_source, sort = TRUE) %>% as.data.frame(), row.names = FALSE)
  }
  # APO/AE/AP military addresses geocode to Europe and the Pacific. They are
  # dropped by bounding box rather than by state code so that genuine territory
  # addresses (GU, VI, MP, PR) survive and land in their delegate districts.
  keep <- x$lat >= 17 & x$lat <= 72 & x$lon >= -180 & x$lon <= -64
  n_drop <- sum(!keep)
  if (n_drop) cat(sprintf("[generalists] dropped %s out-of-US-bbox coordinates\n", n_drop))
  x[keep, ] %>% transmute(id = as.character(npi), latitude = lat, longitude = lon,
                          group = "generalist", coord_source)
}

load_subspecialists <- function(which = NULL) {
  f <- file.path(ISO, "artifacts/isochrones/step_2.5_final_cohort.rds")
  stopifnot(file.exists(f))
  x <- readRDS(f) %>% as_tibble() %>%
    filter(!is.na(latitude), !is.na(longitude)) %>%
    distinct(npi, .keep_all = TRUE)
  if (!is.null(which)) x <- x %>% filter(subspecialty_normalized %in% which)
  x %>% transmute(id = as.character(npi), latitude, longitude,
                  group = subspecialty_normalized)
}

#' Coordinate fitness is enforced by mufflyaccess::assert_travel_time_eligible().
#'
#' This file used to define its own copy. It now lives in the SSOT package
#' beside the other assertions, so callers in any repo get the same guard --
#' and so a fix to it is a fix everywhere rather than a fix here only.
assert_travel_time_eligible <- mufflyaccess::assert_travel_time_eligible

load_midwives <- function() {
  link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
  crd  <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
  link %>%
    filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    distinct(certification_number) %>%
    left_join(crd %>% select(certification_number, latitude, longitude),
              by = "certification_number") %>%
    filter(!is.na(latitude), !is.na(longitude)) %>%
    transmute(id = certification_number, latitude, longitude, group = "midwife")
}
