#!/usr/bin/env Rscript
#' @title Organization affiliation from PECOS reassignment of benefits
#'
#' @description
#' Tier A of the organization resolver. Recovers, for each resolved midwife
#' Type-1 NPI, the organizations receiving that midwife's reassigned Medicare
#' benefits:
#'
#'   midwife NPI -> ENROLLMENT (individual enrlmt_id)
#'               -> REASSIGNMENT (reasgn_bnft_enrlmt_id -> rcv_bnft_enrlmt_id)
#'               -> ENROLLMENT (organization npi, org_name, pac id)
#'               -> PRACTICE_LOCATION
#'
#' @section Why this beats address matching:
#' An address match says two NPIs share a street. A reassignment says this
#' practitioner's Medicare benefits are paid to that entity -- an explicit,
#' CMS-recorded relationship rather than a spatial coincidence. A hospital
#' campus can carry dozens of Type-2 NPIs at one address, so a "unique"
#' address match there is unique only by accident of who else registered.
#'
#' @section It is affiliation, not employment:
#' The output column is `organization_affiliation`, never `employer`. A
#' clinician can bill through a group without being its employee, and the
#' distinction is not recoverable from these files. Naming it `employer` would
#' assert something PECOS does not say.
#'
#' @section Absence is not evidence of independence:
#' PECOS covers providers with approved MEDICARE enrollment. A midwife who
#' takes no Medicare simply is not here. `no_pecos_record` is therefore a
#' distinct state from "no affiliation" -- collapsing them would manufacture a
#' finding about solo practice out of a coverage gap.
#'
#' @section Multiple affiliations are real:
#' One midwife may reassign benefits to several organizations. This writes one
#' row per (midwife, organization) pair and does NOT reduce to one employer.
#' Forcing a single row would discard the concurrent-affiliation signal that
#' makes this worth building.
#'
#' Inputs : PECOS_DIR/{ppefenrol,ppefreassign,ppefaddr}.csv
#'          the resolved AMCB->NPI crosswalk
#' Outputs: artifacts/midwife_pecos_organization_affiliations.csv (person-level,
#'          gitignored) and a suppressed aggregate.
#'
#' @family organization-linkage
#' @concept employer-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(cli)
})

`%||%` <- function(a, b) if (is.null(a)) b else a

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))

PECOS <- Sys.getenv("PECOS_DIR", "/Volumes/MufflySamsung 1/pecos_data")
ENROL   <- file.path(PECOS, "ppefenrol.csv")
REASSIGN<- file.path(PECOS, "ppefreassign.csv")
ADDR    <- file.path(PECOS, "ppefaddr.csv")
OUT     <- "artifacts/midwife_pecos_organization_affiliations.csv"
OUT_AGG <- "artifacts/midwife_organization_affiliation_by_state.csv"

for (f in c(ENROL, REASSIGN)) {
  if (!file.exists(f)) {
    stop(sprintf(paste("PECOS file not found: %s\n",
                       "  Set PECOS_DIR, or mount the volume holding it.\n",
                       "  Refusing to write an empty affiliation table, which",
                       "would read as 'no midwife has an organization'."), f),
         call. = FALSE)
  }
}

# --- the resolved cohort -----------------------------------------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$", cw)]
if (!length(cw)) stop("no AMCB->NPI crosswalk found in artifacts/", call. = FALSE)
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
cli::cli_alert_info("crosswalk: {basename(cw)}")

cohort <- read_csv(cw, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  distinct(amcb_id, npi, linkage_tier)
cli::cli_alert_info("resolved midwives with an NPI: {format(nrow(cohort), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "cohort", cohort)

rd <- function(path) sprintf(
  "read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)", path)

# --- A. individual enrollments for our midwives ------------------------------
cli::cli_h2("PECOS enrollment: the individual side")
ind <- dbGetQuery(con, sprintf("
  SELECT DISTINCT c.amcb_id, c.npi AS midwife_npi, c.linkage_tier,
         e.enrlmt_id AS individual_enrlmt_id,
         e.pecos_asct_cntl_id AS individual_pac_id,
         e.provider_type_desc AS individual_provider_type
  FROM cohort c
  JOIN %s e ON TRIM(e.npi) = c.npi", rd(ENROL)))
cli::cli_alert_success("midwives with a PECOS enrollment: {format(n_distinct(ind$midwife_npi), big.mark = ',')}")

if (!nrow(ind)) {
  stop("no midwife matched a PECOS enrollment. That is implausible for a ",
       "17k cohort and means the join is wrong, not that the data says no.",
       call. = FALSE)
}
duckdb::duckdb_register(con, "ind", ind)

# --- B. reassignment: who receives those benefits ----------------------------
cli::cli_h2("Reassignment of benefits")
pairs <- dbGetQuery(con, sprintf("
  SELECT DISTINCT i.amcb_id, i.midwife_npi, i.linkage_tier,
         i.individual_enrlmt_id, i.individual_pac_id, i.individual_provider_type,
         r.rcv_bnft_enrlmt_id AS org_enrlmt_id
  FROM ind i
  JOIN %s r ON TRIM(r.reasgn_bnft_enrlmt_id) = i.individual_enrlmt_id",
  rd(REASSIGN)))
cli::cli_alert_success("reassignment pairs: {format(nrow(pairs), big.mark = ',')} for {format(n_distinct(pairs$midwife_npi), big.mark = ',')} midwives")
duckdb::duckdb_register(con, "pairs", pairs)

# --- C. resolve the receiving entity -----------------------------------------
cli::cli_h2("The receiving organization")
aff <- dbGetQuery(con, sprintf("
  SELECT DISTINCT p.amcb_id, p.midwife_npi, p.linkage_tier,
         p.individual_enrlmt_id, p.individual_pac_id,
         p.org_enrlmt_id,
         o.npi                 AS organization_npi,
         o.org_name            AS organization_name,
         o.pecos_asct_cntl_id  AS organization_pac_id,
         o.provider_type_desc  AS organization_provider_type,
         o.state_cdstr         AS organization_state
  FROM pairs p
  JOIN %s o ON TRIM(o.enrlmt_id) = p.org_enrlmt_id", rd(ENROL)))

# A receiving entity with no organization name and no Type-2 NPI cannot be
# reported as an organization. Kept and labelled rather than dropped: silently
# discarding them would understate how often reassignment resolves to something
# unnameable.
aff <- aff %>%
  mutate(
    organization_name = trimws(organization_name),
    has_org_identity = (!is.na(organization_npi) & nzchar(trimws(organization_npi))) |
                        (!is.na(organization_name) & nzchar(organization_name)),
    # The evidence label. NOT "employer": PECOS records where benefits are
    # paid, which is a billing relationship. Employment is a different fact and
    # is not in these files.
    affiliation_source = "pecos_reassignment",
    # The receiving entity is USUALLY a group, but not always. 16 midwives
    # reassign to an entity whose provider type is PRACTITIONER -- a solo
    # physician's enrollment, carrying an NPI but no org_name. That is a real
    # billing relationship and it is NOT an organization affiliation; calling
    # it one would put a person in a column labelled organization. Separated so
    # a later analysis of group size or health-system concentration does not
    # silently count sixteen individuals as employers.
    receiving_entity_is_practitioner =
      grepl("^PRACTITIONER", organization_provider_type %||% ""),
    affiliation_strength = dplyr::case_when(
      !has_org_identity                ~ "reassignment_target_unidentified",
      receiving_entity_is_practitioner ~ "confirmed_billing_affiliation_solo_practitioner",
      TRUE                             ~ "confirmed_billing_affiliation"),
    observed_source_file = basename(REASSIGN))

cli::cli_alert_success("organization affiliations: {format(nrow(aff), big.mark = ',')}")
cli::cli_alert_info("distinct organizations: {format(n_distinct(aff$organization_npi), big.mark = ',')}")

# --- D. practice locations for the organization ------------------------------
if (file.exists(ADDR)) {
  duckdb::duckdb_register(con, "aff", aff)
  loc <- dbGetQuery(con, sprintf("
    SELECT org_enrlmt_id, city, state, zip FROM (
      SELECT a.org_enrlmt_id,
             -- state_cdstr is the two-letter abbreviation; state_cd is a
             -- NUMERIC code. Using state_cd produced an aggregate keyed on
             -- 1, 10, 11 -- numbers that look like counts and join to no
             -- state table anywhere.
             l.city_name AS city, l.state_cdstr AS state, l.zip_cd AS zip,
             ROW_NUMBER() OVER (PARTITION BY a.org_enrlmt_id
                                ORDER BY l.state_cdstr, l.city_name, l.zip_cd) rn
      FROM (SELECT DISTINCT org_enrlmt_id FROM aff) a
      JOIN %s l ON TRIM(l.enrlmt_id) = a.org_enrlmt_id) WHERE rn = 1",
    rd(ADDR)))
  # Deterministic pick: an organization with several locations gets the first
  # by state/city/zip, not by row order. Which location is recorded must not
  # depend on how the file was written.
  aff <- aff %>% left_join(loc, by = "org_enrlmt_id", relationship = "many-to-one")
} else {
  cli::cli_alert_warning("practice-location file absent; city/state/zip omitted")
  aff$city <- NA_character_; aff$state <- NA_character_; aff$zip <- NA_character_
}

# --- E. concurrency, which is the point --------------------------------------
n_per <- aff %>% filter(has_org_identity) %>%
  distinct(midwife_npi, organization_npi) %>% count(midwife_npi, name = "n_orgs")
cli::cli_h2("Concurrent affiliations")
print(as.data.frame(count(n_per, n_orgs, name = "n_midwives")), row.names = FALSE)
cli::cli_alert_info("{sum(n_per$n_orgs > 1)} midwives reassign to MORE THAN ONE organization")

out <- aff %>%
  left_join(n_per, by = "midwife_npi", relationship = "many-to-one") %>%
  mutate(n_orgs = coalesce(n_orgs, 0L)) %>%
  select(amcb_id, midwife_npi, linkage_tier,
         organization_npi, organization_name, organization_pac_id,
         organization_provider_type, organization_state,
         practice_city = city, practice_state = state, practice_zip = zip,
         affiliation_source, affiliation_strength, n_concurrent_organizations = n_orgs,
         # Kept in the output, not just used internally. The coverage report and
         # the aggregate both filter on it, and dropping it here made
         # out$has_org_identity NULL -- so `NULL %in% TRUE` counted nothing and
         # the run reported "0 organizations resolved" for a join that had in
         # fact worked. A column a downstream step needs must survive select().
         has_org_identity, receiving_entity_is_practitioner,
         individual_enrlmt_id, org_enrlmt_id, observed_source_file) %>%
  arrange(amcb_id, organization_npi, org_enrlmt_id)

write_with_provenance(out, OUT, na = "", inputs = prov_inputs(cw, ENROL, REASSIGN, ADDR))
cli::cli_alert_success("wrote {OUT} ({format(nrow(out), big.mark = ',')} rows)")

# --- F. coverage, stated honestly --------------------------------------------
cli::cli_h2("Coverage")
n_cohort <- n_distinct(cohort$npi)
n_pecos  <- n_distinct(ind$midwife_npi)
n_reasgn <- n_distinct(out$midwife_npi[out$has_org_identity %in% TRUE])
cli::cli_alert_info("resolved midwives            : {format(n_cohort, big.mark = ',')}")
cli::cli_alert_info("with a PECOS enrollment      : {format(n_pecos, big.mark = ',')} ({round(100*n_pecos/n_cohort,1)}%)")
cli::cli_alert_info("with a resolved organization : {format(n_reasgn, big.mark = ',')} ({round(100*n_reasgn/n_cohort,1)}%)")
cat("\n  ABSENCE IS NOT INDEPENDENCE. PECOS covers providers with approved\n")
cat("  MEDICARE enrollment. A midwife who takes no Medicare is simply not in\n")
cat("  this file. The", format(n_cohort - n_pecos, big.mark = ","), "without a PECOS record are\n")
cat("  no_pecos_record, which is a coverage statement, not a finding about\n")
cat("  solo practice.\n\n")

# --- G. suppressed aggregate --------------------------------------------------
agg <- out %>%
  filter(has_org_identity %in% TRUE, !is.na(practice_state), nzchar(practice_state)) %>%
  distinct(midwife_npi, organization_npi, practice_state) %>%
  count(practice_state, name = "n_affiliations") %>%
  mutate(suppressed = n_affiliations < 11,
         n_affiliations = if_else(suppressed, NA_integer_, n_affiliations)) %>%
  arrange(practice_state)
write_with_provenance(agg, OUT_AGG, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_AGG} (cells under 11 suppressed)")
