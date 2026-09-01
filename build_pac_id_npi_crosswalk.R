#!/usr/bin/env Rscript
#' @title Versioned PAC ID <-> NPI crosswalk from CMS PPEF enrollment
#'
#' @description
#' The affiliation arms identify an organization by three incompatible keys:
#' PECOS and Care Compare by PAC ID, NPPES co-location by Type-2 NPI, the
#' hospital arms by CCN. With no bridge, cross-arm agreement rests on the
#' normalised legal name, which makes `multi_source_confirmed` an undercount
#' (DECISIONS_CONTRACT.md, "Organization identity across arms with no shared
#' identifier").
#'
#' CMS supplies the bridge directly: the PPEF ENROLLMENT record carries NPI and
#' PECOS_ASCT_CNTL_ID on the same row, keyed by ENRLMT_ID.
#'
#'   PAC_ID -> ENRLMT_ID -> NPI
#'
#' @section BUILT FROM IDENTIFIERS ONLY. NO NAME MATCHING:
#' Not one relation in this file is created by comparing organization names.
#' Every (pac_id, npi) pair comes from a single CMS enrollment row that already
#' contained both. `org_name` is carried as a LABEL for readers and is never an
#' input to the relation. This is the whole point: a crosswalk built by fuzzy
#' name matching would reintroduce the very ambiguity it exists to remove.
#'
#' @section IT IS ONE-TO-MANY, AND MUST NOT BE FORCED OTHERWISE:
#' A PAC ID identifies a legal entity as enrolled; an NPI identifies a practice
#' location. Measured, not assumed:
#'
#'   individuals    every PAC ID maps to exactly ONE NPI. No exceptions.
#'   organizations  ~95% map to one NPI; the rest are chains -- WALGREEN CO
#'                  holds 9,166 NPIs under one PAC ID, WAL-MART 2,819, CVS
#'                  1,314. One NPI per store, one PAC ID per corporation.
#'
#' That is what the identifiers mean, not corruption to clean away. So this
#' writes one row per (snapshot, pac_id, npi) and records fan-out in both
#' directions. Collapsing to one row per PAC ID would silently pick a store.
#'
#' @section TWO PRODUCTS, FOR TWO DIFFERENT USES:
#'   pac_npi_snapshot  one row per snapshot_date x pac_id x npi. Use this for
#'                     analysis: a mapping is applied only to the snapshot that
#'                     recorded it.
#'   pac_npi_ever      one row per pac_id x npi with first_seen, last_seen and
#'                     n_snapshots_seen. Use for candidate generation and
#'                     historical reconciliation ONLY.
#'
#' Applying a 2026 mapping to a 2021 Care Compare snapshot is an assumption
#' about organizational continuity, not an observation. The ever-crosswalk makes
#' that assumption available; it does not make it safe, and `n_snapshots_seen`
#' plus the snapshot span are what let a reader judge it.
#'
#' @section ADDITIONAL_NPIS is not published, and the gap is MEASURED:
#' CMS documents an ADDITIONAL_NPIS relation supplying further NPIs for
#' enrollments with several. It is not among this dataset's public
#' distributions, so those NPIs cannot be attached here. Rather than let that
#' pass silently, MULTIPLE_NPI_FLAG is carried and counted: it names exactly the
#' enrollments whose additional NPIs we cannot see. A PAC ID flagged 'Y' with a
#' single NPI in this file is INCOMPLETE, not unique, and is labelled so.
#'
#' @section Snapshot dates come from the FILE, never the download time:
#' The extract is named for the date CMS cut it. mtime is when it was fetched,
#' and using it would date the observation to our own convenience.
#'
#' @section PPEF is currently-approved-only:
#' Per the ruling, an enrollment withdrawn before the snapshot is absent. A join
#' failure is therefore not evidence that an organization never held that PAC
#' ID.
#'
#' Inputs : PPEF_RAW_DIR/PPEF_Enrollment_Extract_YYYY.MM.DD.csv (+ legacy file)
#' Outputs: artifacts/pac_npi_snapshot.csv          (organizations, gitignored -- large)
#'          artifacts/pac_npi_ever.csv              (organizations, gitignored -- large)
#'          artifacts/pac_npi_crosswalk_summary.csv (tracked)
#'          artifacts/pac_npi_cardinality.csv       (tracked)
#'          artifacts/pac_npi_snapshot_manifest.csv (tracked -- hashes)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(digest)
  library(tidyr); library(cli)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))

source(file.path("R", "lib", "medicare_duckdb.R"))
RAW <- Sys.getenv("PPEF_RAW_DIR", "")
if (!nzchar(RAW)) RAW <- samsung_volume_path("ppef_raw")
# The legacy cut is OPTIONAL: it is excluded unless PPEF_INCLUDE_LEGACY is
# set, so its absence must not stop the run.
LEGACY <- Sys.getenv("PPEF_ENROL", "")
if (!nzchar(LEGACY))
  LEGACY <- samsung_volume_path(file.path("pecos_data", "ppefenrol.csv"),
                                must_exist = FALSE)
if (is.na(LEGACY)) LEGACY <- ""
OUT_SNAP <- "artifacts/pac_npi_snapshot.csv"
OUT_EVER <- "artifacts/pac_npi_ever.csv"
OUT_SUM  <- "artifacts/pac_npi_crosswalk_summary.csv"
OUT_CARD <- "artifacts/pac_npi_cardinality.csv"
OUT_MAN  <- "artifacts/pac_npi_snapshot_manifest.csv"

# --- discover snapshots ------------------------------------------------------
files <- Sys.glob(file.path(RAW, "PPEF_Enrollment_Extract_*.csv"))
snap_of <- function(p)
  gsub("\\.", "-", sub(".*PPEF_Enrollment_Extract_([0-9.]+)\\.csv$", "\\1", basename(p)))
man <- if (length(files)) {
  tibble::tibble(path = files, snapshot_date = snap_of(files), source = "ppef_extract")
} else {
  tibble::tibble(path = character(), snapshot_date = character(), source = character())
}

# THE LEGACY ON-VOLUME CUT IS EXCLUDED, and this is the interesting decision.
#
# It carries no snapshot date: a lower-case schema, no MULTIPLE_NPI_FLAG, and
# 2,248,990 rows against 2,978,921 in the July extract. It is plainly an older
# CMS cut, but nothing in the file says WHICH. The only date available is the
# mtime, which is when it was downloaded to this volume.
#
# Dating it by mtime would place 2.25 million relations at 2026-05-19 --
# BETWEEN the April and July extracts -- and manufacture a spike of churn:
# every mapping absent from that older cut would read as disappearing in May and
# returning in July. n_snapshots_seen, the field a reader uses to judge whether a
# mapping is durable, would be corrupted for the entire crosswalk.
#
# An undated snapshot cannot join a versioned series. Set PPEF_INCLUDE_LEGACY=1
# only if its true cut date has been established, and pass it in.
if (file.exists(LEGACY) && nzchar(Sys.getenv("PPEF_INCLUDE_LEGACY"))) {
  d <- Sys.getenv("PPEF_LEGACY_DATE", "")
  if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", d))
    stop("PPEF_INCLUDE_LEGACY is set but PPEF_LEGACY_DATE is not a YYYY-MM-DD ",
         "cut date. Refusing to date a snapshot by its download time.",
         call. = FALSE)
  man <- bind_rows(man, tibble::tibble(path = LEGACY, snapshot_date = d,
                                       source = "legacy_volume_cut"))
} else if (file.exists(LEGACY)) {
  cli::cli_alert_warning("legacy cut excluded: no snapshot date in the file, and mtime is a download time, not an observation date")
}
if (!nrow(man)) {
  stop(sprintf(paste("no PPEF enrollment snapshot found in %s\n",
                     "  Set PPEF_RAW_DIR or PPEF_ENROL. Refusing to write an",
                     "empty crosswalk,\n  which would read as 'no PAC ID has an",
                     "NPI'."), RAW), call. = FALSE)
}

cli::cli_h2("Snapshots")
man <- man %>% rowwise() %>%
  mutate(bytes = file.info(.data$path)$size,
         sha256 = digest::digest(.data$path, algo = "sha256", file = TRUE)) %>%
  ungroup() %>% arrange(.data$snapshot_date)

# PAC8. CMS republishes byte-identical content under a later label -- already
# proven on the revalidation series, where 2024-03 and 2024-08 shared an sha256.
# Two labels for one cut would make an unchanged mapping look re-observed and
# inflate n_snapshots_seen.
man <- man %>% group_by(.data$sha256) %>% arrange(.data$snapshot_date, .by_group = TRUE) %>%
  mutate(is_republication = dplyr::row_number() > 1L,
         republication_of = if_else(.data$is_republication, dplyr::first(.data$snapshot_date), NA_character_),
         use_for_panel = !.data$is_republication) %>%
  ungroup() %>% arrange(.data$snapshot_date)
for (i in seq_len(nrow(man)))
  cli::cli_alert_info("{man$snapshot_date[i]}  {round(man$bytes[i]/1e6)} MB  {man$source[i]}{if (man$is_republication[i]) paste0('  REPUBLICATION of ', man$republication_of[i]) else ''}")
if (any(man$is_republication))
  cli::cli_alert_warning("{sum(man$is_republication)} snapshot(s) excluded as byte-identical republications")

write_with_provenance(man %>% select(-path), OUT_MAN, na = "",
                      inputs = prov_inputs(man$path))

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# --- read each snapshot ------------------------------------------------------
# PAC1/PAC2: every identifier is read as TEXT. A PAC ID or NPI parsed as a
# number loses leading zeros and silently stops joining.
read_snapshot <- function(path, snapshot_date, source) {
  hdr <- names(read_csv(path, n_max = 0, show_col_types = FALSE))
  pick <- function(...) { for (n in c(...)) if (n %in% hdr) return(n); NA_character_ }
  cn <- c(npi = pick("NPI", "npi"),
          pac = pick("PECOS_ASCT_CNTL_ID", "pecos_asct_cntl_id"),
          enr = pick("ENRLMT_ID", "enrlmt_id"),
          ptc = pick("PROVIDER_TYPE_CD", "provider_type_cd"),
          ptd = pick("PROVIDER_TYPE_DESC", "provider_type_desc"),
          org = pick("ORG_NAME", "org_name"),
          st  = pick("STATE_CD", "state_cdstr", "state_cd"),
          mnf = pick("MULTIPLE_NPI_FLAG", "multiple_npi_flag"))
  if (any(is.na(cn[c("npi", "pac", "enr")])))
    stop(sprintf("%s lacks NPI/PAC/ENRLMT_ID columns", basename(path)), call. = FALSE)

  q <- sprintf('
    SELECT DISTINCT
      TRIM(CAST("%s" AS VARCHAR)) AS npi,
      TRIM(CAST("%s" AS VARCHAR)) AS pac_id,
      TRIM(CAST("%s" AS VARCHAR)) AS enrlmt_id,
      %s AS provider_type_cd, %s AS provider_type_desc,
      %s AS org_name, %s AS state, %s AS multiple_npi_flag
    FROM read_csv_auto(\'%s\', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)',
    cn["npi"], cn["pac"], cn["enr"],
    if (is.na(cn["ptc"])) "CAST(NULL AS VARCHAR)" else sprintf('TRIM(CAST("%s" AS VARCHAR))', cn["ptc"]),
    if (is.na(cn["ptd"])) "CAST(NULL AS VARCHAR)" else sprintf('TRIM(CAST("%s" AS VARCHAR))', cn["ptd"]),
    if (is.na(cn["org"])) "CAST(NULL AS VARCHAR)" else sprintf('TRIM(CAST("%s" AS VARCHAR))', cn["org"]),
    if (is.na(cn["st"]))  "NULL" else sprintf('TRIM(CAST("%s" AS VARCHAR))', cn["st"]),
    if (is.na(cn["mnf"])) "CAST(NULL AS VARCHAR)" else sprintf('TRIM(CAST("%s" AS VARCHAR))', cn["mnf"]),
    path)
  d <- dbGetQuery(con, q)
  d$snapshot_date <- snapshot_date
  d$snapshot_source <- source
  d$npi_source <- "ENROLLMENT"   # ADDITIONAL_NPIS is not published; see header.
  d
}

use <- man %>% filter(.data$use_for_panel)
cli::cli_h2("Reading {nrow(use)} snapshot(s)")
raw <- lapply(seq_len(nrow(use)), function(i) {
  cli::cli_alert_info("{use$snapshot_date[i]} ...")
  d <- read_snapshot(use$path[i], use$snapshot_date[i], use$source[i])
  cli::cli_alert_success("{use$snapshot_date[i]}: {format(nrow(d), big.mark = ',')} enrollment rows")
  d
})
raw <- bind_rows(raw)

# PAC3: an enrollment relation with no ENRLMT_ID cannot be traced back to CMS.
# PAC2: an NPI that is not ten digits is not an NPI.
bad_enr <- sum(is.na(raw$enrlmt_id) | !nzchar(raw$enrlmt_id))
bad_npi <- sum(!grepl("^[0-9]{10}$", raw$npi))
cli::cli_alert_info("dropped: {format(bad_enr, big.mark = ',')} rows with no ENRLMT_ID; {format(bad_npi, big.mark = ',')} with a non-10-digit NPI")
raw <- raw %>% filter(nzchar(.data$enrlmt_id), grepl("^[0-9]{10}$", .data$npi),
                      !is.na(.data$pac_id), nzchar(.data$pac_id))

# A PAC ID with ANY organization row is an organization. Computed by set
# membership rather than a grouped mutate: there are ~3.9 million PAC groups
# across the snapshots, and a per-group call takes tens of minutes where a
# vectorised %in% takes seconds. Same answer, and the run actually finishes.
org_pac_ids <- unique(raw$pac_id[!is.na(raw$org_name) & nzchar(raw$org_name)])
raw <- raw %>% mutate(
  entity_kind = if_else(.data$pac_id %in% org_pac_ids, "organization", "individual"))

# --- pac_npi_snapshot and pac_npi_ever, in DuckDB ----------------------------
# Both aggregations run in SQL, not dplyr. There are ~6 million enrollment rows
# and ~5 million (snapshot, pac, npi) groups; a grouped summarise over that many
# groups runs for tens of minutes, while the same work is seconds in a columnar
# engine. Two rewrites of this block in R were abandoned before moving it here.
#
# PAC6: the survivor of a duplicate relation is chosen by ORDER BY inside
# row_number(), so the output does not depend on the order rows arrived in.
cli::cli_h2("pac_npi_snapshot")

# ONLY ORGANIZATIONS ARE AGGREGATED. The written crosswalk is organizations-only
# anyway (the individual half is a person-level name map and is not needed for
# organization identity), and carrying 1.6 million individual enrollments
# through the aggregation made it ~14x larger for output that is then discarded.
# The individual cardinality claim in the header is still asserted, cheaply,
# just below.
ind <- raw %>% filter(.data$entity_kind == "individual")
# DISTINCT NPIs per PAC ID, not rows. Counting rows conflates "this PAC ID has
# several NPIs" with "this PAC ID has several enrollments carrying the SAME
# NPI", and the second is routine. An earlier version counted rows and fired a
# false alarm that the 1:1 claim had broken; verified directly against the July
# extract, all 2,166,297 individual PAC IDs map to exactly one NPI.
ind_card <- ind %>% distinct(.data$snapshot_date, .data$pac_id, .data$npi) %>%
  count(.data$snapshot_date, .data$pac_id, name = "n") %>%
  count(.data$n, name = "n_pac_ids")
cli::cli_alert_info("individual PAC IDs by NPI count: {paste(sprintf('%s NPI=%s', ind_card$n, format(ind_card$n_pac_ids, big.mark = ',')), collapse = '; ')}")
if (!identical(as.integer(ind_card$n), 1L))
  cli::cli_alert_warning("an individual PAC ID maps to more than one NPI; the header's claim no longer holds")

raw <- raw %>% filter(.data$entity_kind == "organization")
cli::cli_alert_info("organization enrollment rows: {format(nrow(raw), big.mark = ',')}")
duckdb::duckdb_register(con, "raw_rows", raw)

snap <- dbGetQuery(con, "
  WITH dedup AS (
    SELECT snapshot_date, pac_id, npi,
           FIRST(enrlmt_id        ORDER BY enrlmt_id) AS enrlmt_id,
           FIRST(provider_type_cd ORDER BY enrlmt_id) AS provider_type_cd,
           FIRST(provider_type_desc ORDER BY enrlmt_id) AS provider_type,
           FIRST(org_name         ORDER BY enrlmt_id) AS organization_name,
           FIRST(state            ORDER BY enrlmt_id) AS state,
           FIRST(multiple_npi_flag ORDER BY enrlmt_id) AS multiple_npi_flag,
           FIRST(entity_kind      ORDER BY enrlmt_id) AS entity_kind,
           FIRST(npi_source       ORDER BY enrlmt_id) AS npi_source,
           FIRST(snapshot_source  ORDER BY enrlmt_id) AS snapshot_source,
           COUNT(*) AS n_enrollments
    FROM raw_rows GROUP BY snapshot_date, pac_id, npi)
  SELECT d.*,
         COUNT(*) OVER (PARTITION BY d.snapshot_date, d.pac_id) AS n_npi_for_pac,
         COUNT(*) OVER (PARTITION BY d.snapshot_date, d.npi)    AS n_pac_for_npi
  FROM dedup d")

snap <- snap %>% mutate(
  # A 'Y' flag with one visible NPI means CMS holds NPIs this file does not
  # publish. Calling that "unique" would assert completeness we do not have.
  pac_npi_resolution = case_when(
    .data$multiple_npi_flag %in% c("Y", "y") & .data$n_npi_for_pac == 1L
      ~ "incomplete_additional_npis_not_published",
    .data$n_npi_for_pac > 1L ~ "multi_location_entity",
    .data$n_pac_for_npi > 1L ~ "npi_holds_multiple_pac_ids",
    TRUE                     ~ "unique"))
cli::cli_alert_success("snapshot rows: {format(nrow(snap), big.mark = ',')}")

cli::cli_h2("pac_npi_ever")
n_snaps <- n_distinct(snap$snapshot_date)
duckdb::duckdb_register(con, "snap_rows", snap)

# ever_ambiguous and ever_unique are kept SEPARATE rather than collapsed into a
# single verdict. A pair ambiguous in an early snapshot and unique in a later
# one is not the same thing as a pair ambiguous throughout, and a dated analysis
# should read resolution_at_latest_snapshot on its own terms.
ever <- dbGetQuery(con, sprintf("
  SELECT pac_id, npi,
         MIN(snapshot_date) AS first_seen,
         MAX(snapshot_date) AS last_seen,
         COUNT(DISTINCT snapshot_date) AS n_snapshots_seen,
         FIRST(entity_kind        ORDER BY snapshot_date DESC) AS entity_kind,
         FIRST(organization_name  ORDER BY snapshot_date DESC) AS organization_name,
         FIRST(provider_type      ORDER BY snapshot_date DESC) AS provider_type,
         FIRST(state              ORDER BY snapshot_date DESC) AS state,
         FIRST(pac_npi_resolution ORDER BY snapshot_date DESC) AS resolution_at_latest_snapshot,
         BOOL_OR(pac_npi_resolution <> 'unique') AS ever_ambiguous,
         BOOL_OR(pac_npi_resolution =  'unique') AS ever_unique,
         %d AS n_snapshots_total
  FROM snap_rows GROUP BY pac_id, npi", n_snaps))

# A PAC ID whose NPI CHANGED between snapshots is not a durable mapping, even
# though each pair was unique in its own snapshot. Eight organizations did this
# between 2026-04 and 2026-07 (MEDEVAC ALASKA LLC re-enumerated, among others).
# Left as "unique", a join on pac_id would either multiply rows or silently pick
# one of the two NPIs. Caught by contract PAC12.
npi_changed <- ever %>% count(.data$pac_id, name = "n_npi_ever") %>%
  filter(.data$n_npi_ever > 1L)
ever <- ever %>%
  left_join(npi_changed, by = "pac_id") %>%
  mutate(n_npi_ever = tidyr::replace_na(.data$n_npi_ever, 1L),
         npi_changed_across_snapshots = .data$n_npi_ever > 1L,
         # Conservative summary, for callers that want one verdict. The detail
         # above is retained so it no longer hides what it summarises.
         pac_npi_resolution = case_when(
           .data$ever_ambiguous               ~ "ambiguous_in_some_snapshot",
           .data$npi_changed_across_snapshots ~ "npi_changed_across_snapshots",
           TRUE                               ~ "unique"),
         seen_in_all_snapshots = .data$n_snapshots_seen == n_snaps)
# Count only what was actually RECLASSIFIED. npi_changed above holds every PAC
# ID with more than one NPI, which is dominated by chains that were already
# ambiguous; reporting that number here implied 14,471 organizations
# re-enumerated between April and July, when the real figure is the handful
# that were otherwise unique.
n_reclassified <- sum(ever$pac_npi_resolution == "npi_changed_across_snapshots")
if (n_reclassified)
  cli::cli_alert_warning("{n_reclassified} otherwise-unique PAC ID(s) map to a DIFFERENT NPI across snapshots; excluded from the durable-unique set")
cli::cli_alert_success("ever rows: {format(nrow(ever), big.mark = ',')}; snapshots: {n_snaps}")


# --- PAC9: cardinality, stratified -------------------------------------------
cli::cli_h2("Cardinality")
band <- function(n) cut(n, c(0, 1, 2, 9, Inf),
                        labels = c("1", "2", "3-9", "10+"), right = TRUE)
latest <- snap %>% filter(.data$snapshot_date == max(.data$snapshot_date))
# Individuals were filtered out before aggregation for speed, so their
# cardinality is folded back in here from the cheap distinct-count above.
# PAC9 requires both entity kinds to be reported; dropping the individual half
# because it was inconvenient to aggregate would defeat the contract.
ind_rows <- ind_card %>%
  transmute(direction = "npis_per_pac_id", entity_kind = "individual",
            band = dplyr::case_when(.data$n == 1L ~ "1", .data$n == 2L ~ "2",
                                    .data$n <= 9L ~ "3-9", TRUE ~ "10+"),
            n_ids = .data$n_pac_ids) %>%
  count(direction, entity_kind, band, wt = .data$n_ids, name = "n")
card <- bind_rows(ind_rows,
  latest %>% distinct(.data$pac_id, .data$entity_kind, .data$n_npi_for_pac) %>%
    transmute(direction = "npis_per_pac_id", entity_kind,
              band = as.character(band(.data$n_npi_for_pac))) %>% count(direction, entity_kind, band),
  latest %>% distinct(.data$npi, .data$entity_kind, .data$n_pac_for_npi) %>%
    transmute(direction = "pac_ids_per_npi", entity_kind,
              band = as.character(band(.data$n_pac_for_npi))) %>% count(direction, entity_kind, band)
) %>% rename(n_ids = n) %>%
  mutate(snapshot_date = max(snap$snapshot_date))
print(as.data.frame(card), row.names = FALSE)

cat("\nresolution, latest snapshot:\n")
print(as.data.frame(count(latest, entity_kind, pac_npi_resolution)), row.names = FALSE)

top <- latest %>% filter(.data$n_npi_for_pac > 1L) %>%
  distinct(.data$pac_id, .data$organization_name, .data$n_npi_for_pac) %>%
  arrange(desc(.data$n_npi_for_pac)) %>% head(5)
cat("\nlargest multi-location entities (inspect these, do not assume):\n")
print(as.data.frame(top), row.names = FALSE)

# --- write -------------------------------------------------------------------
# Organizations only. The individual half is a direct NPI-to-name map for 1.6
# million clinicians -- person-level by construction, and not needed for
# organization identity.
snap_org <- snap %>% filter(.data$entity_kind == "organization") %>%
  arrange(.data$snapshot_date, .data$pac_id, .data$npi)
ever_org <- ever %>% filter(.data$entity_kind == "organization") %>%
  arrange(.data$pac_id, .data$npi)

write_with_provenance(snap_org, OUT_SNAP, na = "", inputs = prov_inputs(use$path))
write_with_provenance(ever_org, OUT_EVER, na = "", inputs = prov_inputs(OUT_SNAP))
cli::cli_alert_success("wrote {OUT_SNAP} ({format(nrow(snap_org), big.mark = ',')}) and {OUT_EVER} ({format(nrow(ever_org), big.mark = ',')})")

write_with_provenance(card, OUT_CARD, na = "", inputs = prov_inputs(OUT_SNAP))
summ <- snap %>% count(snapshot_date, entity_kind, pac_npi_resolution, name = "n_pairs")
write_with_provenance(summ, OUT_SUM, na = "", inputs = prov_inputs(OUT_SNAP))
cli::cli_alert_success("wrote {OUT_CARD} and {OUT_SUM}")

# --- PAC10: classify every arm PAC ID ----------------------------------------
cli::cli_h2("Arm coverage: mapped / ambiguous / genuinely absent")
classify_arm <- function(path, col, label) {
  if (!file.exists(path)) { cli::cli_alert_warning("{label}: absent"); return(NULL) }
  d <- read_csv(path, col_types = cols(.default = "c"), progress = FALSE)
  if (!col %in% names(d)) { cli::cli_alert_warning("{label}: no column {col}"); return(NULL) }
  ids <- unique(d[[col]][!is.na(d[[col]]) & nzchar(d[[col]])])
  u <- ever_org$pac_id[ever_org$pac_npi_resolution == "unique"]
  cls <- dplyr::case_when(ids %in% u ~ "mapped_unique",
                          ids %in% ever_org$pac_id ~ "mapped_ambiguous",
                          TRUE ~ "absent_from_ppef")
  r <- tibble::tibble(arm = label, class = cls) %>% count(arm, class, name = "n_pac_ids") %>%
    mutate(pct = round(100 * n_pac_ids / length(ids), 1))
  print(as.data.frame(r), row.names = FALSE)
  r
}
arm_cov <- bind_rows(
  classify_arm("artifacts/midwife_reassignment_spells.csv", "org_pac_id", "pecos_reassignment"),
  classify_arm("artifacts/midwife_organization_panel.csv",  "org_pac_id", "care_compare"))
# write_with_provenance(), not write_csv(): every tracked artifact needs a
# .provenance.json sidecar recording its inputs and their SHA-256, and the
# artifact-contract gate A3 fails without one.
if (!is.null(arm_cov) && nrow(arm_cov))
  write_with_provenance(arm_cov, "artifacts/pac_npi_arm_coverage.csv", na = "",
                        inputs = prov_inputs(OUT_EVER))
