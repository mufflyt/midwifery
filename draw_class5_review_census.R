#!/usr/bin/env Rscript
# =============================================================================
# Class-5 (surname component) matches: full review census, ordered by risk
# =============================================================================
#
# WHY A CENSUS AND NOT A SAMPLE. There are 164 class-5 matches. A 25-row draw
# from the general review sample would touch maybe a handful of them, and the
# whole point of reviewing this tier is that it is the weakest evidence in the
# crosswalk BY CONSTRUCTION -- admitted at the bottom of the evidence order
# precisely because discarding half a compound surname discards real
# discriminating information. Sampling a population you already suspect, when
# you could enumerate it, throws away certainty for no saving.
#
# THE RISK SIGNAL. A class-5 match joins on ONE component of a compound
# surname. Its precision therefore depends almost entirely on how
# discriminating that component is: "SCHRADER" identifies a small set of
# people, "SMITH" identifies thousands. So the census carries
# shared_token_npi_count -- how many DISTINCT NPIs in the candidate pool carry
# that surname token at all. A match on a token held by 3 NPIs is
# near-conclusive; a match on one held by 900 is a coin flip that happened to
# resolve because the other 899 had different given names.
#
# Rows are ordered by that count DESCENDING, so the least defensible matches
# are reviewed first and a reviewer who stops early has still seen the ones
# most likely to be wrong.
#
# Run: Rscript draw_class5_review_census.R
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path(root_dir, "R", "amcb_name_keys.R"))

XW <- Sys.getenv(
  "CROSSWALK_IN",
  "artifacts/amcb_npi_crosswalk_component_panel-midwifery-plus-nursing_years-2007-2025.csv")
PANEL <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
OUT   <- Sys.getenv("CLASS5_OUT", "artifacts/amcb_class5_review_census.csv")
stopifnot(file.exists(XW), file.exists(PANEL))

x <- read_csv(XW, col_types = cols(.default = "c"))
c5 <- x %>% filter(name_evidence_class == "5")
cat(sprintf("class-5 matches: %s of %s crosswalk rows\n",
            format(nrow(c5), big.mark = ","), format(nrow(x), big.mark = ",")))
stopifnot(nrow(c5) > 0)

# --- Token frequency across the candidate pool -------------------------------
# Only npi and last_name are needed, so pull those two columns rather than
# reading the 493MB panel into R.
con <- dbConnect(duckdb::duckdb()); on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
surnames <- dbGetQuery(con, sprintf(
  "SELECT DISTINCT npi, last_name FROM read_csv_auto('%s', all_varchar = TRUE,
     sample_size = 1000, normalize_names = TRUE)
   WHERE last_name IS NOT NULL AND last_name <> ''", PANEL))
cat(sprintf("distinct (NPI, surname) pairs in pool: %s\n",
            format(nrow(surnames), big.mark = ",")))

tok <- amcb_surname_token_table(surnames$last_name, surnames$npi)
token_freq <- tok %>% group_by(token) %>%
  summarise(shared_token_npi_count = n_distinct(id), .groups = "drop")
cat(sprintf("distinct surname tokens in pool: %s\n",
            format(nrow(token_freq), big.mark = ",")))

# --- The token that produced each match --------------------------------------
# Recomputed from the two recorded surnames rather than trusted from the run,
# so the census is checkable against the artifact instead of restating it.
shared_for <- function(a, b) {
  s <- intersect(amcb_surname_tokens(a), amcb_surname_tokens(b))
  if (!length(s)) NA_character_ else paste(s, collapse = "|")
}
c5$shared_token <- vapply(seq_len(nrow(c5)),
                          function(i) shared_for(c5$normalized_last_name[i],
                                                 c5$nppes_matched_last[i]),
                          character(1))
# A class-5 row with no shared token would mean the strategy fired on evidence
# that cannot be reconstructed -- a defect, not a weak match.
if (any(is.na(c5$shared_token))) {
  stop(sprintf("%d class-5 rows have no reconstructable shared token",
               sum(is.na(c5$shared_token))), call. = FALSE)
}

census <- c5 %>%
  left_join(token_freq, by = c("shared_token" = "token")) %>%
  mutate(
    shared_token_npi_count = coalesce(shared_token_npi_count, 0L),
    # Which side held the compound. Both directions occur and they fail
    # differently: AMCB-compound means NPPES dropped a component, NPPES-compound
    # means AMCB did.
    compound_side = case_when(
      grepl("[- ]", normalized_last_name) & grepl("[- ]", nppes_matched_last) ~ "both",
      grepl("[- ]", normalized_last_name) ~ "amcb",
      grepl("[- ]", nppes_matched_last)   ~ "nppes",
      TRUE ~ "neither"),
    risk_band = cut(shared_token_npi_count, c(-Inf, 5, 25, 100, Inf),
                    labels = c("low_<=5", "moderate_6-25", "high_26-100", "very_high_>100"))) %>%
  arrange(desc(shared_token_npi_count), desc(as.numeric(candidate_count))) %>%
  transmute(review_order = row_number(), risk_band, shared_token,
            shared_token_npi_count, compound_side,
            amcb_customer_id, amcb_id, amcb_name_original,
            normalized_first_name, normalized_middle_name, normalized_last_name,
            npi, nppes_matched_first, nppes_matched_last,
            nppes_first_name, nppes_middle_name, nppes_last_name,
            nppes_name_changed_since_match, nppes_credential,
            nppes_city, nppes_state, nppes_location_year,
            npi_tax_class, linkage_tier, candidate_count, n_at_best_class,
            npi_match_confidence, match_reason,
            reviewer_verdict = "", reviewer_notes = "")

write_csv(census, OUT, na = "")

cat(sprintf("\n============ class-5 review census: %s ============\n", OUT))
cat(sprintf("rows: %s (ALL class-5 matches, not a sample)\n",
            format(nrow(census), big.mark = ",")))
cat("\nby risk band (how many NPIs share the joining token):\n")
print(as.data.frame(count(census, risk_band)))
cat("\nwhich side held the compound surname:\n")
print(as.data.frame(count(census, compound_side)))
cat("\nby taxonomy class:\n")
print(as.data.frame(count(census, npi_tax_class)))
cat(sprintf("\nalso carrying an NPPES name change since the match: %s\n",
            sum(census$nppes_name_changed_since_match == "TRUE", na.rm = TRUE)))
cat("\n---- 12 highest-risk rows (review these first) ----\n")
print(as.data.frame(census %>% slice_head(n = 12) %>%
  transmute(review_order, tok = shared_token, n_npi = shared_token_npi_count,
            side = compound_side, amcb = amcb_name_original,
            nppes = paste(nppes_matched_first, nppes_matched_last),
            st = nppes_state, cand = candidate_count)), right = FALSE)
cat("\n---- 6 lowest-risk rows (for contrast) ----\n")
print(as.data.frame(census %>% slice_tail(n = 6) %>%
  transmute(review_order, tok = shared_token, n_npi = shared_token_npi_count,
            amcb = amcb_name_original,
            nppes = paste(nppes_matched_first, nppes_matched_last))), right = FALSE)
cat("\nreviewer_verdict / reviewer_notes are BLANK by design.\n")
