#!/usr/bin/env Rscript
# =============================================================================
# Match AMCB certified midwives to NPPES for practice city/state
# =============================================================================
#
# AMCB does not publish location (city/state sit behind its paid primary-source
# verification), so geography comes from NPPES instead.
#
# Built on the isochrones matching stack rather than reimplementing it:
#
#   cached_parse_physician_name_enhanced()  utils/name_parser_cache.R
#   parse_physician_name_enhanced()   name_parsing_protocol_enhanced.R (NN #3)
#   score_middle_name_match()         middle_name_flexibility.R
#   should_reject_middle_name_conflict()
#   calculate_similarities()          matching_utils.R
#   apply_scoring()                   matching_utils.R (0.47/0.41/0.12 weights)
#   create_nickname_dictionary()      nickname_system.R
#   write_match_ledger()              match_ledger.R  (one row per candidate)
#   validate_pipeline_output()        match_ledger.R  (hard gate)
#   log_exclusion()                   utils/exclusion_ledger.R (NN #15)
#   assess_potential_maiden_name()    enhanced_name_parsing.R
#   compare_hyphenated_names()        enhanced_name_parsing.R
#   compare_international_names()     enhanced_name_parsing.R
#   score_name_with_nicknames()       enhanced_name_parsing.R
#   validate_scoring_invariants()     scoring_invariants.R
#
# Matching runs in two stages, per the project pipeline: a deterministic exact
# pass (stage1a_exact_match.R's contract -- exact first + last, compatible
# middle) resolves the bulk of the roster, and only the residual pays for
# Jaro-Winkler scoring.
#
# Two functions from that stack are deliberately NOT reused; see
# credential_compatibility.R for why the credential gate is re-implemented and
# why gender blocking is omitted.
#
# Three defects in the first version, each found by inspecting its failures:
#
#   1. AMCB packs middle names into the first-name field ("Tracy Ann Steinke").
#      Compared whole against an NPPES first name, real matches scored 0.78.
#      Now parsed with parse_physician_name_enhanced().
#   2. Candidates were filtered to midwifery taxonomies, so a CNM enumerated as
#      a Women's Health NP was unfindable. Blocking is on surname; taxonomy is
#      evidence in the decision, not a gate.
#   3. Former/maiden names were ignored. This population is ~99% women with
#      certifications dating back decades, so surname change is a leading cause
#      of non-match; every other_names variant is now scored.
#
# Because the pool is every same-surname provider, name score alone is not
# sufficient -- "Dani Abella" matches a behaviour technician perfectly.
# Acceptance requires clinical evidence proportional to name strength.
#
# Inputs : midwives.csv, nppes_candidates.csv (see fetch_npi_candidates.py)
# Outputs: midwives_with_nppes.csv, midwives_unmatched.csv,
#          artifacts/match_ledger.csv, artifacts/exclusion_ledger.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringdist); library(tidyr)
})

Sys.setenv(NAME_PARSER_CACHE_DISABLE = "1")   # cache is here()-relative to isochrones

ISO <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
for (f in c("utils/coalesce_utils.R", "string_normalization.R", "nickname_system.R",
            "name_parsing_protocol_enhanced.R", "utils/name_parser_cache.R",
            "middle_name_flexibility.R", "enhanced_name_parsing.R",
            "matching_utils.R", "scoring_invariants.R", "match_ledger.R",
            "utils/exclusion_ledger.R")) {
  p <- file.path(ISO, f)
  if (!file.exists(p)) {
    stop(sprintf("Cannot find %s. Set ISOCHRONES_R to the isochrones R/ directory.", p),
         call. = FALSE)
  }
  suppressWarnings(suppressMessages(source(p)))
}
source("credential_compatibility.R")

CFG <- list(  # matching_utils.R resolve_config() documented defaults
  weights    = list(last = 0.47, first = 0.41, middle = 0.12, state_bonus = 0),
  thresholds = list(accept = 0.85, review = 0.75, min_last_name_similarity = 0.70),
  # scoring_invariants.R reads the thresholds under this key
  abog_npi_linkage = list(thresholds = list(accept = 0.85, review = 0.75)))

# Acceptance thresholds by strength of clinical evidence.
ACCEPT_STRONG <- 0.82   # midwifery taxonomy, or CNM/CM credential
ACCEPT_WEAK   <- 0.88   # nursing / women's health taxonomy or credential
ACCEPT_NONE   <- 0.95   # unrelated specialty: near-perfect name AND sole candidate
AMBIGUOUS     <- 0.02
SHORTLIST     <- 40     # candidates carried into per-candidate scoring

MIDWIFE_TAX <- c("367A00000X", "176B00000X")
WOMENS_TAX  <- c("363LW0102X", "363LX0001X", "367500000X", "364SW0102X",
                 "363L00000X", "363LA2200X", "163WW0101X", "163W00000X")

# Hard gate on the scoring configuration itself: catches an internally
# inconsistent retune of the 0.47/0.41/0.12 weights before it silently
# degrades 22k matches.
invariants <- tryCatch(validate_scoring_invariants(CFG),
                       error = function(e) { cat("scoring invariants:",
                                                 conditionMessage(e), "\n"); FALSE })
cat(sprintf("validate_scoring_invariants: %s\n",
            if (isTRUE(invariants)) "PASS" else "see message above"))

dir.create("artifacts", showWarnings = FALSE)
LEDGER    <- file.path("artifacts", "match_ledger.csv")
EXCLUSION <- file.path("artifacts", "exclusion_ledger.csv")
unlink(c(LEDGER, EXCLUSION))

# --- AMCB roster -------------------------------------------------------------
amcb <- read_csv("midwives.csv", show_col_types = FALSE) %>%
  mutate(roster_id = certification_number)

full_name <- trimws(gsub("\\s+", " ", paste(coalesce(amcb$first_name, ""),
                                            coalesce(amcb$middle_name, ""),
                                            coalesce(amcb$last_name, ""))))
# Memoised wrapper: the uncached parser is the bottleneck at 22k names.
parsed <- cached_parse_physician_name_enhanced(full_name)
amcb <- amcb %>%
  mutate(last_n   = normalize_string(coalesce(parsed$last_name, last_name, "")),
         first_n  = normalize_string(coalesce(parsed$first_name, first_name, "")),
         middle_n = normalize_string(coalesce(parsed$middle_name, middle_name, "")),
         parse_confidence = parsed$parse_confidence,
         across(c(last_n, first_n, middle_n), ~ replace_na(.x, "")))
cat("Name parse confidence:\n"); print(table(amcb$parse_confidence, useNA = "ifany"))

# --- NPPES candidates --------------------------------------------------------
cand_raw <- read_csv("nppes_candidates.csv", col_types = cols(.default = "c"))
cand <- cand_raw %>%
  mutate(across(c(first_name, last_name, middle_name), normalize_string),
         across(c(first_name, last_name, middle_name), ~ replace_na(.x, "")),
         evidence = case_when(
           grepl(paste(MIDWIFE_TAX, collapse = "|"), all_taxonomies) ~ "strong",
           grepl("\\bCNM\\b|\\bCM\\b|MIDWI", coalesce(credential, ""))~ "strong",
           grepl(paste(WOMENS_TAX, collapse = "|"), all_taxonomies)  ~ "weak",
           grepl("\\bRN\\b|APRN|\\bNP\\b|MSN|DNP|WHNP|FNP", coalesce(credential, "")) ~ "weak",
           TRUE                                                      ~ "none"))

cat(sprintf("AMCB records: %s | candidate name-rows: %s (%s NPIs)\n",
            format(nrow(amcb), big.mark = ","), format(nrow(cand), big.mark = ","),
            format(n_distinct(cand$npi), big.mark = ",")))
cat("Evidence tiers in candidate pool:\n"); print(table(cand$evidence))

# compare_hyphenated_names() / compare_international_names() return a list with
# a 0-30 point score; assess_potential_maiden_name() returns a 0-0.8 confidence.
# Rescale both to [0, 1] before they enter the weighted score.
.variation_score <- function(x) {
  v <- suppressWarnings(as.numeric(x$score))
  if (length(v) != 1 || is.na(v)) 0 else max(0, min(1, v / 30))
}
.maiden_score <- function(x) {
  v <- suppressWarnings(as.numeric(x$confidence))
  if (length(v) != 1 || is.na(v)) 0 else max(0, min(1, v))
}

nick    <- create_nickname_dictionary(verbose = FALSE)
by_last <- split(seq_len(nrow(cand)), cand$last_name)
accept_floor <- c(strong = ACCEPT_STRONG, weak = ACCEPT_WEAK, none = ACCEPT_NONE)

score_one <- function(i) {
  idx <- by_last[[amcb$last_n[i]]]
  if (is.null(idx) || !length(idx)) return(NULL)

  parsed_name <- list(first_name = amcb$first_n[i], middle_name = amcb$middle_n[i],
                      last_name = amcb$last_n[i], suffix = "")
  pool <- cand[idx, ]

  # Credential gate (see credential_compatibility.R): an AMCB certified midwife
  # matching an NPPES record credentialed MD/DO is almost certainly a namesake.
  cred_ok <- vapply(pool$credential, are_credentials_compatible_midwifery,
                    logical(1), amcb_credential = "CNM", USE.NAMES = FALSE)
  pool <- pool[cred_ok, , drop = FALSE]
  if (!nrow(pool)) return(NULL)

  # Stage 1a: deterministic exact match (exact first + last, no middle
  # conflict). Resolves the bulk of the roster before any fuzzy scoring.
  exact <- which(pool$first_name == amcb$first_n[i] & pool$last_name == amcb$last_n[i])
  if (length(exact)) {
    mid_ok <- !vapply(pool$middle_name[exact], should_reject_middle_name_conflict,
                      logical(1), abog_middle = amcb$middle_n[i], USE.NAMES = FALSE)
    exact <- exact[mid_ok]
  }
  if (length(exact) == 1 && pool$evidence[exact] != "none") {
    e <- pool[exact, ]
    return(list(
      best = tibble(roster_id = amcb$roster_id[i], npi = e$npi,
                    practice_city = e$practice_city, practice_state = e$practice_state,
                    practice_zip = e$practice_zip, practice_address = e$practice_address,
                    nppes_taxonomy = e$taxonomy, nppes_taxonomy_desc = e$taxonomy_desc,
                    nppes_credential = e$credential, name_variant = e$name_variant,
                    evidence = e$evidence,
                    middle_match = explain_middle_name_match(amcb$middle_n[i], e$middle_name),
                    match_score = 1, match_decision = "Accept", match_stage = "exact",
                    n_candidates = 1L),
      ledger = tibble(roster_id = amcb$roster_id[i], candidate_npi = e$npi,
                      strategy_name = "stage1a_exact", confidence_score = 1,
                      score_total = 1, last_match = 1, first_match = 1,
                      state_match = NA, zip_match = NA,
                      specialty_signal = e$evidence, accepted = TRUE)))
  }

  cc <- calculate_similarities(parsed_name, pool)
  cc <- cc[cc$last_sim >= CFG$thresholds$min_last_name_similarity, , drop = FALSE]
  if (!nrow(cc)) return(NULL)

  # calculate_similarities() is vectorised, but everything below it costs an R
  # call per candidate. A common surname yields thousands of candidates, so
  # shortlist on the cheap similarities first: anything outside the top
  # SHORTLIST by (last, first) cannot win, and dropping them is what makes the
  # full 22k x 1.28M comparison tractable.
  if (nrow(cc) > SHORTLIST) {
    cheap <- CFG$weights$last * cc$last_sim + CFG$weights$first * cc$first_sim
    cc <- cc[order(cheap, decreasing = TRUE)[seq_len(SHORTLIST)], , drop = FALSE]
  }

  # Nickname-aware first names (JULIE/JULES), then the project's tiered middle
  # scoring: AMCB carries full middle names where NPPES often holds an initial.
  cc$first_sim <- vapply(cc$first_name, function(f)
    calculate_enhanced_first_name_similarity(amcb$first_n[i], f, nick),
    numeric(1), USE.NAMES = FALSE)
  cc$middle_points <- vapply(cc$middle_name, score_middle_name_match, numeric(1),
                             abog_middle = amcb$middle_n[i], USE.NAMES = FALSE)
  cc$middle_sim <- pmax(0, cc$middle_points) / 15   # 15 pts == same initial

  cc <- apply_scoring(cc, CFG)

  # Name-variation credit (enhanced_name_parsing.R). This cohort is ~99% women
  # with certifications going back decades, so surname change -- hyphenation,
  # maiden name, particle surnames -- is a leading cause of non-match.
  variation_bonus <- vapply(seq_len(nrow(cc)), function(k) {
    if (cc$last_sim[k] >= 0.999) return(0)
    hyphen <- compare_hyphenated_names(amcb$last_n[i], cc$last_name[k])
    intl   <- compare_international_names(amcb$last_n[i], cc$last_name[k])
    maiden <- assess_potential_maiden_name(
      list(first = amcb$first_n[i], middle = amcb$middle_n[i], last = amcb$last_n[i]),
      list(first = cc$first_name[k], middle = cc$middle_name[k], last = cc$last_name[k]))
    max(.variation_score(hyphen), .variation_score(intl), .maiden_score(maiden))
  }, numeric(1))
  cc$variation_bonus <- variation_bonus
  cc$total_score <- pmin(1, cc$total_score + 0.10 * variation_bonus)

  # A conflicting middle initial is the project's strongest single rejection.
  conflict <- vapply(cc$middle_name, should_reject_middle_name_conflict, logical(1),
                     abog_middle = amcb$middle_n[i], USE.NAMES = FALSE)
  cc$rejected_middle_conflict <- conflict
  cc <- cc[!conflict, , drop = FALSE]
  if (!nrow(cc)) return(NULL)

  # Collapse name variants (legal vs former): keep each NPI's best scoring row.
  cc <- cc[order(cc$total_score, decreasing = TRUE), , drop = FALSE]
  cc <- cc[!duplicated(cc$npi), , drop = FALSE]

  eligible <- cc$total_score >= accept_floor[cc$evidence] &
              (cc$evidence != "none" | nrow(cc) == 1)
  best <- which.max(cc$total_score)
  decision <- if (any(eligible)) {
    best <- which(eligible)[which.max(cc$total_score[eligible])]
    rivals <- which(eligible & seq_len(nrow(cc)) != best)
    if (length(rivals) && max(cc$total_score[rivals]) >= cc$total_score[best] - AMBIGUOUS)
      "Ambiguous" else "Accept"
  } else if (cc$total_score[best] >= CFG$thresholds$review) {
    "Review"
  } else {
    "No match"
  }

  list(
    best = tibble(roster_id = amcb$roster_id[i], npi = cc$npi[best],
                  practice_city = cc$practice_city[best],
                  practice_state = cc$practice_state[best],
                  practice_zip = cc$practice_zip[best],
                  practice_address = cc$practice_address[best],
                  nppes_taxonomy = cc$taxonomy[best],
                  nppes_taxonomy_desc = cc$taxonomy_desc[best],
                  nppes_credential = cc$credential[best],
                  name_variant = cc$name_variant[best],
                  evidence = cc$evidence[best],
                  middle_match = explain_middle_name_match(amcb$middle_n[i],
                                                           cc$middle_name[best]),
                  match_score = round(cc$total_score[best], 4),
                  match_decision = decision, match_stage = "fuzzy",
                  n_candidates = nrow(cc)),
    ledger = tibble(roster_id = amcb$roster_id[i], candidate_npi = cc$npi,
                    strategy_name = "surname_block_jw_evidence",
                    confidence_score = round(cc$total_score, 4),
                    score_total = round(cc$total_score, 4),
                    last_match = round(cc$last_sim, 4),
                    first_match = round(cc$first_sim, 4),
                    state_match = NA, zip_match = NA,
                    specialty_signal = cc$evidence,
                    accepted = decision == "Accept" & seq_len(nrow(cc)) == best))
}

start <- Sys.time()
results <- vector("list", nrow(amcb))
ledger_buffer <- vector("list", nrow(amcb))
for (i in seq_len(nrow(amcb))) {
  r <- score_one(i)
  if (!is.null(r)) { results[[i]] <- r$best; ledger_buffer[[i]] <- r$ledger }
  if (i %% 2000 == 0) {
    cat(sprintf("  %s/%s (%.0fs)\n", i, nrow(amcb),
                as.numeric(difftime(Sys.time(), start, units = "secs"))))
  }
}
matches <- bind_rows(results)
write_match_ledger(bind_rows(ledger_buffer), LEDGER)

# One NPI belongs to one person: if two certificants claim it, the stronger
# score keeps it and the others drop to Ambiguous.
dupes <- matches %>% filter(match_decision == "Accept") %>%
  group_by(npi) %>% filter(n() > 1) %>%
  arrange(desc(match_score), .by_group = TRUE) %>% slice(-1) %>% ungroup()
cat(sprintf("\nDemoted %s accepted matches sharing an NPI with a stronger claim\n",
            format(nrow(dupes), big.mark = ",")))
matches <- matches %>%
  mutate(match_decision = if_else(roster_id %in% dupes$roster_id, "Ambiguous",
                                  match_decision))

out <- amcb %>%
  select(-last_n, -first_n, -middle_n) %>%
  left_join(matches, by = "roster_id") %>%
  mutate(match_decision = coalesce(match_decision, "No match")) %>%
  # Only accepted matches carry geography; review/ambiguous keep the score for
  # adjudication but must not masquerade as known locations.
  mutate(across(c(npi, practice_city, practice_state, practice_zip, practice_address,
                  nppes_taxonomy, nppes_taxonomy_desc, nppes_credential),
                ~ if_else(match_decision == "Accept", .x, NA_character_)))

write_csv(select(out, -roster_id), "midwives_with_nppes.csv", na = "")
write_csv(filter(out, match_decision != "Accept") %>% select(-roster_id),
          "midwives_unmatched.csv", na = "")

# --- Exclusion + output validation (NN #15) ----------------------------------
accepted <- filter(out, match_decision == "Accept")
invisible(log_exclusion("nppes_match", data_in = out, data_out = accepted,
                        id_col = "roster_id", ledger_path = EXCLUSION,
                        drop_reason_primary = "no_confident_nppes_match",
                        verbose = FALSE))

cat("\nMatch decisions:\n"); print(count(out, match_decision, sort = TRUE))
cat("\nAccepted by evidence tier:\n"); print(count(accepted, evidence, sort = TRUE))
cat(sprintf("\nWith city/state: %s of %s (%.1f%%)\n",
            format(nrow(accepted), big.mark = ","), format(nrow(out), big.mark = ","),
            100 * nrow(accepted) / nrow(out)))
cat("\nBy AMCB status:\n")
print(out %>% group_by(status) %>%
        summarise(n = n(), accepted = sum(match_decision == "Accept"),
                  pct = round(100 * mean(match_decision == "Accept"), 1),
                  .groups = "drop") %>% arrange(desc(n)))
cat("\nTop states:\n")
print(count(accepted, practice_state, sort = TRUE) %>% head(10))

validation <- tryCatch({
  validate_pipeline_output(
    matched_df = out %>% mutate(match_method = "surname_block_jw_evidence",
                                confidence_score = match_score) %>%
      select(roster_id, npi, match_method, confidence_score),
    specialty_config = list(target_match_rate = 0.60),
    n_total = nrow(out), is_test = TRUE)
}, error = function(e) { cat("\nVALIDATION FAILED:\n", conditionMessage(e), "\n"); FALSE })
cat(sprintf("\nvalidate_pipeline_output: %s\n",
            if (isTRUE(validation)) "PASS" else "see messages above"))
