#!/usr/bin/env Rscript
# =============================================================================
# Resolve ambiguous midwife -> Type-2 organization matches, conservatively
# =============================================================================
# link_practice_locations_to_org_npi.R named an organization for 4,728 midwives
# and left 4,750 whose locations matched only AMBIGUOUS keys -- keys where more
# than one Type-2 NPI is registered. This script attacks those, under one rule:
#
#   THE GOAL IS NOT TO MAXIMISE ASCERTAINMENT. Resolve only where additional
#   INDEPENDENT evidence makes exactly one organization defensible.
#
# Never resolved by: first row, largest organization, nearest organization, or
# the most medical-sounding name.
#
# A MIDWIFE MAY LEGITIMATELY PRACTISE AT SEVERAL ORGANIZATIONS. The output is
# LONG -- one row per (midwife, organization) -- so a hospital, a physician
# group and a satellite clinic can all be retained. Where two organizations
# each hold strong independent evidence, BOTH are kept rather than one being
# declared wrong. A single primary_organization is derived only where the
# evidence supports one.
#
# TIERS
#   A  unique strong key (telephone, or ZIP+4 + street), or the same org
#      agreeing across >=2 independent keys                 -> high
#   B  taxonomy EXCLUSION: remove incompatible organizations (dental,
#      optometry, podiatry, pharmacy, ambulance, DME, lab). If exactly one
#      plausible candidate remains, promote it              -> moderate
#      Never promoted merely for BEING a hospital/OB-GYN/FQHC/health system.
#   D  cross-source corroboration: an independent artifact (hospital CCN name,
#      Open Payments address) agrees with exactly one candidate
#                                                           -> moderate/high
#   E  ZIP5-only, shared office building, proximity, city/state: LEFT
#      AMBIGUOUS. Not resolved.
#
# Tier C (name evidence) is recorded as corroboration on the row but never
# promotes on its own, per spec.
#
# WRITES A NEW ARTIFACT. The existing conservative output is not modified.
#
# Outputs: artifacts/midwife_org_affiliations_candidate.csv  (long form)
#          artifacts/midwife_org_person_candidate.csv        (provider level)
#          artifacts/org_resolution_review_sample.csv        (stratified, for
#                                                             human review)
#          artifacts/org_resolution_distribution_shift.csv   (before/after)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
  library(stringr); library(tibble)
})
source("R/lib/address_keys.R")   # norm_addr/zip5/zip9/phone10: one definition
source("R/lib/common_helpers.R")

DB <- Sys.getenv("MEDICARE_DUCKDB",
                 "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb")
PL <- Sys.getenv("PL_FILE", file.path(
  "/Volumes/MufflySamsung/nppes_historical_downloads/august_2026",
  "pl_pfile_20050523-20260809.csv"))
PL_VINTAGE <- "NPPES pl_pfile 2026-08-09"
SEED <- 20260811L   # fixed so the review sample is reproducible

# KEY PROMISCUITY CAP. A key shared by very many organizations is shared
# infrastructure -- a switchboard or a campus mailing address -- not evidence
# of a shared practice. Measured nationally, a phone number maps to a median
# of 1 organization; 99% map to <=6; the maximum is 880. A cap of 10 discards
# 0.3% of phone keys while removing the switchboards that otherwise let one
# midwife inherit every organization on a hospital campus (max 85 affiliations
# before this cap). Tunable so the choice can be shown as a sensitivity.
MAX_KEY_ORGS <- suppressWarnings(as.integer(Sys.getenv("MAX_KEY_ORGS", "10")))

# --- Tier B: taxonomies INCOMPATIBLE with a CNM practice affiliation ----------
# NUCC prefixes. This list only ever REMOVES candidates; nothing here promotes
# an organization. Kept deliberately short: an organization is excluded only
# where co-location with a midwifery practice is implausible, not merely
# unusual. Behavioral health, home health and nursing facilities are NOT
# excluded -- midwives do co-locate with those.
INCOMPATIBLE <- c(
  "^12"    ,  # dental providers
  "^1223"  ,  # dentist specialties
  "^152W"  ,  # optometrist
  "^207W"  ,  # ophthalmology
  "^213E"  ,  # podiatrist
  "^3336"  ,  # pharmacy
  "^3416"  ,  # ambulance
  "^332"   ,  # DME / medical supply
  "^291U"  ,  # clinical medical laboratory
  "^293D"  ,  # physiological laboratory
  "^302F"  ,  # exclusive provider organization
  "^156F"  ,  # technician/optician
  "^111N"  ,  # chiropractic
  "^122"      # dental hygienist etc.
)
is_incompatible <- function(tax) {
  t <- toupper(str_trim(replace(as.character(tax), is.na(as.character(tax)), "")))
  Reduce(`|`, lapply(INCOMPATIBLE, function(p) str_detect(t, p)), FALSE)
}

# --- cohort and locations ----------------------------------------------------
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

prim <- dbGetQuery(con, '
  SELECT CAST(a.NPI AS VARCHAR) AS npi,
         a."Provider First Line Business Practice Location Address" AS addr,
         a."Provider Business Practice Location Address Postal Code" AS zip,
         a."Provider Business Practice Location Address Telephone Number" AS phone
    FROM npi_2024 a INNER JOIN c_npi c ON CAST(a.NPI AS VARCHAR) = c.npi') %>%
  mutate(loc_type = "primary")

pl <- chr(PL)
names(pl) <- names(pl) %>% str_replace_all("[^A-Za-z0-9]+", "_") %>% tolower()
pick <- function(pat) grep(pat, names(pl), value = TRUE)[1]
sec <- pl %>%
  transmute(npi = .data[[grep("^npi$", names(pl), value = TRUE)[1]]],
            addr = .data[[pick("address_line_1")]],
            zip  = .data[[pick("postal_code")]],
            phone= .data[[pick("telephone_number$")]],
            loc_type = "secondary") %>%
  semi_join(coh, by = "npi")

locs <- bind_rows(prim, sec) %>%
  mutate(addr_norm = norm_addr(addr), z9 = zip9(zip), z5 = zip5(zip),
         ph = phone10(phone)) %>%
  filter(!is.na(addr_norm) | !is.na(ph)) %>%
  distinct(npi, loc_type, addr_norm, z5, ph, .keep_all = TRUE)
cat(sprintf("cohort locations: %s\n", format(nrow(locs), big.mark = ",")))

org <- dbGetQuery(con, "
  SELECT CAST(npi AS VARCHAR) AS type2_npi, organization_name,
         practice_address_street AS addr, practice_address_zip AS zip,
         practice_phone AS phone, taxonomy_1 AS organization_taxonomy
    FROM npi_org_all
   WHERE NULLIF(TRIM(organization_name), '') IS NOT NULL") %>%
  mutate(addr_norm = norm_addr(addr), z9 = zip9(zip), z5 = zip5(zip),
         ph = phone10(phone),
         # addr_norm is consumed as a join key on the address joins, so dplyr
         # produces no .y copy of it. Keep a duplicate under its own name so
         # the organization's registered address survives the join and can be
         # compared against an independent source in Tier D.
         org_addr_keep = addr_norm)

# --- every candidate, ambiguity preserved ------------------------------------
cand_for <- function(keycols, label, strength) {
  locs %>% filter(if_all(all_of(keycols), ~ !is.na(.x))) %>%
    inner_join(org %>% filter(if_all(all_of(keycols), ~ !is.na(.x))),
               by = keycols, relationship = "many-to-many") %>%
    transmute(npi, type2_npi, organization_name, organization_taxonomy,
              evidence_key = label, evidence_strength = strength,
              loc_type, org_addr_norm = org_addr_keep)
}
cands_all <- bind_rows(
  cand_for("ph", "telephone", "strong"),
  cand_for(c("addr_norm", "z9"), "zip9_address", "strong"),
  cand_for(c("addr_norm", "z5"), "zip5_address", "weak")) %>%
  distinct(npi, type2_npi, evidence_key, .keep_all = TRUE)

# Drop shared-infrastructure keys before any tier sees them.
promisc <- cands_all %>% count(npi, evidence_key, name = "k_orgs")
cands <- cands_all %>% left_join(promisc, by = c("npi", "evidence_key")) %>%
  filter(k_orgs <= MAX_KEY_ORGS) %>% select(-k_orgs)
cat(sprintf("dropped as shared infrastructure (key maps to >%d orgs): %s of %s candidate rows\n",
            MAX_KEY_ORGS, format(nrow(cands_all) - nrow(cands), big.mark = ","),
            format(nrow(cands_all), big.mark = ",")))
cat(sprintf("candidate (midwife, org, key) rows: %s\n", format(nrow(cands), big.mark = ",")))

# How many organizations sit at each (midwife, key)? This is the ambiguity.
amb <- cands %>% count(npi, evidence_key, name = "n_org_at_key")
cands <- cands %>% left_join(amb, by = c("npi", "evidence_key"))

# --- TIER A ------------------------------------------------------------------
# A1: a STRONG key that resolves to exactly one organization.
tierA1 <- cands %>% filter(evidence_strength == "strong", n_org_at_key == 1L) %>%
  mutate(resolution_method = "unique_strong_key", affiliation_confidence = "high")

# A2: the same organization reached by >=2 INDEPENDENT keys.
#
# Independence is by key FAMILY, not by key name. zip9_address and
# zip5_address are NOT independent: ZIP5 is a prefix of ZIP+4, so a single
# address match satisfies both and would "agree with itself". Counting them
# separately promoted 70,629 pairs to high confidence and gave one midwife 135
# affiliations, with Kaiser gaining 71 and an urgent-care centre 33 -- the
# distribution check caught it. Only phone-vs-address counts as agreement.
tierA2 <- cands %>%
  mutate(key_family = if_else(evidence_key == "telephone", "phone", "address")) %>%
  group_by(npi, type2_npi) %>%
  summarise(n_keys = n_distinct(key_family),
            keys = paste(sort(unique(evidence_key)), collapse = "+"),
            organization_name = first(organization_name),
            organization_taxonomy = first(organization_taxonomy),
            .groups = "drop") %>%
  filter(n_keys >= 2L) %>%
  transmute(npi, type2_npi, organization_name, organization_taxonomy,
            evidence_key = keys, evidence_strength = "strong",
            resolution_method = "multi_key_agreement",
            affiliation_confidence = "high")

resolved_A <- bind_rows(
  tierA1 %>% select(npi, type2_npi, organization_name, organization_taxonomy,
                    evidence_key, evidence_strength, resolution_method,
                    affiliation_confidence),
  tierA2) %>%
  distinct(npi, type2_npi, .keep_all = TRUE)
cat(sprintf("\nTier A resolved (midwife-org pairs): %s across %s midwives\n",
            format(nrow(resolved_A), big.mark = ","),
            format(n_distinct(resolved_A$npi), big.mark = ",")))

# --- TIER B: taxonomy EXCLUSION on ambiguous strong keys ---------------------
amb_strong <- cands %>%
  filter(evidence_strength == "strong", n_org_at_key > 1L) %>%
  anti_join(resolved_A, by = "npi")

tierB <- amb_strong %>%
  mutate(bad = is_incompatible(organization_taxonomy)) %>%
  group_by(npi, evidence_key) %>%
  filter(!bad) %>%
  mutate(n_left = n_distinct(type2_npi)) %>%
  ungroup() %>%
  filter(n_left == 1L) %>%
  distinct(npi, type2_npi, .keep_all = TRUE) %>%
  transmute(npi, type2_npi, organization_name, organization_taxonomy,
            evidence_key, evidence_strength,
            resolution_method = "taxonomy_exclusion_unique",
            affiliation_confidence = "moderate")
cat(sprintf("Tier B resolved by taxonomy exclusion: %s midwives\n",
            format(n_distinct(tierB$npi), big.mark = ",")))

# --- TIER D: cross-source corroboration --------------------------------------
ext <- tibble(npi = character(), ext_value = character(), ext_source = character())
if (file.exists("artifacts/dac_facility_affiliations.csv")) {
  d <- chr("artifacts/dac_facility_affiliations.csv")
  if (all(c("npi", "facility_name") %in% names(d)))
    ext <- bind_rows(ext, d %>% filter(!is.na(facility_name)) %>%
      transmute(npi, ext_value = norm_addr(facility_name), ext_source = "hospital_ccn_name"))
}
op_addr <- NULL
if (file.exists("artifacts/open_payments_recent_address.csv")) {
  op_addr <- chr("artifacts/open_payments_recent_address.csv") %>%
    transmute(npi, op_addr_norm = norm_addr(addr)) %>% filter(!is.na(op_addr_norm))
}

amb_rest <- cands %>%
  anti_join(resolved_A, by = "npi") %>% anti_join(tierB, by = "npi") %>%
  filter(n_org_at_key > 1L)

tierD <- tibble()
if (!is.null(op_addr) && nrow(amb_rest)) {
  # An independent source (Open Payments) puts the midwife at the candidate's
  # own registered address. Agreement with exactly one candidate breaks the tie.
  d1 <- amb_rest %>% inner_join(op_addr, by = "npi") %>%
    filter(!is.na(org_addr_norm), org_addr_norm == op_addr_norm) %>%
    group_by(npi) %>% filter(n_distinct(type2_npi) == 1L) %>% ungroup() %>%
    distinct(npi, type2_npi, .keep_all = TRUE) %>%
    transmute(npi, type2_npi, organization_name, organization_taxonomy,
              evidence_key, evidence_strength,
              resolution_method = "cross_source_open_payments_address",
              affiliation_confidence = "moderate")
  tierD <- bind_rows(tierD, d1)
}
if (nrow(ext) && nrow(amb_rest)) {
  d2 <- amb_rest %>% inner_join(ext, by = "npi", relationship = "many-to-many") %>%
    filter(norm_addr(organization_name) == ext_value) %>%
    group_by(npi) %>% filter(n_distinct(type2_npi) == 1L) %>% ungroup() %>%
    distinct(npi, type2_npi, .keep_all = TRUE) %>%
    transmute(npi, type2_npi, organization_name, organization_taxonomy,
              evidence_key, evidence_strength,
              resolution_method = "cross_source_hospital_ccn_name",
              affiliation_confidence = "moderate")
  tierD <- bind_rows(tierD, d2)
}
cat(sprintf("Tier D resolved by cross-source: %s midwives\n",
            format(if (nrow(tierD)) n_distinct(tierD$npi) else 0L, big.mark = ",")))

# --- assemble long form ------------------------------------------------------
long <- bind_rows(resolved_A, tierB, tierD) %>%
  distinct(npi, type2_npi, .keep_all = TRUE) %>%
  mutate(source_vintage = PL_VINTAGE) %>%
  left_join(coh, by = "npi") %>%
  select(certification_number, npi, type2_npi, organization_name,
         organization_taxonomy, evidence_key, evidence_strength,
         resolution_method, affiliation_confidence, source_vintage)

# Tier E: everything still ambiguous stays ambiguous, and is counted.
still_amb <- cands %>% anti_join(long, by = "npi") %>% distinct(npi)

cat(sprintf("\n=== LONG-FORM AFFILIATIONS ===\n"))
cat(sprintf("rows: %s | midwives: %s (%.1f%% of cohort)\n",
            format(nrow(long), big.mark = ","),
            format(n_distinct(long$npi), big.mark = ","),
            100 * n_distinct(long$npi) / N))
cat("\nby confidence:\n"); print(long %>% count(affiliation_confidence))
cat("\nby resolution method:\n"); print(long %>% count(resolution_method, sort = TRUE))

multi <- long %>% count(npi, name = "n_orgs") %>% filter(n_orgs > 1L)
cat(sprintf("\nmidwives with MULTIPLE retained affiliations: %s (max %d)\n",
            format(nrow(multi), big.mark = ","),
            if (nrow(multi)) max(multi$n_orgs) else 0L))
cat(sprintf("still ambiguous, deliberately unresolved: %s\n",
            format(nrow(still_amb), big.mark = ",")))

write_csv(long, "artifacts/midwife_org_affiliations_candidate.csv", na = "")

# --- provider-level summary for Table 1 --------------------------------------
rank_conf <- c(high = 1L, moderate = 2L, weak = 3L)
person <- long %>%
  mutate(r = rank_conf[affiliation_confidence]) %>%
  arrange(certification_number, r, organization_name) %>%
  group_by(certification_number) %>%
  summarise(npi = first(npi),
            n_affiliations = n(),
            primary_organization = first(organization_name),
            primary_type2_npi = first(type2_npi),
            best_confidence = first(affiliation_confidence),
            resolution_method = first(resolution_method),
            .groups = "drop")
write_csv(person, "artifacts/midwife_org_person_candidate.csv", na = "")
cat(sprintf("\nprovider-level rows: %s\n", format(nrow(person), big.mark = ",")))

# --- validation: distribution shift ------------------------------------------
old <- if (file.exists("artifacts/midwife_org_person.csv"))
  chr("artifacts/midwife_org_person.csv") else NULL
if (!is.null(old)) {
  before <- old %>% count(organization_name, name = "n_before")
  after  <- person %>% count(primary_organization, name = "n_after") %>%
    rename(organization_name = primary_organization)
  shift <- full_join(before, after, by = "organization_name") %>%
    mutate(across(c(n_before, n_after), ~ coalesce(as.integer(.x), 0L)),
           gain = n_after - n_before) %>%
    arrange(desc(gain))
  write_csv(shift, "artifacts/org_resolution_distribution_shift.csv", na = "")
  cat("\n=== organizations gaining the most midwives (implausible gains are a red flag) ===\n")
  print(shift %>% head(10) %>% as.data.frame())
}

# --- validation: stratified review sample ------------------------------------
set.seed(SEED)
strata <- list(
  telephone        = long %>% filter(evidence_key == "telephone",
                                     resolution_method == "unique_strong_key"),
  zip9             = long %>% filter(evidence_key == "zip9_address",
                                     resolution_method == "unique_strong_key"),
  taxonomy_excl    = long %>% filter(resolution_method == "taxonomy_exclusion_unique"),
  cross_source     = long %>% filter(str_starts(resolution_method, "cross_source")),
  multi_key        = long %>% filter(resolution_method == "multi_key_agreement"))
samp <- bind_rows(lapply(names(strata), function(s) {
  d <- strata[[s]]
  if (!nrow(d)) return(NULL)
  d %>% slice_sample(n = min(25L, nrow(d))) %>% mutate(review_stratum = s)
}))
amb_samp <- cands %>% semi_join(still_amb, by = "npi") %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>%
  slice_sample(n = min(25L, nrow(still_amb))) %>%
  transmute(npi, type2_npi, organization_name, organization_taxonomy,
            evidence_key, evidence_strength,
            resolution_method = "LEFT_AMBIGUOUS",
            affiliation_confidence = "none",
            review_stratum = "left_ambiguous")
# Review captures WHY a match fails, not just whether. A single overall PPV
# would hide the thing evidence tiers exist to expose -- telephone matches may
# be near-perfect while taxonomy-exclusion matches are not.
samp <- bind_rows(samp, amb_samp) %>%
  mutate(human_verdict = "",   # correct | incorrect | indeterminate
         error_type    = "",   # wrong_organization | multiple_legitimate_affiliations |
                               # address_collision | taxonomy_misleading |
                               # stale_location | source_conflict | other
         review_notes  = "")
write_csv(samp, "artifacts/org_resolution_review_sample.csv", na = "")
cat(sprintf("\nreview sample written: %s rows across %d strata (human_verdict blank for review)\n",
            format(nrow(samp), big.mark = ","), n_distinct(samp$review_stratum)))
cat("  artifacts/org_resolution_review_sample.csv\n")
