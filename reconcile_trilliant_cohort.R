#!/usr/bin/env Rscript
# =============================================================================
# Which cohort is the Trilliant work-site build describing?
# =============================================================================
# Two person lists are in circulation, and they have different sizes:
#
#   11,920  ACTIVE, primary-linked certificants of the 2026-08-10 freeze
#           (sha256 dbcc76f4...). build_trilliant_work_sites.R was first run
#           against this, because it is the freeze on the machine that ran it.
#   11,093  artifacts/tracked_roster_active_primary_linked.csv. Not a cohort:
#           the tracked person-level roster, rebuilt in #195 from the same
#           freeze but restricted to the 40 states of the file it replaced.
#
# Neither is the canonical ACTIVE, primary-linked cohort. The current freeze is
# the 22,357-row reconcile_ab_20260910T193000_issue172 roster (manifest
# artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json), and the registered
# count against it is 12,171 (tests/ci_science_laws.R, LAW_COHORTS;
# artifacts/table1_provenance.csv).
#
# This script reconciles the two lists that are available, person by person,
# and names a reason for every difference. It does not overwrite either list,
# and it does not decide which one is right: the answer to that is the current
# freeze, which this script only reads the manifest of.
#
# Inputs : LEGACY_FROZEN_CSV  the 2026-08-10 freeze, refused unless its sha256
#                             is dbcc76f4... (person-level, gitignored)
#          CURRENT_FROZEN_CSV optional: the current freeze, refused unless it is
#                             the one the manifest describes. When given, the
#                             reconciliation becomes three-way and explains every
#                             difference between 11,920 and the current count.
#          artifacts/tracked_roster_active_primary_linked.csv   (tracked)
#          artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json  (tracked)
# Outputs: artifacts/trilliant_cohort_reconciliation.csv   person-level, gitignored:
#            one row per certificant in either list, with the reason
#          artifacts/trilliant_cohort_transitions.csv   person-level, gitignored
#            (three-way only): 11,920 -> current, one reason per certificant
#          artifacts/trilliant_cohort_reconciliation_reasons.csv   aggregate, tracked
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source(file.path("R", "lib", "common_helpers.R"))       # chr()
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance(), sha256_of()
source(file.path("R", "lib", "cohort_definitions.R"))   # canonical_active_primary(), cohort_transition_reasons()

LEGACY_SHA256 <- "dbcc76f420ac9be850efcc8aabc1523772cbcccea259783db88a5099d3a2209b"
LEGACY        <- Sys.getenv("LEGACY_FROZEN_CSV", "")
ROSTER        <- "artifacts/tracked_roster_active_primary_linked.csv"
MANIFEST      <- "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json"

if (!nzchar(LEGACY) || !file.exists(LEGACY))
  stop("Set LEGACY_FROZEN_CSV to the 2026-08-10 freeze (sha256 ", substr(LEGACY_SHA256, 1, 8), "...).",
       call. = FALSE)
if (sha256_of(LEGACY) != LEGACY_SHA256)
  stop(LEGACY, " is not the 2026-08-10 freeze; refusing to reconcile against another roster.",
       call. = FALSE)

legacy_linkage <- chr(LEGACY)
legacy <- legacy_linkage |> canonical_active_primary() |>
  transmute(certification_number, legacy_npi = npi, legacy_state = nppes_state)
roster <- chr(ROSTER) |>
  transmute(certification_number, roster_npi = npi, roster_state = nppes_state)
if (anyDuplicated(roster$certification_number))
  stop(ROSTER, " repeats a certification_number; it is meant to be one row per person.", call. = FALSE)

# The roster's states are the 40 the file it replaced covered.
roster_states <- sort(unique(roster$roster_state))
us_jurisdictions <- c(state.abb, "DC")

recon <- full_join(legacy, roster, by = "certification_number") |>
  mutate(
    in_legacy_11920 = !is.na(legacy_npi),
    in_roster_11093 = !is.na(roster_npi),
    reason = case_when(
      in_legacy_11920 & in_roster_11093 & legacy_npi == roster_npi ~ "in both, same NPI",
      in_legacy_11920 & in_roster_11093                           ~ "in both, NPI differs",
      in_legacy_11920 & legacy_state %in% roster_states            ~ "legacy only, state IS in the roster's 40 (unexplained)",
      in_legacy_11920 & legacy_state %in% us_jurisdictions         ~ "legacy only, practice state outside the roster's 40",
      in_legacy_11920                                              ~ "legacy only, military / territorial / foreign / blank practice state",
      TRUE                                                         ~ "roster only (not ACTIVE primary-linked in the legacy freeze)"),
    state = coalesce(legacy_state, roster_state))

man <- jsonlite::read_json(MANIFEST)
reasons <- recon |>
  count(reason, state, name = "n_certificants") |>
  arrange(reason, desc(n_certificants)) |>
  mutate(legacy_freeze_sha256 = LEGACY_SHA256,
         current_freeze_sha256 = man$artifact_sha256,
         current_freeze_rows = man$artifact_rows)

write_with_provenance(recon, "artifacts/trilliant_cohort_reconciliation.csv",
                      inputs = c(LEGACY, ROSTER), na = "")
write_with_provenance(reasons, "artifacts/trilliant_cohort_reconciliation_reasons.csv",
                      inputs = c(ROSTER, MANIFEST), na = "")

cat(sprintf("legacy 11,920 list: %s   tracked roster: %s\n",
            format(sum(recon$in_legacy_11920), big.mark = ","),
            format(sum(recon$in_roster_11093), big.mark = ",")))
print(count(recon, reason, name = "n"), n = Inf)
cat("\nlegacy-only, by practice state:\n")
print(recon |> filter(in_legacy_11920, !in_roster_11093) |> count(state, sort = TRUE), n = Inf)
CURRENT <- Sys.getenv("CURRENT_FROZEN_CSV", "")
if (nzchar(CURRENT)) {
  verify_linkage_freeze(CURRENT, MANIFEST, allow_sha256 = "")
  tr <- cohort_transition_reasons(legacy_linkage, chr(CURRENT)) |>
    mutate(in_roster_11093 = certification_number %in% roster$certification_number)
  write_with_provenance(tr, "artifacts/trilliant_cohort_transitions.csv",
                        inputs = c(LEGACY, CURRENT, ROSTER), na = "")
  trans <- tr |> count(reason, in_roster_11093, name = "n_certificants") |>
    mutate(legacy_freeze_sha256 = LEGACY_SHA256, current_freeze_sha256 = man$artifact_sha256)
  write_with_provenance(trans, "artifacts/trilliant_cohort_transition_reasons.csv",
                        inputs = c(ROSTER, MANIFEST), na = "")
  cat(sprintf("\nthree-way: legacy %s -> current %s (change %+d)\n",
              format(sum(tr$in_old), big.mark = ","), format(sum(tr$in_new), big.mark = ","),
              sum(tr$in_new) - sum(tr$in_old)))
  print(count(tr, reason, name = "n"), n = Inf)
} else cat(sprintf("\ncurrent freeze: %s rows, sha256 %s... -- not on this machine; the canonical\nACTIVE, primary-linked cohort is the registered 12,171 against it.\n",
            format(man$artifact_rows, big.mark = ","), substr(man$artifact_sha256, 1, 8)))
