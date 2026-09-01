#!/usr/bin/env Rscript
#' @title Care Compare group affiliation, as an NPI x organization x vintage panel
#'
#' @description
#' Tier B of the organization resolver, and the arm that can carry TIME.
#'
#'   midwife NPI -> Care Compare clinician row -> org_pac_id + Facility Name
#'
#' The Doctors & Clinicians National Downloadable File is organised at the
#' clinician x enrollment x group x address level, so one clinician legitimately
#' appears on many rows. Read across several vintages it becomes a panel:
#'
#'   NPI x organization x vintage
#'
#' from which transitions, tenure, concurrency and organisation size follow.
#'
#' @section Why this is independent of PECOS:
#' PECOS reassignment says where a midwife's Medicare benefits are PAID.
#' Care Compare says which group CMS lists her practising with. They are built
#' from the same enrollment system but published through different pipelines
#' and at different times, so agreement between them is corroboration and
#' disagreement is a finding. Neither is derived from the other here.
#'
#' @section Vintages are DISCOVERED, not listed:
#' Every DAC_NationalDownloadableFile_YYYY-MM.csv found is used, plus any
#' unversioned copy, which is dated from its own mtime and labelled as inferred.
#' A hardcoded list would silently stop growing, and the value of this file is
#' entirely in having more snapshots over time.
#'
#' @section What two vintages can and cannot support:
#' With snapshots at YYYY-MM and YYYY-MM only, "changed organisation between
#' them" is measurable and an ANNUAL transition rate is not. The panel reports
#' its own vintage span and refuses to describe gaps it cannot see; a midwife
#' who moved twice between two snapshots reads as one move, or as none.
#'
#' Inputs : DAC_NationalDownloadableFile*.csv (repo root and CARE_COMPARE_DIR)
#'          the resolved AMCB->NPI crosswalk
#' Outputs: artifacts/midwife_organization_panel.csv (person-level, gitignored)
#'          artifacts/midwife_organization_panel_summary.csv (tracked, suppressed)
#'
#' @family organization-linkage
#' @concept employer-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))

OUT     <- "artifacts/midwife_organization_panel.csv"
OUT_SUM <- "artifacts/midwife_organization_panel_summary.csv"
source(file.path("R", "lib", "medicare_duckdb.R"))
# A SUPPLEMENTARY location only: find_vintages() globs the working directory
# first and can succeed with the drive unmounted, so absence is not fatal.
EXTRA   <- Sys.getenv("CARE_COMPARE_DIR", "")
if (!nzchar(EXTRA))
  EXTRA <- samsung_volume_path("nppes_historical_downloads", must_exist = FALSE)

# --- discover vintages -------------------------------------------------------
# PREFER THE MORE RECENT VINTAGE. Where two files would resolve to the same
# YYYY-MM, the newer mtime wins; a stale duplicate must never shadow a current
# one. This is the mistake that produced a two-year-old enrollment measurement
# earlier in this project.
find_vintages <- function() {
  cands <- unique(c(
    Sys.glob("DAC_NationalDownloadableFile*.csv"),
    if (is.na(EXTRA)) character(0)
    else Sys.glob(file.path(EXTRA, "DAC_NationalDownloadableFile*.csv"))))
  cands <- cands[file.exists(cands)]
  if (!length(cands)) return(tibble::tibble())

  ym <- sub(".*DAC_NationalDownloadableFile_?([0-9]{4}-[0-9]{2})?\\.csv$", "\\1",
            basename(cands))
  inferred <- !nzchar(ym)
  # An unversioned file is dated from its own mtime and SAID to be inferred.
  # Guessing silently is how a 2024 file gets read as current.
  ym[inferred] <- format(file.mtime(cands[inferred]), "%Y-%m")

  tibble::tibble(path = cands, vintage = ym, vintage_inferred = inferred,
                 mtime = file.mtime(cands)) |>
    dplyr::arrange(.data$vintage, dplyr::desc(.data$mtime)) |>
    dplyr::distinct(.data$vintage, .keep_all = TRUE) |>
    dplyr::arrange(.data$vintage)
}

V <- find_vintages()
if (!nrow(V)) {
  stop("no DAC_NationalDownloadableFile*.csv found.\n",
       "  Refusing to write an empty panel, which would read as ",
       "'no midwife has an organization in any year'.", call. = FALSE)
}
cli::cli_h2("Care Compare vintages")
for (i in seq_len(nrow(V))) {
  cli::cli_alert_info("{V$vintage[i]}{if (V$vintage_inferred[i]) ' (inferred from mtime)' else ''}: {basename(V$path[i])}")
}

# --- cohort ------------------------------------------------------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$", cw)]
if (!length(cw)) stop("no AMCB->NPI crosswalk in artifacts/", call. = FALSE)
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]

cohort <- read_csv(cw, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct(amcb_id, npi)
cli::cli_alert_info("resolved midwives: {format(nrow(cohort), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "cohort", cohort)

# --- read each vintage -------------------------------------------------------
panel <- list()
for (i in seq_len(nrow(V))) {
  cli::cli_alert_info("reading {V$vintage[i]} ...")
  q <- sprintf('
    SELECT DISTINCT c.amcb_id, c.npi AS midwife_npi,
           NULLIF(TRIM(CAST(d."org_pac_id" AS VARCHAR)), \'\')     AS org_pac_id,
           NULLIF(TRIM(CAST(d."Facility Name" AS VARCHAR)), \'\')  AS organization_name,
           NULLIF(TRIM(CAST(d."num_org_mem" AS VARCHAR)), \'\')    AS org_member_count,
           NULLIF(TRIM(CAST(d."State" AS VARCHAR)), \'\')          AS practice_state,
           NULLIF(TRIM(CAST(d."City/Town" AS VARCHAR)), \'\')      AS practice_city,
           \'%s\' AS vintage
    FROM cohort c
    JOIN read_csv_auto(\'%s\', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE) d
      ON TRIM(CAST(d."NPI" AS VARCHAR)) = c.npi',
    V$vintage[i], V$path[i])
  got <- dbGetQuery(con, q)
  cli::cli_alert_success("{V$vintage[i]}: {format(nrow(got), big.mark = ',')} rows, {format(dplyr::n_distinct(got$midwife_npi), big.mark = ',')} midwives")
  panel[[i]] <- got
}
p <- bind_rows(panel) %>%
  mutate(vintage_inferred = vintage %in% V$vintage[V$vintage_inferred])

# A row with no org_pac_id and no name is a clinician record with no group --
# solo or unlisted. Kept and labelled: dropping it would make the panel look
# like everyone always has a group.
p <- p %>%
  mutate(has_group = !is.na(org_pac_id) | !is.na(organization_name),
         affiliation_source = "care_compare_ndf",
         affiliation_strength = if_else(has_group,
                                        "confirmed_group_affiliation",
                                        "listed_without_group"))

# --- the panel ---------------------------------------------------------------
cli::cli_h2("Panel")
per_vintage <- p %>% filter(has_group) %>%
  group_by(vintage) %>%
  summarise(midwives = n_distinct(midwife_npi),
            organizations = n_distinct(org_pac_id),
            rows = n(), .groups = "drop")
print(as.data.frame(per_vintage), row.names = FALSE)

conc <- p %>% filter(has_group) %>%
  distinct(midwife_npi, vintage, org_pac_id) %>%
  count(midwife_npi, vintage, name = "n_orgs")
cli::cli_alert_info("median concurrent organizations per midwife-vintage: {stats::median(conc$n_orgs)}; max {max(conc$n_orgs)}")

out <- p %>%
  left_join(conc, by = c("midwife_npi", "vintage"),
            relationship = "many-to-one") %>%
  mutate(n_concurrent_organizations = coalesce(n_orgs, 0L)) %>%
  select(amcb_id, midwife_npi, vintage, vintage_inferred,
         org_pac_id, organization_name, org_member_count,
         practice_city, practice_state,
         affiliation_source, affiliation_strength, has_group,
         n_concurrent_organizations) %>%
  arrange(amcb_id, vintage, org_pac_id)

write_with_provenance(out, OUT, na = "", inputs = prov_inputs(c(cw, V$path)))
cli::cli_alert_success("wrote {OUT} ({format(nrow(out), big.mark = ',')} rows)")

# --- change between vintages, stated only as far as it can be ----------------
cli::cli_h2("Change between vintages")
vs <- sort(unique(out$vintage))
if (length(vs) < 2L) {
  cli::cli_alert_warning("only {length(vs)} vintage: no change can be measured")
  cat("\n  A single snapshot supports CURRENT affiliation and nothing about\n")
  cat("  movement. Transitions need at least two.\n\n")
} else {
  first <- vs[1]; last <- vs[length(vs)]
  sets <- out %>% filter(has_group, vintage %in% c(first, last)) %>%
    distinct(midwife_npi, vintage, org_pac_id) %>%
    group_by(midwife_npi, vintage) %>%
    summarise(orgs = paste(sort(unique(org_pac_id)), collapse = "|"), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = vintage, values_from = orgs)

  both <- sets %>% filter(!is.na(.data[[first]]), !is.na(.data[[last]]))
  changed <- sum(both[[first]] != both[[last]])
  cli::cli_alert_info("midwives present in BOTH {first} and {last}: {format(nrow(both), big.mark = ',')}")
  cli::cli_alert_info("of those, organization set CHANGED: {format(changed, big.mark = ',')} ({round(100*changed/max(nrow(both),1),1)}%)")

  gap_months <- length(seq(as.Date(paste0(first, "-01")),
                           as.Date(paste0(last, "-01")), by = "month")) - 1L
  cat(sprintf("\n  SPAN: %s to %s, %d months, %d snapshot(s).\n", first, last, gap_months, length(vs)))
  cat("  A midwife who moved twice inside that span reads as ONE change, or as\n")
  cat("  none if she returned. This supports 'changed between these snapshots'\n")
  cat("  and does NOT support an annual transition rate.\n\n")
}

# --- tracked summary ---------------------------------------------------------
summ <- out %>% filter(has_group) %>%
  distinct(midwife_npi, vintage, practice_state) %>%
  filter(!is.na(practice_state), nzchar(practice_state)) %>%
  count(vintage, practice_state, name = "n_midwives") %>%
  mutate(suppressed = n_midwives < 11,
         n_midwives = if_else(suppressed, NA_integer_, n_midwives)) %>%
  arrange(vintage, practice_state)
write_with_provenance(summ, OUT_SUM, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_SUM} (cells under 11 suppressed)")
