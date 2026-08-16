#!/usr/bin/env Rscript
#' @title NPI x organization x vintage panel from the revalidation warehouse
#'
#' @description
#' Turns the monthly CMS Revalidation Group Practice Reassignment warehouse
#' into a per-relationship panel with interval-censored bounds.
#'
#' One row per (midwife, organization, SPELL). A spell is a run of consecutive
#' snapshots in which the relationship was on file. A relationship that
#' disappears and returns produces TWO spells, not one long one, because those
#' are different facts and averaging them away would invent continuity nobody
#' observed.
#'
#' @section What every date here means, and does not:
#' Per docs/DECISIONS_CONTRACT.md, a PPEF/revalidation reassignment is a
#' relationship ON FILE at the snapshot date. So:
#'
#'   first_seen_vintage   the FIRST snapshot showing it. The relationship may
#'                        have existed earlier; if it is the first snapshot in
#'                        the warehouse, it is LEFT-CENSORED and the start is
#'                        unknown, not equal to that date.
#'   last_seen_vintage    the LAST snapshot showing it. If that is the newest
#'                        snapshot, it is RIGHT-CENSORED and ongoing.
#'   ended_between        the two snapshots bracketing a disappearance. NOT a
#'                        termination date.
#'
#' No duration is converted to a rate, and no midpoint is imputed. A
#' relationship seen in March and gone in April ended somewhere in that
#' interval, and the honest width of that interval is the snapshot cadence.
#'
#' @section Gaps in the snapshot series are not gaps in employment:
#' CMS did not publish every month. Where a month is missing from the
#' warehouse, a relationship spanning it is NOT treated as interrupted -- the
#' spell logic works on consecutive AVAILABLE snapshots and records the
#' observed cadence so a reader can see how coarse the bounds are.
#'
#' Inputs : REVAL_DB warehouse, the resolved AMCB->NPI crosswalk
#' Outputs: artifacts/midwife_reassignment_panel.csv        (person-level, gitignored)
#'          artifacts/midwife_reassignment_spells.csv       (person-level, gitignored)
#'          artifacts/midwife_reassignment_panel_summary.csv (tracked, suppressed)
#'
#' @family organization-linkage
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

DB   <- Sys.getenv("REVAL_DB", "/Volumes/MufflySamsung 1/cms_revalidation.duckdb")
TBL  <- "revalidation_reassignment"
OUT  <- "artifacts/midwife_reassignment_panel.csv"
OUT_SP <- "artifacts/midwife_reassignment_spells.csv"
OUT_SUM <- "artifacts/midwife_reassignment_panel_summary.csv"

if (!file.exists(DB)) {
  stop(sprintf(paste("warehouse not found: %s\n",
                     "  Run archive_revalidation_reassignment.R first, or set",
                     "REVAL_DB.\n  Refusing to write an empty panel."), DB),
       call. = FALSE)
}

# --- cohort ------------------------------------------------------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("\\.manifest\\.json$", cw)]
if (!length(cw)) stop("no AMCB->NPI crosswalk in artifacts/", call. = FALSE)
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
cohort <- read_csv(cw, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct(amcb_id, npi)
cli::cli_alert_info("cohort: {format(nrow(cohort), big.mark = ',')} resolved midwives")

con <- dbConnect(duckdb::duckdb(), DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "cohort", cohort)

vint <- dbGetQuery(con, sprintf(
  "SELECT DISTINCT vintage FROM %s ORDER BY vintage", TBL))$vintage

# --- CMS REPUBLISHES CONTENT UNDER A LATER MONTH -----------------------------
# 2024-03 and 2024-08 are BYTE-IDENTICAL (same md5, same size) but were
# published at two different URLs under two different month directories. The
# download was correct; the duplication is upstream.
#
# It cannot be left in. Between those two months CMS published nothing, so a
# relationship that ENDED in April 2024 would still appear "on file" in the
# 2024-08 vintage -- five months of phantom continuity, and precisely the kind
# of thing this panel exists to avoid asserting.
#
# A republished month is dropped and the EARLIER one kept, because the earlier
# date is when that content was actually current.
#
# PREFER THE HASH. artifacts/revalidation_vintage_manifest.csv carries an
# sha256 per raw snapshot, which settles the question exactly. The row-count
# fingerprint below is the fallback for when the manifest is absent (the raw
# volume is not always mounted); it is weaker, because three equal counts is
# strong evidence of identical content but not proof, whereas an equal sha256
# is. Neither ever keys on a month name -- the next republication will not be
# 2024-08, and a hardcoded month would miss it.
MAN <- "artifacts/revalidation_vintage_manifest.csv"
drop_from_manifest <- NULL
if (file.exists(MAN)) {
  mn <- readr::read_csv(MAN, col_types = readr::cols(.default = "c"),
                        progress = FALSE)
  if (all(c("vintage", "sha256", "use_for_panel") %in% names(mn))) {
    keep <- mn$use_for_panel %in% c("TRUE", "true")
    drop_from_manifest <- intersect(mn$vintage[!keep], vint)
    cli::cli_alert_info("vintage manifest: {sum(keep)} distinct contents across {nrow(mn)} labels")
  } else {
    cli::cli_alert_warning("{MAN} lacks the expected columns; falling back to the fingerprint")
  }
}

fp <- dbGetQuery(con, sprintf('
  SELECT vintage, COUNT(*) AS n_rows,
         COUNT(DISTINCT individual_npi) AS n_ind,
         COUNT(DISTINCT group_pac_id)   AS n_grp
  FROM %s GROUP BY vintage ORDER BY vintage', TBL)) |>
  dplyr::mutate(key = paste(.data$n_rows, .data$n_ind, .data$n_grp))

dupes <- fp |> dplyr::group_by(.data$key) |>
  dplyr::filter(dplyr::n() > 1L) |> dplyr::arrange(.data$vintage) |>
  dplyr::mutate(keep = dplyr::row_number() == 1L) |> dplyr::ungroup()

if (!is.null(drop_from_manifest)) {
  drop_v <- drop_from_manifest
  detect_by <- "sha256 manifest"
  # The fingerprint is still computed, and a disagreement is reported rather
  # than silently overridden: it means the warehouse and the raw files have
  # drifted apart, which is worth knowing.
  fp_drop <- if (nrow(dupes)) dupes$vintage[!dupes$keep] else character(0)
  if (!setequal(fp_drop, drop_v)) {
    cli::cli_alert_warning(paste(
      "manifest and row-count fingerprint disagree.",
      "manifest drops [{paste(sort(drop_v), collapse = ', ')}];",
      "fingerprint drops [{paste(sort(fp_drop), collapse = ', ')}].",
      "Using the manifest -- an equal hash is proof, equal counts are not."))
  }
} else {
  drop_v <- if (nrow(dupes)) dupes$vintage[!dupes$keep] else character(0)
  detect_by <- "row-count fingerprint (no manifest)"
}

if (length(drop_v)) {
  cli::cli_alert_warning("republished vintages detected by {detect_by}, identical content under a later month:")
  for (k in unique(dupes$key)) {
    grp <- dupes$vintage[dupes$key == k]
    if (length(grp) > 1L)
      cli::cli_alert_warning("  {paste(grp, collapse = \" == \")}  -> keeping {grp[1]}")
  }
  vint <- setdiff(vint, drop_v)
  cli::cli_alert_info("{length(drop_v)} vintage(s) excluded as republished")
} else {
  cli::cli_alert_success("no republished vintages ({detect_by})")
}
cli::cli_alert_success("warehouse: {length(vint)} vintages, {min(vint)} to {max(vint)}")
if (length(vint) < 2L) {
  stop("a panel needs at least two vintages; the warehouse has ", length(vint),
       call. = FALSE)
}

# --- the panel ---------------------------------------------------------------
cli::cli_h2("Panel")
panel <- dbGetQuery(con, sprintf('
  SELECT DISTINCT c.amcb_id, r.individual_npi AS midwife_npi,
         r.group_pac_id AS org_pac_id, r.group_name AS organization_name,
         r.group_state AS organization_state,
         r.individual_revalidation_due, r.group_revalidation_due,
         r.employer_association_count, r.individual_specialty, r.vintage
  FROM cohort c
  JOIN %s r ON r.individual_npi = c.npi
  WHERE r.group_pac_id IS NOT NULL AND r.group_pac_id <> \'\'
    AND r.vintage IN (%s)', TBL,
  paste(sprintf("'%s'", vint), collapse = ", ")))
cli::cli_alert_success("panel rows: {format(nrow(panel), big.mark = ',')}")
cli::cli_alert_info("midwives: {format(n_distinct(panel$midwife_npi), big.mark = ',')}; organizations: {format(n_distinct(panel$org_pac_id), big.mark = ',')}")

per_v <- panel %>% group_by(vintage) %>%
  summarise(midwives = n_distinct(midwife_npi),
            organizations = n_distinct(org_pac_id),
            rows = n(), .groups = "drop")
print(as.data.frame(per_v), row.names = FALSE)

write_with_provenance(
  panel %>% arrange(amcb_id, vintage, org_pac_id),
  OUT, na = "", inputs = prov_inputs(cw, DB))
cli::cli_alert_success("wrote {OUT}")

# --- spells ------------------------------------------------------------------
# A spell is a run of CONSECUTIVE AVAILABLE snapshots. Consecutive is defined
# against the warehouse's own vintage list, not the calendar: CMS did not
# publish every month, and treating a month it never published as a break would
# manufacture terminations out of a publication schedule.
cli::cli_h2("Spells")
vidx <- setNames(seq_along(vint), vint)

spells <- panel %>%
  distinct(amcb_id, midwife_npi, org_pac_id, organization_name, vintage) %>%
  mutate(vi = unname(vidx[vintage])) %>%
  arrange(midwife_npi, org_pac_id, vi) %>%
  group_by(midwife_npi, org_pac_id) %>%
  mutate(brk = cumsum(c(1L, diff(vi) != 1L))) %>%
  group_by(amcb_id, midwife_npi, org_pac_id, organization_name, brk) %>%
  summarise(first_seen_vintage = vint[min(vi)],
            last_seen_vintage  = vint[max(vi)],
            n_snapshots_seen   = dplyr::n(),
            .groups = "drop") %>%
  mutate(
    # CENSORING. A spell starting at the first warehouse snapshot may have
    # started long before it; one ending at the last is ongoing. Saying so is
    # the difference between a bound and a fabricated date.
    left_censored  = first_seen_vintage == min(vint),
    right_censored = last_seen_vintage  == max(vint),
    # The bracket around a disappearance, only where one was observed.
    ended_between_start = if_else(right_censored, NA_character_, last_seen_vintage),
    ended_between_end   = if_else(right_censored, NA_character_,
                                  vint[pmin(length(vint), match(last_seen_vintage, vint) + 1L)]),
    spell_index = brk) %>%
  select(-brk) %>%
  arrange(amcb_id, org_pac_id, first_seen_vintage)

cli::cli_alert_success("spells: {format(nrow(spells), big.mark = ',')}")
cli::cli_alert_info("left-censored: {format(sum(spells$left_censored), big.mark = ',')}; right-censored (ongoing): {format(sum(spells$right_censored), big.mark = ',')}")
cli::cli_alert_info("fully observed (start AND end inside the window): {format(sum(!spells$left_censored & !spells$right_censored), big.mark = ',')}")

multi <- spells %>% count(midwife_npi, org_pac_id) %>% filter(n > 1L)
cli::cli_alert_info("relationships that STOPPED and RESUMED: {nrow(multi)}")

write_with_provenance(spells, OUT_SP, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_SP}")

# --- what the panel supports -------------------------------------------------
cli::cli_h2("What these bounds do and do not support")
cadence <- paste(range(vint), collapse = " to ")
cat(sprintf("  %d snapshots, %s.\n", length(vint), cadence))
cat("  first_seen / last_seen are BOUNDS. A relationship first seen in the\n")
cat("  earliest snapshot may have begun years before it; one still present in\n")
cat("  the latest is ongoing. Neither is a start or end date.\n")
cat("  A disappearance is bracketed by two snapshots, and the honest width of\n")
cat("  that interval is the publication cadence -- not a day.\n")
cat("  Months CMS never published are not breaks: spells run over consecutive\n")
cat("  AVAILABLE snapshots, so a publication gap does not become a termination.\n\n")

# --- tracked summary ---------------------------------------------------------
summ <- panel %>%
  distinct(midwife_npi, vintage, organization_state) %>%
  filter(!is.na(organization_state), nzchar(organization_state)) %>%
  count(vintage, organization_state, name = "n_midwives") %>%
  mutate(suppressed = n_midwives < 11,
         n_midwives = if_else(suppressed, NA_integer_, n_midwives)) %>%
  arrange(vintage, organization_state)
write_with_provenance(summ, OUT_SUM, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT_SUM} (cells under 11 suppressed)")
