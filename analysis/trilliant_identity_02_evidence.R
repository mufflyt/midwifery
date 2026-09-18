#!/usr/bin/env Rscript
# =============================================================================
# Trilliant identity experiment, step 2: candidate evidence for AMCB -> NPI
# =============================================================================
# READ-ONLY. Nothing here changes the canonical linkage, mysterynpi, or any
# freeze. It asks one question: used as a second national provider master
# beside NPPES, does Trilliant's provider directory add identity evidence?
#
# FOUR STRATA of AMCB certificants, each person x candidate NPI scored:
#   1_control_high_confidence  primary-tier matches at evidence class 1 (exact
#                              first + last + middle), unique at that class,
#                              and the shadow arm agrees on the NPI
#   2_ambiguous                tied names, contested NPIs, unruled-out
#                              components, class-5 held out
#   3_production_vs_shadow     the freeze and the shadow arm name different
#                              NPIs (or only one of them names one)
#   4_unmatched_active         ACTIVE certificants with no candidate at all
# A person in more than one stratum is reported under the first of 3, 2, 4, 1.
#
# CANDIDATES come from the linkage (canonical NPI, shadow NPI, held-out class-5
# NPI, the matcher's candidate pool) AND from a search of the WHOLE Trilliant
# directory by name, across every specialty, so the search is not limited to
# NPIs the NPPES matcher already saw. The search blocks on a surname token (from
# the AMCB surname or middle name, against the Trilliant surname or middle
# name) plus a first initial (of the AMCB first or middle name), then keeps a
# pair only if mysterynpi's surname rule corroborates and the given names are
# compatible. One gap is deliberate: a nickname with a different initial
# (PEGGY / MARGARET) is not searched, because mysterynpi reserves nickname
# expansion to npi_search(). Such pairs still arrive through the matcher pool.
#
# EVIDENCE CLASSES. Identity evidence: name, middle name, sex, credential,
# specialty, school, graduation year. Contextual evidence: organization,
# practice location, active flag, practice count, patient panel, attribution
# quality. Only identity evidence enters the score. Context is reported beside
# it and never establishes an identity on its own. active_provider = FALSE is
# never evidence of a wrong identity. A specialty or location mismatch is never
# a veto on its own.
#
# NO HAND-SET WEIGHTS. Each identity field's weight is a log2 likelihood ratio,
# P(level | true match) / P(level | same-name decoy), estimated from stratum 1:
# the canonical NPI is the true match, and every other candidate of the same
# certificant is a decoy. Stratum-1 scores are cross-fitted (two folds by
# certificant), so no person is scored with weights learned from themselves.
# "Uninformative" levels (missing on either side) weigh 0 by rule. The two
# decision thresholds (score floor, winning margin) are read off the stratum-1
# calibration at PRECISION_TARGET; they are not chosen by hand either.
#
# LIMITS, stated up front because they bound every number:
#   * No adjudicated truth set is on this machine (artifacts/truth/ holds only
#     the protocol; the 327-row instrument and its verdicts are absent), so the
#     "gold standard" here is a silver one: high-confidence matches vs decoys.
#     Where a genuine state board (WA, CO, TX) lists the certificant, a license
#     number that also appears in the candidate's NPPES record is reported as
#     independent confirmation.
#   * Stratum 1 was SELECTED on NPPES name agreement and midwifery taxonomy.
#     Trilliant's names and specialty mostly copy NPPES, so their weights are
#     inflated by that selection. Every field carries a selection_coupled flag
#     and an NPPES-redundancy rate.
#   * AMCB records no address, sex or school, so geography cannot be compared
#     with the certificant; it is compared only with a genuine board license
#     state and with the candidate's own NPPES address.
#
# Inputs (arguments or environment variables; see R/analysis_args.R):
#   1 LINKAGE_CSV          production linkage freeze (person-level)
#   2 SHADOW_CSV           the shadow arm to compare against
#   3 CANDIDATE_AUDIT_CSV  the matcher's candidate pool (amcb_id, npi, ...)
#   4 TRILLIANT_LAKE       lake data/main directory
#   5 NPPES_SLIM           analysis/trilliant_identity_nppes_slim.parquet (step 0)
#   artifacts/live_{washington,colorado,texas}_bon_*.csv  genuine board records
#   data/acme_accredited_midwifery_programs.csv
# Outputs (all gitignored: analysis/*.csv, *.parquet):
#   analysis/trilliant_identity_pairs.csv          person x candidate evidence
#   analysis/trilliant_identity_person_audit.csv   one row per person: action + reason
#   analysis/trilliant_identity_field_weights.csv  per field level: m, u, weight
#   analysis/trilliant_identity_field_value.csv    per field: coverage, AUC, redundancy
#   analysis/trilliant_identity_calibration.csv    thresholds and their precision
#   analysis/trilliant_identity_audit_counts.csv   stratum x action counts
#   analysis/trilliant_identity_run_manifest.csv   input hashes
#
# Trilliant ToS 2.2(b): source attribution, "Trilliant Health provider
# directory". 2.3(i)/(iii): no redistribution of derived data, hence gitignored
# outputs only.
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(readr); library(stringr); library(tidyr); library(purrr)
})
suppressPackageStartupMessages(library(mysterynpi))
source(file.path("R", "analysis_args.R"))           # arg_or()
source(file.path("R", "lib", "medicare_duckdb.R"))  # samsung_volume_path()
source("credential_compatibility.R")                # classify_credentials()

LINKAGE    <- arg_or(1, "LINKAGE_CSV")
SHADOW     <- arg_or(2, "SHADOW_CSV")
POOL       <- arg_or(3, "CANDIDATE_AUDIT_CSV")
LAKE       <- arg_or(4, "TRILLIANT_LAKE", samsung_volume_path("hpt_prices/trilliant/20260721/lake/data/main"))
NPPES_SLIM <- arg_or(5, "NPPES_SLIM", "analysis/trilliant_identity_nppes_slim.parquet")
PRECISION_TARGET <- 0.99
OUT <- function(x) file.path("analysis", paste0("trilliant_identity_", x))
SEARCH_CACHE <- OUT("search_pairs.parquet")

db_exec("SET memory_limit='5GB'")
db_exec("SET threads=3")
set.seed(20260914)

# The name rules are per-element and slow; evaluate each on distinct values.
memo <- function(f) function(x) { u <- unique(x); f(u)[match(x, u)] }
# AMCB (and some registry records) fuse middle names into the first-name field
# ("Kirstin Sasha"). The matcher splits them with mysterynpi::split_given(); so
# does this, on both sides, and compares the combined middle ("*_middle_cmp").
# Raw fields are kept untouched beside it.
mid_from_given <- memo(function(x) coalesce(split_given(x)$middle_from_given, ""))
join_middle <- function(middle, first) {
  x <- str_squish(paste(coalesce(middle, ""), mid_from_given(first)))
  if_else(x == "", NA_character_, x)
}

# ---- 1. the linkage and the strata ---------------------------------------------
rd <- function(p) read_csv(p, col_types = cols(.default = "c"), guess_max = Inf, progress = FALSE)
fz <- rd(LINKAGE)
sh <- rd(SHADOW)
stopifnot(!anyDuplicated(fz$amcb_id), !anyDuplicated(sh$amcb_id), setequal(fz$amcb_id, sh$amcb_id))

AMBIGUOUS <- c("ambiguous_tied_names", "ambiguous_contested_npi",
               "ambiguous_unruled_out_component", "candidate_class5_held_out_of_cohort")
blank_na <- function(x) if_else(is.na(x) | str_trim(x) == "", NA_character_, x)
people_all <- fz |>
  transmute(amcb_id, certification_number, status, certification,
            cert_year = as.integer(str_sub(certification_date, -4L)),
            first_name, middle_name = blank_na(middle_name), last_name,
            middle_cmp = join_middle(blank_na(middle_name), first_name),
            linkage_tier, npi_match_status, name_evidence_class, npi_match_resolution, n_at_best_class,
            current_canonical_npi = blank_na(npi),
            current_match_tier = paste(linkage_tier, npi_match_status, sep = "/"),
            class5_candidate_npi = blank_na(class5_candidate_npi),
            nppes_state_canonical = nppes_state) |>
  left_join(sh |> transmute(amcb_id, shadow_npi = blank_na(npi), shadow_match_status = npi_match_status),
            by = "amcb_id", relationship = "one-to-one") |>
  mutate(
    in_s1 = linkage_tier == "primary_midwifery" & !is.na(current_canonical_npi) &
      name_evidence_class == "1" & npi_match_resolution == "unique_best_class_with_middle" &
      n_at_best_class == "1" & coalesce(shadow_npi == current_canonical_npi, FALSE),
    in_s2 = npi_match_status %in% AMBIGUOUS,
    in_s3 = coalesce(current_canonical_npi, "") != coalesce(shadow_npi, ""),
    in_s4 = status == "ACTIVE" & npi_match_status == "unmatched",
    stratum = case_when(in_s3 ~ "3_production_vs_shadow", in_s2 ~ "2_ambiguous",
                        in_s4 ~ "4_unmatched_active", in_s1 ~ "1_control_high_confidence"))
people <- people_all |> filter(!is.na(stratum))
cat("people per stratum:\n"); print(count(people, stratum))

# Every NPI the freeze already gives to someone: a proposal may not take one.
held <- fz |> filter(!is.na(blank_na(npi))) |> distinct(npi, holder = amcb_id)

# ---- 2. candidates the linkage already knows ----------------------------------
pool <- rd(POOL) |> distinct(amcb_id, npi)
link_cands <- bind_rows(
  people |> transmute(amcb_id, npi = current_canonical_npi, src = "canonical"),
  people |> transmute(amcb_id, npi = shadow_npi, src = "shadow"),
  people |> transmute(amcb_id, npi = class5_candidate_npi, src = "class5_held_out"),
  pool |> semi_join(people, by = "amcb_id") |> mutate(src = "matcher_pool")
) |> filter(!is.na(npi))

# ---- 3. search the whole Trilliant directory by name -------------------------
trl <- read_parquet_duckdb(file.path(LAKE, "directory_provider", "*.parquet"), prudence = "stingy")

# Blocking tokens only: a SUPERSET, cheap enough for 900k distinct surnames.
# mysterynpi's surname_agreement() decides the survivors below.
block_tokens <- function(x, id) {
  k <- gsub("'", "", toupper(stringi::stri_trans_general(x, "Latin-ASCII")), fixed = TRUE)
  parts <- strsplit(k, "[^A-Z]+")
  bind_rows(tibble(id = rep(id, lengths(parts)), token = unlist(parts, use.names = FALSE)),
            tibble(id = id, token = gsub("[^A-Z]", "", k))) |>
    filter(!is.na(token), nchar(token) >= 2L, !token %in% SURNAME_PARTICLES) |>
    distinct()
}
initial_of <- function(x) substr(gsub("[^A-Z]", "", toupper(stringi::stri_trans_general(coalesce(x, ""), "Latin-ASCII"))), 1L, 1L)

if (file.exists(SEARCH_CACHE) && Sys.getenv("REFRESH_SEARCH") != "1") {
  search <- read_parquet_duckdb(SEARCH_CACHE) |> collect()
  cat("name search: read cache", SEARCH_CACHE, "\n")
} else {
  a_last <- block_tokens(people$last_name, people$amcb_id)
  a_mid  <- block_tokens(people$middle_cmp, people$amcb_id) |> filter(nchar(token) >= MIN_SURNAME_TOKEN)
  a_init <- bind_rows(tibble(id = people$amcb_id, init = initial_of(people$first_name)),
                      tibble(id = people$amcb_id, init = initial_of(people$middle_cmp))) |>
    filter(init != "") |> distinct()
  # (a) Trilliant surname against the AMCB surname or middle name (maiden as middle)
  key_last <- bind_rows(a_last, a_mid) |> distinct() |>
    inner_join(a_init, by = "id", relationship = "many-to-many") |> rename(amcb_id = id)
  # (b) Trilliant middle name against the AMCB surname (Trilliant keeps the old surname as middle)
  key_mid <- a_last |> inner_join(a_init, by = "id", relationship = "many-to-many") |> rename(amcb_id = id)

  dl <- trl |> distinct(provider_last_name) |> collect()
  tl <- block_tokens(dl$provider_last_name, dl$provider_last_name) |>
    rename(provider_last_name = id) |> semi_join(key_last, by = "token")
  dm <- trl |> filter(!is.na(provider_middle_name)) |> distinct(provider_middle_name) |> collect()
  tm <- block_tokens(dm$provider_middle_name, dm$provider_middle_name) |>
    rename(provider_middle_name = id) |> semi_join(key_mid, by = "token")

  hits <- function(tok_map, by_col, keys) {
    trl |>
      select(provider_npi, provider_first_name, all_of(by_col)) |>
      inner_join(as_duckdb_tibble(tok_map), by = by_col, relationship = "many-to-many") |>
      mutate(init = dd$upper(substr(provider_first_name, 1L, 1L))) |>   # dd$: DuckDB's upper()
      inner_join(as_duckdb_tibble(keys), by = c("token", "init"), relationship = "many-to-many") |>
      distinct(amcb_id, provider_npi) |>
      collect()
  }
  search <- bind_rows(hits(tl, "provider_last_name", key_last),
                      hits(tm, "provider_middle_name", key_mid)) |>
    distinct() |>
    transmute(amcb_id, npi = format(provider_npi, scientific = FALSE, trim = TRUE))
  cat(sprintf("name search: %s blocked pairs over %s people\n",
              format(nrow(search), big.mark = ","), format(n_distinct(search$amcb_id), big.mark = ",")))
  write_parquet_duckdb <- function(df, path) as_duckdb_tibble(df) |> compute_parquet(path)
  write_parquet_duckdb(search, SEARCH_CACHE)
}

lead_given <- memo(function(x) sub(" .*$", "", gsub(".", "", coalesce(name_key(x), ""), fixed = TRUE)))
full_tokens <- memo(function(x) lapply(middle_tokens(x), function(t) t[nchar(t) >= 2L]))
all_tokens <- memo(middle_tokens)
sk <- memo(function(x) gsub("'", "", name_key(x), fixed = TRUE))

#' Given-name and surname verdicts for person x candidate rows
#'
#' Given names: mysterynpi's positional rule (equal, recorded nickname, or an
#' initial against a full token; never initial against initial), evaluated
#' through nickname_agreement() on DISTINCT pairs, because
#' names_have_compatible_given() costs ~12 ms a pair here. A given-name
#' conflict where one side's first name is the other's middle name is kept
#' apart as "middle_as_first". Surnames: exact key, else mysterynpi's
#' surname_agreement() on DISTINCT combinations (component, maiden-as-middle,
#' NPPES recorded former surname).
name_verdicts <- function(p, drop_given_conflicts = FALSE) {
  p <- p |> mutate(a = lead_given(first_name), b = lead_given(trl_first_name))
  gp <- p |> filter(trilliant_found) |> distinct(a, b)
  gp <- gp |> mutate(nick = nickname_agreement(a, b),
                     given_level = case_when(a == "" | b == "" ~ "uninformative",
                                             a == b & nchar(a) >= 2L ~ "exact",
                                             nchar(a) == 1L & nchar(b) == 1L ~ "initial_vs_initial",
                                             nick == "corroborates" & (nchar(a) == 1L | nchar(b) == 1L) ~ "initial",
                                             nick == "corroborates" ~ "nickname",
                                             TRUE ~ "conflicts"))
  p <- p |> left_join(gp |> select(a, b, given_level), by = c("a", "b"))
  mf <- p |> filter(trilliant_found, given_level == "conflicts") |> distinct(a, b, middle_cmp, trl_middle_cmp)
  mf$middle_as_first <- mapply(function(ta, tt, a, b) (nchar(b) >= 2L && b %in% ta) || (nchar(a) >= 2L && a %in% tt),
                               full_tokens(mf$middle_cmp), full_tokens(mf$trl_middle_cmp), mf$a, mf$b)
  p <- p |>
    left_join(mf, by = c("a", "b", "middle_cmp", "trl_middle_cmp")) |>
    mutate(ag_first = case_when(!trilliant_found ~ "uninformative",
                                given_level == "conflicts" & coalesce(middle_as_first, FALSE) ~ "middle_as_first",
                                TRUE ~ given_level),
           sur_exact = trilliant_found & coalesce(sk(last_name) == sk(trl_last_name), FALSE)) |>
    select(-a, -b, -given_level, -middle_as_first)
  if (drop_given_conflicts) p <- p |> filter(ag_first %in% GIVEN_OK)
  sc <- p |> filter(trilliant_found, !sur_exact) |>
    distinct(last_name, trl_last_name, middle_cmp, trl_middle_cmp, nppes_other_last)
  sc$verdict <- surname_agreement(sc$last_name, sc$trl_last_name, sc$middle_cmp, sc$trl_middle_cmp,
                                  alternates_b = sc$nppes_other_last)
  sc$mtype <- name_surname_match_type(sc$last_name, sc$trl_last_name)
  p |>
    left_join(sc, by = c("last_name", "trl_last_name", "middle_cmp", "trl_middle_cmp", "nppes_other_last")) |>
    mutate(ag_surname = case_when(!trilliant_found ~ "uninformative",
                                  sur_exact ~ "exact",
                                  verdict == "corroborates" & mtype != "none" ~ "component",
                                  verdict == "corroborates" ~ "cross_slot_or_former",
                                  verdict == "uninformative" ~ "uninformative",
                                  TRUE ~ "conflicts")) |>
    select(-verdict, -mtype, -sur_exact)
}
GIVEN_OK <- c("exact", "nickname", "initial", "middle_as_first")
SURNAME_OK <- c("exact", "component", "cross_slot_or_former")

# The search blocks loosely (6-7 million pairs); apply the name rules to names
# alone before fetching every field for the survivors.
blocked <- search |>
  inner_join(people |> select(amcb_id, first_name, middle_cmp, last_name), by = "amcb_id")
trl_names <- trl |>
  semi_join(as_duckdb_tibble(tibble(provider_npi = as.numeric(unique(blocked$npi)))), by = "provider_npi") |>
  select(provider_npi, trl_first_name = provider_first_name, trl_middle_name = provider_middle_name,
         trl_last_name = provider_last_name) |>
  collect() |>
  mutate(npi = format(provider_npi, scientific = FALSE, trim = TRUE), .keep = "unused")
nppes_alt <- read_parquet_duckdb(NPPES_SLIM) |>
  semi_join(as_duckdb_tibble(tibble(npi = unique(blocked$npi))), by = "npi") |>
  filter(!is.na(other_last)) |> select(npi, nppes_other_last = other_last) |> collect()
blocked <- blocked |>
  left_join(trl_names, by = "npi") |>
  left_join(nppes_alt, by = "npi") |>
  mutate(trilliant_found = TRUE, trl_middle_cmp = join_middle(trl_middle_name, trl_first_name))
n_blocked <- nrow(blocked)
blocked <- blocked |> name_verdicts(drop_given_conflicts = TRUE)
search <- blocked |> filter(ag_first %in% GIVEN_OK, ag_surname %in% SURNAME_OK) |> select(amcb_id, npi)
cat(sprintf("name rules: %s blocked pairs -> %s candidate pairs over %s people\n",
            format(n_blocked, big.mark = ","), format(nrow(search), big.mark = ","),
            format(n_distinct(search$amcb_id), big.mark = ",")))
rm(blocked, trl_names, nppes_alt)

# ---- 4. Trilliant and NPPES values for every candidate ------------------------
cand <- bind_rows(link_cands, search |> mutate(src = "trilliant_name_search")) |>
  group_by(amcb_id, npi) |>
  summarise(candidate_source = paste(sort(unique(src)), collapse = ";"), .groups = "drop")
cand_npis <- tibble(provider_npi = as.numeric(unique(cand$npi)))

trl_c <- trl |>
  semi_join(as_duckdb_tibble(cand_npis), by = "provider_npi") |>
  select(provider_npi, active_provider, provider_first_name, provider_middle_name, provider_last_name,
         provider_suffix, provider_credential, provider_gender, provider_medical_school_name,
         provider_medical_school_graduation_year, provider_primary_specialty_code,
         provider_primary_specialty_description, provider_specialty_classification,
         primary_organization_name, provider_practices_total, panel_median_age,
         panel_percent_age_20_44, panel_percent_female, provider_affiliated_practice_1_name,
         provider_affiliated_practice_1_city, provider_affiliated_practice_1_state,
         provider_affiliated_practice_1_zip_code, provider_affiliated_practice_1_visits_percent_total) |>
  collect() |>
  mutate(npi = format(provider_npi, scientific = FALSE, trim = TRUE), .keep = "unused")
# Raw values, renamed only: trl_ prefix, never transformed.
names(trl_c) <- names(trl_c) |>
  sub(pattern = "^provider_affiliated_practice_1_", replacement = "trl_p1_") |>
  sub(pattern = "^provider_medical_school_name$", replacement = "trl_school") |>
  sub(pattern = "^provider_medical_school_graduation_year$", replacement = "trl_grad_year") |>
  sub(pattern = "^provider_", replacement = "trl_") |>
  sub(pattern = "^active_provider$", replacement = "trl_active") |>
  sub(pattern = "^primary_organization_name$", replacement = "trl_org") |>
  sub(pattern = "^panel_percent_", replacement = "trl_panel_pct_") |>
  sub(pattern = "^panel_median_age$", replacement = "trl_panel_median_age")
stopifnot(!anyDuplicated(trl_c$npi), all(c("trl_gender", "trl_school", "trl_p1_state", "trl_active") %in% names(trl_c)))

nppes_raw <- read_parquet_duckdb(NPPES_SLIM) |>
  semi_join(as_duckdb_tibble(tibble(npi = unique(cand$npi))), by = "npi") |>
  collect()
nppes_primary_tax <- nppes_raw |>
  select(npi, starts_with("taxonomy_"), starts_with("primary_switch_")) |>
  pivot_longer(-npi, names_to = c(".value", "slot"), names_pattern = "(taxonomy|primary_switch)_(\\d+)") |>
  filter(!is.na(taxonomy)) |>
  arrange(npi, desc(primary_switch == "Y"), as.integer(slot)) |>
  distinct(npi, .keep_all = TRUE) |>
  select(npi, nppes_primary_taxonomy = taxonomy)
nppes_lic <- nppes_raw |>
  select(npi, starts_with("license_")) |>
  pivot_longer(-npi, names_to = c(".value", "slot"), names_pattern = "(license_state|license)_(\\d+)") |>
  filter(!is.na(license)) |>
  transmute(npi, lic_state = license_state, lic_key = sub("^0+", "", gsub("[^0-9]", "", license))) |>
  filter(nzchar(lic_key)) |> distinct()
nppes <- nppes_raw |>
  transmute(npi, nppes_first = first, nppes_middle = middle, nppes_last = last, nppes_other_last = other_last,
            nppes_credential = credential, nppes_sex = sex, nppes_practice_state = practice_state,
            nppes_zip5 = substr(practice_zip, 1L, 5L),
            nppes_enum_year = as.integer(substr(enumeration_date, 7L, 10L)),
            nppes_deactivated = !is.na(deactivation_date) & is.na(reactivation_date)) |>
  left_join(nppes_primary_tax, by = "npi")

# Genuine state-board licenses (WA, CO, TX live APIs). FL and OR are left out:
# their harvesters are new and not yet reviewed.
bon <- bind_rows(
  read_csv("artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv", col_types = cols(.default = "c")) |>
    filter(live_bon_match_status == "VERIFIED_LIVE_BON") |>
    transmute(certification_number, bon_state = "WA", lic = live_bon_credential_num),
  read_csv("artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv", col_types = cols(.default = "c")) |>
    filter(live_bon_match_status == "VERIFIED_LIVE_BON") |>
    transmute(certification_number, bon_state = "CO", lic = live_bon_credential_num),
  read_csv("artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv", col_types = cols(.default = "c")) |>
    filter(live_bon_match_status == "VERIFIED_LIVE_BON") |>
    transmute(certification_number, bon_state = "TX", lic = live_bon_license_number)
) |>
  mutate(lic_key = sub("^0+", "", gsub("[^0-9]", "", lic))) |>
  filter(nzchar(lic_key))

acme_names <- toupper(read_csv("data/acme_accredited_midwifery_programs.csv", show_col_types = FALSE)$institution)

# ---- 5. agreement fields (raw Trilliant values kept; interpretations beside) --

pairs <- cand |>
  inner_join(people |> select(amcb_id, certification_number, stratum, status, certification, cert_year,
                              first_name, middle_name, middle_cmp, last_name, current_canonical_npi, current_match_tier,
                              shadow_npi, class5_candidate_npi),
             by = "amcb_id") |>
  left_join(trl_c, by = "npi") |>
  left_join(nppes, by = "npi") |>
  mutate(trilliant_found = !is.na(trl_gender),
         trl_middle_cmp = join_middle(trl_middle_name, trl_first_name),
         nppes_middle_cmp = join_middle(nppes_middle, nppes_first),
         is_canonical = coalesce(npi == current_canonical_npi, FALSE),
         is_shadow = coalesce(npi == shadow_npi, FALSE))

pairs <- name_verdicts(pairs)

# Linkage candidates the search also found keep the search label only if they
# pass the name rules; linkage candidates themselves stay, whatever they score,
# because they are what is being evaluated.
pairs <- pairs |>
  mutate(candidate_source = if_else(str_detect(candidate_source, ";") &
                                      !(ag_surname %in% SURNAME_OK & ag_first %in% GIVEN_OK),
                                    str_remove(candidate_source, ";?trilliant_name_search"), candidate_source))
cat(sprintf("pairs scored: %s\n", format(nrow(pairs), big.mark = ",")))

# Middle names as token sets; "full" when a whole token (not an initial) is shared.
mm <- pairs |> distinct(middle_cmp, trl_middle_cmp, nppes_middle_cmp)
mm$verdict <- middle_agreement(all_tokens(mm$middle_cmp), all_tokens(mm$trl_middle_cmp))
mm$full <- mapply(function(x, y) length(intersect(x, y)) > 0L, full_tokens(mm$middle_cmp), full_tokens(mm$trl_middle_cmp))
# The same comparison against NPPES, to see what Trilliant adds.
mm$ag_middle_nppes <- middle_agreement(all_tokens(mm$middle_cmp), all_tokens(mm$nppes_middle_cmp))
pairs <- pairs |>
  left_join(mm, by = c("middle_cmp", "trl_middle_cmp", "nppes_middle_cmp")) |>
  mutate(ag_middle = case_when(!trilliant_found ~ "uninformative",
                               verdict == "corroborates" & full ~ "full",
                               verdict == "corroborates" ~ "initial",
                               TRUE ~ verdict)) |>
  select(-verdict, -full)

stem_of <- function(x) str_squish(strip_med_suffix(toupper(str_squish(x))))
acme_hit <- memo(function(stem) vapply(stem, function(s) !is.na(s) && nchar(s) >= 8L &&
                                         any(str_detect(acme_names, fixed(s))), logical(1)))
spec_class <- function(code) case_when(is.na(code) ~ "uninformative",
                                       code %in% c("367A00000X", "176B00000X") ~ "midwife",
                                       code %in% c("363LW0102X", "363LX0001X") ~ "np_womens_or_ob",
                                       startsWith(code, "363L") ~ "np_other",
                                       startsWith(code, "364S") ~ "cns",
                                       startsWith(code, "163W") ~ "rn",
                                       startsWith(code, "20") ~ "physician",
                                       TRUE ~ "other")
WOMENS <- "OB|GYN|WOMEN|MIDWI|BIRTH|MATERN|OBSTET|PERINAT|LABOR AND DELIVERY"

pairs <- pairs |>
  mutate(
    ag_sex = case_when(trl_gender == "FEMALE" ~ "female", trl_gender == "MALE" ~ "male", TRUE ~ "uninformative"),
    ag_credential = if_else(trilliant_found, classify_credentials(trl_credential), "UNKNOWN"),
    ag_credential = if_else(ag_credential == "UNKNOWN", "uninformative", ag_credential),
    ag_specialty = spec_class(trl_primary_specialty_code),
    school_stem = stem_of(if_else(trl_school %in% "Other", NA_character_, trl_school)),
    ag_school = case_when(is.na(trl_school) ~ "uninformative",
                          # DAC's placeholder names no school: it says only that DAC
                          # has a record, so it is no evidence about which person this is
                          trl_school == "Other" ~ "uninformative",
                          acme_hit(school_stem) ~ "named_acme_university",
                          TRUE ~ "named_other"),
    grad_year_diff = trl_grad_year - cert_year,
    ag_grad_year = case_when(is.na(grad_year_diff) ~ "uninformative",
                             grad_year_diff == 0 ~ "0", grad_year_diff == -1 ~ "-1", grad_year_diff == 1 ~ "+1",
                             between(grad_year_diff, -3, -2) ~ "-3..-2", between(grad_year_diff, 2, 3) ~ "+2..3",
                             between(grad_year_diff, -10, -4) ~ "-10..-4", between(grad_year_diff, 4, 10) ~ "+4..10",
                             TRUE ~ "|d|>10"),
    # contextual ------------------------------------------------------------
    cx_active = case_when(is.na(trl_active) ~ "uninformative", trl_active ~ "active", TRUE ~ "inactive"),
    cx_attribution = case_when(!trilliant_found ~ "uninformative",
                               !is.na(trl_p1_state) & !is.na(trl_panel_median_age) ~ "practice_with_panel",
                               !is.na(trl_p1_state) ~ "practice_without_panel",
                               !is.na(trl_panel_median_age) ~ "panel_without_practice",
                               TRUE ~ "none"),
    cx_attribution_flag = case_when(cx_attribution == "practice_without_panel" ~ "downweight: practice not backed by a rendering panel (may be ordering/referring/certifying only)",
                                    coalesce(trl_p1_visits_percent_total < 0.25, FALSE) ~ "downweight: practice 1 holds <25% of visits",
                                    TRUE ~ NA_character_),
    cx_practices = case_when(is.na(trl_practices_total) ~ "uninformative", trl_practices_total >= 3 ~ "3+",
                             TRUE ~ as.character(trl_practices_total)),
    cx_panel_female = case_when(is.na(trl_panel_pct_female) ~ "uninformative", trl_panel_pct_female >= 0.95 ~ ">=95%",
                                trl_panel_pct_female >= 0.80 ~ "80-95%", trl_panel_pct_female >= 0.50 ~ "50-80%",
                                TRUE ~ "<50%"),
    cx_panel_age_20_44 = case_when(is.na(trl_panel_pct_age_20_44) ~ "uninformative", trl_panel_pct_age_20_44 >= 0.60 ~ ">=60%",
                                   trl_panel_pct_age_20_44 >= 0.40 ~ "40-60%", TRUE ~ "<40%"),
    cx_org_womens = case_when(is.na(trl_org) & is.na(trl_p1_name) ~ "uninformative",
                              str_detect(toupper(coalesce(trl_org, "")), WOMENS) |
                                str_detect(toupper(coalesce(trl_p1_name, "")), WOMENS) ~ "womens_health_named",
                              TRUE ~ "other_named"),
    cx_state_vs_own_nppes = case_when(is.na(trl_p1_state) | is.na(nppes_practice_state) ~ "uninformative",
                                      trl_p1_state == nppes_practice_state ~ "same", TRUE ~ "different"),
    cx_zip_vs_own_nppes = case_when(is.na(trl_p1_zip_code) | is.na(nppes_zip5) ~ "uninformative",
                                    substr(trl_p1_zip_code, 1L, 5L) == nppes_zip5 ~ "same", TRUE ~ "different"),
    # NPPES redundancy: is Trilliant's value just NPPES's? ---------------------
    trl_eq_nppes_first = sk(trl_first_name) == sk(nppes_first),
    trl_eq_nppes_middle = coalesce(sk(trl_middle_name), "") == coalesce(sk(nppes_middle), ""),
    trl_eq_nppes_last = sk(trl_last_name) == sk(nppes_last),
    trl_eq_nppes_sex = substr(trl_gender, 1L, 1L) == nppes_sex,
    trl_eq_nppes_taxonomy = trl_primary_specialty_code == nppes_primary_taxonomy,
    trl_eq_nppes_credential = gsub("[^A-Z]", "", toupper(coalesce(trl_credential, ""))) ==
      gsub("[^A-Z]", "", toupper(coalesce(nppes_credential, ""))),
    grad_minus_nppes_enum_year = trl_grad_year - nppes_enum_year
  )

# Board license state and license agreement, for certificants a genuine board lists
bon_state <- bon |> group_by(certification_number) |> summarise(bon_states = paste(sort(unique(bon_state)), collapse = ";"), .groups = "drop")
lic_hit <- pairs |> select(amcb_id, npi, certification_number) |>
  inner_join(bon, by = "certification_number", relationship = "many-to-many") |>
  inner_join(nppes_lic, by = c("npi", "bon_state" = "lic_state", "lic_key"), relationship = "many-to-many") |>
  distinct(amcb_id, npi) |> mutate(bon_license_in_nppes = TRUE)
pairs <- pairs |>
  left_join(bon_state, by = "certification_number") |>
  left_join(lic_hit, by = c("amcb_id", "npi")) |>
  mutate(bon_license_in_nppes = if_else(is.na(bon_states), NA, coalesce(bon_license_in_nppes, FALSE)),
         cx_state_vs_board = case_when(is.na(bon_states) | is.na(trl_p1_state) ~ "uninformative",
                                       str_detect(bon_states, fixed(trl_p1_state)) ~ "same", TRUE ~ "different"))

# ---- 6. weights from stratum 1 (silver standard), cross-fitted -----------------
ID_FIELDS <- c("ag_surname", "ag_first", "ag_middle", "ag_sex", "ag_credential", "ag_specialty", "ag_school", "ag_grad_year")
# Trilliant's names, sex, credential and specialty are NPPES's own values
# (measured below, analysis/trilliant_identity_nppes_redundancy.csv). Only the
# DAC-derived school and graduation year are evidence NPPES does not hold.
TRL_ONLY_FIELDS <- c("ag_school", "ag_grad_year")
NPPES_COPIED_FIELDS <- setdiff(ID_FIELDS, TRL_ONLY_FIELDS)
CX_FIELDS <- c("cx_active", "cx_attribution", "cx_practices", "cx_panel_female", "cx_panel_age_20_44",
               "cx_org_womens", "cx_state_vs_own_nppes", "cx_state_vs_board")
SELECTION_COUPLED <- c(ag_surname = TRUE, ag_first = TRUE, ag_middle = TRUE, ag_credential = TRUE, ag_specialty = TRUE,
                       ag_sex = FALSE, ag_school = FALSE, ag_grad_year = FALSE)
# Levels that may never count against a candidate, by the handoff's rules.
NEVER_NEGATIVE <- c("cx_active" = "inactive")
# A level seen fewer times than this, true and decoy together, is not
# estimable: add-0.5 smoothing on a handful of rows manufactures large weights
# (e.g. a level the search filter itself excludes from decoys).
MIN_LEVEL_N <- 30L

ctrl_ids <- people |> filter(stratum == "1_control_high_confidence") |> arrange(amcb_id) |>
  mutate(fold = rep_len(1:2, n())) |> select(amcb_id, fold)
train <- pairs |> filter(trilliant_found) |> inner_join(ctrl_ids, by = "amcb_id") |>
  mutate(is_true = is_canonical)

fit_weights <- function(d, fields) {
  map_dfr(fields, function(f) {
    d |> count(level = .data[[f]], is_true) |>
      complete(level, is_true = c(TRUE, FALSE), fill = list(n = 0L)) |>
      pivot_wider(names_from = is_true, values_from = n, names_prefix = "n_") |>
      mutate(field = f, k = n(),
             m = (n_TRUE + 0.5) / (sum(n_TRUE) + 0.5 * k),
             u = (n_FALSE + 0.5) / (sum(n_FALSE) + 0.5 * k),
             estimable = n_TRUE + n_FALSE >= MIN_LEVEL_N,
             weight = if_else(level == "uninformative" | !estimable, 0, log2(m / u))) |>
      select(field, level, n_true = n_TRUE, n_decoy = n_FALSE, m, u, estimable, weight)
  }) |>
    mutate(weight = if_else(paste(field, level) %in% paste(names(NEVER_NEGATIVE), NEVER_NEGATIVE), pmax(weight, 0), weight))
}
score_with <- function(d, w, fields) {
  s <- numeric(nrow(d))
  for (f in fields) {
    wf <- w |> filter(field == f) |> select(level, weight)
    s <- s + coalesce(wf$weight[match(d[[f]], wf$level)], 0)
  }
  s
}
w_all <- fit_weights(train, c(ID_FIELDS, CX_FIELDS))
w_fold <- lapply(1:2, function(k) fit_weights(train |> filter(fold != k), c(ID_FIELDS, CX_FIELDS)))

pairs$fold <- ctrl_ids$fold[match(pairs$amcb_id, ctrl_ids$amcb_id)]
for (v in c("id_score", "id_score_trl_only", "id_score_nppes_copied", "cx_score")) pairs[[v]] <- NA_real_
score_block <- function(i, w) {
  pairs$id_score_trl_only[i] <<- score_with(pairs[i, ], w, TRL_ONLY_FIELDS)
  pairs$id_score_nppes_copied[i] <<- score_with(pairs[i, ], w, NPPES_COPIED_FIELDS)
  pairs$cx_score[i] <<- score_with(pairs[i, ], w, CX_FIELDS)
}
for (k in 1:2) score_block(which(pairs$fold %in% k), w_fold[[k]])   # stratum 1: out of fold
score_block(which(is.na(pairs$fold)), w_all)                         # strata 2-4: all of stratum 1
pairs <- pairs |>
  mutate(id_score = id_score_trl_only + id_score_nppes_copied,
         across(c(id_score, id_score_trl_only, id_score_nppes_copied, cx_score), ~ if_else(trilliant_found, .x, NA_real_)))

# Positive evidence and contradictions, counted per field (not weighted).
# A surname conflict with an exact first name and a corroborating middle name
# is the marriage pattern: mysterynpi calls it a case for review, not a veto,
# so it counts as weak ("surname_changed"), not strong.
pairs <- pairs |>
  mutate(ag_surname_contra = case_when(ag_surname != "conflicts" ~ NA_character_,
                                       ag_first == "exact" & ag_middle %in% c("full", "initial") ~ "surname_changed",
                                       TRUE ~ "conflicts"))
POSITIVE <- list(ag_surname = c("exact", "component", "cross_slot_or_former"), ag_first = c("exact", "nickname"),
                 ag_middle = "full", ag_credential = "midwifery", ag_specialty = "midwife",
                 ag_school = "named_acme_university", ag_grad_year = c("0", "-1", "+1"))
STRONG_CONTRA <- list(ag_surname_contra = "conflicts", ag_first = "conflicts", ag_middle = "conflicts",
                      ag_credential = c("physician", "other_doc"))
WEAK_CONTRA <- list(ag_surname_contra = "surname_changed", ag_sex = "male",
                    ag_specialty = c("physician", "other"), ag_grad_year = "|d|>10")
count_hits <- function(d, lst) Reduce(`+`, imap(lst, function(lv, f) as.integer(d[[f]] %in% lv)))
tag_hits <- function(d, lst) {
  out <- rep(NA_character_, nrow(d))
  for (j in seq_along(lst)) {
    f <- names(lst)[j]
    hit <- d[[f]] %in% lst[[j]]
    tag <- paste0(sub("^ag_", "", sub("_contra$", "", f)), "=", d[[f]])
    out[hit] <- if_else(is.na(out[hit]), tag[hit], paste(out[hit], tag[hit], sep = ";"))
  }
  out
}
pairs <- pairs |>
  mutate(n_positive = if_else(trilliant_found, count_hits(pairs, POSITIVE), NA_integer_),
         n_strong_contradictions = if_else(trilliant_found, count_hits(pairs, STRONG_CONTRA), NA_integer_),
         n_weak_contradictions = if_else(trilliant_found, count_hits(pairs, WEAK_CONTRA), NA_integer_),
         contradictions = tag_hits(pairs, c(STRONG_CONTRA, WEAK_CONTRA))) |>
  group_by(amcb_id) |>
  mutate(candidate_rank = if_else(trilliant_found, min_rank(desc(id_score)), NA_integer_),
         n_candidates_found = sum(trilliant_found)) |>
  ungroup()

# ---- 7. calibration on the HARD part of stratum 1 -------------------------------
# Calibrating on all of stratum 1 is too easy: the canonical NPI usually beats
# its decoys on middle name and taxonomy by a wide margin, so almost any margin
# looks precise (the first run found 0.03). The ambiguous strata are ambiguous
# because their candidates TIE on name. So the thresholds are read off
# "name-tied twins": decoys whose first-name, surname and middle-name verdicts
# are the canonical NPI's own. Each certificant with such a twin is ranked among
# {canonical, twins} only.
person_top <- function(d) {
  d |> filter(trilliant_found) |>
    group_by(amcb_id) |>
    arrange(desc(id_score), .by_group = TRUE) |>
    summarise(top_npi = first(npi), top_score = first(id_score),
              top_tied = sum(id_score == first(id_score)) > 1L,
              runner_up_npi = nth(npi, 2L), runner_up_score = nth(id_score, 2L),
              # the Trilliant-only part: does it alone put the top candidate ahead?
              trl_margin = first(id_score_trl_only) - max(c(id_score_trl_only[-1], 0)),
              nppes_copied_margin = first(id_score_nppes_copied) - max(c(id_score_nppes_copied[-1], -Inf)),
              .groups = "drop") |>
    mutate(margin = top_score - coalesce(runner_up_score, 0))
}
precision_threshold <- function(margin, correct) {
  mg <- sort(unique(margin[is.finite(margin)]))
  pr <- vapply(mg, function(m) mean(correct[margin >= m]), numeric(1))
  ok <- which(pr >= PRECISION_TARGET & rev(cummin(rev(pr >= PRECISION_TARGET))) == 1)
  if (length(ok)) mg[ok[1]] else Inf
}
ctrl_pairs <- pairs |> filter(stratum == "1_control_high_confidence", trilliant_found)
can1 <- ctrl_pairs |> filter(is_canonical) |> select(amcb_id, cf = ag_first, cs = ag_surname, cm = ag_middle)
twins <- ctrl_pairs |> filter(!is_canonical) |> inner_join(can1, by = "amcb_id") |>
  filter(ag_first == cf, ag_surname == cs, ag_middle == cm) |> select(-cf, -cs, -cm)
twin_set <- bind_rows(ctrl_pairs |> filter(is_canonical, amcb_id %in% twins$amcb_id), twins)
twin_top <- person_top(twin_set) |>
  left_join(people |> select(amcb_id, current_canonical_npi), by = "amcb_id") |>
  mutate(top_is_true = top_npi == current_canonical_npi & !top_tied)
best_twin <- twins |> group_by(amcb_id) |> summarise(best = max(id_score), .groups = "drop")
SCORE_FLOOR <- unname(quantile(best_twin$best, PRECISION_TARGET))
MARGIN_MIN <- precision_threshold(twin_top$margin, twin_top$top_is_true)
# Trilliant-only: rank each twin set by the Trilliant-only score alone
trl_rank <- twin_set |> group_by(amcb_id) |> arrange(desc(id_score_trl_only), .by_group = TRUE) |>
  summarise(trl_top_npi = first(npi), m = first(id_score_trl_only) - nth(id_score_trl_only, 2L), .groups = "drop") |>
  left_join(people |> select(amcb_id, current_canonical_npi), by = "amcb_id") |>
  filter(m > 0) |> mutate(correct = trl_top_npi == current_canonical_npi)
TRL_MARGIN_MIN <- precision_threshold(trl_rank$m, trl_rank$correct)
calib <- tibble(
  quantity = c("controls", "controls_with_name_tied_twin", "name_tied_twin_pairs",
               "twin_sets_top_is_canonical", "score_floor", "margin_min", "precision_at_margin_min",
               "twin_sets_passing_both", "precision_passing_both",
               "twin_sets_separated_by_trilliant_only_fields", "trl_margin_min", "precision_at_trl_margin_min",
               "twin_sets_passing_trl_margin"),
  value = c(n_distinct(ctrl_pairs$amcb_id), nrow(twin_top), nrow(twins),
            mean(twin_top$top_is_true), SCORE_FLOOR, MARGIN_MIN,
            mean(twin_top$top_is_true[twin_top$margin >= MARGIN_MIN]),
            sum(twin_top$margin >= MARGIN_MIN & twin_top$top_score >= SCORE_FLOOR),
            mean(twin_top$top_is_true[twin_top$margin >= MARGIN_MIN & twin_top$top_score >= SCORE_FLOOR]),
            nrow(trl_rank), TRL_MARGIN_MIN, mean(trl_rank$correct[trl_rank$m >= TRL_MARGIN_MIN]),
            sum(trl_rank$m >= TRL_MARGIN_MIN)),
  note = c("stratum-1 certificants with the canonical NPI or a decoy in Trilliant",
           "certificants with >=1 decoy tying the canonical NPI on first, surname and middle verdicts",
           "", "share whose top-ranked candidate (full identity score) is the canonical NPI",
           sprintf("%.0fth percentile of the best twin's full identity score", 100 * PRECISION_TARGET),
           sprintf("smallest full-score margin with precision >= %.2f at and above it", PRECISION_TARGET),
           "", "", "",
           "twin sets where the Trilliant-only score (grad year, named school) has a unique leader",
           sprintf("smallest Trilliant-only margin with precision >= %.2f at and above it", PRECISION_TARGET),
           "", ""))
write_csv(calib, OUT("calibration.csv"))
cat(sprintf("calibration (name-tied twins): score floor %.2f, margin %.2f, Trilliant-only margin %.2f\n",
            SCORE_FLOOR, MARGIN_MIN, TRL_MARGIN_MIN))

# ---- 8. per-person action ------------------------------------------------------------
tops <- person_top(pairs)
canon <- pairs |> filter(is_canonical) |>
  select(amcb_id, canon_found = trilliant_found, canon_score = id_score, canon_trl_score = id_score_trl_only,
         canon_rank = candidate_rank, canon_strong = n_strong_contradictions, canon_weak = n_weak_contradictions,
         canon_contra = contradictions)
shadow_sc <- pairs |> filter(is_shadow) |> select(amcb_id, shadow_found = trilliant_found, shadow_score = id_score)
top_attrs <- pairs |> select(amcb_id, top_npi = npi, top_strong = n_strong_contradictions,
                             top_weak = n_weak_contradictions, top_source = candidate_source)
held_by_other <- tops |> select(amcb_id, top_npi) |>
  inner_join(held, by = c("top_npi" = "npi")) |>
  filter(holder != amcb_id) |>
  group_by(amcb_id) |> summarise(top_held_by = paste(holder, collapse = ";"), .groups = "drop")

audit <- people |>
  select(amcb_id, certification_number, stratum, status, current_canonical_npi, current_match_tier,
         shadow_npi, shadow_match_status) |>
  left_join(tops, by = "amcb_id", relationship = "one-to-one") |>
  left_join(top_attrs, by = c("amcb_id", "top_npi"), relationship = "many-to-one") |>
  left_join(canon, by = "amcb_id", relationship = "one-to-one") |>
  left_join(shadow_sc, by = "amcb_id", relationship = "one-to-one") |>
  left_join(held_by_other, by = "amcb_id", relationship = "one-to-one") |>
  mutate(
    top_held_by_other = !is.na(top_held_by),
    decisive = !is.na(top_score) & !top_tied & top_score >= SCORE_FLOOR & margin >= MARGIN_MIN &
      coalesce(top_strong, 0L) == 0L & coalesce(top_weak, 0L) < 2L,
    # What put the winner ahead: Trilliant's own fields, or NPPES's values restated?
    evidence_basis = case_when(is.na(top_score) ~ NA_character_,
                               trl_margin >= TRL_MARGIN_MIN ~ "trilliant_only_fields",
                               nppes_copied_margin >= MARGIN_MIN ~ "nppes_copied_fields",
                               TRUE ~ "combined_neither_alone"),
    canon_contradicted = coalesce(canon_strong, 0L) >= 1L | coalesce(canon_weak, 0L) >= 2L,
    rival_outranks = !is.na(current_canonical_npi) & coalesce(canon_found, FALSE) & decisive & top_npi != current_canonical_npi,
    has_current = !is.na(current_canonical_npi),
    # For a confirmation: does a Trilliant-only field independently agree?
    confirmation_basis = if_else(has_current & coalesce(canon_trl_score > 0, FALSE),
                                 "trilliant_only_fields_agree", "nppes_copied_fields_only"),
    recommended_action = case_when(
      # people who hold an NPI today (strata 1, 3; stratum 3 without one falls through)
      has_current & !coalesce(canon_found, FALSE) ~ "no useful Trilliant evidence",
      has_current & (canon_contradicted | rival_outranks) ~ "contradicts current match",
      has_current & decisive & top_npi == current_canonical_npi ~ "confirms current match",
      has_current ~ "no useful Trilliant evidence",
      # people with no NPI today
      is.na(top_score) ~ "no useful Trilliant evidence",
      !decisive | top_held_by_other ~ "no useful Trilliant evidence",
      stratum %in% c("2_ambiguous", "3_production_vs_shadow") &
        str_detect(top_source, "canonical|shadow|matcher_pool|class5") ~ "resolves ambiguous candidates",
      TRUE ~ "proposes new plausible NPI"),
    reason = case_when(
      has_current & !coalesce(canon_found, FALSE) ~ "CURRENT_NPI_NOT_IN_TRILLIANT",
      has_current & canon_contradicted ~ paste0("CURRENT_NPI_CONTRADICTED:", canon_contra),
      has_current & rival_outranks ~ paste0("RIVAL_OUTRANKS_CURRENT:", top_npi),
      has_current & decisive & top_npi == current_canonical_npi ~ "CURRENT_NPI_TOP_AND_DECISIVE",
      has_current & !is.na(top_npi) & top_npi == current_canonical_npi ~ "CURRENT_NPI_TOP_BELOW_THRESHOLD",
      has_current ~ "CURRENT_NPI_NOT_TOP_BELOW_THRESHOLD",
      is.na(top_score) ~ "NO_CANDIDATE_IN_TRILLIANT",
      top_tied ~ "TOP_TIED",
      coalesce(top_strong, 0L) > 0L | coalesce(top_weak, 0L) >= 2L ~ "TOP_HAS_CONTRADICTIONS",
      top_score < SCORE_FLOOR ~ "TOP_BELOW_SCORE_FLOOR",
      margin < MARGIN_MIN ~ "MARGIN_BELOW_THRESHOLD",
      top_held_by_other ~ "TOP_NPI_HELD_BY_ANOTHER_CERTIFICANT",
      TRUE ~ "TOP_DECISIVE"))
# Two people "resolved" to one NPI: neither stands.
dup <- audit |> filter(recommended_action %in% c("resolves ambiguous candidates", "proposes new plausible NPI")) |>
  count(top_npi) |> filter(n > 1L)
audit <- audit |>
  mutate(claimed_twice = top_npi %in% dup$top_npi &
           recommended_action %in% c("resolves ambiguous candidates", "proposes new plausible NPI"),
         recommended_action = if_else(claimed_twice, "no useful Trilliant evidence", recommended_action),
         reason = if_else(claimed_twice, "TOP_NPI_CLAIMED_BY_TWO_PEOPLE", reason)) |>
  select(-claimed_twice)
# Stratum 3 detail: which arm Trilliant supports
audit <- audit |>
  mutate(shadow_vs_production = case_when(
    stratum != "3_production_vs_shadow" ~ NA_character_,
    is.na(current_canonical_npi) | is.na(shadow_npi) ~ "only one arm names an NPI",
    is.na(canon_score) & is.na(shadow_score) ~ "neither in Trilliant",
    coalesce(canon_score, -Inf) - coalesce(shadow_score, -Inf) >= MARGIN_MIN ~ "supports production",
    coalesce(shadow_score, -Inf) - coalesce(canon_score, -Inf) >= MARGIN_MIN ~ "supports shadow",
    TRUE ~ "undecided"))

pairs <- pairs |>
  left_join(audit |> select(amcb_id, top_npi, runner_up_score, margin), by = "amcb_id") |>
  group_by(amcb_id) |>
  mutate(score_margin_to_runner_up = if_else(npi == top_npi, margin, id_score - max(id_score, na.rm = TRUE))) |>
  ungroup() |>
  left_join(audit |> select(amcb_id, recommended_action, reason), by = "amcb_id") |>
  mutate(pair_action = case_when(npi == top_npi ~ recommended_action, TRUE ~ "not top candidate"),
         pair_reason = if_else(npi == top_npi, reason, "RANKED_BELOW_TOP")) |>
  select(-top_npi, -runner_up_score, -margin, -recommended_action, -reason, -fold, -school_stem)

# ---- 9. field value: coverage, AUC, NPPES redundancy --------------------------
auc <- function(score, y) {
  if (length(unique(y)) < 2L) return(NA_real_)
  r <- rank(score); n1 <- sum(y); n0 <- sum(!y)
  (sum(r[y]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
# Out-of-fold single-field scores, so the AUC is not scored on its own training rows
field_value <- map_dfr(c(ID_FIELDS, CX_FIELDS), function(f) {
  oof <- numeric(nrow(train))
  for (k in 1:2) {
    i <- which(train$fold == k); wf <- w_fold[[k]] |> filter(field == f)
    oof[i] <- coalesce(wf$weight[match(train[[f]][i], wf$level)], 0)
  }
  known_cnm <- pairs |> filter(trilliant_found, is_canonical, stratum == "1_control_high_confidence")
  tibble(field = f,
         evidence_class = if (startsWith(f, "ag_")) "identity" else "contextual",
         coverage_known_cnm = mean(known_cnm[[f]] != "uninformative"),
         coverage_decoys = mean(train[[f]][!train$is_true] != "uninformative"),
         auc_true_vs_decoy = auc(oof, train$is_true),
         selection_coupled = unname(coalesce(SELECTION_COUPLED[f], FALSE)))
})
redund <- pairs |> filter(trilliant_found, is_canonical, stratum == "1_control_high_confidence") |>
  summarise(across(starts_with("trl_eq_nppes_"), ~ mean(.x, na.rm = TRUE)),
            grad_eq_enum_year = mean(grad_minus_nppes_enum_year == 0, na.rm = TRUE),
            grad_within1_enum_year = mean(abs(grad_minus_nppes_enum_year) <= 1, na.rm = TRUE),
            grad_eq_cert_year = mean(grad_year_diff == 0, na.rm = TRUE),
            middle_trl_only = mean(ag_middle_nppes == "uninformative" & ag_middle %in% c("full", "initial"), na.rm = TRUE),
            license_confirmed_share = mean(bon_license_in_nppes, na.rm = TRUE),
            n_with_board = sum(!is.na(bon_license_in_nppes))) |>
  pivot_longer(everything(), names_to = "check", values_to = "value")
write_csv(w_all, OUT("field_weights.csv"))
write_csv(field_value, OUT("field_value.csv"))
write_csv(redund, OUT("nppes_redundancy.csv"))

# License-confirmed controls: do Trilliant fields agree as often there?
lic_check <- pairs |> filter(stratum == "1_control_high_confidence", is_canonical, trilliant_found, !is.na(bon_license_in_nppes)) |>
  group_by(bon_license_in_nppes) |>
  summarise(n = n(), grad_within1 = mean(abs(grad_year_diff) <= 1, na.rm = TRUE),
            specialty_midwife = mean(ag_specialty == "midwife"), female = mean(ag_sex == "female"),
            state_same_as_board = mean(cx_state_vs_board == "same" , na.rm = TRUE), .groups = "drop")
write_csv(lic_check, OUT("license_confirmed_check.csv"))

# ---- 10. write ------------------------------------------------------------------------
# Attribution: would NPPES alone, searched with the same rules, have found it?
pool_any <- unique(pool$npi)
pairs <- pairs |>
  mutate(amcb_first_multi_token = str_detect(str_squish(first_name), " "),
         trl_name_eq_nppes = coalesce(trl_eq_nppes_first & trl_eq_nppes_middle & trl_eq_nppes_last, FALSE),
         npi_in_matcher_pool_any = npi %in% pool_any)
audit <- audit |>
  left_join(pairs |> select(amcb_id, top_npi = npi, top_amcb_first_multi_token = amcb_first_multi_token,
                            top_name_eq_nppes = trl_name_eq_nppes, top_in_matcher_pool_any = npi_in_matcher_pool_any,
                            top_nppes_enum_year = nppes_enum_year, top_grad_year_diff = grad_year_diff),
            by = c("amcb_id", "top_npi"), relationship = "many-to-one")
pairs_out <- pairs |>
  select(amcb_id, certification_number, stratum, candidate_npi = npi, current_canonical_npi, current_match_tier,
         shadow_npi, candidate_source, is_canonical, is_shadow, trilliant_found,
         starts_with("trl_"), starts_with("ag_"), grad_year_diff, starts_with("cx_"),
         starts_with("nppes_"), grad_minus_nppes_enum_year, bon_states, bon_license_in_nppes,
         amcb_first_multi_token, trl_name_eq_nppes, npi_in_matcher_pool_any,
         id_score, id_score_trl_only, id_score_nppes_copied, cx_score, n_positive, n_strong_contradictions, n_weak_contradictions, contradictions,
         candidate_rank, n_candidates_found, score_margin_to_runner_up, pair_action, pair_reason) |>
  arrange(stratum, amcb_id, candidate_rank)
write_csv(pairs_out, OUT("pairs.csv"))
write_csv(audit, OUT("person_audit.csv"))
counts <- audit |> count(stratum, recommended_action) |>
  pivot_wider(names_from = recommended_action, values_from = n, values_fill = 0L)
counts_basis <- audit |>
  mutate(basis = case_when(recommended_action == "confirms current match" ~ confirmation_basis,
                           recommended_action %in% c("resolves ambiguous candidates", "proposes new plausible NPI",
                                                     "contradicts current match") ~ evidence_basis,
                           TRUE ~ NA_character_)) |>
  count(stratum, recommended_action, basis)
write_csv(counts_basis, OUT("audit_counts_by_basis.csv"))
write_csv(counts, OUT("audit_counts.csv"))
trilliant_identity_sha <- function(p) digest::digest(file = p, algo = "sha256")
write_csv(tibble(input = c("LINKAGE_CSV", "SHADOW_CSV", "CANDIDATE_AUDIT_CSV", "NPPES_SLIM", "TRILLIANT_LAKE"),
                 path = c(LINKAGE, SHADOW, POOL, NPPES_SLIM, LAKE),
                 sha256 = c(trilliant_identity_sha(LINKAGE), trilliant_identity_sha(SHADOW), trilliant_identity_sha(POOL), NA, NA),
                 note = c("", "", "", "NPPES 2026-08-09 dissemination, individual NPIs",
                          "Trilliant Health provider directory, snapshot 2026-06-25 (lake 20260721)")),
          OUT("run_manifest.csv"))
cat("\naudit counts:\n"); print(as.data.frame(counts))
cat("\nwrote", OUT("*.csv"), "\n")
