#!/usr/bin/env Rscript
# =============================================================================
# Assemble artifacts/federal_adverse_action_flags.csv from every NPI-linked source
# =============================================================================
# Combines independent federal/administrative-action sources through
# R/federal_adverse_action_exclusions.R::build_federal_adverse_action_flags(),
# which already dedupes by NPI and concatenates sources when more than one
# flags the same person (tested: tests/test_exclusion_flow_saboteurs.R). Three
# sources today:
#
#   - CMS NDH hhs_in_exclusion_list (cms_ndh_midwives.csv). Unverified: only
#     10/153 of these NPIs were confirmed against the real public LEIE by NPI
#     (docs/TECHNICAL_APPENDIX_CMS_NDH.md s5).
#   - CMS PECOS Medicare revocation, a re-enrollment bar
#     (cms_pecos_revoked_providers_cohort.csv, built by
#     match_cms_pecos_revocations.R). CMS's own administrative-action record,
#     NPI-keyed -- no name matching involved, so this one is not subject to
#     the NDH flag's verification problem.
#   - FDA Debarment List, Drug Product Applications
#     (fda_debarment_match_cohort.csv, built by match_fda_debarment.R). Name
#     matched, not NPI-keyed -- the FDA file carries no identifier but a name
#     (docs/TECHNICAL_APPENDIX_CMS_NDH.md s10) -- only fda_debarred == TRUE
#     rows (a clean, unambiguous one-to-one name match) are passed through;
#     AMBIGUOUS name collisions are never flagged.
#
# DEA is not wired in: unlike CMS and FDA, DEA does not publish a bulk list of
# revoked/surrendered registrants, only a single-registrant verification
# lookup -- there is no dataset here to join or match against.
#
# The one NPI the NDH and PECOS sources currently agree on (1366580714), and
# the one FDA name match (NPI 1891824926), are each already LAPSED in the
# roster and so already excluded from the analytic cohort for an unrelated
# reason -- this step only changes federal_adverse_action_source for those
# rows, not the cohort count.
#
# Inputs : artifacts/cms_ndh_midwives.csv
#          artifacts/cms_pecos_revoked_providers_cohort.csv
#          artifacts/fda_debarment_match_cohort.csv
# Output : artifacts/federal_adverse_action_flags.csv
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source(file.path("R", "federal_adverse_action_exclusions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

NDH   <- "artifacts/cms_ndh_midwives.csv"
PECOS <- "artifacts/cms_pecos_revoked_providers_cohort.csv"
FDA   <- "artifacts/fda_debarment_match_cohort.csv"
OUT   <- "artifacts/federal_adverse_action_flags.csv"

missing <- c(NDH, PECOS, FDA)[!file.exists(c(NDH, PECOS, FDA))]
if (length(missing))
  stop(sprintf("Missing input(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

ndh <- read_csv(NDH, col_types = cols(.default = "c"), show_col_types = FALSE) %>%
  transmute(npi, listed = ndh_hhs_exclusion_list,
            source = "CMS NDH exclusion flag (unverified, see appendix)")

pecos <- read_csv(PECOS, col_types = cols(.default = "c"), show_col_types = FALSE) %>%
  transmute(npi, listed = pecos_revoked,
            source = "CMS PECOS Medicare revocation (reenrollment barred)")

fda <- read_csv(FDA, col_types = cols(.default = "c"), show_col_types = FALSE) %>%
  transmute(npi, listed = fda_debarred,
            source = "FDA debarment, drug product applications (name match, unverified, see appendix)")

flags <- build_federal_adverse_action_flags(list(ndh = ndh, pecos = pecos, fda = fda))
write_with_provenance(flags, OUT, inputs = c(NDH, PECOS, FDA))

cat(sprintf("federal adverse-action flags: %s NPI(s)\n", format(nrow(flags), big.mark = ",")))
print(table(flags$federal_adverse_action_source))
