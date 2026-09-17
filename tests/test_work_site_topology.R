#!/usr/bin/env Rscript
# =============================================================================
# Work-site geography and topology: R/lib/work_site_topology.R
# =============================================================================
# Three ways this goes wrong without anyone noticing: a county NAME maps to the
# wrong county (Richmond city vs Richmond County, VA -- one word apart, one
# metropolitan and one not); the same building seen by two sources is counted
# as two workplaces; and a birth center identified only by its name is
# reported as strong evidence of hospital + birth-center practice.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "work_site_topology.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

cb <- data.frame(
  GEOID = c("51159", "51760", "29189", "29510", "35013", "02170", "02110", "09110", "09130", "08031", "24005", "24510",
            "51775", "17099", "18091", "29186", "09160"),
  state = c("VA", "VA", "MO", "MO", "NM", "AK", "AK", "CT", "CT", "CO", "MD", "MD", "VA", "IL", "IN", "MO", "CT"),
  acs_name = c("Richmond County, Virginia", "Richmond city, Virginia", "St. Louis County, Missouri",
               "St. Louis city, Missouri", "Doña Ana County, New Mexico", "Matanuska-Susitna Borough, Alaska",
               "Juneau City and Borough, Alaska", "Capitol Planning Region, Connecticut",
               "Lower Connecticut River Valley Planning Region, Connecticut", "Denver County, Colorado",
               "Baltimore County, Maryland", "Baltimore city, Maryland", "Salem city, Virginia",
               "LaSalle County, Illinois", "LaPorte County, Indiana", "Ste. Genevieve County, Missouri",
               "Northwest Hills Planning Region, Connecticut"),
  stringsAsFactors = FALSE)
keys <- county_match_keys(cb)
m <- function(name, st) match_county(name, st, keys)

cat("\n-- COUNTY NAME -> GEOID --\n")
chk(m("RICHMOND CITY", "VA") == "51760", "T1 RICHMOND CITY is the independent city (51760)")
chk(m("RICHMOND", "VA") == "51159", "T2 RICHMOND is the county (51159), not the city")
chk(m("SAINT LOUIS CITY", "MO") == "29510", "T3 SAINT LOUIS CITY -> St. Louis city")
chk(m("ST LOUIS", "MO") == "29189", "T4 ST LOUIS -> St. Louis County")
chk(m("DONA ANA", "NM") == "35013", "T5 an accent in the Census name does not block the match")
chk(m("MATANUSKA SUSITNA", "AK") == "02170", "T6 a hyphenated borough matches its spaced spelling")
chk(m("JUNEAU", "AK") == "02110", "T7 'City and Borough' is a suffix, not part of the name")
chk(m("CAPITOL", "CT") == "09110", "T8 a Connecticut planning region by its short name")
chk(m("LOWER CT RIVER VLY", "CT") == "09130", "T9 Trilliant's CT abbreviations expand to the Census name")
chk(m("BALTIMORE CITY", "MD") == "24510" && m("BALTIMORE", "MD") == "24005", "T10 Baltimore city vs Baltimore County")
chk(is.na(m("NOWHERE", "CO")), "T11 an unknown name is NA, not a guess")
chk(m("SALEM", "VA") == "51775", "T11a SALEM, VA is Salem city (no Salem County exists to confuse it with)")
chk(m("LA SALLE", "IL") == "17099" && m("LA PORTE", "IN") == "18091", "T11b spacing differences (LA SALLE / LaSalle)")
chk(m("SAINTE GENEVIEVE", "MO") == "29186", "T11c Sainte -> Ste.")
chk(m("NW HILLS", "CT") == "09160", "T11d Trilliant's NW HILLS is Northwest Hills")
chk(is.na(m("DENVER", "VA")), "T12 a name is only matched within its own state")
chk(is.na(m(NA, "CO")) && is.na(m("DENVER", NA)), "T13 a missing name or state is NA")

cat("\n-- DISTANCE --\n")
chk(abs(haversine_km(39.7392, -104.9903, 40.0150, -105.2705) - 38.6) < 1, "T14 Denver to Boulder is about 39 km")
chk(haversine_km(39.7, -105, 39.7, -105) == 0, "T15 a site is 0 km from itself")

cat("\n-- DISTINCT SITES --\n")
ids <- assign_site_ids(
  midwife     = c("M1", "M1", "M1", "M1", "M2", "M1"),
  lat         = c(39.72829, NA, 39.72829, 40.01, 39.72829, NA),
  lon         = c(-104.99052, NA, -104.99052, -105.27, -104.99052, NA),
  street_norm = c("777 bannock st", "777 bannock st", NA, NA, "777 bannock st", NA),
  zip5        = c("80204", "80204", NA, NA, "80204", NA))
chk(length(unique(ids[1:3])) == 1L, "T16 coordinates or address link rows into one site, transitively")
chk(ids[4] != ids[1], "T17 a different location is a different site")
chk(!startsWith(ids[5], "M1"), "T18 two midwives at one building have separate site ids")
chk(ids[6] != ids[1] && ids[6] != ids[4], "T19 a row with no coordinates and no address is its own site")
perm <- c(6, 4, 2, 5, 3, 1)
ids2 <- assign_site_ids(c("M1", "M1", "M1", "M1", "M2", "M1")[perm],
                        c(39.72829, NA, 39.72829, 40.01, 39.72829, NA)[perm],
                        c(-104.99052, NA, -104.99052, -105.27, -104.99052, NA)[perm],
                        c("777 bannock st", "777 bannock st", NA, NA, "777 bannock st", NA)[perm],
                        c("80204", "80204", NA, NA, "80204", NA)[perm])
chk(identical(ids2, ids[perm]), "T20 site ids do not depend on row order")
chk(ids[1] != ids[4] && length(unique(ids[ids != ids[6] & startsWith(ids, "M1")])) == 2L,
    "T21 M1 has three distinct sites: the building, the second location, the unkeyed row")

cat("\n-- BLENDED HOSPITAL + BIRTH CENTER --\n")
s <- data.frame(
  certification_number = c("A", "A", "B", "B", "C", "C", "D", "D"),
  source = c("cms_dac_facility_affiliation", "cabc_birth_center",
             "trilliant_claims_top_site", "nppes_primary_location",
             "trilliant_claims_top_site", "trilliant_primary_org",
             "nppes_primary_location", "nppes_secondary_location"),
  facility_type = c("hospital", "birth_center", "hospital", "birth_center",
                    "hospital", "birth_center", "hospital", "birth_center"),
  facility_type_basis = c("cms_dac_facility_affiliation_file", "cabc_accreditation",
                          "site_name_pattern", "site_name_pattern",
                          "named_org_match", "name_pattern",
                          "building_at_address", "building_at_address"),
  ccn = c("060011", NA, "060011", NA, NA, NA, NA, NA), stringsAsFactors = FALSE)
b <- blended_practice(s)
blend_flag <- function(id, col) b[[col]][b$certification_number == id]
chk(blend_flag("A", "blended_strict"), "T22 DAC hospital + CABC birth center is strict")
chk(!blend_flag("B", "blended_strict") && blend_flag("B", "blended_broad"),
    "T23 a birth center known only by its name is broad, not strict")
chk(blend_flag("B", "hospital_strict"), "T24 the Trilliant claims site with a hospital CCN is a strict hospital")
chk(!blend_flag("C", "birth_center_broad"), "T25 an employer's name never counts as a work site")
chk(!blend_flag("D", "hospital_strict") && blend_flag("D", "birth_center_strict") && blend_flag("D", "blended_broad"),
    "T26 an NPPES address in a hospital building is broad hospital evidence only")

cat("\n-- ONE ROW PER MIDWIFE --\n")
t <- data.frame(
  certification_number = c("A", "A", "A", "B"),
  site_id = c("A#1", "A#1", "A#2", "B#1"),
  source = c("trilliant_claims_top_site", "nppes_primary_location", "cabc_birth_center", "trilliant_claims_top_site"),
  facility_type = c("hospital", "hospital", "birth_center", "clinic_practice"),
  lat = c(39.7392, 39.7392, 40.0150, 39.7), lon = c(-104.9903, -104.9903, -105.2705, -105),
  GEOID = c("08031", "08031", "08013", "08031"),
  rucc_cat = c("Metro (RUCC 1-3)", "Metro (RUCC 1-3)", "Nonmetro, adjacent (4-6)", "Metro (RUCC 1-3)"),
  stringsAsFactors = FALSE)
tp <- topology_by_midwife(t)
ta <- tp[tp$certification_number == "A", ]
chk(ta$n_distinct_sites == 2L, "T27 two source rows at one building count as one site")
chk(ta$setting_combination == "birth_center + hospital", "T28 the setting combination is listed")
chk(abs(ta$max_km_between_sites - 38.6) < 1, "T29 the spread is the largest distance between sites")
chk(ta$rurality_mix == "mixed" && ta$n_distinct_counties == 2L, "T30 metro + nonmetro sites are 'mixed'")
chk(tp$max_km_between_sites[tp$certification_number == "B"] == 0, "T31 a single-site midwife has 0 km spread")

cat(if (fails) sprintf("\nFAILURES (%d)\n", fails) else "\nPASS (0 failures)\n")
quit(status = if (fails) 1L else 0L)
