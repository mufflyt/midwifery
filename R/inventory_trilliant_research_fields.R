#!/usr/bin/env Rscript
# =============================================================================
# What the Trilliant asset actually contains, and which studies it can support
# =============================================================================
# A read-only inventory of every table in the Trilliant DuckLake
# (hpt_prices/trilliant/20260721/lake on the external volume), and a
# feasibility matrix whose "identifiable" columns are COMPUTED from that
# inventory and from checks that the other sources exist -- not asserted.
#
# Why this exists. The research program proposed for this asset includes
# clinician-level delivery volume and longitudinal practice histories. Neither
# may be assumed: the project has already published one delivery-attendance
# layer that never read a procedure code (retracted in #195). This script shows
# what fields exist before any analysis is built on them.
#
# Outputs (aggregate; no person-level values -- identifier-like columns get no
# example values at all):
#   artifacts/trilliant_schema_inventory.csv
#   artifacts/trilliant_research_question_feasibility.csv
#
# Cost. Non-missing counts come from the parquet footers (exact, no scan).
# Distinct counts are HyperLogLog estimates (approx_count_distinct, ~2% error):
# over the full table for tables up to 20 million rows; for the price tables,
# over three evenly spaced whole parquet files, named in distinct_basis. (A
# row-level reservoir sample would still read all 62 GB.)
#
# SQL. Two short statements: attaching the DuckLake catalog, and reading parquet
# footer statistics. R has no other way to do either. Everything else is dplyr.
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(stringr); library(purrr)
})
source(file.path("R", "lib", "medicare_duckdb.R"))      # samsung_volume_path()
source(file.path("R", "lib", "artifact_provenance.R"))  # write_with_provenance()

LAKE_REL <- "hpt_prices/trilliant/20260721/lake"
LAKE <- { v <- Sys.getenv("TRILLIANT_LAKE_ROOT", ""); if (nzchar(v)) v else samsung_volume_path(LAKE_REL) }
BIG_TABLE_ROWS <- 20e6
SAMPLE_FILES <- 3L   # price tables: profile 3 evenly spaced whole parquet files

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "INSTALL ducklake; LOAD ducklake;")
dbExecute(con, sprintf(
  "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', OVERRIDE_DATA_PATH true, READ_ONLY);",
  file.path(LAKE, "metadata.ducklake"), file.path(LAKE, "data")))

columns <- dbGetQuery(con, "
  SELECT table_name, column_name, data_type, ordinal_position
  FROM information_schema.columns WHERE table_catalog = 'lake' ORDER BY table_name, ordinal_position") |>
  as_tibble()
tables <- sort(unique(columns$table_name))
meta <- dbGetQuery(con, "SELECT * FROM lake.directory_meta") |> as_tibble()

# Parquet footers: exact row and null counts per column, without a scan.
footer <- map_dfr(tables, function(t) {
  files <- Sys.glob(file.path(LAKE, "data", "main", t, "*.parquet"))
  if (!length(files)) return(tibble())
  dbGetQuery(con, sprintf(
    "SELECT path_in_schema AS column_name, sum(num_values) AS n_values,
            sum(coalesce(stats_null_count, 0)) AS n_null
     FROM parquet_metadata([%s]) GROUP BY 1",
    paste(sprintf("'%s'", files), collapse = ","))) |>
    as_tibble() |> mutate(table_name = t)
})

# Identifier-like columns never get example values.
inv_is_identifier <- function(col) str_detect(col, regex(
  "npi|name|address|street|phone|latitude|longitude|_id$|^id$|attester|license|url|hash|path|zip|email", TRUE))

inv_profile_table <- function(t) {
  cols <- columns$column_name[columns$table_name == t]
  n_rows <- dbGetQuery(con, sprintf('SELECT count(*) AS n FROM lake."%s"', t))$n
  files <- sort(Sys.glob(file.path(LAKE, "data", "main", t, "*.parquet")))
  big <- n_rows > BIG_TABLE_ROWS && length(files) > SAMPLE_FILES
  if (big) {
    pick <- files[unique(round(seq(1, length(files), length.out = SAMPLE_FILES)))]
    src <- sprintf("read_parquet([%s])", paste(sprintf("'%s'", pick), collapse = ","))
    basis <- sprintf("HyperLogLog over %d of %d parquet files (evenly spaced)", length(pick), length(files))
    scanned <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s", src))$n
  } else {
    src <- sprintf('lake."%s"', t)
    basis <- "HyperLogLog over all rows"
    scanned <- n_rows
  }
  q <- function(fun) paste(sprintf('%s("%s") AS "%s"', fun, cols, cols), collapse = ", ")
  distinct <- dbGetQuery(con, sprintf("SELECT %s FROM %s", q("approx_count_distinct"), src))
  nonmiss  <- dbGetQuery(con, sprintf("SELECT %s FROM %s", q("count"), src))
  examples <- map_chr(cols, function(cn) {
    if (inv_is_identifier(cn) || distinct[[cn]] > 50) return("")
    top <- dbGetQuery(con, sprintf('SELECT CAST("%s" AS VARCHAR) AS v, count(*) AS n FROM %s
                                    WHERE "%s" IS NOT NULL GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 3', cn, src, cn))
    paste(str_trunc(top$v, 40), collapse = " | ")
  })
  tibble(table_name = t, table_rows = n_rows, column_name = cols,
         n_distinct_approx = unlist(distinct[1, cols]),
         n_nonmissing_scanned = unlist(nonmiss[1, cols]),
         scanned_rows = scanned,
         distinct_basis = basis, example_values = examples)
}

cat("profiling", length(tables), "tables\n")
prof <- map_dfr(tables, function(t) { cat("  ", t, "\n"); inv_profile_table(t) })

inv_has <- function(col, pat) str_detect(col, regex(pat, TRUE))
inventory <- columns |>
  select(table_name, column_name, data_type) |>
  left_join(prof, by = c("table_name", "column_name"), relationship = "one-to-one") |>
  left_join(footer |> select(table_name, column_name, n_values, n_null),
            by = c("table_name", "column_name"), relationship = "one-to-one") |>
  mutate(
    database = "trilliant_ducklake_20260721", schema = "main",
    # Exact from footers where the table is parquet-backed; otherwise the scan
    # (or the sample, for the price tables -- then it is a sample count).
    n_nonmissing = coalesce(n_values - n_null, n_nonmissing_scanned),
    n_nonmissing_basis = if_else(!is.na(n_values), "parquet footer (exact)",
                                 if_else(scanned_rows < table_rows, "sample", "full scan")),
    contains_npi        = inv_has(column_name, "npi"),
    contains_clinician_npi = inv_has(column_name, "^provider_npi$|rendering.*npi|attending.*npi|performing.*npi|operating.*npi"),
    contains_date       = str_detect(data_type, "DATE|TIMESTAMP") | inv_has(column_name, "_date$|_on$|year"),
    contains_service_date = contains_date & inv_has(column_name, "service|claim|encounter|visit|admit|discharge"),
    contains_geography  = inv_has(column_name, "state|city|county|zip|latitude|longitude|address|street"),
    contains_procedure  = inv_has(column_name, "^cpt$|hcpcs|^icd|drg|^rc$|ndc|procedure|diagnosis"),
    # Whole name parts only: "count" inside discounted_cash or county is not a volume.
    contains_volume_measure = inv_has(column_name, "(^|_)count($|_)|(^|_)(visits|patients|volume)(_|$)|^panel_|practices_total|percent_total"),
    example_values_redacted = if_else(inv_is_identifier(column_name), "[identifier: not shown]", example_values),
    possible_research_use = case_when(
      contains_clinician_npi ~ "clinician linkage key",
      inv_has(column_name, "active_provider") ~ "current clinical-activity flag (single snapshot)",
      inv_has(column_name, "^panel_") ~ "patient-panel composition (aggregate, single snapshot)",
      inv_has(column_name, "practices_total|visits_percent") ~ "practice topology (single snapshot)",
      inv_has(column_name, "affiliated_practice_1") ~ "main practice site (single snapshot)",
      inv_has(column_name, "specialty|credential|taxonomy") ~ "clinician/organization classification",
      inv_has(column_name, "organization_type") ~ "facility classification",
      contains_procedure & table_name %in% c("standard_charges", "standard_charge_details") ~ "hospital price list code (not clinician-level)",
      str_detect(table_name, "charge") ~ "hospital price transparency (facility-level)",
      contains_geography ~ "geography",
      TRUE ~ "")) |>
  select(database, schema, table = table_name, table_rows, column_name, data_type,
         n_nonmissing, n_nonmissing_basis, n_distinct_approx, distinct_basis,
         example_values_redacted, contains_npi, contains_clinician_npi, contains_date,
         contains_service_date, contains_geography, contains_procedure, contains_volume_measure,
         possible_research_use)

# -----------------------------------------------------------------------------
# Feasibility: computed from the inventory and from source-existence checks
# -----------------------------------------------------------------------------
tbl_has <- inventory |>
  group_by(table) |>
  summarise(clin_npi = any(contains_clinician_npi), svc_date = any(contains_service_date),
            proc = any(contains_procedure), .groups = "drop")
claim_level_tables <- tbl_has$table[tbl_has$clin_npi & tbl_has$svc_date & tbl_has$proc]
snapshots <- nrow(meta[meta$table_name == "directory_provider", ])
inv_vol <- function(rel) !is.na(samsung_volume_path(rel, must_exist = FALSE))
inv_repo <- function(p) file.exists(p)
src <- c(
  nppes_history      = inv_vol("nppes_historical_downloads") || inv_vol("temporal_nppes.duckdb"),
  medicare_warehouse = inv_vol("DuckDB/nber_my_duckdb.duckdb"),
  dac_vintages       = inv_vol("facility_affiliation"),
  nppes_deactivation = inv_vol("nppes_deactivation_reports"),
  persistence_paper  = inv_repo("manuscript/midwife_persistence.qmd"),
  degree_nppes_text  = inv_repo("artifacts/msn_dnp_credential_classification.csv"),
  cabc               = inv_repo("artifacts/cabc_accredited_birth_centers_master.csv"),
  delivery_code_obs  = inv_repo("artifacts/medicare_delivery_code_observability.csv"),
  cohort_definitions = inv_repo("R/lib/cohort_definitions.R"),
  work_site_build    = inv_repo("build_trilliant_work_sites.R"))
inv_yn <- function(x) if (isTRUE(x)) "yes" else "no"
inv_listed <- function(...) { v <- c(...); paste(names(v)[v], collapse = "; ") }
trill_single <- sprintf("directory_provider (%d snapshot, %s)", snapshots,
                        paste(meta$snapshot_label[meta$table_name == "directory_provider"], collapse = ","))
delivery_ok <- length(claim_level_tables) > 0

feas <- tribble(
  ~research_question, ~required_variables, ~trilliant_tables, ~other_linked_sources, ~status, ~main_limitation, ~recommended_analysis,
  "Main work setting (current)",
    "clinician NPI; main practice site; site facility type",
    trill_single, inv_listed(cohort_definitions = src[["cohort_definitions"]], work_site_build = src[["work_site_build"]]),
    "fully", "single snapshot; site type inferred from organizations at the address",
    "cross-sectional topology among the canonical cohort (Aim 1)",
  "Multi-site practice",
    "number of practice sites; visit share at the main site",
    trill_single, "NPPES secondary locations; CMS DAC affiliations",
    "fully", "Trilliant names only the top site; other sites come from NPPES/DAC and must be deduplicated by address",
    "distribution of sites and main-site share; distinct-address deduplication before counting",
  "Hospital + birth-center blended practice",
    "hospital evidence; birth-center evidence; per-site type",
    trill_single, inv_listed(cabc = src[["cabc"]], dac_vintages = src[["dac_vintages"]]),
    "partially", "CABC covers accredited centers only; DAC covers Medicare billers only; strict definition will undercount",
    "strict (CABC + DAC/Trilliant hospital) and broad definitions reported side by side (Aim 2)",
  "Rural current practice",
    "main-site coordinates or ZIP; RUCA/RUCC",
    trill_single, "Census ZCTA/RUCC already in the repository",
    "fully", "rurality of the claims-derived main site, one date",
    "rurality of each work site, not only the NPPES address",
  "Rural longitudinal retention",
    "dated practice location per year per clinician",
    "none (directory is replace-on-refresh; one snapshot)", inv_listed(nppes_history = src[["nppes_history"]], persistence_paper = src[["persistence_paper"]]),
    if (src[["nppes_history"]]) "partially" else "not", "Trilliant has no history; NPPES addresses are self-reported and often stale; this is ALREADY the subject of manuscript/midwife_persistence.qmd",
    "do not start a second retention paper; use Trilliant's 2026 claims-derived site to validate the NPPES end point of the existing panel",
  "DNP versus MSN (as exposure)",
    "degree per clinician with source and confidence",
    "directory_provider.provider_credential (free text, one snapshot)", inv_listed(degree_nppes_text = src[["degree_nppes_text"]]),
    "partially", "credential strings are self-reported and incomplete; unknown must stay a category",
    "degree as a predictor of setting, sites and activity; report coverage and unknowns",
  "Clinical inactivity (current)",
    "activity indicator; patient panel; last billing",
    trill_single, inv_listed(medicare_warehouse = src[["medicare_warehouse"]]),
    "partially", "active_provider is undocumented and lags a stop in practice; quantify the lag against AMCB RETIRED/DECEASED before using it",
    "evidence-hierarchy phenotype, never active_provider alone; validate against AMCB RETIRED/DECEASED",
  "Retirement / clinical exit timing",
    "dated last clinical activity per clinician",
    "none (no dated activity in Trilliant)", inv_listed(medicare_warehouse = src[["medicare_warehouse"]], nppes_deactivation = src[["nppes_deactivation"]]),
    "partially", "only Medicare-year billing gives dates, and it misses midwives with young, non-Medicare panels; exit dates are interval-censored at best",
    "interval-censored exit using last Medicare year plus AMCB status; label as Medicare-observable exit",
  "Birth attendance (any)",
    "clinician NPI + service date + delivery procedure codes in one table",
    if (delivery_ok) paste(claim_level_tables, collapse = "; ") else "none", inv_listed(delivery_code_obs = src[["delivery_code_obs"]]),
    if (delivery_ok) "fully" else "not",
    "no Trilliant table carries clinician NPI, service date and procedure codes together; public Medicare Part B has zero delivery-code rows for any provider (artifacts/medicare_delivery_code_observability.csv)",
    if (delivery_ok) "build observed deliveries per clinician" else "NOT IDENTIFIABLE FROM CURRENT TRILLIANT ASSET",
  "Deliveries per month (volume)",
    "dated delivery claims per clinician",
    if (delivery_ok) paste(claim_level_tables, collapse = "; ") else "none", "none",
    if (delivery_ok) "fully" else "not",
    "requires claim-level data this download does not contain",
    if (delivery_ok) "monthly observed deliveries with global/component de-duplication" else "DELIVERY VOLUME NOT IDENTIFIABLE FROM CURRENT TRILLIANT ASSET",
  "Geographic mobility",
    "dated locations per clinician",
    "none (one snapshot)", inv_listed(nppes_history = src[["nppes_history"]], persistence_paper = src[["persistence_paper"]]),
    if (src[["nppes_history"]]) "partially" else "not", "same as rural retention; already the persistence manuscript's subject",
    "cross-check: NPPES latest address vs Trilliant claims site (a staleness measure, not mobility)",
  "Practice longevity",
    "first and last dated clinical activity",
    "none", inv_listed(medicare_warehouse = src[["medicare_warehouse"]], nppes_history = src[["nppes_history"]]),
    "partially", "Medicare years 2013-2023 only; NPPES presence is not practice",
    "report as Medicare-observable span; do not call it practice longevity") |>
  mutate(fully_identifiable = status == "fully", partially_identifiable = status == "partially",
         not_identifiable = status == "not",
         evidence = sprintf("claim-level Trilliant tables found: %s; directory snapshots: %d",
                            if (length(claim_level_tables)) paste(claim_level_tables, collapse = ",") else "none",
                            snapshots)) |>
  select(research_question, required_variables, trilliant_tables, other_linked_sources,
         fully_identifiable, partially_identifiable, not_identifiable, main_limitation,
         recommended_analysis, evidence)

write_with_provenance(inventory, "artifacts/trilliant_schema_inventory.csv", na = "")
write_with_provenance(feas, "artifacts/trilliant_research_question_feasibility.csv", na = "")

cat(sprintf("\n%d tables, %d columns. Tables with a clinician NPI: %s\n", length(tables), nrow(inventory),
            paste(unique(inventory$table[inventory$contains_clinician_npi]), collapse = ", ")))
cat(sprintf("Tables with clinician NPI + service date + procedure codes together: %s\n",
            if (length(claim_level_tables)) paste(claim_level_tables, collapse = ", ") else "NONE"))
cat(sprintf("Directory snapshots held: %d\n\n", snapshots))
print(feas |> select(research_question, fully_identifiable, partially_identifiable, not_identifiable), n = Inf, width = 200)
