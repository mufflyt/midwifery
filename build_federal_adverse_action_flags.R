#!/usr/bin/env Rscript
# =============================================================================
# Assemble artifacts/federal_adverse_action_flags.csv from every NPI-linked source
# =============================================================================
# Combines independent federal/administrative-action sources through
# R/federal_adverse_action_exclusions.R::build_federal_adverse_action_flags(),
# which already dedupes by NPI and concatenates sources when more than one
# flags the same person (tested: tests/test_exclusion_flow_saboteurs.R). Two
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
#
# The one NPI both sources currently agree on (1366580714) is already LAPSED
# in the roster and so already excluded from the analytic cohort for an
# unrelated reason -- this step changes federal_adverse_action_source for that
# row, not the cohort count.
#
# Inputs : artifacts/cms_ndh_midwives.csv
#          artifacts/cms_pecos_revoked_providers_cohort.csv
# Output : artifacts/federal_adverse_action_flags.csv
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source(file.path("R", "federal_adverse_action_exclusions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

NDH   <- "artifacts/cms_ndh_midwives.csv"
PECOS <- "artifacts/cms_pecos_revoked_providers_cohort.csv"
OUT   <- "artifacts/federal_adverse_action_flags.csv"

missing <- c(NDH, PECOS)[!file.exists(c(NDH, PECOS))]
if (length(missing))
  stop(sprintf("Missing input(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

ndh <- read_csv(NDH, col_types = cols(.default = "c"), show_col_types = FALSE) %>%
  transmute(npi, listed = ndh_hhs_exclusion_list,
            source = "CMS NDH exclusion flag (unverified, see appendix)")

pecos <- read_csv(PECOS, col_types = cols(.default = "c"), show_col_types = FALSE) %>%
  transmute(npi, listed = pecos_revoked,
            source = "CMS PECOS Medicare revocation (reenrollment barred)")

flags <- build_federal_adverse_action_flags(list(ndh = ndh, pecos = pecos))
write_with_provenance(flags, OUT, inputs = c(NDH, PECOS))

cat(sprintf("federal adverse-action flags: %s NPI(s)\n", format(nrow(flags), big.mark = ",")))
print(table(flags$federal_adverse_action_source))
