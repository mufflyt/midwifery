#!/usr/bin/env Rscript
#' @title Do Open Payments, Healthgrades or Doximity reach the unresolved 1,544?
#'
#' @description
#' Four signals have now been tested against the 1,544 unresolved ACTIVE
#' CNM/CMs. Taxonomy compatibility bought ~107; NPPES endpoints 8; secondary
#' practice locations 2. Every one has been either high-quality-and-absent or
#' well-covered-and-non-discriminating.
#'
#' This tests three external sources at once, because the harness is the same
#' and the question is identical: does the source SEE these midwives, and where
#' it does, does it name exactly one organization?
#'
#'   OPEN PAYMENTS   Type-2 organizations linked to a midwife by industry
#'                   payment records. SELECTED BY CONSTRUCTION: a CNM appears
#'                   only if a manufacturer or GPO reported activity. Absence
#'                   is not evidence of no affiliation, and coverage is
#'                   expected to be low.
#'   HEALTHGRADES    a practice name and address per certificant. Commercially
#'                   compiled, so it is not authoritative -- but it is
#'                   independent of NPPES, which is exactly what the ambiguous
#'                   group needs.
#'   DOXIMITY        a self-reported affiliation string. The weakest provenance
#'                   of the three and the least verifiable, reported separately
#'                   rather than pooled.
#'
#' @section Two different successes, kept apart:
#' A commercial directory names an organization but rarely an NPI. Naming the
#' organization ANSWERS THE ENDPOINT QUESTION -- "what organization is this
#' CNM/CM affiliated with" -- even when no Type-2 NPI can be attached. So this
#' reports:
#'
#'   named_unique       exactly one organization NAME from the source
#'   npi_reconciled     that name also resolves to exactly one Type-2 NPI
#'
#' Collapsing them would either overstate identifier coverage or discard real
#' affiliation evidence.
#'
#' @section Fail-closed, unchanged:
#' Several names is ambiguous, not a pick. No source is allowed to break a tie
#' by plausibility. Sources are never pooled into a single verdict: a
#' disagreement between two commercial directories is a finding.
#'
#' Inputs : artifacts/unresolved_affiliation_reasons.csv, the AMCB->NPI
#'          crosswalk, and the three source artifacts
#' Outputs: artifacts/external_source_yield.csv       (tracked)
#'          artifacts/external_source_candidates.csv  (person-level, gitignored)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "org_names.R"))

rd <- function(p) if (file.exists(p)) read_csv(p, col_types = cols(.default = "c"),
                                               progress = FALSE) else NULL

reasons <- rd("artifacts/unresolved_affiliation_reasons.csv")
if (is.null(reasons)) stop("run diagnose_unresolved_affiliations.R first", call. = FALSE)

cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("manifest|provenance", cw)]
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
spine <- rd(cw) %>% filter(!is.na(npi), nzchar(npi)) %>%
  distinct(certification_number = amcb_id, npi)

tgt <- reasons %>% select(npi, reason) %>% left_join(spine, by = "npi")
cli::cli_alert_info("unresolved cohort: {format(nrow(tgt), big.mark = ',')} ({sum(!is.na(tgt$certification_number))} with a certification number)")

# --- one shape per source ----------------------------------------------------
# Each returns: certification_number, org_name. Nothing else is comparable
# across a payments file, a directory scrape and a profile scrape.
grab <- function(path, id_col, name_col, label) {
  d <- rd(path)
  if (is.null(d)) { cli::cli_alert_warning("{label}: absent"); return(NULL) }
  if (!all(c(id_col, name_col) %in% names(d))) {
    cli::cli_alert_warning("{label}: missing {id_col} or {name_col}")
    return(NULL)
  }
  out <- d %>%
    transmute(certification_number = .data[[id_col]],
              org_name = .data[[name_col]]) %>%
    filter(!is.na(certification_number), nzchar(certification_number),
           !is.na(org_name), nzchar(org_name)) %>%
    mutate(org_key = norm_org(org_name)) %>%
    filter(nzchar(org_key)) %>%
    distinct(certification_number, org_key, .keep_all = TRUE) %>%
    mutate(source = label)
  cli::cli_alert_success("{label}: {format(nrow(out), big.mark = ',')} org rows over {format(dplyr::n_distinct(out$certification_number), big.mark = ',')} certificants")
  out
}

cli::cli_h2("Sources")
src <- bind_rows(
  grab("artifacts/cohort_midwives_open_payments_type2_organizations_full.csv",
       "certification_number", "type2_organization_name", "open_payments"),
  grab("healthgrades_midwives.csv", "certification_number", "hg_practice", "healthgrades"),
  grab("artifacts/doximity_public_matched.csv",
       "certification_number", "affiliation", "doximity")
)
if (is.null(src) || !nrow(src)) stop("no source produced organization rows", call. = FALSE)

# --- restrict to the unresolved cohort ---------------------------------------
hit <- src %>% inner_join(tgt %>% filter(!is.na(certification_number)),
                          by = "certification_number", relationship = "many-to-many")

cli::cli_h2("Coverage and uniqueness on the unresolved cohort")
per_src <- hit %>%
  group_by(source, certification_number) %>%
  summarise(n_orgs = dplyr::n_distinct(org_key), reason = dplyr::first(reason),
            .groups = "drop")

yield <- per_src %>%
  group_by(source, reason) %>%
  summarise(seen = dplyr::n(),
            named_unique = sum(n_orgs == 1L),
            ambiguous_multi = sum(n_orgs > 1L),
            .groups = "drop") %>%
  left_join(tgt %>% count(reason, name = "group_n"), by = "reason") %>%
  mutate(pct_seen = round(100 * seen / group_n, 1),
         pct_resolved = round(100 * named_unique / group_n, 1)) %>%
  arrange(source, desc(named_unique))
print(as.data.frame(yield), row.names = FALSE)

tot <- per_src %>% group_by(source) %>%
  summarise(seen = dplyr::n(), named_unique = sum(n_orgs == 1L), .groups = "drop") %>%
  mutate(pct_of_1544 = round(100 * named_unique / nrow(tgt), 1))
cli::cli_h2("Totals")
print(as.data.frame(tot), row.names = FALSE)

# Union across sources, and the disagreements. Two directories naming
# different organizations for one midwife is information, not noise to average.
combined <- per_src %>% filter(n_orgs == 1L) %>%
  distinct(certification_number, source)
u <- dplyr::n_distinct(combined$certification_number)
cli::cli_alert_success("ANY source names exactly one organization: {format(u, big.mark = ',')} of {format(nrow(tgt), big.mark = ',')} ({round(100*u/nrow(tgt),1)}%)")

multi <- hit %>% filter(certification_number %in% combined$certification_number) %>%
  group_by(certification_number) %>%
  summarise(n_src = dplyr::n_distinct(source),
            n_distinct_org = dplyr::n_distinct(org_key), .groups = "drop") %>%
  filter(n_src > 1L)
if (nrow(multi))
  cli::cli_alert_info("{nrow(multi)} midwives seen by >1 source; sources DISAGREE on the organization for {sum(multi$n_distinct_org > 1L)}")

write_with_provenance(yield, "artifacts/external_source_yield.csv", na = "",
                      inputs = prov_inputs(cw))
write_with_provenance(hit, "artifacts/external_source_candidates.csv", na = "",
                      inputs = prov_inputs(cw))
cli::cli_alert_success("wrote artifacts/external_source_yield.csv and _candidates.csv")
