#!/usr/bin/env Rscript
# =============================================================================
# Where do the cohort's midwives work?  Trilliant claims + NPPES + CMS + CABC
# =============================================================================
# R / duckplyr version of build_sites.sql. The large Trilliant tables are read
# with duckplyr (DuckDB underneath, dplyr verbs on top) and cut down to the
# rows we need before anything is pulled into R. Everything after that is
# ordinary dplyr and stringr. There is no SQL in this file.
#
# What each source contributes:
#   Trilliant directory_provider   the midwife's main practice site from claims
#                                  (snapshot 2026-06-25), share of visits there,
#                                  number of practice sites, billing organization
#   Trilliant directory_organization  every organization NPI at a street address,
#                                  with CMS facility type and NPI taxonomy; used
#                                  to decide whether a site is a hospital, birth
#                                  center, FQHC or clinic
#   NPPES practice locations       the midwife's self-reported primary/secondary address
#   CMS DAC facility affiliation   hospitals CMS lists for the midwife (Medicare billers)
#   CABC                           accredited birth centers matched to the midwife
#   CMS hospital enrollments /     hospital CCN, so a hospital site can be linked
#   hospital universe / MRF crosswalk  to that hospital's price-transparency file
#
# Inputs:
#   Trilliant DuckLake on the Samsung volume   hpt_prices/trilliant/20260721/lake (TRILLIANT_LAKE)
#   hpt_prices reference files, same volume    hpt_prices/reference, hpt_prices/crosswalk (HPT_PRICES)
#   artifacts/amcb_npi_linkage_FROZEN.csv, midwife_practice_locations.csv,
#   dac_facility_affiliations.csv, cabc_matched_midwives_final.csv,
#   organization_affiliation_resolved.csv   (person-level, gitignored; MIDWIFERY_ARTIFACTS)
#
# Outputs:
#   artifacts/midwife_work_sites_long.csv                    person-level, gitignored
#       one row per midwife x site x source
#   artifacts/midwife_work_sites_summary.csv                 person-level, gitignored
#       one row per midwife
#   artifacts/midwife_work_sites_excluded_non_workplace.csv  person-level, gitignored
#       labs, pathology, pharmacy, ambulance, imaging: where orders were filled
#   artifacts/midwife_work_setting_summary.csv               aggregate, tracked
#       counts of midwives by main-site type and by combination of settings
#
# Trilliant's data are licensed; nothing person-level from it is tracked.
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr)
  library(dplyr)
  library(stringr)
  library(readr)
  library(stringdist)
})
source(file.path("R", "lib", "common_helpers.R"))       # chr(), pad_ccn()
source(file.path("R", "lib", "medicare_duckdb.R"))      # samsung_volume_path()
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()
source(file.path("R", "lib", "cohort_definitions.R"))   # verify_linkage_freeze(), canonical_active_primary()
source(file.path("R", "lib", "work_site_topology.R"))   # match_county(), assign_site_ids(), blended_practice(), topology_by_midwife()
source(file.path("R", "lib", "table1_bands.R"))         # band_rurality(), RURALITY_LABELS_COHORT
source(file.path("R", "lib", "zip_county_crosswalk.R")) # zip_county_dominant()
source(file.path("R", "lib", "ct_county_crosswalk.R"))  # ct_zip_to_region()

# ---- paths -------------------------------------------------------------------
# The drive mounts as "MufflySamsung" or "MufflySamsung 1" depending on the day;
# samsung_volume_path() finds it either way and stops if it finds neither.
env_or_volume <- function(var, relative) {
  v <- Sys.getenv(var, "")
  if (nzchar(v)) v else samsung_volume_path(relative)
}
LAKE <- env_or_volume("TRILLIANT_LAKE", "hpt_prices/trilliant/20260721/lake/data/main")
HPT  <- env_or_volume("HPT_PRICES", "hpt_prices")
ART  <- Sys.getenv("MIDWIFERY_ARTIFACTS", "artifacts")
OUT  <- Sys.getenv("OUT", "artifacts")
TRILLIANT_SNAPSHOT <- "2026-06-25"
NPPES_VINTAGE      <- "2026-08-09"
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

# ---- text helpers ----------------------------------------------------------------
# Street normalizer: drop suite/unit tails and punctuation, abbreviate suffixes
# and directionals, so NPPES "2500 ENGLISH CREEK AVE STE 1000" meets Trilliant
# "2500 English Creek Ave".
STREET_ABBREV <- c(
  street = "st", avenue = "ave", drive = "dr", road = "rd", boulevard = "blvd",
  lane = "ln", parkway = "pkwy", highway = "hwy", place = "pl", court = "ct",
  circle = "cir", terrace = "ter", square = "sq", plaza = "plz",
  expressway = "expy", freeway = "fwy", northeast = "ne", northwest = "nw",
  southeast = "se", southwest = "sw", north = "n", south = "s", east = "e",
  west = "w", route = "rte", "state rte" = "rte", "us hwy" = "hwy", "state hwy" = "hwy"
)
norm_street <- function(s) {
  s <- str_to_lower(coalesce(s, ""))
  s <- str_remove(s, "\\s*(,|\\s)\\s*(ste|suite|unit|apt|fl|floor|rm|room|bldg|building|dept|#)\\b.*$")
  s <- str_replace_all(s, "[^a-z0-9 ]", " ")
  for (w in names(STREET_ABBREV)) {
    s <- str_replace_all(s, paste0("\\b", w, "\\b"), STREET_ABBREV[[w]])
  }
  str_squish(s)
}

has <- function(x, pattern) str_detect(str_to_lower(coalesce(x, "")), pattern)
is_birth_center <- function(x) has(x, "birth(ing)?\\s*(center|centre|place|house|cottage|suite)|birthcenter|center for birth|maternity center")
is_hospital     <- function(x) has(x, "\\bhospitals?\\b|medical center\\b|\\bmed ctr\\b")
is_hospital_word <- function(x) has(x, "\\bhospitals?\\b")
is_chc          <- function(x) has(x, "community health|health center,? inc|\\bfqhc\\b|federally qualified|family health cent")
is_lab          <- function(x) has(x, paste0(
  "patholog|cytolog|laborator|\\blabs?\\b|lab sciences|quest diagnostics|sonora quest|labcorp|",
  "laboratory corporation|natera|myriad genetic|invitae|progenity|sema4|bio-?reference|enzo clinical|",
  "ambry|genova diagnostics|arbor diagnostics|avero diagnostics|incyte diagnostics|starling diagnostics|",
  "diagnostic virology|diagnostic testing|aurora diagnostics|pathgroup|genetic testing|genomics|",
  "propath|genomind|otogenetics|med ?fusion|tricore"))
is_noncare      <- function(x) has(x, "pharmacy|\\bambulance\\b|\\bems\\b|radiology|imaging|medical supply|durable medical")
is_surgery_urgent <- function(x) has(x, "surgery cent|surgical cent|\\basc\\b|ambulatory surg|urgent care")

# Jaro-Winkler similarity of two names, 0..1 (1 = identical)
name_sim <- function(a, b) stringsim(str_to_lower(a), str_to_lower(b), method = "jw", p = 0.1)

# CCNs are six characters; the CMS enrollment file drops the leading zero
# (Denver Health 060011 is published as 60011). pad_ccn() from common_helpers.R
# puts it back.
read_latin1 <- function(path) read_csv(path, col_types = cols(.default = col_character()),
                                       locale = locale(encoding = "latin1"), progress = FALSE)

# =============================================================================
# 1. Cohort: ACTIVE certificants with a primary-tier NPI link
# =============================================================================
# WHICH FREEZE. The cohort is only the canonical one if the linkage file is
# the freeze the tracked manifest describes (current: 22,357 rows, registered
# ACTIVE, primary-linked count 12,171). Anything else stops unless
# ALLOW_FREEZE_SHA256 names it on purpose, and the summary records which
# freeze it came from. The first run of this script used the 2026-08-10
# freeze (11,920) because it was the only one on that machine.
#
# WHO. The canonical cohort, whole. No board-coverage restriction: Trilliant
# and CMS observe midwives in every state, whether or not a state board was
# ever queried (R/lib/cohort_definitions.R).
FROZEN <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")
FROZEN_SHA256 <- verify_linkage_freeze(FROZEN)

cohort <- chr(FROZEN) |>
  canonical_active_primary() |>
  transmute(certification_number, npi = as.numeric(npi), first_name, last_name, nppes_state)
cat("cohort:", nrow(cohort), "midwives\n")

# =============================================================================
# 2. Trilliant provider rows for the cohort (7.5M rows read lazily, ~12k kept)
# =============================================================================
trilliant <- read_parquet_duckdb(file.path(LAKE, "directory_provider", "*.parquet")) |>
  semi_join(as_duckdb_tibble(select(cohort, provider_npi = npi)), by = "provider_npi") |>
  collect() |>
  left_join(select(cohort, certification_number, npi), by = c("provider_npi" = "npi"))

# =============================================================================
# 3. Every place a midwife may work, as an address
# =============================================================================
top_sites <- trilliant |>
  filter(!is.na(provider_affiliated_practice_1_street_address)) |>
  transmute(
    certification_number, npi = provider_npi,
    source = "trilliant_claims_top_site", source_rank = 1L,
    site_name  = provider_affiliated_practice_1_name,
    street     = provider_affiliated_practice_1_street_address,
    city       = provider_affiliated_practice_1_city,
    state      = provider_affiliated_practice_1_state,
    zip5       = str_sub(provider_affiliated_practice_1_zip_code, 1, 5),
    lat        = provider_affiliated_practice_1_latitude,
    lon        = provider_affiliated_practice_1_longitude,
    county_name = provider_affiliated_practice_1_county,
    visit_share = provider_affiliated_practice_1_visits_percent_total,
    evidence_date = TRILLIANT_SNAPSHOT)

nppes_sites <- chr(file.path(ART, "midwife_practice_locations.csv")) |>
  semi_join(cohort, by = "certification_number") |>
  transmute(
    certification_number, npi = as.numeric(npi),
    source = paste0("nppes_", loc_type, "_location"),
    source_rank = if_else(loc_type == "primary", 2L, 3L),
    site_name = NA_character_, street = addr, city, state = st, zip5 = z5,
    lat = NA_real_, lon = NA_real_, county_name = NA_character_, visit_share = NA_real_,
    evidence_date = NPPES_VINTAGE)

addr_sites <- bind_rows(top_sites, nppes_sites) |>
  mutate(site_id = row_number(), ns = norm_street(street))

# =============================================================================
# 4. Organizations at those addresses (3.3M rows read lazily, cut by ZIP first)
# =============================================================================
site_zips <- addr_sites |> distinct(oz = zip5) |> filter(!is.na(oz))

# Read once for the addresses above, and again (below) only for ZIPs that CMS
# hospital affiliations and CABC birth centers add. Each org carries Trilliant's
# geocode and county, which is where every non-Trilliant site gets its place.
read_orgs <- function(zips) {
  read_parquet_duckdb(file.path(LAKE, "directory_organization", "*.parquet")) |>
    filter(!is.na(organization_zip_code), !is.na(organization_street_line_1)) |>
    # 1L / 5L, not 1 / 5: DuckDB's substr() wants whole numbers
    mutate(oz = substr(organization_zip_code, 1L, 5L)) |>
    semi_join(as_duckdb_tibble(tibble(oz = unique(zips))), by = "oz") |>
    select(org_npi = organization_npi, org_name = organization_name, org_type = organization_type,
           tax = organization_primary_taxonomy_code, tax_desc = organization_primary_taxonomy_description,
           oz, street1 = organization_street_line_1,
           org_lat = organization_latitude, org_lon = organization_longitude,
           org_county = organization_county, org_state = organization_state) |>
    collect() |>
    mutate(
      ns = norm_street(street1),
      org_class = case_when(
        org_type == "Independent Laboratory" | tax == "291U00000X" | str_starts(coalesce(tax, ""), "207ZP") |
          is_lab(org_name) ~ "lab_pathology",
        tax == "261QB0400X" | is_birth_center(org_name) ~ "birth_center",
        str_detect(coalesce(org_type, ""), "(?i)hospital") | str_starts(coalesce(tax, ""), "28") |
          str_starts(coalesce(tax, ""), "27") ~ "hospital",
        tax %in% c("261QF0400X", "261QR1300X", "261QC1500X", "261QC1800X") | is_chc(org_name) ~ "fqhc_community_health",
        org_type %in% c("Pharmacy", "Supplier", "Imaging Center", "Transportation Service",
                        "Home Health and Hospice", "Nursing Facility") ~ "non_care_other",
        org_type %in% c("Urgent Care", "Surgery Center", "Free-Standing Emergency Department") ~ "other_facility",
        TRUE ~ "clinic_practice"),
      # higher = more like the hospital itself (acute / critical access), for picking a name
      hospital_rank = if_else(org_class == "hospital",
        1L + 10L * str_detect(coalesce(org_type, ""), "(?i)acute|critical"), 0L))
}
orgs <- read_orgs(site_zips$oz)

# =============================================================================
# 5. Match each address to the organizations in the same building
# =============================================================================
candidates <- addr_sites |>
  filter(ns != "") |>
  select(site_id, site_name, zip5, ns) |>
  inner_join(orgs, by = c("zip5" = "oz", "ns" = "ns"), relationship = "many-to-many") |>
  mutate(jw = if_else(is.na(site_name), NA_real_, name_sim(site_name, org_name)))

building <- candidates |>
  group_by(site_id) |>
  summarise(
    n_orgs_at_address     = n(),
    addr_has_hospital     = any(org_class == "hospital"),
    addr_has_birth_center = any(org_class == "birth_center"),
    addr_has_fqhc         = any(org_class == "fqhc_community_health"),
    .groups = "drop")

building_hospital <- candidates |>
  filter(org_class == "hospital") |>
  arrange(site_id, desc(hospital_rank)) |>
  distinct(site_id, .keep_all = TRUE) |>
  select(site_id, addr_hospital_name = org_name, addr_hospital_npi = org_npi)

building_birth_center <- candidates |>
  filter(org_class == "birth_center") |>
  arrange(site_id, org_name) |>
  distinct(site_id, .keep_all = TRUE) |>
  select(site_id, addr_birth_center_name = org_name)

# Best named organization: highest name similarity; unnamed addresses fall
# back to what kind of place the building is.
class_priority <- c(birth_center = 1, hospital = 2, fqhc_community_health = 3,
                    clinic_practice = 4, other_facility = 5, non_care_other = 6, lab_pathology = 7)
best_org <- candidates |>
  mutate(priority = class_priority[org_class]) |>
  arrange(site_id, desc(coalesce(jw, -1)), priority) |>
  distinct(site_id, .keep_all = TRUE) |>
  select(site_id, best_org_npi = org_npi, best_org_name = org_name, best_org_type = org_type,
         best_org_taxonomy = tax_desc, best_org_class = org_class, best_jw = jw)

# =============================================================================
# 6. Decide what kind of place each address is
# =============================================================================
addr_classified <- addr_sites |>
  left_join(best_org, by = "site_id") |>
  left_join(building, by = "site_id") |>
  left_join(building_hospital, by = "site_id") |>
  left_join(building_birth_center, by = "site_id") |>
  mutate(
    across(c(addr_has_hospital, addr_has_birth_center, addr_has_fqhc), \(x) coalesce(x, FALSE)),
    named = !is.na(site_name),
    name_matched = named & coalesce(best_jw, 0) >= 0.80,
    facility_type = case_when(
      # 1. what the site calls itself; a lab or pathology practice is never a workplace
      is_lab(site_name) ~ "lab_pathology",
      is_birth_center(site_name) & !addr_has_hospital ~ "birth_center",
      is_hospital(site_name) ~ "hospital",
      is_chc(site_name) ~ "fqhc_community_health",
      is_noncare(site_name) ~ "non_care_other",
      is_surgery_urgent(site_name) ~ "other_facility",
      # 2. the directory organization it resolves to (clinical classes only; a
      #    practice's own in-house lab NPI must not relabel the practice)
      name_matched & best_org_class == "birth_center" ~ if_else(addr_has_hospital, "hospital", "birth_center"),
      name_matched & best_org_class %in% c("hospital", "fqhc_community_health", "clinic_practice") ~ best_org_class,
      # 3. the building
      addr_has_hospital ~ "hospital",
      addr_has_birth_center ~ "birth_center",
      addr_has_fqhc ~ "fqhc_community_health",
      # an unnamed self-reported address is never excluded because a lab shares the building
      !named & best_org_class %in% c("lab_pathology", "non_care_other") ~ "unclassified",
      !named & !is.na(best_org_class) ~ best_org_class,
      named | !is.na(best_org_class) ~ "clinic_practice",
      TRUE ~ "unclassified"),
    facility_type_basis = case_when(
      named & (is_lab(site_name) | is_birth_center(site_name) | is_hospital(site_name) | is_chc(site_name) |
               is_noncare(site_name) | is_surgery_urgent(site_name)) ~ "site_name_pattern",
      name_matched & best_org_class %in% c("hospital", "fqhc_community_health", "clinic_practice", "birth_center") ~ "named_org_match",
      !is.na(best_org_class) ~ "building_at_address",
      named ~ "site_name_only",
      TRUE ~ "no_directory_match"),
    # report a "matched organization" only when the names really matched
    matched_org_name     = if_else(facility_type_basis == "named_org_match", best_org_name, NA_character_),
    matched_org_npi      = if_else(facility_type_basis == "named_org_match", best_org_npi, NA_character_),
    matched_org_type     = if_else(facility_type_basis == "named_org_match", best_org_type, NA_character_),
    matched_org_taxonomy = if_else(facility_type_basis == "named_org_match", best_org_taxonomy, NA_character_),
    hospital_org_npi = if_else(facility_type == "hospital",
      coalesce(if_else(str_detect(coalesce(best_org_type, ""), "(?i)hospital") & facility_type_basis == "named_org_match",
                       best_org_npi, NA_character_), addr_hospital_npi),
      NA_character_),
    name_similarity = round(best_jw, 3))

# =============================================================================
# 7. Sources that name a place but give no address
# =============================================================================
employer_type <- function(name) case_when(
  is_lab(name) ~ "lab_pathology",
  is_birth_center(name) ~ "birth_center",
  is_hospital_word(name) ~ "hospital",
  is_chc(name) ~ "fqhc_community_health",
  TRUE ~ "employer_org")

dac_sites <- chr(file.path(ART, "dac_facility_affiliations.csv")) |>
  semi_join(cohort, by = "certification_number") |>
  filter(facility_type == "Hospital") |>
  transmute(certification_number, npi = as.numeric(npi),
            source = "cms_dac_facility_affiliation", source_rank = 4L,
            site_name = facility_name, state, facility_type = "hospital",
            facility_type_basis = "cms_dac_facility_affiliation_file", ccn, detail = hospital_type)

cabc_sites <- chr(file.path(ART, "cabc_matched_midwives_final.csv")) |>
  semi_join(cohort, by = "certification_number") |>
  transmute(certification_number, npi = as.numeric(npi),
            source = "cabc_birth_center", source_rank = 5L,
            site_name = matched_cabc_birth_center, street = cabc_address, state = midwife_state,
            zip5 = str_sub(cabc_zip, 1, 5), facility_type = "birth_center",
            facility_type_basis = "cabc_accreditation")

trilliant_org_sites <- trilliant |>
  filter(!is.na(primary_organization_name)) |>
  transmute(certification_number, npi = provider_npi,
            source = "trilliant_primary_org", source_rank = 6L,
            site_name = primary_organization_name, state = provider_affiliated_practice_1_state,
            facility_type = employer_type(primary_organization_name), facility_type_basis = "name_pattern")

resolved_org_sites <- chr(file.path(ART, "organization_affiliation_resolved.csv")) |>
  semi_join(cohort, by = "certification_number") |>
  transmute(certification_number, npi = as.numeric(npi),
            source = "resolved_employer_org", source_rank = 7L,
            site_name = organization_name,
            facility_type = employer_type(organization_name), facility_type_basis = "name_pattern",
            detail = paste0(affiliation_class, " / ", currentness_class, " / last ",
                            coalesce(last_evidence_date, "?")))

# =============================================================================
# 8. Hospital CCN, and the hospital's price-transparency file
# =============================================================================
enrollments <- read_latin1(file.path(HPT, "reference/cms_enrollments/Hospital_Enrollments_2026.07.31.csv")) |>
  rename_with(\(x) str_to_lower(str_replace_all(x, "[^A-Za-z0-9]+", "_"))) |>
  mutate(ccn = pad_ccn(ccn))

additional_npis <- chr(file.path(HPT, "reference/cms_enrollments/Hospital_Additional_NPIs_2026.07.31.csv")) |>
  rename_with(\(x) str_to_lower(str_replace_all(x, "[^A-Za-z0-9]+", "_")))

npi_to_ccn <- bind_rows(
  read_latin1(file.path(HPT, "reference/npi_ccn_crosswalk.csv")) |>
    select(org_npi = npi, ccn),
  enrollments |> select(org_npi = npi, ccn),
  additional_npis |> inner_join(select(enrollments, enrollment_id, ccn), by = "enrollment_id") |>
    select(org_npi = npi, ccn)) |>
  filter(!is.na(org_npi), !is.na(ccn)) |>
  mutate(ccn = pad_ccn(ccn)) |>
  group_by(org_npi) |>
  summarise(ccn = min(ccn), .groups = "drop")

universe <- read_latin1(file.path(HPT, "reference/hospital_universe.csv"))
hospital_ref <- bind_rows(
  enrollments |> transmute(ccn, hname = str_to_upper(coalesce(doing_business_as_name, organization_name)),
                           hstate = state, hcity = str_to_upper(city), hns = norm_street(address_line_1),
                           hz = str_sub(zip_code, 1, 5)),
  universe |> transmute(ccn = pad_ccn(facility_id), hname = str_to_upper(facility_name), hstate = state,
                        hcity = str_to_upper(citytown), hns = norm_street(address),
                        hz = str_sub(str_pad(zip_code, 5, pad = "0"), 1, 5))) |>
  filter(!is.na(ccn)) |>
  distinct()

price_files <- read_parquet_duckdb(file.path(HPT, "crosswalk/facility_ccn.parquet")) |>
  filter(!is.na(ccn), !coalesce(ccn_ambiguous, FALSE), !coalesce(ccn_conflict, FALSE)) |>
  select(ccn, hospital_name, facility_key, ccn_match_score) |>
  collect() |>
  arrange(ccn, desc(ccn_match_score)) |>
  distinct(ccn, .keep_all = TRUE) |>
  select(ccn, mrf_hospital_name = hospital_name, mrf_facility_key = facility_key)

# CCN for hospital addresses. Collect every candidate CCN, from four kinds of
# evidence, best first:
#   1 the NPI of the organization the site's name matched
#   2 the NPI of any hospital organization at the same street address
#   3 the street address itself, against CMS's hospital lists
#   4 a close name match (>= 0.92) in the same city
# A candidate whose hospital is in another state is dropped. Trilliant's
# directory sometimes files an NPI at the wrong address when two hospitals share
# a name (Community Hospital, Tallassee AL, turns up at Community Hospital's
# street address in Grand Junction CO). Among what's left, prefer the main
# hospital's CCN (last four digits 0001-0879, short-term; 1300-1399, critical
# access) over a psych or swing-bed unit (34S143) or another subunit.
ccn_state <- hospital_ref |> distinct(ccn, hstate) |> filter(!is.na(hstate))
is_main_hospital_ccn <- function(ccn) {
  tail4 <- suppressWarnings(as.integer(str_sub(ccn, 3, 6)))
  str_detect(ccn, "^[0-9]{6}$") & (between(tail4, 1, 879) | between(tail4, 1300, 1399))
}

hosp_sites <- addr_classified |> filter(facility_type == "hospital")

ccn_candidates <- bind_rows(
  hosp_sites |>
    filter(!is.na(matched_org_npi)) |>
    inner_join(npi_to_ccn, by = c("matched_org_npi" = "org_npi")) |>
    transmute(site_id, ccn, evidence = 1L, ccn_basis = "org_npi"),
  hosp_sites |>
    select(site_id) |>
    inner_join(candidates |> filter(org_class == "hospital") |> distinct(site_id, org_npi), by = "site_id") |>
    inner_join(npi_to_ccn, by = "org_npi") |>
    transmute(site_id, ccn, evidence = 2L, ccn_basis = "org_npi"),
  hosp_sites |>
    filter(ns != "") |>
    inner_join(hospital_ref |> filter(hns != "") |> distinct(ccn, hz, hns),
               by = c("zip5" = "hz", "ns" = "hns"), relationship = "many-to-many") |>
    transmute(site_id, ccn, evidence = 3L, ccn_basis = "address"),
  hosp_sites |>
    filter(!is.na(site_name)) |>
    select(site_id, site_name, state, city) |>
    inner_join(hospital_ref |> distinct(ccn, hname, hstate, hcity), by = c("state" = "hstate"),
               relationship = "many-to-many") |>
    filter(is.na(city) | hcity == str_to_upper(city)) |>
    filter(stringsim(str_to_upper(site_name), hname, method = "jw", p = 0.1) >= 0.92) |>
    transmute(site_id, ccn, evidence = 4L, ccn_basis = "name_city"))

ccn_best <- ccn_candidates |>
  left_join(select(hosp_sites, site_id, site_state = state), by = "site_id") |>
  left_join(ccn_state, by = "ccn", relationship = "many-to-many") |>
  filter(is.na(site_state) | is.na(hstate) | hstate == site_state) |>
  distinct(site_id, ccn, evidence, ccn_basis) |>
  arrange(site_id, evidence, desc(is_main_hospital_ccn(ccn)), ccn) |>
  distinct(site_id, .keep_all = TRUE) |>
  select(site_id, ccn, ccn_basis)

addr_rows <- addr_classified |>
  left_join(ccn_best, by = "site_id") |>
  select(certification_number, npi, source, source_rank, site_name, street, city, state, zip5, lat, lon,
         county_name, visit_share, evidence_date, facility_type, facility_type_basis,
         matched_org_name, matched_org_npi, matched_org_type, matched_org_taxonomy, n_orgs_at_address,
         name_similarity, addr_has_hospital, addr_hospital_name, addr_has_birth_center, addr_birth_center_name,
         hospital_org_npi, ccn, ccn_basis)

sites_all <- bind_rows(addr_rows, dac_sites, cabc_sites, trilliant_org_sites, resolved_org_sites) |>
  mutate(ccn = pad_ccn(ccn),
         ccn_basis = if_else(source == "cms_dac_facility_affiliation" & !is.na(ccn), "dac", ccn_basis)) |>
  left_join(price_files, by = "ccn")

# =============================================================================
# 8b. Where each site is: coordinates, county, rurality, and which rows are one place
# =============================================================================
# Only the Trilliant claims site came with coordinates. Every other address
# takes the geocode Trilliant's organization directory gives the organizations
# at that street address; a CMS hospital affiliation is placed at the
# hospital's CMS address first, a CABC center at its listed address. County:
# Trilliant's county name where it matches one Census county
# (match_county()), else the ZIP's dominant county (the repository's
# crosswalk), with Connecticut ZIPs rescued to their 2022 planning region when
# that crosswalk is present. Rurality: RUCC 2023 from data/county_base.csv,
# banded exactly as the cohort papers band it.
NON_WORKPLACE <- c("lab_pathology", "non_care_other")
EMPLOYER_SOURCES <- c("trilliant_primary_org", "resolved_employer_org")

dac_addr <- hospital_ref |>
  filter(!is.na(hns), hns != "", !is.na(hz)) |>
  arrange(ccn, hz, hns) |>
  group_by(ccn) |> slice_head(n = 1) |> ungroup() |>
  select(ccn, dac_ns = hns, dac_zip = hz)
sites_all <- sites_all |>
  left_join(dac_addr, by = "ccn", relationship = "many-to-one") |>
  mutate(
    ns_geo = case_when(
      source == "cms_dac_facility_affiliation" ~ dac_ns,
      source == "cabc_birth_center" ~ norm_street(str_remove(street, ",.*$")),
      TRUE ~ norm_street(street)),
    ns_geo = if_else(ns_geo == "", NA_character_, ns_geo),
    zip_geo = if_else(source == "cms_dac_facility_affiliation", dac_zip, zip5)) |>
  select(-dac_ns, -dac_zip)

extra_zips <- setdiff(unique(stats::na.omit(sites_all$zip_geo)), unique(orgs$oz))
orgs_geo <- if (length(extra_zips)) bind_rows(orgs, read_orgs(extra_zips)) else orgs
modal <- function(x) { t <- table(x); if (length(t)) names(t)[which.max(t)] else NA_character_ }
geo_at_address <- orgs_geo |>
  filter(!is.na(org_lat), !is.na(org_lon), ns != "") |>
  group_by(oz, ns) |>
  summarise(g_lat = stats::median(org_lat), g_lon = stats::median(org_lon),
            g_county = modal(org_county), g_state = modal(org_state), .groups = "drop")

county_base <- chr(file.path("data", "county_base.csv"))
county_keys <- county_match_keys(county_base)
zip_county <- zip_county_dominant(file.path("data", "zcta_county_2020.txt"))
ct_regions <- ct_zip_to_region()

sites_all <- sites_all |>
  left_join(geo_at_address, by = c("zip_geo" = "oz", "ns_geo" = "ns"), relationship = "many-to-one") |>
  mutate(coordinate_basis = case_when(!is.na(lat) ~ "trilliant_claims_site",
                                      !is.na(g_lat) ~ "trilliant_organizations_at_address"),
         lat = coalesce(lat, g_lat), lon = coalesce(lon, g_lon),
         county_name = coalesce(county_name, g_county),
         state_geo = coalesce(state, g_state)) |>
  select(-g_lat, -g_lon, -g_county, -g_state)

name_pairs <- sites_all |>
  distinct(county_name, state_geo) |>
  filter(!is.na(county_name), !is.na(state_geo))
name_pairs$geoid_from_name <- match_county(name_pairs$county_name, name_pairs$state_geo, county_keys)
sites_all <- sites_all |>
  left_join(name_pairs, by = c("county_name", "state_geo"), relationship = "many-to-one") |>
  left_join(rename(zip_county, geoid_from_zip = GEOID), by = c("zip_geo" = "zip5"), relationship = "many-to-one") |>
  mutate(county_geoid = coalesce(geoid_from_name, geoid_from_zip),
         geography_basis = case_when(!is.na(geoid_from_name) ~ "trilliant_county_name",
                                     !is.na(geoid_from_zip) ~ "zip_dominant_county"))
if (!is.null(ct_regions)) {
  sites_all <- sites_all |>
    left_join(rename(ct_regions, geoid_ct = GEOID), by = c("zip_geo" = "zip5"), relationship = "many-to-one") |>
    mutate(ct_legacy = !is.na(county_geoid) & substr(county_geoid, 1, 2) == "09" & !county_geoid %in% county_base$GEOID,
           geography_basis = if_else(ct_legacy & !is.na(geoid_ct), "ct_zip_to_planning_region", geography_basis),
           county_geoid = if_else(ct_legacy & !is.na(geoid_ct), geoid_ct, county_geoid)) |>
    select(-geoid_ct, -ct_legacy)
}
sites_all <- sites_all |>
  left_join(county_base |> select(county_geoid = GEOID, rucc_2023), by = "county_geoid",
            relationship = "many-to-one") |>
  mutate(rucc_cat = coalesce(band_rurality(rucc_2023, RURALITY_LABELS_COHORT), "Unknown")) |>
  select(-geoid_from_name, -geoid_from_zip, -state_geo)

# Which rows are one physical place: same coordinates to ~11 m, or same street + ZIP.
work_rows <- !sites_all$facility_type %in% NON_WORKPLACE & !sites_all$source %in% EMPLOYER_SOURCES
sites_all$site_id <- NA_character_
sites_all$site_id[work_rows] <- assign_site_ids(
  sites_all$certification_number[work_rows], sites_all$lat[work_rows], sites_all$lon[work_rows],
  sites_all$ns_geo[work_rows], sites_all$zip_geo[work_rows])

# =============================================================================
# 9. Keep workplaces; set the rest aside where they can be audited
# =============================================================================
# Labs, pathology practices, pharmacies, DME suppliers, ambulance and imaging are
# where a midwife's ORDERS were filled, not where the midwife works.
sites_long <- sites_all |> filter(!facility_type %in% NON_WORKPLACE)
excluded   <- sites_all |> filter(facility_type %in% NON_WORKPLACE)

# The repository-side inputs, for the sidecars. The Trilliant and hpt_prices
# files live on the external volume and are named in the header instead.
INPUTS <- file.path(ART, c("amcb_npi_linkage_FROZEN.csv", "midwife_practice_locations.csv",
                           "dac_facility_affiliations.csv", "cabc_matched_midwives_final.csv",
                           "organization_affiliation_resolved.csv"))
write_with_provenance(arrange(sites_long, certification_number, source_rank),
                      file.path(OUT, "midwife_work_sites_long.csv"), inputs = INPUTS, na = "")
write_with_provenance(arrange(excluded, certification_number, source_rank),
                      file.path(OUT, "midwife_work_sites_excluded_non_workplace.csv"),
                      inputs = INPUTS, na = "")

# One row per midwife x physical place. The name, coordinates and county come
# from the best-ranked source at that place (Trilliant claims site first).
first_known <- function(x) { x <- x[!is.na(x)]; if (length(x)) x[1] else x[NA_integer_] }
distinct_sites <- sites_long |>
  filter(!is.na(site_id)) |>
  arrange(certification_number, site_id, source_rank, site_name) |>
  group_by(certification_number, site_id) |>
  summarise(site_name = first_known(site_name), facility_types = paste(sort(unique(facility_type)), collapse = " + "),
            sources = paste(sort(unique(source)), collapse = "; "), n_source_rows = n(),
            street = first_known(street), zip5 = first_known(zip_geo), lat = first_known(lat), lon = first_known(lon),
            coordinate_basis = first_known(coordinate_basis), county_geoid = first_known(county_geoid),
            geography_basis = first_known(geography_basis), rucc_2023 = first_known(rucc_2023),
            rucc_cat = first_known(rucc_cat), visit_share = first_known(visit_share), ccn = first_known(ccn),
            .groups = "drop")
write_with_provenance(distinct_sites, file.path(OUT, "midwife_distinct_work_sites.csv"), inputs = INPUTS, na = "")

# =============================================================================
# 10. One row per midwife
# =============================================================================
top <- sites_long |> filter(source == "trilliant_claims_top_site")
top_excluded <- excluded |>
  filter(source == "trilliant_claims_top_site") |>
  transmute(certification_number, top_site_excluded_as = paste0(facility_type, ": ", coalesce(site_name, "?")))

# Setting flags use site evidence only. Employer names say who pays a midwife,
# not where the midwife works, so they stay in the long table but not here.
flags <- sites_long |>
  filter(!source %in% c("trilliant_primary_org", "resolved_employer_org")) |>
  group_by(certification_number) |>
  summarise(
    any_hospital     = any(facility_type == "hospital"),
    any_birth_center = any(facility_type == "birth_center"),
    any_fqhc         = any(facility_type == "fqhc_community_health"),
    any_clinic       = any(facility_type == "clinic_practice"),
    hospital_names   = paste(sort(unique(str_to_upper(site_name[facility_type == "hospital" & !is.na(site_name)]))), collapse = " | "),
    birth_center_names = paste(sort(unique(coalesce(site_name, addr_birth_center_name)[facility_type == "birth_center"])), collapse = " | "),
    n_distinct_addresses = n_distinct(paste(norm_street(street), zip5)[!is.na(street) & !is.na(zip5)]),
    sources = paste(sort(unique(source)), collapse = "; "),
    .groups = "drop")

summary_tbl <- cohort |>
  left_join(trilliant |> select(certification_number, trilliant_active = active_provider,
                                trilliant_n_practice_sites = provider_practices_total,
                                primary_organization_name), by = "certification_number") |>
  left_join(top |> transmute(certification_number,
                             top_site_name = site_name, top_site_street = street, top_site_city = city,
                             top_site_state = state, top_site_zip = zip5, top_site_lat = lat, top_site_lon = lon,
                             top_site_visit_share = round(visit_share, 3),
                             top_site_facility_type = facility_type, top_site_type_basis = facility_type_basis,
                             top_site_org_type = matched_org_type, top_site_taxonomy = matched_org_taxonomy,
                             top_site_building_hospital = addr_hospital_name, top_site_ccn = ccn,
                             top_site_ccn_basis = ccn_basis, top_site_price_file_hospital = mrf_hospital_name),
            by = "certification_number") |>
  left_join(top_excluded, by = "certification_number") |>
  mutate(trilliant_primary_org = if_else(is_lab(primary_organization_name), NA_character_, primary_organization_name)) |>
  select(-primary_organization_name) |>
  left_join(flags, by = "certification_number") |>
  mutate(across(c(any_hospital, any_birth_center, any_fqhc, any_clinic), \(x) coalesce(x, FALSE)))

# Topology, blended practice and rurality (R/lib/work_site_topology.R).
topology <- topology_by_midwife(sites_long |>
  transmute(certification_number, site_id, source, facility_type, lat, lon, GEOID = county_geoid, rucc_cat))
blended <- blended_practice(sites_long)
top_geo <- top |> transmute(certification_number, top_site_county_geoid = county_geoid,
                            top_site_geography_basis = geography_basis, top_site_rucc_cat = rucc_cat)
nppes_geo <- sites_long |>
  filter(source == "nppes_primary_location") |>
  arrange(certification_number, site_id) |>
  group_by(certification_number) |> slice_head(n = 1) |> ungroup() |>
  transmute(certification_number, nppes_primary_rucc_cat = rucc_cat,
            nppes_primary_lat = lat, nppes_primary_lon = lon)
summary_tbl <- summary_tbl |>
  left_join(top_geo, by = "certification_number", relationship = "one-to-one") |>
  left_join(nppes_geo, by = "certification_number", relationship = "one-to-one") |>
  left_join(topology, by = "certification_number", relationship = "one-to-one") |>
  left_join(blended, by = "certification_number", relationship = "one-to-one") |>
  mutate(
    n_distinct_sites = coalesce(n_distinct_sites, 0L),
    across(c(hospital_strict, birth_center_strict, hospital_broad, birth_center_broad,
             blended_strict, blended_broad), \(x) coalesce(x, FALSE)),
    # Does the NPPES address put a midwife in the same rurality band as where
    # her claims say she works? NPPES addresses drive the persistence analysis.
    # "same band" names its band, so each NPPES band's disagreement rate can be
    # read off the tracked summary: the rural bands disagree far more than Metro.
    rurality_nppes_vs_claims = case_when(
      is.na(top_site_rucc_cat) | top_site_rucc_cat == "Unknown" |
        is.na(nppes_primary_rucc_cat) | nppes_primary_rucc_cat == "Unknown" ~ "not comparable",
      top_site_rucc_cat == nppes_primary_rucc_cat ~ paste0("same band: ", nppes_primary_rucc_cat),
      TRUE ~ paste0("NPPES ", nppes_primary_rucc_cat, " / claims ", top_site_rucc_cat)),
    # How far the self-reported NPPES address is from the site where claims place the midwife.
    # A disagreement tens of km away is a different place, not a county line.
    nppes_to_claims_km = round(haversine_km(as.numeric(nppes_primary_lat), as.numeric(nppes_primary_lon),
                                            as.numeric(top_site_lat), as.numeric(top_site_lon)), 1))

write_with_provenance(arrange(summary_tbl, certification_number),
                      file.path(OUT, "midwife_work_sites_summary.csv"), inputs = INPUTS, na = "")

# The one tracked output: counts of midwives, no person in it. Everything above
# is person-level and licensed and stays out of git.
settings <- summary_tbl |>
  mutate(pattern = paste(c("hospital", "birth center", "FQHC/CHC", "clinic/practice")[
    which(c(any_hospital, any_birth_center, any_fqhc, any_clinic))], collapse = " + "),
    .by = certification_number) |>
  mutate(pattern = if_else(pattern == "", "no classified site", pattern))
# Every dimension partitions the cohort: its levels sum to cohort_n.
setting_summary <- bind_rows(
  summary_tbl |>
    count(level = coalesce(top_site_facility_type, "no Trilliant site"), name = "n_midwives") |>
    mutate(dimension = "trilliant_main_site_type"),
  settings |> count(level = pattern, name = "n_midwives") |> mutate(dimension = "work_setting_combination"),
  summary_tbl |>
    count(level = if_else(n_distinct_sites >= 5L, "5+", as.character(n_distinct_sites)), name = "n_midwives") |>
    mutate(dimension = "n_distinct_work_sites"),
  summary_tbl |>
    count(level = case_when(blended_strict ~ "hospital + birth center, strict evidence",
                            blended_broad ~ "hospital + birth center, broad evidence only",
                            TRUE ~ "not both"), name = "n_midwives") |>
    mutate(dimension = "blended_hospital_birth_center"),
  summary_tbl |>
    count(level = coalesce(top_site_rucc_cat, "no Trilliant site"), name = "n_midwives") |>
    mutate(dimension = "main_site_rurality"),
  summary_tbl |>
    count(level = coalesce(rurality_mix, "no site"), name = "n_midwives") |>
    mutate(dimension = "rurality_mix_across_sites"),
  summary_tbl |>
    count(level = rurality_nppes_vs_claims, name = "n_midwives") |>
    mutate(dimension = "rurality_nppes_address_vs_claims_site"),
  summary_tbl |>
    count(level = paste0(
      case_when(rurality_nppes_vs_claims == "not comparable" ~ "not comparable",
                str_starts(rurality_nppes_vs_claims, "same band") ~ "same band",
                TRUE ~ "different band"), ", ",
      case_when(is.na(nppes_to_claims_km) ~ "no coordinates for both",
                nppes_to_claims_km < 1 ~ "<1 km", nppes_to_claims_km < 10 ~ "1-10 km",
                nppes_to_claims_km < 40 ~ "10-40 km", nppes_to_claims_km < 80 ~ "40-80 km",
                nppes_to_claims_km < 250 ~ "80-250 km", TRUE ~ "250+ km")), name = "n_midwives") |>
    mutate(dimension = "nppes_address_to_claims_site_distance")) |>
  mutate(cohort_n = nrow(summary_tbl), frozen_sha256 = FROZEN_SHA256,
         trilliant_snapshot = TRILLIANT_SNAPSHOT) |>
  select(dimension, level, n_midwives, cohort_n, frozen_sha256, trilliant_snapshot) |>
  arrange(dimension, desc(n_midwives))
write_with_provenance(setting_summary, file.path(OUT, "midwife_work_setting_summary.csv"),
                      inputs = c(INPUTS, file.path(OUT, "midwife_work_sites_summary.csv")))

# =============================================================================
# 11. What came out
# =============================================================================
cat("\nrows by source\n");               print(count(sites_all, source), n = Inf)
cat("\nexcluded (not workplaces)\n");    print(count(excluded, source, facility_type), n = Inf)
cat("\nmain site (Trilliant claims)\n"); print(count(summary_tbl, top_site_facility_type, sort = TRUE), n = Inf)
cat("\nhospital main sites with a CCN / a price file\n")
print(top |> filter(facility_type == "hospital") |>
        summarise(n = n(), with_ccn = sum(!is.na(ccn)), with_price_file = sum(!is.na(mrf_hospital_name)),
                  five_char_ccn = sum(nchar(ccn) == 5, na.rm = TRUE)))
cat("\nwork-setting patterns\n")
print(summary_tbl |>
        mutate(pattern = paste(c("hospital", "birth center", "FQHC/CHC", "clinic/practice")[
          which(c(any_hospital, any_birth_center, any_fqhc, any_clinic))], collapse = " + "),
          .by = certification_number) |>
        count(pattern, sort = TRUE), n = Inf)

cat("\ndistinct work sites per midwife\n"); print(count(summary_tbl, n_distinct_sites), n = Inf)
cat("\nblended hospital + birth center\n")
print(summary_tbl |> summarise(strict = sum(blended_strict), broad = sum(blended_broad)))
cat("\nmain-site rurality\n"); print(count(summary_tbl, top_site_rucc_cat), n = Inf)
cat("\nNPPES address vs claims site rurality\n"); print(count(summary_tbl, rurality_nppes_vs_claims, sort = TRUE), n = Inf)
cat("\nhow each site got its county\n"); print(count(sites_long |> filter(!is.na(site_id)), geography_basis), n = Inf)
