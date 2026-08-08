#!/usr/bin/env Rscript
# =============================================================================
# AMCB certified midwives -> NPI, using the existing isochrones machinery
# =============================================================================
#
# This deliberately does NOT introduce another fuzzy matcher. It reuses the
# stable pipeline logic from:
#
#   scripts/match_enthealth_to_npi.R   -- itself adapted from
#   R/canonical_abog_npi_pipeline_STABLE.R
#
# Specifically reused, not reimplemented:
#   norm_name(), first_initial()   name normalisation
#   compute_match_score()          additive flag scoring (score_total / 108)
#   rank_one_to_one()              greedy bijection with deterministic tiebreak
#   safe_pct()                     reporting helper
#
# ENTHealth is the right precedent: a scrape with names but no NPI, matched
# against an NPPES pool. AMCB is the harder case of the same shape, because it
# publishes no location at all -- so the zip/city/phone signals that pipeline
# leans on are unavailable, and the discriminating evidence is name plus the
# fact that every candidate in the panel is already a midwife.
#
# Candidates come from the 2007-2025 historical NPPES panel rather than the
# current registry, so midwives who have since left NPPES remain matchable.
# For each matched NPI the MOST RECENT panel appearance supplies the location,
# and nppes_location_year travels beside it: for someone last seen in 2014 this
# is their last observed practice location, not their current one.
#
# Every AMCB row is preserved. Unmatched rows keep NA geography.
#
# Output: artifacts/amcb_npi_matched.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringdist); library(tidyr)
})

ISO <- Sys.getenv("ISOCHRONES_DIR", path.expand("~/isochrones"))
Sys.setenv(PIPELINE_LOAD_ONLY = "1")   # suppress the script's auto-main()
ent_script <- file.path(ISO, "scripts", "match_enthealth_to_npi.R")
if (!file.exists(ent_script)) {
  stop(sprintf("Cannot find %s -- set ISOCHRONES_DIR", ent_script), call. = FALSE)
}
# The script guards that here::here() resolves to the isochrones root, because
# every source() inside it depends on that. Sourcing from another repo trips the
# guard, so source it from its own root and come straight back. (here caches the
# root it resolves; nothing here calls here() afterwards.)
local({
  owd <- setwd(ISO)
  on.exit(setwd(owd), add = TRUE)
  suppressWarnings(suppressMessages(source(file.path("scripts",
                                                     "match_enthealth_to_npi.R"))))
})
for (fn in c("norm_name", "first_initial", "compute_match_score",
             "rank_one_to_one", "safe_pct")) {
  if (!exists(fn)) stop(sprintf("%s() not available from %s", fn, ent_script),
                        call. = FALSE)
}
cat("reusing:", paste(c("norm_name", "first_initial", "compute_match_score",
                        "rank_one_to_one"), collapse = ", "), "\n")

PANEL   <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
ROSTER  <- "midwives.csv"
OUT_DIR <- "artifacts"
dir.create(OUT_DIR, showWarnings = FALSE)
YEAR_FLOOR <- suppressWarnings(as.integer(Sys.getenv("PANEL_YEAR_MAX", "")))
# The A/B variant must not overwrite the production artifact -- it did once,
# and the truncated-panel numbers silently replaced the full-panel ones.
OUT     <- file.path(OUT_DIR, if (is.na(YEAR_FLOOR)) "amcb_npi_matched.csv"
                              else sprintf("amcb_npi_matched_through%d.csv", YEAR_FLOOR))

# --- Valid NPI: 10 digits, Luhn with the 80840 prefix (NPPES check digit) ----
npi_luhn_ok <- function(npi) {
  ok <- grepl("^[0-9]{10}$", npi)
  if (!any(ok, na.rm = TRUE)) return(ok & FALSE)
  digits <- lapply(npi, function(x) if (grepl("^[0-9]{10}$", x))
    as.integer(strsplit(paste0("80840", substr(x, 1, 9)), "")[[1]]) else NULL)
  vapply(seq_along(npi), function(i) {
    d <- digits[[i]]
    if (is.null(d)) return(FALSE)
    idx <- rev(seq_along(d))
    dbl <- d; odd <- which(idx %% 2 == 1)
    dbl[odd] <- dbl[odd] * 2
    dbl[dbl > 9] <- dbl[dbl > 9] - 9
    (10 - (sum(dbl) %% 10)) %% 10 == as.integer(substr(npi[i], 10, 10))
  }, logical(1))
}

# --- Inputs ------------------------------------------------------------------
amcb <- read_csv(ROSTER, show_col_types = FALSE) %>%
  mutate(amcb_id = certification_number,
         last_clean  = norm_name(last_name),
         # AMCB fuses middle names into first_name ("Julie Ann"): the first
         # token is the given name, the rest is middle.
         first_raw   = norm_name(first_name),
         first_clean = sub("\\s.*$", "", first_raw),
         mid_from_first = trimws(sub("^[^ ]*", "", first_raw)),
         middle_clean = trimws(paste(norm_name(middle_name), mid_from_first)),
         first_init  = first_initial(first_clean),
         mid_init    = substr(middle_clean, 1, 1))

panel_raw <- read_csv(PANEL, col_types = cols(.default = "c")) %>%
  mutate(snapshot_year = suppressWarnings(as.integer(snapshot_year)))
if (!is.na(YEAR_FLOOR)) {
  panel_raw <- filter(panel_raw, snapshot_year <= YEAR_FLOOR)
  cat(sprintf("panel restricted to snapshots <= %d\n", YEAR_FLOOR))
}

panel <- panel_raw %>%
  filter(!is.na(npi), npi_luhn_ok(npi)) %>%
  mutate(nppes_last_clean  = norm_name(last_name),
         nppes_first_clean = norm_name(first_name),
         nppes_first_init  = first_initial(nppes_first_clean),
         nppes_mid_init    = substr(norm_name(middle_name), 1, 1))

# Candidate identities: one row per (NPI, name spelling) so every historical
# surname is matchable, not just the current one.
identities <- panel %>%
  distinct(npi, nppes_last_clean, nppes_first_clean, nppes_first_init, nppes_mid_init)

# Most recent appearance per NPI supplies the geography.
latest <- panel %>%
  filter(!is.na(practice_state) & nzchar(practice_state)) %>%
  arrange(desc(snapshot_year)) %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>%
  # Business PRACTICE location (build_midwife_panel.R selects
  # provider_first_line_business_practice_location_address), never the mailing
  # address. The source fields ride along: publishing city/state is fine, but
  # validating them later is impossible without what they were derived from.
  transmute(npi,
            nppes_city = practice_city, nppes_state = practice_state,
            nppes_zip = practice_zip,
            nppes_practice_address = practice_address,
            nppes_location_year = snapshot_year)

cat(sprintf("AMCB rows: %s | panel identities: %s (%s NPIs, snapshots %s)\n",
            format(nrow(amcb), big.mark = ","), format(nrow(identities), big.mark = ","),
            format(n_distinct(identities$npi), big.mark = ","),
            paste(range(panel$snapshot_year, na.rm = TRUE), collapse = "-")))

# --- Staged matching ---------------------------------------------------------
# Flags feed compute_match_score() unchanged. There is no zip/city/phone signal
# to give it -- AMCB has no location -- so those stay 0 and the score is driven
# by name agreement plus the specialty signal, which is 1 for every candidate
# because the panel is midwives by construction.
# specialty_signal is deliberately 0, not 1. Every candidate in this pool is a
# midwife by construction, so a constant flag cannot favour one NPI over
# another -- scoring it would only inflate confidence uniformly and disguise
# how thin the discriminating evidence actually is.
base_flags <- function(df, strategy, method) {
  df %>% mutate(match_strategy = strategy, match_method = method,
                specialty_signal = 0L, zip_match = 0L, city_match = 0L,
                phone_match = 0L)
}
# Maximum attainable score with name evidence alone (exact_last 40 + exact_first
# 20); the ENT pipeline's 108 assumed zip/city/phone/specialty signals we do not
# have, so scaling by it would understate nothing and overstate confidence.
MAX_NAME_SCORE <- 60

s1 <- amcb %>%
  inner_join(identities, by = c("last_clean" = "nppes_last_clean",
                                "first_clean" = "nppes_first_clean"),
             relationship = "many-to-many") %>%
  mutate(exact_last = 1L, exact_first = 1L, first_init_ok = 1L) %>%
  base_flags(1L, "exact_last_first")

s2 <- amcb %>%
  anti_join(s1, by = "amcb_id") %>%
  inner_join(identities, by = c("last_clean" = "nppes_last_clean",
                                "first_init" = "nppes_first_init"),
             relationship = "many-to-many") %>%
  filter(mid_init == "" | nppes_mid_init == "" | mid_init == nppes_mid_init) %>%
  mutate(exact_last = 1L, exact_first = 0L, first_init_ok = 1L) %>%
  base_flags(2L, "exact_last_first_initial")

# Fuzzy surname, exact given name: marriage/hyphenation drift the panel's own
# name history did not happen to capture.
s3 <- amcb %>%
  anti_join(bind_rows(s1, s2), by = "amcb_id") %>%
  inner_join(identities, by = c("first_clean" = "nppes_first_clean"),
             relationship = "many-to-many") %>%
  mutate(lv_last = stringdist(last_clean, nppes_last_clean, method = "lv")) %>%
  filter(lv_last > 0, lv_last <= 2, nchar(last_clean) >= 5) %>%
  mutate(exact_last = 0L, exact_first = 1L, first_init_ok = 1L) %>%
  base_flags(3L, "fuzzy_last_exact_first")

candidates <- bind_rows(s1, s2, s3) %>%
  compute_match_score() %>%
  mutate(confidence_score = pmin(1.0, score_total / MAX_NAME_SCORE),
         mid_match = as.integer(nzchar(mid_init) & mid_init == nppes_mid_init))

cat("\ncandidate pairs by strategy:\n"); print(count(candidates, match_strategy, match_method))

# --- Identifiability guard ---------------------------------------------------
# rank_one_to_one() enforces a bijection, and with the ENTHealth data that was
# safe because address and phone carried independent identifying information.
# AMCB supplies name only. A bijection over name-only evidence would silently
# manufacture identifiability: if three midwives are named JENNIFER SMITH, the
# algorithm still hands out exactly one NPI, and the result LOOKS clean.
#
# So resolution happens BEFORE ranking, and a row is accepted only when the
# name evidence actually singles out one NPI:
#   1. one candidate NPI holds the top score outright, or
#   2. the tie is broken by a middle initial both sides record.
# Anything still tied is quarantined as ambiguous rather than being resolved by
# the bijection's arbitrary but deterministic ordering.
per_npi <- candidates %>%
  group_by(amcb_id, npi) %>%
  summarise(score_total = max(score_total), mid_match = max(mid_match),
            match_method = match_method[which.max(score_total)],
            match_strategy = match_strategy[which.max(score_total)],
            confidence_score = max(confidence_score), .groups = "drop")

pre_rank <- per_npi %>% count(amcb_id, name = "n_candidates_pre_rank")

resolved <- per_npi %>%
  left_join(pre_rank, by = "amcb_id") %>%
  group_by(amcb_id) %>%
  mutate(top_score = max(score_total),
         n_at_top  = sum(score_total == top_score),
         n_top_mid = sum(score_total == top_score & mid_match == 1L)) %>%
  filter(score_total == top_score) %>%
  mutate(resolution = case_when(
    n_at_top == 1L                             ~ "unique_top_score",
    n_top_mid == 1L & mid_match == 1L          ~ "resolved_by_middle",
    TRUE                                       ~ "tied")) %>%
  filter(resolution != "tied",
         !(n_at_top > 1L & resolution == "unique_top_score")) %>%
  ungroup()

quarantined_ids <- setdiff(unique(candidates$amcb_id), unique(resolved$amcb_id))

# Only now enforce one NPI to one person, over candidates that were already
# individually identifiable. Record contested NPIs before the bijection prunes
# them, since that count is itself a data-quality signal.
contested <- resolved %>% count(npi) %>% filter(n > 1)

matched <- resolved %>%
  mutate(enthealth_id = amcb_id) %>%
  rank_one_to_one() %>%
  transmute(amcb_id, npi, npi_match_method = match_method,
            npi_match_resolution = resolution,
            npi_match_confidence = round(confidence_score, 4),
            npi_match_score = score_total,
            n_candidates_pre_rank, match_strategy)

# Rows identifiable on name but which lost the bijection to a stronger claim.
lost_bijection <- setdiff(unique(resolved$amcb_id), matched$amcb_id)
ambiguous_ids <- union(quarantined_ids, lost_bijection)

out <- amcb %>%
  select(-last_clean, -first_raw, -first_clean, -mid_from_first,
         -middle_clean, -first_init, -mid_init) %>%
  left_join(matched, by = "amcb_id") %>%
  left_join(latest, by = "npi") %>%
  mutate(npi_match_status = case_when(
    !is.na(npi)                  ~ "matched",
    amcb_id %in% quarantined_ids ~ "ambiguous_tied_names",
    amcb_id %in% lost_bijection  ~ "ambiguous_contested_npi",
    TRUE                         ~ "unmatched")) %>%
  left_join(pre_rank, by = "amcb_id", suffix = c("", "_all")) %>%
  mutate(n_candidates_pre_rank = coalesce(n_candidates_pre_rank,
                                          n_candidates_pre_rank_all, 0L)) %>%
  select(-any_of("n_candidates_pre_rank_all"))

stopifnot(nrow(out) == nrow(amcb), !any(duplicated(out$amcb_id)))
write_csv(out, OUT, na = "")

# --- Report ------------------------------------------------------------------
n <- nrow(out); nm <- sum(!is.na(out$npi))
cat(sprintf("\n================ AMCB -> NPI ================\n"))
cat(sprintf("total AMCB rows            : %s\n", format(n, big.mark = ",")))
cat(sprintf("unique certification numbers: %s\n", format(n_distinct(out$amcb_id), big.mark = ",")))
cat(sprintf("unique (last, first) names : %s\n",
            format(nrow(distinct(out, last_name, first_name)), big.mark = ",")))
cat(sprintf("NPI matched                : %s (%s)\n", format(nm, big.mark = ","), safe_pct(nm, n)))
cat(sprintf("ambiguous (lost bijection) : %s\n", format(length(ambiguous_ids), big.mark = ",")))
cat(sprintf("unmatched                  : %s (%s)\n",
            format(sum(out$npi_match_status == "unmatched"), big.mark = ","),
            safe_pct(sum(out$npi_match_status == "unmatched"), n)))
cat("\nby match method:\n"); print(count(filter(out, !is.na(npi)), npi_match_method, sort = TRUE))
cat("\nby resolution:\n"); print(count(filter(out, !is.na(npi)), npi_match_resolution, sort = TRUE))

# The categories that matter for identifiability, reported separately rather
# than rolled into a single yield number.
cat("\n---- identifiability breakdown ----\n")
ex <- filter(out, npi_match_method == "exact_last_first", !is.na(npi))
cat(sprintf("exact first+last, single candidate NPI : %s\n",
            format(sum(ex$n_candidates_pre_rank == 1), big.mark = ",")))
cat(sprintf("exact first+last, >1 candidate NPI     : %s\n",
            format(sum(ex$n_candidates_pre_rank > 1), big.mark = ",")))
cat(sprintf("resolved by middle name/initial        : %s\n",
            format(sum(out$npi_match_resolution == "resolved_by_middle", na.rm = TRUE),
                   big.mark = ",")))
cat(sprintf("fuzzy-surname matches                  : %s\n",
            format(sum(out$npi_match_method == "fuzzy_last_exact_first", na.rm = TRUE),
                   big.mark = ",")))
cat(sprintf("quarantined: tied on name evidence     : %s\n",
            format(sum(out$npi_match_status == "ambiguous_tied_names"), big.mark = ",")))
cat(sprintf("quarantined: contested NPI             : %s\n",
            format(sum(out$npi_match_status == "ambiguous_contested_npi"), big.mark = ",")))
cat(sprintf("unmatched (no candidate at all)        : %s\n",
            format(sum(out$npi_match_status == "unmatched"), big.mark = ",")))
dupe_names <- out %>% count(last_name, first_name) %>% filter(n > 1)
cat(sprintf("AMCB (last, first) names held by >1 row: %s names, %s rows\n",
            format(nrow(dupe_names), big.mark = ","),
            format(sum(dupe_names$n), big.mark = ",")))
cat(sprintf("NPIs contested by >1 AMCB row pre-bijection: %s\n",
            format(nrow(contested), big.mark = ",")))

cat("\nby confidence tier:\n")
print(out %>% filter(!is.na(npi)) %>%
        mutate(tier = cut(npi_match_confidence, c(-Inf, .5, .7, .85, Inf),
                          labels = c("<0.50", "0.50-0.70", "0.70-0.85", ">=0.85"))) %>%
        count(tier))
cat(sprintf("\ncity/state populated       : %s (%s)\n",
            format(sum(!is.na(out$nppes_state)), big.mark = ","),
            safe_pct(sum(!is.na(out$nppes_state)), n)))
cat("\nnppes_location_year distribution:\n")
print(count(filter(out, !is.na(nppes_location_year)), nppes_location_year))
dup <- out %>% filter(!is.na(npi)) %>% count(npi) %>% filter(n > 1)
cat(sprintf("\nduplicate NPI assignments  : %s\n", format(nrow(dup), big.mark = ",")))
cat(sprintf("saved artifact             : %s\n", normalizePath(OUT)))

cat("\n---------------- 20 matched rows ----------------\n")
print(out %>% filter(!is.na(npi)) %>%
        select(certification_number, status, last_name, first_name, npi,
               npi_match_method, npi_match_confidence, nppes_city, nppes_state,
               nppes_location_year) %>%
        slice_sample(n = min(20, nm)) %>% as.data.frame())
cat("\n------- 20 ambiguous / unmatched rows -------\n")
print(out %>% filter(is.na(npi)) %>%
        select(certification_number, status, last_name, first_name,
               middle_name, npi_match_status, n_candidates_pre_rank) %>%
        slice_sample(n = 20) %>% as.data.frame())
