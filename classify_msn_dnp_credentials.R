#!/usr/bin/env Rscript
# =============================================================================
# Degree-level first pass from the NPPES free-text credential field
# =============================================================================
# NPPES carries a self-reported, unstructured credential string per provider
# (e.g. "CNM, MSN", "DNP, APRN, CNM", "C.N.M."). Following the approach used by
# Vanderlaan et al. to identify midwives from this same field, this classifies
# each cohort member's self-reported degree level from tokens in that string:
# DNP (or PhD, reported separately) as doctoral, MSN/MS as master's, BSN/BS as
# bachelor's.
#
# WHAT THIS IS NOT. The field is free text and self-reported at NPPES
# enrollment/update time, not verified against any credentialing body, and a
# provider who never updated it after finishing a doctorate reports nothing.
# This is a first-pass, high-coverage / lower-precision complement to the
# structural DNP-thesis linkage in harvest_dnp_theses.py + link_theses_to_amcb.R
# (Tier E), which is lower-coverage but much higher precision. Absence of a
# token here is not evidence the person lacks the degree.
#
# Input : artifacts/amcb_npi_linkage_FROZEN.csv
# Output: artifacts/msn_dnp_credential_classification.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})
source(file.path("R", "lib", "artifact_provenance.R"))

FROZEN <- Sys.getenv("STAGE2_FROZEN", "artifacts/amcb_npi_linkage_FROZEN.csv")
d <- read_csv(FROZEN, show_col_types = FALSE) %>% filter(cohort_member)

# Periods are pure abbreviation punctuation in this field ("M.S.N.", "C.N.M.")
# and never a meaningful token separator, so they are stripped before the
# word-boundary match; commas/spaces/hyphens/slashes remain as separators.
has_token <- function(credential, tokens) {
  flat <- str_replace_all(toupper(coalesce(credential, "")), "\\.", "")
  pattern <- paste0("\\b(", paste(tokens, collapse = "|"), ")\\b")
  str_detect(flat, pattern)
}

out <- d %>%
  transmute(
    certification_number, npi, last_name, first_name, status,
    nppes_credential,
    has_dnp = has_token(nppes_credential, c("DNP")),
    has_phd = has_token(nppes_credential, c("PHD")),
    has_msn = has_token(nppes_credential, c("MSN", "MS")),
    has_bsn = has_token(nppes_credential, c("BSN", "BS"))
  ) %>%
  mutate(highest_self_reported_degree = case_when(
    has_dnp | has_phd ~ "doctoral",
    has_msn           ~ "masters",
    has_bsn           ~ "bachelors",
    is.na(nppes_credential) ~ "not_reported",
    TRUE              ~ "unclassified"
  ))

write_with_provenance(out, "artifacts/msn_dnp_credential_classification.csv",
                      inputs = FROZEN, na = "")

cat(sprintf("cohort members                : %s\n", format(nrow(out), big.mark = ",")))
cat(sprintf("credential field non-missing  : %s (%.1f%%)\n",
            format(sum(!is.na(out$nppes_credential)), big.mark = ","),
            100 * mean(!is.na(out$nppes_credential))))
cat(sprintf("has DNP token                 : %s (%.1f%% of cohort)\n",
            format(sum(out$has_dnp), big.mark = ","), 100 * mean(out$has_dnp)))
cat(sprintf("has PhD token                 : %s (%.1f%% of cohort)\n",
            format(sum(out$has_phd), big.mark = ","), 100 * mean(out$has_phd)))
cat(sprintf("has MSN/MS token              : %s (%.1f%% of cohort)\n",
            format(sum(out$has_msn), big.mark = ","), 100 * mean(out$has_msn)))
cat(sprintf("has BSN/BS token              : %s (%.1f%% of cohort)\n",
            format(sum(out$has_bsn), big.mark = ","), 100 * mean(out$has_bsn)))
cat("\nhighest self-reported degree:\n")
print(count(out, highest_self_reported_degree, sort = TRUE))
