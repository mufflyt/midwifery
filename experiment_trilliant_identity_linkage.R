#!/usr/bin/env Rscript
# =============================================================================
# Experiment: can Trilliant's provider directory resolve AMCB -> NPI identity?
# =============================================================================
# The frozen linkage resolves certificants on name evidence alone and
# quarantines what names cannot settle. This asks, before anything in
# mysterynpi or the matcher changes, what a second national provider master
# would add. Every certificant in the freeze is run through the full
# directory (not only the linked ones), in the strata trl_stratum() defines:
#
#   1a existing links at the matcher's strongest evidence (primary, class 1-2)
#   1b every other existing link (class 3-4, nursing and fuzzy tiers)
#   2  quarantined: tied, contested, unruled-out, class-5 held out
#   3  no candidate at all
#
# and the result is reported as how often Trilliant confirms the current NPI,
# contradicts it, chooses between competing NPIs, produces a plausible new NPI,
# or offers nothing useful (trl_outcome()).
#
# CANDIDATES come from exact keys only -- no fuzzy join. Each rule is named on
# every pair it produces:
#   exact_name          surname key + given-name key, any profession
#   surname_initial     surname key + first initial, nursing or midwifery records
#   pool_surname_drift  given-name key, midwifery records, surname within edit
#                       distance 2 or sharing a surname component (maiden name
#                       carried as a middle name included)
#   pool_surname_change given-name key, midwifery records, surname different,
#                       a full middle name agreeing AND graduation within a year
#                       of certification: the shape of a married-name change
#   incumbent           the NPI the freeze already holds, always scored
#   freeze_class5       the class-5 candidate the freeze held out
# The last two are added whether or not a rule would find them, so a current
# link is always assessed. Edit distance is computed only inside a block that an
# exact given-name key has already formed.
#
# NOTHING HERE WRITES A LINK. The freeze is read, verified by sha256, and never
# written. Outputs are evidence and proposals beside it.
#
# THE TRUTH SET. The v1 adjudication instrument is sealed while adjudication is
# under way (artifacts/truth/README.md). This experiment's outputs are matcher
# output: they must not reach a reviewer, and nothing here reads the truth set.
#
# Inputs : the linkage freeze (verified; ALLOW_FREEZE_SHA256 names another on purpose)
#          artifacts/trilliant_provider_identity_index.parquet (build_trilliant_provider_identity_index.R)
#          NPPES bulk file, November 2025 (NPPES_2025 overrides)
# Outputs, aggregate and tracked, the freeze's sha8 in every name:
#          artifacts/trilliant_identity_outcomes_<sha8>.csv
#          artifacts/trilliant_identity_field_coverage_<sha8>.csv
#          artifacts/trilliant_identity_grad_year_agreement_<sha8>.csv
# Outputs, person-level and gitignored:
#          artifacts/trilliant_identity_candidates_<sha8>.parquet   every pair and its evidence
#          artifacts/trilliant_identity_decisions_<sha8>.csv        one row per certificant
#          artifacts/trilliant_identity_proposals_<sha8>.csv        every proposed change
#          artifacts/trilliant_identity_nppes_extract.parquet       NPPES rows for candidate NPIs (cache)
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(readr); library(stringr); library(tibble)
  library(tidyr)
})
# duckplyr is for the lazy parquet and CSV scans. Attaching it also routes dplyr
# verbs on ORDINARY data frames through DuckDB, whose joins do not keep row
# order (measured 2026-09-14: a left_join of a shuffled 50,000-row tibble came
# back reordered). The first runs of the experiment paired 22 of 655,646
# candidates with another row's profession that way. Restore dplyr's methods so
# in-memory frames keep dplyr's semantics; duckplyr frames keep their own.
invisible(duckplyr::methods_restore())
source(file.path("R", "lib", "common_helpers.R"))        # chr()
source(file.path("R", "lib", "medicare_duckdb.R"))       # samsung_volume_path()
source(file.path("R", "lib", "artifact_provenance.R"))   # write_with_provenance()
source(file.path("R", "lib", "cohort_definitions.R"))    # verify_linkage_freeze()
source(file.path("R", "amcb_name_keys.R"))               # amcb_blank_na(), amcb_split_first()
source("credential_compatibility.R")                     # classify_credentials()
source(file.path("R", "lib", "trilliant_identity.R"))

FROZEN <- Sys.getenv("FROZEN_CSV", file.path("artifacts", "amcb_npi_linkage_FROZEN.csv"))
FROZEN_SHA256 <- verify_linkage_freeze(FROZEN)
SHA8 <- substr(FROZEN_SHA256, 1, 8)
INDEX <- file.path("artifacts", "trilliant_provider_identity_index.parquet")
if (!file.exists(INDEX)) stop("no identity index; run build_trilliant_provider_identity_index.R", call. = FALSE)
NPPES <- Sys.getenv("NPPES_2025", "")
if (!nzchar(NPPES)) NPPES <- samsung_volume_path(file.path("nppes_historical_downloads", "extracted_2025",
                                                           "npidata_pfile_20050523-20251109.csv"))
TRILLIANT_SNAPSHOT <- "2026-06-25"
out_path <- function(stem, ext = "csv") file.path("artifacts", sprintf("trilliant_identity_%s_%s.%s", stem, SHA8, ext))
log_line <- function(...) cat(sprintf(...), "\n", sep = "")

# ---- the certificants, keyed exactly as match_amcb_to_npi.R keys them ------------
linkage <- chr(FROZEN)
if (anyDuplicated(linkage$certification_number))
  stop("the freeze lists a certification number twice; resolve before scoring", call. = FALSE)
sp <- amcb_split_first(linkage$first_name)
amcb <- linkage |>
  transmute(amcb_id = certification_number, status, certification,
            cert_year = suppressWarnings(as.integer(str_extract(certification_date, "\\d{4}"))),
            linkage_tier, npi_match_status, name_evidence_class,
            incumbent_npi = if_else(!is.na(npi) & nzchar(npi), npi, NA_character_),
            class5_npi = if_else(!is.na(class5_candidate_npi) & nzchar(class5_candidate_npi),
                                 class5_candidate_npi, NA_character_),
            amcb_last = trl_blank(amcb_blank_na(last_name, fold_hyphens = TRUE)),
            amcb_given = trl_blank(sp$given),
            amcb_middle = str_squish(paste(trl_blank(amcb_blank_na(middle_name)), trl_blank(sp$middle_from_first))),
            amcb_init = substr(amcb_given, 1, 1)) |>
  mutate(stratum = trl_stratum(linkage_tier, name_evidence_class, incumbent_npi))
log_line("freeze %s...: %s certificants", SHA8, format(nrow(amcb), big.mark = ","))
print(count(amcb, stratum))

# Who already holds each NPI in the freeze: a proposal may not quietly take one.
holders <- amcb |> filter(!is.na(incumbent_npi)) |> distinct(npi = incumbent_npi, holder_id = amcb_id)
if (anyDuplicated(holders$npi)) stop("the freeze gives one NPI to two certificants", call. = FALSE)

# ---- candidates from the index ---------------------------------------------------
ix_cols <- c("provider_npi", "last_key", "given_key", "middle_key", "middle_from_given", "first_init",
             "provider_first_name", "provider_middle_name", "provider_last_name", "provider_credential",
             "credential_class", "provider_primary_specialty_code", "specialty_class", "sex_code",
             "provider_medical_school_graduation_year", "provider_medical_school_name", "school_clean",
             "provider_affiliated_practice_1_state", "primary_organization_name", "active_provider",
             "midwife_pool", "nursing_pool")
ix <- read_parquet_duckdb(INDEX) |> select(all_of(ix_cols))
as_trl <- function(d) d |> collect() |>
  mutate(npi = sprintf("%.0f", provider_npi),
         trl_middle = str_squish(paste(trl_blank(middle_key), trl_blank(middle_from_given)))) |>
  select(-provider_npi)

keys_exact <- amcb |> filter(nzchar(amcb_last), nzchar(amcb_given)) |> distinct(last_key = amcb_last, given_key = amcb_given)
t_exact <- ix |> semi_join(as_duckdb_tibble(keys_exact), by = c("last_key", "given_key")) |> as_trl()
keys_init <- amcb |> filter(nzchar(amcb_last), nzchar(amcb_init)) |> distinct(last_key = amcb_last, first_init = amcb_init)
t_init <- ix |> filter(nursing_pool) |> semi_join(as_duckdb_tibble(keys_init), by = c("last_key", "first_init")) |> as_trl()
t_pool <- ix |> filter(midwife_pool) |> as_trl()
log_line("directory rows: %s share a surname and given name with a certificant, %s a surname and initial (nursing/midwifery), %s in the midwifery pool",
    format(nrow(t_exact), big.mark = ","), format(nrow(t_init), big.mark = ","), format(nrow(t_pool), big.mark = ","))

# Each rule yields (certificant, NPI) keys only; the full rows are joined once,
# below, from one directory row per NPI.
pairs_exact <- amcb |> inner_join(t_exact, by = c(amcb_last = "last_key", amcb_given = "given_key"),
                                  relationship = "many-to-many") |>
  transmute(amcb_id, npi, rule = "exact_name")
pairs_init <- amcb |> inner_join(t_init, by = c(amcb_last = "last_key", amcb_init = "first_init"),
                                 keep = TRUE, relationship = "many-to-many") |>
  filter(given_key != amcb_given) |> transmute(amcb_id, npi, rule = "surname_initial")
# The given-name block is ~2 million pairs on the 2026-08-10 freeze, so it is
# formed on key columns only, filtered with vectorised tests, and joined back
# to the full rows afterwards. mysterynpi's per-row surname comparator runs only
# where a surname token of one side appears among the other side's surname or
# middle tokens -- the only rows it could call corroborating.
blk <- amcb |> filter(nzchar(amcb_given), nzchar(amcb_last)) |>
  select(amcb_id, amcb_given, amcb_last, amcb_middle, cert_year) |>
  inner_join(t_pool |> select(npi, given_key, last_key, trl_middle, gy = provider_medical_school_graduation_year),
             by = c(amcb_given = "given_key"), relationship = "many-to-many") |>
  filter(last_key != amcb_last)
blk$edit <- stringdist::stringdist(blk$amcb_last, blk$last_key, method = "lv")
token_in <- function(words, haystack) {
  hay <- paste0(" ", haystack, " ")
  hit <- function(t) !is.na(t) & nchar(t) >= 3L & stringi::stri_detect_fixed(hay, paste0(" ", t, " "))
  hit(word(words, 1)) | hit(word(words, 2))
}
maybe <- blk$edit > 2L & (token_in(blk$amcb_last, paste(blk$last_key, blk$trl_middle)) |
                            token_in(blk$last_key, paste(blk$amcb_last, blk$amcb_middle)))
comp <- rep(FALSE, nrow(blk))
comp[maybe] <- mysterynpi::surname_agreement(blk$amcb_last[maybe], blk$last_key[maybe],
                                             middle_a = blk$amcb_middle[maybe],
                                             middle_b = blk$trl_middle[maybe]) == "corroborates"
m_a <- word(blk$amcb_middle, 1); m_t <- word(blk$trl_middle, 1)
full_middle <- !is.na(m_a) & !is.na(m_t) & nchar(m_a) >= 2L & m_a == m_t
grad_close <- trl_grad_year_band(blk$gy, blk$cert_year) == "within_1"
blk$rule <- ifelse(blk$edit <= 2L | comp, "pool_surname_drift",
            ifelse(full_middle & grad_close, "pool_surname_change", NA_character_))
log_line("midwifery-pool block: %s pairs share a given name; %s kept (%s surname drift, %s surname change)",
    format(nrow(blk), big.mark = ","), format(sum(!is.na(blk$rule)), big.mark = ","),
    format(sum(blk$rule %in% "pool_surname_drift"), big.mark = ","),
    format(sum(blk$rule %in% "pool_surname_change"), big.mark = ","))
pairs_pool <- blk |> filter(!is.na(rule)) |> select(amcb_id, npi, rule)
rm(blk, comp, maybe, m_a, m_t, full_middle, grad_close)

anchor <- bind_rows(amcb |> filter(!is.na(incumbent_npi)) |> transmute(amcb_id, npi = incumbent_npi, rule = "incumbent"),
                    amcb |> filter(!is.na(class5_npi)) |> transmute(amcb_id, npi = class5_npi, rule = "freeze_class5"))
t_anchor <- ix |> semi_join(as_duckdb_tibble(tibble(provider_npi = as.numeric(unique(anchor$npi)))),
                            by = "provider_npi") |> as_trl()
pairs_anchor <- anchor |> semi_join(t_anchor, by = "npi")

# One directory row per NPI. Every source reads the same index row through the
# same transform, so duplicates are identical; if two ever differ, stop rather
# than let row order pick one.
trl_rows <- bind_rows(t_exact, t_init, t_pool, t_anchor) |> distinct()
if (anyDuplicated(trl_rows$npi))
  stop("an NPI carries two different directory rows; the index is not one row per NPI", call. = FALSE)
pairs <- bind_rows(pairs_exact, pairs_init, pairs_pool, pairs_anchor) |>
  distinct(amcb_id, npi, rule) |>
  group_by(amcb_id, npi) |>
  summarise(rules = paste(sort(rule), collapse = "|"), .groups = "drop") |>
  inner_join(amcb, by = "amcb_id", relationship = "many-to-one") |>
  inner_join(trl_rows, by = "npi", relationship = "many-to-one")
rm(pairs_exact, pairs_init, pairs_pool, pairs_anchor, trl_rows)
log_line("candidate pairs: %s over %s certificants and %s NPIs", format(nrow(pairs), big.mark = ","),
    format(n_distinct(pairs$amcb_id), big.mark = ","), format(n_distinct(pairs$npi), big.mark = ","))

# ---- NPPES for every candidate NPI, and for incumbents the directory lacks --------
# Cached, and the cache is used only if it covers every NPI asked for and came
# from the same bulk file; otherwise the 11 GB file is scanned again.
nppes_extract <- function(npis) {
  cache <- file.path("artifacts", "trilliant_identity_nppes_extract.parquet")
  if (file.exists(cache)) {
    cached <- read_parquet_duckdb(cache) |> collect()
    if (all(npis %in% cached$npi) && identical(unique(cached$nppes_source), basename(NPPES))) {
      log_line("NPPES: reusing cached extract (%s NPIs)", format(nrow(cached), big.mark = ","))
      return(cached)
    }
  }
  log_line("NPPES: scanning %s for %s NPIs (several minutes)", basename(NPPES), format(length(npis), big.mark = ","))
  tax <- sprintf("Healthcare Provider Taxonomy Code_%d", 1:15)
  lic <- sprintf("Provider License Number State Code_%d", 1:15)
  cols <- c(npi = "NPI", nppes_last = "Provider Last Name (Legal Name)", nppes_first = "Provider First Name",
            nppes_middle = "Provider Middle Name", nppes_credential = "Provider Credential Text",
            nppes_other_last_raw = "Provider Other Last Name", nppes_state = "Provider Business Practice Location Address State Name",
            nppes_enumeration_date = "Provider Enumeration Date", nppes_deactivation_date = "NPI Deactivation Date",
            nppes_reactivation_date = "NPI Reactivation Date", nppes_sex = "Provider Sex Code",
            stats::setNames(tax, sprintf("tax_%02d", 1:15)), stats::setNames(lic, sprintf("lic_%02d", 1:15)))
  raw <- read_csv_duckdb(NPPES, options = list(all_varchar = TRUE)) |>
    select(all_of(cols)) |>
    semi_join(as_duckdb_tibble(tibble(npi = npis)), by = "npi") |>
    collect()
  long_codes <- function(prefix) raw |> select(npi, starts_with(prefix)) |>
    pivot_longer(-npi, values_to = "code") |> filter(!is.na(code), nzchar(code))
  tx <- long_codes("tax_") |> group_by(npi) |>
    summarise(nppes_taxonomies = paste(unique(code), collapse = "|"),
              nppes_classes = paste(sort(unique(na.omit(trl_taxonomy_class(code)))), collapse = "|"), .groups = "drop")
  lc <- long_codes("lic_") |> group_by(npi) |>
    summarise(nppes_license_states = paste(sort(unique(code)), collapse = "|"), .groups = "drop")
  out <- tibble(npi = npis) |>
    left_join(raw |> select(-starts_with("tax_"), -starts_with("lic_")), by = "npi", relationship = "one-to-one") |>
    left_join(tx, by = "npi", relationship = "one-to-one") |>
    left_join(lc, by = "npi", relationship = "one-to-one") |>
    mutate(nppes_found = npi %in% raw$npi,
           nppes_deactivated = !is.na(nppes_deactivation_date) & nzchar(nppes_deactivation_date) &
             (is.na(nppes_reactivation_date) | !nzchar(nppes_reactivation_date)),
           nppes_source = basename(NPPES))
  tmp <- paste0(cache, ".tmp")
  unlink(tmp)
  invisible(compute_parquet(as_duckdb_tibble(out), tmp))
  stopifnot(file.rename(tmp, cache))
  out
}
nppes <- nppes_extract(sort(unique(c(pairs$npi, anchor$npi))))

pairs <- pairs |>
  left_join(nppes, by = "npi", relationship = "many-to-one") |>
  mutate(nppes_other_last = trl_blank(amcb_blank_na(nppes_other_last_raw, fold_hyphens = TRUE)),
         trl_last = last_key, trl_given = given_key,
         last_edit_distance = stringdist::stringdist(amcb_last, last_key, method = "lv"))

# ---- evidence, scores, ranks ------------------------------------------------------
# Every derived column is computed from the row's own columns, never attached by
# position after a join: see the methods_restore() note at the top.
scored <- pairs |>
  mutate(trl_profession(specialty_class, credential_class, nppes_classes)) |>
  trl_name_evidence() |>
  mutate(grad_year_diff = as.integer(provider_medical_school_graduation_year) - cert_year,
         grad_year_band = trl_grad_year_band(provider_medical_school_graduation_year, cert_year),
         trl_sex = sex_code,
         is_incumbent = !is.na(incumbent_npi) & npi == incumbent_npi) |>
  trl_score_pairs() |>
  left_join(holders, by = "npi", relationship = "many-to-one") |>
  mutate(npi_held_by_other_certificant = !is.na(holder_id) & holder_id != amcb_id,
         # Does the directory carry the name NPPES carries? If so, a name
         # conflict is the matcher's own rule, not the directory's evidence.
         trl_name_equals_nppes = if_else(nppes_found & !is.na(nppes_last),
                                         gsub("[^A-Z]", "", toupper(provider_first_name)) == gsub("[^A-Z]", "", toupper(nppes_first)) &
                                           gsub("[^A-Z]", "", toupper(provider_last_name)) == gsub("[^A-Z]", "", toupper(nppes_last)),
                                         NA),
         contra_source = trl_contradiction_source(contra_given, contra_middle, contra_profession, contra_grad_year,
                                                  trl_name_equals_nppes))

# Fail closed if any row's recorded profession is not its own.
recheck <- trl_profession(scored$specialty_class, scored$credential_class, scored$nppes_classes)
if (!identical(recheck$profession_class, scored$profession_class))
  stop(sum(recheck$profession_class != scored$profession_class),
       " candidate(s) carry another row's profession; a join reordered rows", call. = FALSE)

# The holder's own score for an NPI another certificant is also drawn to, so a
# contested NPI can be read in both directions.
holder_scores <- scored |> filter(is_incumbent) |> select(npi, holder_score_full = score_full,
                                                           holder_score_identity_only = score_identity_only)
scored <- scored |> left_join(holder_scores, by = "npi", relationship = "many-to-one") |>
  mutate(holder_score_full = if_else(npi_held_by_other_certificant, holder_score_full, NA_real_),
         holder_score_identity_only = if_else(npi_held_by_other_certificant, holder_score_identity_only, NA_real_))

ranked <- list(full = trl_rank_candidates(scored, "full"),
               identity_only = trl_rank_candidates(scored, "identity_only"))

# One NPI accepted for two certificants is not a proposal, it is a conflict.
decide_one_to_one <- function(d) {
  dup <- d |> filter(decision == "ACCEPT") |> count(best_npi) |> filter(n > 1L)
  d |> mutate(
    clash = decision == "ACCEPT" & best_npi %in% dup$best_npi,
    decision = if_else(clash, "REVIEW", decision),
    decision_reason = if_else(clash, "review:npi_proposed_for_multiple_certificants", decision_reason)) |>
    select(-clash)
}
decisions <- lapply(names(ranked), function(v) decide_one_to_one(trl_decide(ranked[[v]], v)))
names(decisions) <- names(ranked)

# ---- outcomes, per certificant and variant ----------------------------------------
incumbent_found <- amcb$incumbent_npi %in% scored$npi[scored$is_incumbent]
# An emptied pool emptied only by name rules on the names NPPES carries is the
# matcher's first-initial class failing a stricter rule, not the directory.
pool_sources <- scored |> filter(contradiction_count > 0L) |> group_by(amcb_id) |>
  summarise(name_rule_only_pool = all(contra_source == "name_rule"), .groups = "drop")
per_person <- bind_rows(lapply(names(ranked), function(v) {
  inc <- ranked[[v]] |> filter(is_incumbent) |>
    transmute(amcb_id, inc_rank = rank, inc_n_at_top = n_at_top, inc_contradictions = contradiction_count,
              inc_corroborated = if (v == "full") corroborated_full else corroborated_identity,
              inc_score = .data[[paste0("score_", v)]], inc_contra_source = contra_source,
              inc_contra_fields = paste0(if_else(contra_given, "given;", ""), if_else(contra_middle, "middle;", ""),
                                         if_else(contra_profession, "profession;", ""),
                                         if_else(contra_grad_year, "grad_year;", "")))
  amcb |>
    select(amcb_id, stratum, status, linkage_tier, npi_match_status, incumbent_npi) |>
    mutate(incumbent_found = incumbent_found) |>
    left_join(decisions[[v]], by = "amcb_id", relationship = "one-to-one") |>
    left_join(inc, by = "amcb_id", relationship = "one-to-one") |>
    left_join(pool_sources, by = "amcb_id", relationship = "one-to-one") |>
    mutate(
      variant = v,
      name_rule_only_pool = coalesce(name_rule_only_pool, FALSE),
      decision = coalesce(decision, "UNRESOLVED"),
      decision_reason = coalesce(decision_reason, "unresolved:no_candidate"),
      n_candidates = coalesce(n_candidates, 0L),
      incumbent_confirms = incumbent_found & inc_rank %in% 1L & inc_n_at_top %in% 1L &
        inc_contradictions %in% 0L & inc_corroborated %in% TRUE,
      incumbent_contradicted = incumbent_found & inc_contra_source %in% c("directory_fields", "directory_name"),
      displaced = incumbent_found & decision == "ACCEPT" & !is.na(best_npi) & best_npi != incumbent_npi,
      outcome = trl_outcome(stratum, incumbent_found, incumbent_confirms, inc_contra_source, displaced, decision),
      outcome_detail = case_when(
        startsWith(stratum, "1") & !incumbent_found ~ "incumbent_not_in_directory",
        outcome == "contradicts" & incumbent_contradicted & displaced ~ "incumbent_contradicted_and_displaced",
        outcome == "contradicts" & incumbent_contradicted ~
          paste0(inc_contra_source, ":", sub(";$", "", inc_contra_fields)),
        outcome == "contradicts" ~ "displaced_by_accepted_candidate",
        outcome == "name_rule_conflict" ~ paste0("name_rule:", sub(";$", "", inc_contra_fields)),
        outcome == "confirms" ~ "incumbent_unique_best_corroborated",
        startsWith(stratum, "1") & inc_n_at_top > 1L & inc_rank == 1L ~ "incumbent_tied_at_top",
        startsWith(stratum, "1") & inc_rank > 1L ~ "incumbent_outranked_not_decisively",
        startsWith(stratum, "1") ~ "incumbent_uncorroborated",
        outcome == "chooses_between_competing" ~ "accept",
        outcome == "plausible_new_npi" ~ tolower(decision),
        emptied %in% TRUE & name_rule_only_pool ~ "every_candidate_contradicted:name_rule_only",
        emptied %in% TRUE ~ "every_candidate_contradicted:directory_evidence",
        n_candidates == 0L ~ "no_candidate_in_directory",
        TRUE ~ "best_candidate_below_plausible"))
}))

# ---- proposals: every change, with the evidence behind it ------------------------
evidence_cols <- c("rules", "provider_first_name", "provider_middle_name", "provider_last_name", "provider_credential",
                   "provider_primary_specialty_code", "nppes_taxonomies", "nppes_other_last_raw", "sex_code",
                   "provider_medical_school_graduation_year", "cert_year", "grad_year_diff",
                   "surname_evidence", "given_evidence", "middle_evidence", "profession_class", "profession_mixed",
                   "grad_year_band", "contradiction_count", "contra_given", "contra_middle", "contra_profession",
                   "contra_grad_year", "contra_source", "trl_name_equals_nppes", "nppes_first", "nppes_last", "score_full", "score_identity_only", "holder_id", "holder_score_full",
                   "provider_affiliated_practice_1_state", "nppes_state", "active_provider", "nppes_deactivated")
# Both sides of a change travel together: the prior link's evidence (prior_*)
# and the candidate's (cand_*), so a reviewer never has to reconstruct either.
ev <- scored |> select(amcb_id, npi, all_of(evidence_cols))
ev_as <- function(prefix) rename_with(ev, ~ paste0(prefix, .x), -c(amcb_id, npi))
proposals <- per_person |>
  mutate(action = case_when(
    startsWith(stratum, "1") & displaced ~ "propose_replacement",
    startsWith(stratum, "1") & incumbent_contradicted ~ "quarantine_existing_for_readjudication",
    startsWith(stratum, "1") & outcome == "name_rule_conflict" ~ "name_rule_conflict_existing",
    !startsWith(stratum, "1") & decision == "ACCEPT" ~ "propose_link",
    !startsWith(stratum, "1") & decision == "REVIEW" ~ "review_link",
    TRUE ~ NA_character_)) |>
  filter(!is.na(action)) |>
  mutate(candidate_npi = if_else(!is.na(best_npi) & (is.na(incumbent_npi) | best_npi != incumbent_npi),
                                 best_npi, NA_character_)) |>
  select(variant, amcb_id, stratum, status, action, prior_npi = incumbent_npi, candidate_npi, tied_npis,
         decision, decision_reason, best_score, runner_up_score, margin, n_candidates,
         prior_score = inc_score, prior_contradicted_fields = inc_contra_fields) |>
  left_join(ev_as("cand_"), by = c("amcb_id", candidate_npi = "npi"), relationship = "many-to-one", na_matches = "never") |>
  left_join(ev_as("prior_"), by = c("amcb_id", prior_npi = "npi"), relationship = "many-to-one", na_matches = "never")

# ---- aggregates --------------------------------------------------------------------
outcomes <- per_person |>
  count(variant, stratum, outcome, outcome_detail, name = "n") |>
  group_by(variant, stratum) |> mutate(stratum_n = sum(n), pct_of_stratum = round(100 * n / stratum_n, 2)) |>
  ungroup() |>
  bind_rows(per_person |> count(variant, stratum, outcome = paste0("decision:", decision), name = "n") |>
              group_by(variant, stratum) |> mutate(stratum_n = sum(n), pct_of_stratum = round(100 * n / stratum_n, 2)) |>
              ungroup() |> mutate(outcome_detail = "")) |>
  bind_rows(per_person |> filter(stratum == "2_ambiguous") |>
              count(variant, stratum, outcome = paste0("quarantine:", npi_match_status, ":", decision), name = "n") |>
              mutate(outcome_detail = "", stratum_n = NA_integer_, pct_of_stratum = NA_real_)) |>
  mutate(frozen_sha256 = FROZEN_SHA256, trilliant_snapshot = TRILLIANT_SNAPSHOT, nppes_file = basename(NPPES)) |>
  arrange(variant, stratum, outcome, outcome_detail)

# Coverage among certificants whose CURRENT NPI is in the directory, by stratum:
# what each field can offer the midwives already linked.
inc_rows <- scored |> filter(is_incumbent)
cov_field <- function(d, label, present) tibble(field = label, n = nrow(d), n_present = sum(present))
coverage <- bind_rows(lapply(split(inc_rows, inc_rows$stratum), function(d) bind_rows(
  cov_field(d, "sex (FEMALE or MALE)", !is.na(d$sex_code)),
  cov_field(d, "sex MALE", d$sex_code %in% "M"),
  cov_field(d, "credential present", !is.na(d$provider_credential)),
  cov_field(d, "credential midwifery", d$credential_class %in% "midwife"),
  cov_field(d, "specialty present", !is.na(d$provider_primary_specialty_code)),
  cov_field(d, "specialty midwifery", d$specialty_class %in% "midwife"),
  cov_field(d, "specialty nursing", d$specialty_class %in% "nursing"),
  cov_field(d, "any NPPES taxonomy midwifery", grepl("midwife", d$nppes_classes)),
  cov_field(d, "school: named institution", !is.na(d$school_clean)),
  cov_field(d, "school: placeholder 'Other'", d$provider_medical_school_name %in% "Other"),
  cov_field(d, "school: absent", is.na(d$provider_medical_school_name)),
  cov_field(d, "graduation year", !is.na(d$provider_medical_school_graduation_year)),
  cov_field(d, "practice-1 state", !is.na(d$provider_affiliated_practice_1_state)),
  cov_field(d, "practice-1 state equals NPPES practice state",
            !is.na(d$provider_affiliated_practice_1_state) & !is.na(d$nppes_state) &
              d$provider_affiliated_practice_1_state == d$nppes_state),
  cov_field(d, "billing organization", !is.na(d$primary_organization_name)),
  cov_field(d, "middle name", nzchar(d$trl_middle)),
  cov_field(d, "NPPES other last name", nzchar(d$nppes_other_last))) |>
    mutate(stratum = d$stratum[1]))) |>
  mutate(pct_present = round(100 * n_present / n, 2), frozen_sha256 = FROZEN_SHA256,
         trilliant_snapshot = TRILLIANT_SNAPSHOT) |>
  select(stratum, field, n, n_present, pct_present, frozen_sha256, trilliant_snapshot)

grad <- bind_rows(
  inc_rows |> mutate(population = paste0("incumbent, tier ", linkage_tier)),
  scored |> filter(!is_incumbent, !is.na(incumbent_npi)) |>
    mutate(population = "other candidates of certificants who have an incumbent")) |>
  count(population, grad_year_band, name = "n") |>
  group_by(population) |> mutate(pct = round(100 * n / sum(n), 2)) |> ungroup() |>
  mutate(frozen_sha256 = FROZEN_SHA256, trilliant_snapshot = TRILLIANT_SNAPSHOT)

# ---- write -------------------------------------------------------------------------
cand_out <- out_path("candidates", "parquet")
unlink(cand_out)
cand_tbl <- scored |> mutate(across(where(is.list), ~ vapply(.x, paste, "", collapse = " ")))
invisible(compute_parquet(as_duckdb_tibble(cand_tbl), cand_out))
write_with_provenance(per_person, out_path("decisions"), na = "")
write_with_provenance(proposals, out_path("proposals"), na = "")
write_with_provenance(outcomes, out_path("outcomes"), na = "")
write_with_provenance(coverage, out_path("field_coverage"), na = "")
write_with_provenance(grad, out_path("grad_year_agreement"), na = "")
log_line("wrote %s, %s, %s (aggregate) and the person-level candidates, decisions, proposals",
    out_path("outcomes"), out_path("field_coverage"), out_path("grad_year_agreement"))

show <- per_person |> count(variant, stratum, outcome) |> group_by(variant, stratum) |>
  mutate(pct = round(100 * n / sum(n), 1)) |> ungroup()
print(show, n = Inf)
print(proposals |> count(variant, action), n = Inf)
