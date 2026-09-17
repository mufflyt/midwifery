# =============================================================================
# Where a midwife's work sites are, and how they fit together
# =============================================================================
# build_trilliant_work_sites.R produces one row per midwife x site x source.
# Rows are not places: the Trilliant claims site, an NPPES address and a CMS
# hospital affiliation can all be the same building. And before this file,
# only the Trilliant site carried coordinates, so no site had a rurality.
#
# Everything here is pure (no I/O) so it can be tested on fixtures:
#   county_key() / match_county()   Trilliant's county NAME -> county GEOID
#   haversine_km()                  distance between two sites
#   assign_site_ids()               source rows -> distinct physical sites
#   blended_practice()              hospital + birth-center practice, strict and broad
#   topology_by_midwife()           one row per midwife: sites, settings, spread, rurality
#
# Rurality uses the repository's own bands (band_rurality(),
# RURALITY_LABELS_COHORT in R/lib/table1_bands.R) on RUCC 2023 from
# data/county_base.csv, so a work site's rurality means what the cohort
# papers' rurality means.
# =============================================================================

#' Normalise a county name for matching
#'
#' Accents, punctuation and hyphens go; "Saint" becomes "St"; Trilliant's
#' Connecticut planning-region abbreviations ("CT", "VLY") are expanded.
#' "City" is KEPT: Richmond city (51760) and Richmond County (51159) are
#' different places that differ only in that word.
#' @param x [character]
county_key <- function(x) {
  # macOS iconv transliterates "ñ" to "~n" and glibc to "n"; dropping the
  # marks it can leave behind makes both give "n".
  x <- iconv(as.character(x), to = "ASCII//TRANSLIT", sub = "")
  x <- gsub("[~^`\"]", "", x)
  x <- tolower(x)
  x <- gsub("[.'`’]", "", x)
  x <- gsub("-", " ", x)
  x <- gsub("\\bsaint\\b", "st", x)
  x <- gsub("\\bsainte\\b", "ste", x)
  x <- gsub("\\bnw\\b", "northwest", x)
  x <- gsub("\\bct\\b", "connecticut", x)
  x <- gsub("\\bvly\\b", "valley", x)
  x <- gsub("\\s+", " ", x)
  trimws(x)
}

#' Match keys for every county in data/county_base.csv
#'
#' `full` is the ACS name without its state ("richmond city", "richmond
#' county"); `base` drops a county-type suffix but never "city".
#' @param county_base [data.frame] GEOID, state, acs_name
county_match_keys <- function(county_base) {
  full <- county_key(sub(",.*$", "", county_base$acs_name))
  base <- sub(" (city and borough|census area|planning region|municipality|county|parish|borough)$", "", full)
  data.frame(GEOID = county_base$GEOID, state = county_base$state, full = full, base = base,
             stringsAsFactors = FALSE)
}

#' County GEOID from a county name and state
#'
#' In order, each tier only if the previous found nothing and each hit must
#' be unique in the state: the full ACS name; the suffix-stripped name; the
#' name plus " city" (Trilliant writes Salem city, VA as "SALEM", and Virginia
#' has no Salem County); the name with spaces removed (LA SALLE / LaSalle, LA
#' PORTE / LaPorte). Anything else is NA -- never a guess; callers fall back to
#' the ZIP crosswalk.
#' @param name,state [character] parallel vectors
#' @param keys [data.frame] from county_match_keys()
#' @return [character] GEOID or NA
match_county <- function(name, state, keys) {
  k <- county_key(name)
  out <- rep(NA_character_, length(k))
  for (i in seq_along(k)) {
    if (is.na(k[i]) || !nzchar(k[i]) || is.na(state[i])) next
    s <- keys[keys$state == state[i], , drop = FALSE]
    tiers <- list(s$full == k[i], s$base == k[i], s$full == paste(k[i], "city"),
                  gsub(" ", "", s$base) == gsub(" ", "", k[i]))
    for (t in tiers) {
      hit <- s$GEOID[t]
      if (length(hit) == 1L) { out[i] <- hit; break }
      if (length(hit) > 1L) break          # ambiguous at this tier: stop, do not fall through
    }
  }
  out
}

#' Great-circle distance in kilometres
haversine_km <- function(lat1, lon1, lat2, lon2) {
  rad <- pi / 180
  dlat <- (lat2 - lat1) * rad
  dlon <- (lon2 - lon1) * rad
  a <- sin(dlat / 2)^2 + cos(lat1 * rad) * cos(lat2 * rad) * sin(dlon / 2)^2
  6371.0088 * 2 * atan2(sqrt(a), sqrt(pmax(0, 1 - a)))
}

#' Collapse source rows into distinct physical sites
#'
#' Two rows are one site when they share rounded coordinates (4 decimal
#' places, about 11 m) OR the same normalised street + ZIP. The link is
#' transitive -- a row with coordinates and an address joins rows known by
#' either -- so this is connected components, computed within each midwife.
#' Rows with neither key are their own site. IDs are deterministic: the sites
#' are numbered by the sorted keys they contain.
#' @param midwife [character] one per row
#' @param lat,lon [numeric] NA allowed
#' @param street_norm,zip5 [character] NA allowed
#' @return [character] "<midwife>#<n>"
assign_site_ids <- function(midwife, lat, lon, street_norm, zip5) {
  n <- length(midwife)
  ll <- ifelse(!is.na(lat) & !is.na(lon), sprintf("ll:%.4f,%.4f", round(lat, 4), round(lon, 4)), NA_character_)
  ad <- ifelse(!is.na(street_norm) & nzchar(street_norm) & !is.na(zip5) & nzchar(zip5),
               paste0("ad:", street_norm, "|", zip5), NA_character_)
  parent <- seq_len(n)
  find <- function(i) { while (parent[i] != i) i <- parent[i]; i }
  for (key in list(ll, ad)) {
    has_key <- !is.na(key)
    for (g in split(which(has_key), paste(midwife[has_key], key[has_key]))) {
      if (length(g) < 2L) next
      r <- vapply(g, find, integer(1))
      parent[r] <- min(r)
    }
  }
  root <- vapply(seq_len(n), find, integer(1))
  # A component is named by the smallest key any of its rows carries, so the
  # numbering does not depend on row order. A row with no key stands alone.
  rowkey <- pmin(ll, ad, na.rm = TRUE)
  rowkey[is.na(rowkey)] <- sprintf("zz:row%07d", which(is.na(rowkey)))
  label <- tapply(rowkey, root, min)[as.character(root)]
  num <- ave(seq_len(n), midwife, FUN = function(i) match(label[i], sort(unique(label[i]))))
  paste0(midwife, "#", num)
}

#' Hospital + birth-center practice, strict and broad
#'
#' STRICT needs evidence beyond a name. Hospital: a CMS Doctors & Clinicians
#' facility affiliation, or the Trilliant claims site resolved to a hospital
#' CCN. Birth center: CABC accreditation, or a site whose Trilliant
#' organization match or building carries the birthing-center taxonomy.
#' BROAD accepts any work-site row typed as either, including by name.
#' Employer rows (billing organizations) never count: they say who pays a
#' midwife, not where the midwife works.
#' @param sites [data.frame] certification_number, source, facility_type,
#'   facility_type_basis, ccn -- workplace rows only
#' @return [data.frame] one row per certification_number
blended_practice <- function(sites) {
  s <- sites[!sites$source %in% c("trilliant_primary_org", "resolved_employer_org"), , drop = FALSE]
  hosp_strict <- s$facility_type == "hospital" &
    (s$source == "cms_dac_facility_affiliation" |
       (s$source == "trilliant_claims_top_site" & !is.na(s$ccn) & nzchar(s$ccn)))
  bc_strict <- s$facility_type == "birth_center" &
    (s$source == "cabc_birth_center" |
       s$facility_type_basis %in% c("named_org_match", "building_at_address"))
  agg <- function(v) tapply(v, s$certification_number, any)
  out <- data.frame(
    certification_number = sort(unique(s$certification_number)), stringsAsFactors = FALSE)
  out$hospital_strict     <- as.logical(agg(hosp_strict)[out$certification_number])
  out$birth_center_strict <- as.logical(agg(bc_strict)[out$certification_number])
  out$hospital_broad      <- as.logical(agg(s$facility_type == "hospital")[out$certification_number])
  out$birth_center_broad  <- as.logical(agg(s$facility_type == "birth_center")[out$certification_number])
  out$blended_strict <- out$hospital_strict & out$birth_center_strict
  out$blended_broad  <- out$hospital_broad & out$birth_center_broad
  out
}

#' One row per midwife: distinct sites, settings, spread and rurality
#'
#' @param sites [data.frame] workplace rows with certification_number, site_id,
#'   source, facility_type, lat, lon, GEOID, rucc_cat
#' @return [data.frame]
topology_by_midwife <- function(sites) {
  s <- sites[!sites$source %in% c("trilliant_primary_org", "resolved_employer_org") & !is.na(sites$site_id), , drop = FALSE]
  by <- split(s, s$certification_number)
  rows <- lapply(names(by), function(m) {
    d <- by[[m]]
    one <- d[!duplicated(d$site_id), , drop = FALSE]
    xy <- one[!is.na(one$lat) & !is.na(one$lon), , drop = FALSE]
    spread <- if (nrow(xy) >= 2L) {
      p <- utils::combn(nrow(xy), 2)
      max(haversine_km(xy$lat[p[1, ]], xy$lon[p[1, ]], xy$lat[p[2, ]], xy$lon[p[2, ]]))
    } else if (nrow(xy) == 1L) 0 else NA_real_
    settings <- sort(unique(d$facility_type[d$facility_type %in% c("hospital", "birth_center", "fqhc_community_health", "clinic_practice", "other_facility")]))
    rur <- unique(stats::na.omit(one$rucc_cat[one$rucc_cat != "Unknown"]))
    data.frame(
      certification_number = m,
      n_distinct_sites = length(unique(d$site_id)),
      n_sites_with_coordinates = nrow(xy),
      n_distinct_settings = length(settings),
      setting_combination = if (length(settings)) paste(settings, collapse = " + ") else "no classified site",
      max_km_between_sites = spread,
      n_distinct_counties = length(unique(stats::na.omit(one$GEOID))),
      rurality_mix = if (!length(rur)) "unknown" else if (length(rur) == 1L) rur else "mixed",
      stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
