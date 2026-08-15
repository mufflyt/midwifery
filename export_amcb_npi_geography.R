#!/usr/bin/env Rscript
# =============================================================================
# AMCB roster -> NPI -> NPPES practice location, with the match provenance
# =============================================================================
# This is a SELECT, not a match. The identity resolution already happened:
# match_amcb_to_npi.R generates candidates against the NPPES panel,
# match_nppes.R scores them through the canonical isochrones matching stack
# (parse_physician_name_enhanced, calculate_similarities/apply_scoring,
# score_middle_name_match, the nickname dictionary), and reconcile_linkage.R
# resolves them into artifacts/amcb_npi_linkage_FROZEN.csv, which already
# carries the NPPES city, state, ZIP and street address for every accepted NPI.
#
# So geography here is strictly DOWNSTREAM of identity:
#
#     AMCB person -> frozen NPI crosswalk -> NPPES practice address
#
# and never AMCB name -> city/state. Nothing in this file re-matches, re-scores,
# widens a threshold, or promotes a tier. A row without an NPI leaves this
# script without a city, which is the correct answer rather than a gap to fill:
# 3,147 quarantined certificants have candidate NPIs that the evidence cannot
# separate, and inventing geography for them would assert an identity the
# matcher deliberately refused to assert.
#
# Output : artifacts/amcb_npi_geography.csv  (PERSON-LEVEL, gitignored)
#          artifacts/amcb_npi_geography_by_state.csv  (aggregate, safe to track)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})


root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}

FROZEN <- file.path(root, "artifacts", "amcb_npi_linkage_FROZEN.csv")
OUT    <- file.path(root, "artifacts", "amcb_npi_geography.csv")
OUT_AGG <- file.path(root, "artifacts", "amcb_npi_geography_by_state.csv")

source(file.path(root, "R", "lib", "artifact_provenance.R"))

stopifnot("frozen crosswalk not found" = file.exists(FROZEN))

d <- read_csv(FROZEN, show_col_types = FALSE, progress = FALSE)

out <- d %>%
  transmute(
    # --- AMCB identity, as scraped -----------------------------------------
    certification, certification_number, status,
    certification_date, expiration_date,
    last_name, first_name, middle_name, amcb_id,

    # --- resolved identity --------------------------------------------------
    npi,

    # --- NPPES practice location, carried from the matched NPI --------------
    nppes_city, nppes_state, nppes_zip,
    nppes_practice_address, nppes_location_year,

    # --- how the identity was established, kept with the geography so a
    #     downstream reader cannot use a city without seeing the evidence
    #     behind the NPI it came from --------------------------------------
    linkage_tier, npi_match_status, npi_match_method, match_strategy,
    name_evidence_class, npi_match_resolution,
    npi_match_confidence, npi_match_score,

    # --- ambiguity, preserved rather than resolved --------------------------
    has_candidate, candidate_count, n_candidates_pre_rank, n_at_best_class,
    ambiguity_flag, match_reason, nppes_name_changed_since_match
  )

# GEOGRAPHY REQUIRES AN ACCEPTED NPI. 164 rows arrive from the frozen crosswalk
# with an nppes_state but npi = NA -- NPPES fields retained from a candidate the
# matcher declined to accept. Carrying that through would do the exact thing
# this pipeline refuses: assert a location for a person whose identity the
# evidence could not settle.
#
#     156  sensitivity_name_component  the whole tier
#       8  quarantined                 npi_match_status
#                                      "ambiguous_unruled_out_component"
#
# The name-component tier is the larger share and the more surprising one: every
# row in it carries a city and state while carrying no NPI at all. I first saw
# only the 8 and had to be corrected by the count.
#
# They are blanked here rather than in the crosswalk, because the crosswalk is
# frozen and rewriting it is a separate, reviewable decision. The suppression is
# counted and reported, never silent.
suppressed <- sum(is.na(out$npi) &
                    !is.na(out$nppes_state) & nzchar(out$nppes_state))

out <- out %>%
  mutate(across(c(nppes_city, nppes_state, nppes_zip,
                  nppes_practice_address, nppes_location_year),
                ~ if_else(is.na(npi), NA, .x)))

write_csv(out, OUT)

agg <- out %>%
  filter(!is.na(nppes_state), nzchar(nppes_state)) %>%
  count(nppes_state, linkage_tier, name = "n") %>%
  arrange(nppes_state, desc(n))

# The aggregate is tracked, so it gets a sidecar in the same call that writes
# it -- recording the frozen crosswalk it was derived from and that file's
# SHA-256 at the moment of writing. The person-level export above is gitignored
# and deliberately gets none: a sidecar for a file nobody else can hold is
# provenance for nothing.
write_with_provenance(agg, OUT_AGG, inputs = FROZEN)

cat(sprintf("rows                     : %s\n", format(nrow(out), big.mark = ",")))
cat(sprintf("geography SUPPRESSED     : %s (no accepted NPI; see comment)\n",
            format(suppressed, big.mark = ",")))
cat(sprintf("with an NPI              : %s\n",
            format(sum(!is.na(out$npi)), big.mark = ",")))
cat(sprintf("with city/state/ZIP      : %s\n",
            format(sum(!is.na(out$nppes_state) & nzchar(out$nppes_state)), big.mark = ",")))
cat(sprintf("with a street address    : %s\n",
            format(sum(!is.na(out$nppes_practice_address) &
                         nzchar(out$nppes_practice_address)), big.mark = ",")))
cat("\nby tier (geography follows identity, so quarantined stays empty):\n")
print(out %>%
        group_by(linkage_tier) %>%
        summarise(n = n(),
                  with_state = sum(!is.na(nppes_state) & nzchar(nppes_state)),
                  pct = round(100 * with_state / n, 1),
                  .groups = "drop") %>%
        arrange(desc(n)))
cat(sprintf("\nperson-level -> %s (gitignored)\naggregate    -> %s\n", OUT, OUT_AGG))
