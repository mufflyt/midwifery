#!/usr/bin/env Rscript
#' @title Candidate-level detail for tied and contested "No NPI match" cases
#'
#' @description
#' build_exclusion_flow_person_level.R records THAT a person's candidate
#' pool was tied or contested and how many candidates existed
#' (match_reason/candidate_count), but not which NPIs/names those
#' candidates actually were -- that detail lives only in
#' linkage_candidate_audit.csv (match_amcb_to_npi.R's own pre-resolution
#' candidate pool), which is not itself a name/location table. This script
#' joins that candidate pool back to the NPPES historical panel (most
#' recent snapshot per NPI, matching the convention used everywhere else
#' in this pipeline) to answer "who, specifically, was this person tied
#' with or contested against".
#'
#' Scope: ACTIVE certificants in the ambiguous_tied_names /
#' ambiguous_contested_npi dispositions only (1,516 people, ~24k candidate
#' rows) -- the two categories where "no NPI match" means "we found
#' multiple plausible people", not "we found nobody" (unmatched) or "we
#' found one but held it to a stricter bar" (the sensitivity tiers, which
#' already carry their candidate's identity in no_npi_match.csv's
#' would_be_* columns).
#'
#' Output: docs/figures/exclusion_by_stage/no_npi_match_candidate_detail.csv,
#' one row per (certification_number, candidate NPI).
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

AUDIT <- file.path("artifacts", "linkage_candidate_audit.csv")
PANEL <- "midwife_panel.csv"
NO_MATCH <- file.path("docs", "figures", "exclusion_by_stage", "no_npi_match.csv")

for (p in c(AUDIT, PANEL, NO_MATCH)) {
  if (!file.exists(p)) {
    stop(sprintf(paste0(
      "%s not found. This script needs the person-level candidate audit\n",
      "and NPPES panel, both gitignored -- run match_amcb_to_npi.R on a\n",
      "machine holding them first."), p), call. = FALSE)
  }
}

audit <- read_csv(AUDIT, show_col_types = FALSE, progress = FALSE, guess_max = Inf)
no_match <- read_csv(NO_MATCH, show_col_types = FALSE, progress = FALSE)

subjects <- no_match %>%
  filter(match_status %in% c("ambiguous_tied_names", "ambiguous_contested_npi"))

candidates <- audit %>%
  filter(amcb_id %in% subjects$certification_number) %>%
  transmute(certification_number = amcb_id, npi = as.character(npi),
           name_evidence_class, taxonomy_axis, match_method)

# Most recent panel snapshot per candidate NPI -- same convention as
# match_amcb_to_npi.R's own final-match location ("for each matched NPI the
# MOST RECENT panel appearance supplies the location").
panel <- read_csv(PANEL, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(npi %in% unique(candidates$npi)) %>%
  mutate(snapshot_year = suppressWarnings(as.integer(snapshot_year))) %>%
  arrange(npi, desc(snapshot_year)) %>%
  distinct(npi, .keep_all = TRUE) %>%
  transmute(npi, candidate_last = last_name, candidate_first = first_name,
           candidate_city = practice_city, candidate_state = practice_state,
           candidate_last_seen = snapshot_year)

out <- candidates %>%
  left_join(panel, by = "npi") %>%
  left_join(subjects %>% select(certification_number, last_name, first_name,
                               match_status, candidate_count, match_reason),
           by = "certification_number") %>%
  arrange(certification_number, name_evidence_class)

# NOT every subject has a row here, and that is reported rather than
# silently accepted or hard-failed on. linkage_candidate_audit.csv is
# written by match_amcb_to_npi.R per A/B arm; reconcile_linkage.R's final
# match_status for a handful of people comes from combining both arms, and
# this script only has whichever arm's audit is currently on disk. A person
# present in no_npi_match.csv but absent here genuinely has no candidate
# detail available on this machine right now -- not an error in this join.
missing_subjects <- setdiff(subjects$certification_number, out$certification_number)
if (length(missing_subjects)) {
  message(sprintf(
    "%d of %d tied/contested subjects (%.1f%%) have no row in %s and are NOT in this output -- likely resolved via a different A/B arm than the one currently on disk.",
    length(missing_subjects), nrow(subjects),
    100 * length(missing_subjects) / nrow(subjects), AUDIT))
}

out_path <- file.path("docs", "figures", "exclusion_by_stage",
                      "no_npi_match_candidate_detail.csv")
write_with_provenance(out, out_path, inputs = c(AUDIT, PANEL, NO_MATCH))

cat(sprintf("wrote %s (%d rows, %d people, %d distinct candidate NPIs)\n",
           out_path, nrow(out), n_distinct(out$certification_number),
           n_distinct(out$npi)))
cat(sprintf("candidate NPIs not found in the panel (no name available): %d\n",
           sum(is.na(out$candidate_last))))
