#!/usr/bin/env Rscript
# =============================================================================
# Turn a midwife's practice locations into an identifiable organization
# =============================================================================
# CMS exposes BOTH practice locations for an individual NPI: the primary one on
# the main NPPES file, and any number of secondary ones on the separate
# practice-location file (pl_pfile). This script collects both for the cohort
# and links each location to the Type-2 (organization) NPIs registered at the
# SAME location -- which is what turns "3300 Main St" into a named hospital,
# FQHC, OB/GYN group or health system.
#
# EXACT KEYS ONLY, NEVER PROXIMITY. Locations are joined on telephone, on
# ZIP+4 plus normalized street, or on ZIP5 plus normalized street. No distance
# rule, no nearest-facility fallback: a midwife practising near a hospital is
# not employed by it, and a proximity assignment would produce an affiliation
# that cannot be falsified.
#
# AMBIGUITY IS REPORTED, NOT RESOLVED. Medical office buildings hold many
# organizations at one street address, so a location often matches several
# Type-2 NPIs. Where more than one organization sits at a key, the location is
# labelled ambiguous and NO organization is assigned. Picking the first row, the
# largest, or the nearest would fabricate an employer. Only a location matching
# exactly one organization yields a name.
#
# KEY STRENGTH IS RANKED AND RECORDED. Telephone is the strongest evidence (a
# shared direct line implies a shared practice), ZIP+4 next, ZIP5 weakest. The
# key that produced each match is carried on the output so a downstream table
# can restrict to strong evidence rather than treating all matches alike.
#
# VINTAGE. pl_pfile defaults to the August 2026 dissemination (data through
# 2026-08-09); the organization file is a separate NPPES cut, so the two sides
# are not from the same instant. Locations close and organizations move, so a
# match asserts co-location AS RECORDED, not present-day employment.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          pl_pfile_*.csv                     (PL_FILE)
#          npi_2024, npi_org_all              (MEDICARE_DUCKDB)
# Outputs: artifacts/midwife_practice_locations.csv     (location level)
#          artifacts/midwife_org_links.csv              (location-organization)
#          artifacts/midwife_org_person.csv             (one row per midwife)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
  library(stringr); library(tibble)
})
source("R/lib/common_helpers.R")

DB <- Sys.getenv("MEDICARE_DUCKDB",
                 "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb")
# Default to the CURRENT dissemination. The December 2022 file that was on
# disk carried 681,081 secondary locations; the August 2026 file carries
# 1,241,922 -- 82% more -- and lifts cohort secondary locations from 2,687 to
# 5,303. A stale practice-location file understates exactly the multi-site
# midwives this linkage exists to find.
PL <- Sys.getenv("PL_FILE", file.path(
  "/Volumes/MufflySamsung/nppes_historical_downloads/august_2026",
  "pl_pfile_20050523-20260809.csv"))
for (f in c(DB, PL))
  if (!file.exists(f)) stop(sprintf("Required input not found: %s", f), call. = FALSE)

norm_addr <- function(x) {
  y <- toupper(str_trim(as.character(x)))
  y <- str_replace_all(y, "[.,#]", " ")
  rep <- c("\\bSTREET\\b"="ST","\\bAVENUE\\b"="AVE","\\bROAD\\b"="RD",
           "\\bDRIVE\\b"="DR","\\bBOULEVARD\\b"="BLVD","\\bPLACE\\b"="PL",
           "\\bLANE\\b"="LN","\\bCOURT\\b"="CT","\\bPARKWAY\\b"="PKWY",
           "\\bHIGHWAY\\b"="HWY","\\bSUITE\\b"="STE","\\bNORTH\\b"="N",
           "\\bSOUTH\\b"="S","\\bEAST\\b"="E","\\bWEST\\b"="W")
  for (p in names(rep)) y <- str_replace_all(y, p, rep[[p]])
  y <- str_trim(str_replace_all(y, "\\s+", " "))
  y[!nzchar(y)] <- NA_character_
  y
}
# ZIP+4 only counts when all nine digits are present; a 5-digit value must not
# masquerade as a ZIP+4 match, which would silently weaken the strongest
# address key into the weakest one.
zip9 <- function(x) {
  d <- str_remove_all(as.character(x), "[^0-9]")
  ifelse(!is.na(d) & nchar(d) >= 9, substr(d, 1, 9), NA_character_)
}
zip5 <- function(x) {
  d <- str_remove_all(as.character(x), "[^0-9]")
  ifelse(!is.na(d) & nchar(d) >= 5, substr(d, 1, 5), NA_character_)
}
phone10 <- function(x) {
  d <- str_remove_all(as.character(x), "[^0-9]")
  d <- ifelse(!is.na(d) & nchar(d) == 11 & substr(d, 1, 1) == "1", substr(d, 2, 11), d)
  ifelse(!is.na(d) & nchar(d) == 10, d, NA_character_)
}

coh <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                show_col_types = FALSE, progress = FALSE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE) %>%
  mutate(npi = as.character(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>%
  select(certification_number, npi)
N <- nrow(coh)
cat(sprintf("cohort: %s\n", format(N, big.mark = ",")))

con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "c_npi", coh %>% select(npi), temporary = TRUE, overwrite = TRUE)

# --- primary practice location, from the main NPPES file ---------------------
prim <- dbGetQuery(con, '
  SELECT CAST(a.NPI AS VARCHAR) AS npi,
         a."Provider First Line Business Practice Location Address" AS addr,
         a."Provider Business Practice Location Address City Name" AS city,
         a."Provider Business Practice Location Address State Name" AS st,
         a."Provider Business Practice Location Address Postal Code" AS zip,
         a."Provider Business Practice Location Address Telephone Number" AS phone
    FROM npi_2024 a INNER JOIN c_npi c ON CAST(a.NPI AS VARCHAR) = c.npi') %>%
  mutate(loc_type = "primary")
cat(sprintf("primary practice locations: %s\n", format(nrow(prim), big.mark = ",")))

# --- secondary practice locations, from pl_pfile ------------------------------
pl <- chr(PL)
names(pl) <- names(pl) %>% str_replace_all("[^A-Za-z0-9]+", "_") %>% tolower()
pl_npi <- grep("^npi$", names(pl), value = TRUE)[1]
pick <- function(pat) grep(pat, names(pl), value = TRUE)[1]
sec <- pl %>%
  transmute(npi = .data[[pl_npi]],
            addr = .data[[pick("address_line_1")]],
            city = .data[[pick("city_name")]],
            st   = .data[[pick("state_name")]],
            zip  = .data[[pick("postal_code")]],
            phone= .data[[pick("telephone_number$")]],
            loc_type = "secondary") %>%
  semi_join(coh, by = "npi")
cat(sprintf("secondary practice locations for the cohort: %s across %s midwives\n",
            format(nrow(sec), big.mark = ","),
            format(n_distinct(sec$npi), big.mark = ",")))

locs <- bind_rows(prim, sec) %>%
  mutate(addr_norm = norm_addr(addr), z9 = zip9(zip), z5 = zip5(zip),
         ph = phone10(phone)) %>%
  filter(!is.na(addr_norm) | !is.na(ph)) %>%
  distinct(npi, loc_type, addr_norm, z5, ph, .keep_all = TRUE)
locs <- coh %>% inner_join(locs, by = "npi")
write_csv(locs, "artifacts/midwife_practice_locations.csv", na = "")
cat(sprintf("total distinct cohort locations: %s (%s midwives)\n",
            format(nrow(locs), big.mark = ","),
            format(n_distinct(locs$certification_number), big.mark = ",")))

# --- Type-2 organizations, keyed the same way --------------------------------
org <- dbGetQuery(con, "
  SELECT CAST(npi AS VARCHAR) AS org_npi, organization_name,
         practice_address_street AS addr, practice_address_city AS city,
         practice_address_state AS st, practice_address_zip AS zip,
         practice_phone AS phone, taxonomy_1
    FROM npi_org_all
   WHERE NULLIF(TRIM(organization_name), '') IS NOT NULL") %>%
  mutate(addr_norm = norm_addr(addr), z9 = zip9(zip), z5 = zip5(zip),
         ph = phone10(phone))
cat(sprintf("\nType-2 organizations with a name: %s\n", format(nrow(org), big.mark = ",")))

# Only keys mapping to exactly ONE organization can name an employer.
uniq_key <- function(d, keycols) {
  d %>% filter(if_all(all_of(keycols), ~ !is.na(.x))) %>%
    group_by(across(all_of(keycols))) %>%
    summarise(n_org = n_distinct(org_npi),
              org_npi = first(org_npi), organization_name = first(organization_name),
              .groups = "drop")
}
k_phone <- uniq_key(org, "ph")
k_z9    <- uniq_key(org, c("addr_norm", "z9"))
k_z5    <- uniq_key(org, c("addr_norm", "z5"))

join_rank <- function(locs, key, keycols, label) {
  locs %>% inner_join(key, by = keycols) %>%
    transmute(certification_number, npi, loc_type, addr, city, st, zip,
              match_key = label, n_org_at_key = n_org,
              org_npi = if_else(n_org == 1L, org_npi, NA_character_),
              organization_name = if_else(n_org == 1L, organization_name, NA_character_))
}
links <- bind_rows(
  join_rank(locs, k_phone, "ph", "telephone"),
  join_rank(locs, k_z9, c("addr_norm", "z9"), "zip9_address"),
  join_rank(locs, k_z5, c("addr_norm", "z5"), "zip5_address"))

cat("\n=== links by key strength ===\n")
links %>% mutate(resolved = !is.na(organization_name)) %>%
  count(match_key, resolved) %>% as.data.frame() %>% print()

# Strongest available key per midwife; ambiguous keys never name an employer.
rank_of <- c(telephone = 1L, zip9_address = 2L, zip5_address = 3L)
person <- links %>%
  filter(!is.na(organization_name)) %>%
  mutate(r = rank_of[match_key]) %>%
  arrange(certification_number, r, organization_name) %>%
  group_by(certification_number) %>% slice(1) %>% ungroup() %>%
  select(certification_number, npi, org_npi, organization_name,
         match_key, loc_type)

amb_only <- links %>%
  group_by(certification_number) %>%
  summarise(any_resolved = any(!is.na(organization_name)),
            any_link = n() > 0, .groups = "drop") %>%
  filter(any_link, !any_resolved)

cat(sprintf("\nmidwives with a NAMED organization: %s (%.1f%% of cohort)\n",
            format(nrow(person), big.mark = ","), 100 * nrow(person) / N))
cat(sprintf("midwives whose locations matched only AMBIGUOUS keys: %s\n",
            format(nrow(amb_only), big.mark = ",")))
cat("\ntop organizations:\n")
person %>% count(organization_name, sort = TRUE) %>% head(12) %>%
  as.data.frame() %>% print()

write_csv(links,  "artifacts/midwife_org_links.csv",  na = "")
write_csv(person, "artifacts/midwife_org_person.csv", na = "")
cat("\nwritten: artifacts/midwife_org_links.csv, artifacts/midwife_org_person.csv\n")
