#!/usr/bin/env Rscript
# =============================================================================
# Match AMCB certified midwives to NPPES for practice city/state
# =============================================================================
#
# AMCB's directory does not expose location (city/state sit behind their paid
# primary-source verification), so geography comes from NPPES instead.
#
# Reuses the isochrones-A name-matching stack rather than reinventing it:
#   normalize_string()                       string_normalization.R
#   create_nickname_dictionary()             nickname_system.R
#   calculate_enhanced_first_name_similarity()
#
# Scoring follows matching_utils.R apply_scoring(): a weighted combination of
# Jaro-Winkler similarities with the documented default weights and thresholds
# (last 0.47, first 0.41, middle 0.12; accept 0.85, review 0.75).
#
# Inputs : midwives.csv, nppes_midwives.parquet (see extract_nppes_midwives.R)
# Output : midwives_with_nppes.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringdist)
  library(arrow)
})

ISO <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones-A/R"))
for (f in c("string_normalization.R", "nickname_system.R")) {
  p <- file.path(ISO, f)
  if (!file.exists(p)) {
    stop(sprintf("Cannot find %s. Set ISOCHRONES_R to the isochrones-A R/ directory.", p),
         call. = FALSE)
  }
  source(p)
}

WEIGHTS    <- c(last = 0.47, first = 0.41, middle = 0.12)
ACCEPT     <- 0.85
REVIEW     <- 0.75
MIN_LAST   <- 0.70   # blocking floor, matching_utils.R min_last_name_similarity
AMBIGUOUS  <- 0.02   # runner-up within this of the best -> refuse to pick

amcb <- read_csv("midwives.csv", show_col_types = FALSE) %>%
  mutate(row_id = row_number(),
         last_n   = normalize_string(last_name),
         first_n  = normalize_string(first_name),
         middle_n = normalize_string(coalesce(middle_name, "")))

nppes <- read_parquet("nppes_midwives.parquet") %>%
  mutate(across(c(last_name, first_name, middle_name), normalize_string),
         middle_name = coalesce(middle_name, ""))

cat(sprintf("AMCB records: %s | NPPES midwifery providers: %s\n",
            format(nrow(amcb), big.mark = ","), format(nrow(nppes), big.mark = ",")))

nick <- create_nickname_dictionary(verbose = FALSE)

# Blocking: exact last name, then the first four characters for spelling and
# hyphenation drift on the records that block found nothing for.
by_last   <- split(seq_len(nrow(nppes)), nppes$last_name)
by_prefix <- split(seq_len(nrow(nppes)), substr(nppes$last_name, 1, 4))

middle_similarity <- function(a, b) {
  # Tiered, per matching_utils.R: initials only signal weakly.
  if (!nzchar(a) || !nzchar(b)) return(0)
  if (nchar(a) > 1 && nchar(b) > 1) return(stringsim(a, b, method = "jw"))
  if (substr(a, 1, 1) == substr(b, 1, 1)) return(0.1)
  0
}

score_one <- function(i) {
  idx <- by_last[[amcb$last_n[i]]]
  if (is.null(idx)) idx <- by_prefix[[substr(amcb$last_n[i], 1, 4)]]
  if (is.null(idx) || !length(idx)) return(NULL)

  cand <- nppes[idx, ]
  last_sim <- stringsim(amcb$last_n[i], cand$last_name, method = "jw")
  keep <- last_sim >= MIN_LAST
  if (!any(keep)) return(NULL)
  cand <- cand[keep, ]; last_sim <- last_sim[keep]

  first_sim <- vapply(cand$first_name, function(f)
    calculate_enhanced_first_name_similarity(amcb$first_n[i], f, nick),
    numeric(1), USE.NAMES = FALSE)
  mid_sim <- vapply(cand$middle_name, middle_similarity, numeric(1),
                    a = amcb$middle_n[i], USE.NAMES = FALSE)

  total <- WEIGHTS[["last"]] * last_sim + WEIGHTS[["first"]] * first_sim +
           WEIGHTS[["middle"]] * mid_sim
  ord <- order(total, decreasing = TRUE)
  best <- ord[1]
  runner_up <- if (length(ord) > 1) total[ord[2]] else -Inf

  decision <- if (total[best] < REVIEW) {
    "No match"
  } else if (runner_up >= total[best] - AMBIGUOUS &&
             cand$npi[ord[2]] != cand$npi[best]) {
    "Ambiguous"
  } else if (total[best] >= ACCEPT) {
    "Accept"
  } else {
    "Review"
  }

  tibble(row_id = amcb$row_id[i],
         npi            = cand$npi[best],
         practice_city  = cand$practice_city[best],
         practice_state = cand$practice_state[best],
         practice_zip   = substr(cand$practice_zip[best], 1, 5),
         nppes_taxonomy = cand$taxonomy[best],
         match_score    = round(total[best], 4),
         match_decision = decision,
         n_candidates   = nrow(cand))
}

start <- Sys.time()
matches <- vector("list", nrow(amcb))
for (i in seq_len(nrow(amcb))) {
  matches[[i]] <- score_one(i)
  if (i %% 2000 == 0) {
    cat(sprintf("  %s/%s (%.0fs)\n", i, nrow(amcb),
                as.numeric(difftime(Sys.time(), start, units = "secs"))))
  }
}
matches <- bind_rows(matches)

out <- amcb %>%
  select(-last_n, -first_n, -middle_n) %>%
  left_join(matches, by = "row_id") %>%
  mutate(match_decision = coalesce(match_decision, "No match")) %>%
  # Only accepted matches carry geography; review/ambiguous keep the score so
  # they can be adjudicated, but must not masquerade as known locations.
  mutate(across(c(npi, practice_city, practice_state, practice_zip, nppes_taxonomy),
                ~ if_else(match_decision == "Accept", .x, NA_character_))) %>%
  select(-row_id)

write_csv(out, "midwives_with_nppes.csv", na = "")

cat("\nMatch decisions:\n")
print(count(out, match_decision, sort = TRUE))
cat(sprintf("\nWith city/state: %s of %s (%.1f%%)\n",
            format(sum(!is.na(out$practice_state)), big.mark = ","),
            format(nrow(out), big.mark = ","),
            100 * mean(!is.na(out$practice_state))))
cat("\nTop states:\n")
print(out %>% filter(!is.na(practice_state)) %>% count(practice_state, sort = TRUE) %>% head(10))
