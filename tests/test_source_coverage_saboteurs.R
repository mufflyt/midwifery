#!/usr/bin/env Rscript
# =============================================================================
# Twenty-six saboteurs: every way we know to make this publish a lie
# =============================================================================
# tests/test_source_coverage_contracts.R proves the contract works on the
# cases we designed it for. This file is the adversary. Each saboteur
# deliberately damages a declared input the way a real machine, a real
# rsync, a real rename or a real producer bug would, then asserts the build
# REFUSES TO PUBLISH -- naming what broke.
#
# The standard every saboteur is held to:
#
#   A missing, unreadable, mis-yeared or mis-schema'd input must FAIL LOUDLY.
#   A present, readable, correctly-yeared input with ZERO qualifying records
#   must PASS -- it is valid evidence of absence.
#
# Four saboteurs (S4, S11, S14, S19) are inverted on purpose: they sabotage
# the pipeline into being too STRICT, and pass only if the contract keeps
# working. A contract that fails everything is as useless as one that fails
# nothing, and without these a later "fix" could satisfy the other sixteen
# by simply refusing all input.
#
# Provenance of the two real defects reproduced here:
#   S2  the 2026-11-12 Open Payments collapse, five years -> one
#       (docs/state-source-audit-coverage-defect.md)
#   S16 the Colorado/Pennsylvania dropped state column, 1,411 records
#       (docs/state-source-audit-bon-reharvest.md)
# =============================================================================

.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "source_coverage.R"))


sabotage_dir <- file.path(tempdir(), "saboteurs")

# --- the crime scene, rebuilt before every saboteur ---------------------------
DECLARED_YEARS <- 2021:2025

coverage_year_path <- function(program_year)
  file.path(sabotage_dir, sprintf("cohort_general_%d.csv", program_year))

coverage_write_year <- function(program_year, n_rows = 3L, year_written = program_year,
                       path = coverage_year_path(program_year)) {
  readr::write_csv(tibble::tibble(
    certification_number = sprintf("CNM%05d", seq_len(n_rows)),
    npi = sprintf("1%09d", seq_len(n_rows)),
    program_year = rep(year_written, n_rows),
    recipient_state = rep(c("CO", "NM", "AZ"), length.out = n_rows)), path)
  path
}

coverage_restore_scene <- function() {
  unlink(sabotage_dir, recursive = TRUE)
  dir.create(sabotage_dir, recursive = TRUE, showWarnings = FALSE)
  for (program_year in DECLARED_YEARS) coverage_write_year(program_year)
}

manifest_for <- function(years = DECLARED_YEARS) {
  tibble::tibble(
    source_id = "open_payments", source_name = "saboteur fixture",
    expected_year = years, required = TRUE, source_type = "annual",
    input_path = coverage_year_path(years), producer = "fixture",
    date_field = "program_year", state_field = "recipient_state",
    validation_method = "in_file_date", source_vintage = "fixture",
    artifact_sha256 = NA_character_, availability_status = "available",
    notes = "saboteur fixture")
}

# Returns the refusal, or a failure-to-refuse, without ever letting an error
# escape and abort the run -- a saboteur that crashes the harness has not
# been tested.
attempt_publication <- function(manifest_rows = manifest_for()) {
  tryCatch({
    audit <- suppressMessages(suppressWarnings(
      validate_source_coverage(manifest_rows, publication_mode = TRUE)))
    list(refused = FALSE, message = "", audit = audit)
  },
  error = function(e) list(refused = TRUE, message = conditionMessage(e),
                           audit = NULL))
}

exploratory_audit <- function(manifest_rows = manifest_for()) {
  tryCatch(
    suppressMessages(suppressWarnings(
      validate_source_coverage(manifest_rows, publication_mode = FALSE))),
    error = function(e) NULL)
}

coverage_status_of <- function(audit, program_year) {
  if (is.null(audit)) return(NA_character_)
  hit <- dplyr::filter(audit, .data$program_year == !!program_year)
  if (!nrow(hit)) NA_character_ else hit$validation_status[1]
}

saboteur <- function(number, name) cat(sprintf("\nS%d %s\n", number, name))

# =============================================================================
# PART 1 -- SABOTAGING COVERAGE: make the window smaller than declared
# =============================================================================

saboteur(1, "delete one required year")
{
  coverage_restore_scene(); file.remove(coverage_year_path(2023))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses to publish")
  chk(grepl("2023", verdict$message), "names 2023")
}

saboteur(2, "delete four of five years -- the 2026-11-12 defect exactly")
{
  coverage_restore_scene(); file.remove(coverage_year_path(c(2021, 2022, 2023, 2025)))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses to publish a one-year series")
  chk(all(vapply(c("2021", "2022", "2023", "2025"), grepl, logical(1),
                 x = verdict$message)),
      "names all four missing years, not just the first")
  usable <- resolve_source_inputs(exploratory_audit(), "open_payments")
  chk(nrow(usable) == 1L,
      sprintf("exploratory mode admits it has only 1 year [%d]", nrow(usable)))
}

saboteur(3, "rename a year's file -- a glob would never notice")
{
  coverage_restore_scene()
  file.rename(coverage_year_path(2022), file.path(sabotage_dir, "cohort_general_2022.bak"))
  verdict <- attempt_publication()
  chk(verdict$refused && grepl("2022", verdict$message),
      "a renamed input is a missing year, named")
}

saboteur(4, "INVERTED -- a genuinely empty year must still publish")
{
  coverage_restore_scene(); coverage_write_year(2024, n_rows = 0L)
  verdict <- attempt_publication()
  chk(!verdict$refused, "does NOT refuse: zero records is evidence of absence")
  chk(identical(coverage_status_of(verdict$audit, 2024L), "present_zero_records"),
      "and is recorded as its own verdict, not as ok")
  chk(identical(as.integer(
        dplyr::filter(verdict$audit,
                      .data$program_year == 2024L)$source_record_count), 0L),
      "with a measured 0, never NA")
}

saboteur(5, "a year's file holds another year's data")
{
  coverage_restore_scene(); coverage_write_year(2022, year_written = 2023L)
  verdict <- attempt_publication()
  chk(verdict$refused && grepl("2022", verdict$message),
      "refuses, naming the year whose contents contradict it")
}

saboteur(6, "substitute an older snapshot under the right filename")
{
  coverage_restore_scene()
  file.copy(coverage_year_path(2024), coverage_year_path(2025), overwrite = TRUE)
  verdict <- attempt_publication()
  chk(verdict$refused,
      "refuses a 2024 file wearing the 2025 name")
  chk(grepl("2025", verdict$message), "names 2025")
}

saboteur(7, "every year present, one of them silently truncated mid-write")
{
  coverage_restore_scene()
  full_lines <- readLines(coverage_year_path(2023))
  writeLines(full_lines[1:2], coverage_year_path(2023))   # header + one row survives
  verdict <- attempt_publication()
  chk(!verdict$refused,
      "a short but well-formed year is not refused -- rows are not coverage")
  chk(identical(coverage_status_of(verdict$audit, 2023L), "ok"),
      "it validates, and its record count is what reports the truncation")
  chk(identical(as.integer(
        dplyr::filter(verdict$audit,
                      .data$program_year == 2023L)$source_record_count), 1L),
      "the count is 1, so a reader can see the loss")
}

# =============================================================================
# PART 2 -- SABOTAGING THE YEAR: make a file lie about when it is from
# =============================================================================

saboteur(8, "strip the program_year column")
{
  coverage_restore_scene()
  stripped <- readr::read_csv(coverage_year_path(2023), col_types = readr::cols(),
                              progress = FALSE) %>% dplyr::select(-program_year)
  readr::write_csv(stripped, coverage_year_path(2023))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses: a filename is not proof of a year")
  chk(grepl("2023|program_year", verdict$message), "names the year or column")
}

saboteur(9, "blank every program_year value")
{
  coverage_restore_scene()
  coverage_write_year(2021, year_written = NA)
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses an unverifiable year")
}

saboteur(10, "an impossible program_year")
{
  coverage_restore_scene(); coverage_write_year(2025, year_written = 2099L)
  verdict <- attempt_publication()
  chk(verdict$refused && grepl("2025", verdict$message),
      "refuses a year no CMS file could carry")
}

saboteur(11, "INVERTED -- an undeclared extra year must not widen the study")
{
  coverage_restore_scene(); coverage_write_year(2026L)
  verdict <- attempt_publication()
  chk(!verdict$refused, "does not refuse over a file it was never promised")
  resolved <- resolve_source_inputs(verdict$audit, "open_payments")
  chk(nrow(resolved) == 5L && !(2026L %in% resolved$program_year),
      sprintf("and analyses exactly the 5 declared years [%d]", nrow(resolved)))
}

# =============================================================================
# PART 3 -- SABOTAGING THE FILE: present, but not readable as data
# =============================================================================

saboteur(12, "a zero-byte file")
{
  coverage_restore_scene(); file.create(coverage_year_path(2022))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses a file with not even a header")
}

saboteur(13, "binary junk with a valid header")
{
  coverage_restore_scene()
  writeLines(c("certification_number,npi,program_year,recipient_state",
               "\"unterminated,1,2023,CO", "\x01\x02\x03 not csv"),
             coverage_year_path(2023))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses an unparseable file")
  chk(!identical(coverage_status_of(exploratory_audit(), 2023L), "ok"),
      "and never records it as ok, even exploring")
}

saboteur(14, "INVERTED -- a declared path that is a DIRECTORY")
{
  # file.exists() returns TRUE for a directory in R, so a naive existence
  # check passes and the read then explodes. The contract must call this
  # unusable, and must not abort the harness doing so.
  coverage_restore_scene(); file.remove(coverage_year_path(2024)); dir.create(coverage_year_path(2024))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses a directory masquerading as the input")
  chk(nzchar(verdict$message), "with a message, not an uncaught crash")
  unlink(coverage_year_path(2024), recursive = TRUE)
}

saboteur(15, "a file the process cannot read")
{
  coverage_restore_scene()
  Sys.chmod(coverage_year_path(2021), mode = "000")
  readable <- file.access(coverage_year_path(2021), mode = 4L) == 0L
  if (readable) {
    cat("  skip S15 -- running with privileges that ignore file modes\n")
  } else {
    verdict <- attempt_publication()
    chk(verdict$refused, "refuses an unreadable declared input")
  }
  Sys.chmod(coverage_year_path(2021), mode = "644")
}

saboteur(16, "drop the declared state column -- the Colorado defect")
{
  coverage_restore_scene()
  destated <- readr::read_csv(coverage_year_path(2022), col_types = readr::cols(),
                              progress = FALSE) %>%
    dplyr::select(-recipient_state)
  readr::write_csv(destated, coverage_year_path(2022))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses: 62% of records once vanished exactly this way")
  chk(grepl("recipient_state", verdict$message),
      "names the column, so the fix is obvious from the CI log")
}

saboteur(17, "drop the npi column")
{
  coverage_restore_scene()
  deidentified <- readr::read_csv(coverage_year_path(2023), col_types = readr::cols(),
                                  progress = FALSE) %>% dplyr::select(-npi)
  readr::write_csv(deidentified, coverage_year_path(2023))
  verdict <- attempt_publication()
  chk(verdict$refused, "refuses a file nothing can be linked through")
}

# =============================================================================
# PART 4 -- SABOTAGING THE DECLARATION ITSELF
# =============================================================================

saboteur(18, "declare the same source-year twice")
{
  coverage_restore_scene()
  doubled <- dplyr::bind_rows(manifest_for(),
                              dplyr::filter(manifest_for(),
                                            .data$expected_year == 2023L))
  doubled_path <- file.path(sabotage_dir, "doubled_manifest.csv")
  readr::write_csv(doubled, doubled_path, na = "")
  refused <- tryCatch({
    suppressMessages(read_source_manifest(doubled_path)); FALSE
  }, error = function(e) grepl("twice", conditionMessage(e)))
  chk(isTRUE(refused), "the manifest itself is refused, before any input is read")
}

saboteur(19, "INVERTED -- declare a state column the source truly lacks")
{
  # Texas and Washington publish no state. They declare an EMPTY state_field,
  # and that must be honoured -- otherwise the only way to pass the contract
  # is to invent a state, which is the fabrication the audit exists to stop.
  coverage_restore_scene()
  readr::write_csv(tibble::tibble(
    certification_number = "CNM1", npi = "1000000001",
    program_year = 2026L, live_bon_status = "Active"),
    file.path(sabotage_dir, "no_state_board.csv"))
  honest <- tibble::tibble(
    source_id = "state_boards_of_nursing", source_name = "stateless board",
    expected_year = 2026L, required = TRUE, source_type = "snapshot",
    input_path = file.path(sabotage_dir, "no_state_board.csv"),
    producer = "fixture", date_field = "program_year", state_field = "",
    validation_method = "producer_declared", source_vintage = "fixture",
    artifact_sha256 = NA_character_, availability_status = "available",
    notes = "source publishes no state")
  verdict <- attempt_publication(honest)
  chk(!verdict$refused, "a declared absence of state is accepted")
  chk(identical(as.integer(verdict$audit$state_observed_count), 0L),
      "and observes 0 states, so it can never pass as state evidence")

  # The same file, now CLAIMING a state column it does not have.
  dishonest <- honest; dishonest$state_field <- "live_bon_state"
  chk(attempt_publication(dishonest)$refused,
      "while claiming a column it lacks is refused")
}

saboteur(20, "fabricate the state column the source cannot support")
{
  # The tempting repair for Texas: derive state = "TX" and move on. Because
  # the harvester already selected on nppes_state == "TX", that value agrees
  # with NPPES by construction and measures nothing. The manifest declares
  # no state field, so the contract must ignore the fabricated column rather
  # than reward it with a state count.
  coverage_restore_scene()
  fabricated_path <- file.path(sabotage_dir, "fabricated_state_board.csv")
  readr::write_csv(tibble::tibble(
    certification_number = sprintf("CNM%d", 1:4),
    npi = sprintf("1%09d", 1:4), program_year = rep(2026L, 4),
    live_bon_state = rep("TX", 4)), fabricated_path)
  declared_stateless <- tibble::tibble(
    source_id = "state_boards_of_nursing", source_name = "texas board",
    expected_year = 2026L, required = TRUE, source_type = "snapshot",
    input_path = fabricated_path, producer = "fixture",
    date_field = "program_year", state_field = "",
    validation_method = "producer_declared", source_vintage = "fixture",
    artifact_sha256 = NA_character_, availability_status = "available",
    notes = "source publishes no state")
  verdict <- attempt_publication(declared_stateless)
  chk(!verdict$refused, "the build proceeds")
  chk(identical(as.integer(verdict$audit$state_observed_count), 0L),
      "but the fabricated column earns 0 state observations, not 4")
}

# =============================================================================
# S21-S25: the panel shape, where file.exists() answers nothing
# =============================================================================
# Eight of the audit's ten sources keep every year in ONE file. Saboteurs
# S1-S20 all damage a file; these five leave the file perfectly intact and
# damage a YEAR INSIDE it, which is the only way to attack a panel and the
# reason the panel contract exists.

panel_path <- file.path(sabotage_dir, "panel.csv")

panel_write <- function(years, state_values = NULL, npi_values = NULL) {
  readr::write_csv(tibble::tibble(
    npi = npi_values %||% sprintf("1%09d", seq_along(years)),
    snapshot_year = as.character(years),
    practice_state = state_values %||%
      rep(c("CO", "NM"), length.out = length(years))), panel_path)
  panel_path
}

panel_manifest_for <- function(years = DECLARED_YEARS) {
  tibble::tibble(
    source_id = "nppes", source_name = "saboteur panel",
    expected_year = years, required = TRUE, source_type = "panel",
    input_path = panel_path, producer = "fixture",
    date_field = "snapshot_year", npi_field = "npi",
    state_field = "practice_state",
    validation_method = "in_file_year_set", source_vintage = "fixture",
    artifact_sha256 = NA_character_, availability_status = "available",
    notes = "saboteur panel")
}

saboteur(21, "delete one year from INSIDE the panel, leaving the file intact")
{
  coverage_restore_scene()
  panel_write(c(2021, 2022, 2024, 2025))
  verdict <- attempt_publication(panel_manifest_for())
  chk(file.exists(panel_path), "the file is still there and readable")
  chk(verdict$refused, "and the build still refuses")
  chk(grepl("2023", verdict$message), "naming the year the panel lost")
  chk(grepl("presence proved nothing", verdict$message),
      "and saying the file existing settled nothing")
}

saboteur(22, "append a year nobody declared -- the glob defect, sign flipped")
{
  coverage_restore_scene()
  panel_write(2021:2026)
  verdict <- attempt_publication(panel_manifest_for(2021:2025))
  chk(verdict$refused, "an undeclared year refuses to publish")
  chk(grepl("undeclared_year_observed", verdict$message),
      "with its own verdict, not mistaken for a missing year")
  audit <- exploratory_audit(panel_manifest_for(2021:2025))
  chk(!(2026L %in% suppressMessages(
          resolve_source_inputs(audit, "nppes"))$program_year),
      "and it is never resolved as a usable input")
}

saboteur(23, "collapse the panel to its newest year -- 11-12, panel form")
{
  coverage_restore_scene()
  panel_write(2025L)
  verdict <- attempt_publication(panel_manifest_for())
  chk(verdict$refused, "four declared years gone refuses to publish")
  chk(all(vapply(c("2021", "2022", "2023", "2024"),
                 function(y) grepl(y, verdict$message), logical(1))),
      "and the refusal names ALL FOUR, not just the first")
}

saboteur(24, "sort the panel so head and tail see only the endpoints")
{
  # WHY THE SCAN IS EXACT. source_year_from_columns() samples a head and a
  # tail, which is right for a one-year file. A panel ordered by year would
  # show it 2021 and 2025 and nothing between, and every middle year would be
  # refuted although the data is perfect. This saboteur is INVERTED: it
  # passes only if the contract keeps working.
  coverage_restore_scene()
  ordered_years <- rep(2021:2025, each = 40L)
  panel_write(ordered_years,
              npi_values = sprintf("1%09d", seq_along(ordered_years)))
  verdict <- attempt_publication(panel_manifest_for())
  chk(!verdict$refused, "an ordered panel publishes")
  audit <- exploratory_audit(panel_manifest_for())
  chk(all(audit$validation_status == "ok"),
      "and every middle year validates, not just the endpoints")
  chk(identical(as.integer(audit$source_record_count), rep(40L, 5L)),
      "each year reporting its OWN 40 rows, not the panel's 200")
}

saboteur(25, "rename the panel's person key")
{
  coverage_restore_scene()
  panel_write(DECLARED_YEARS)
  renamed <- readr::read_csv(panel_path, progress = FALSE,
                             col_types = readr::cols(.default = "c"))
  names(renamed)[names(renamed) == "npi"] <- "provider_npi"
  readr::write_csv(renamed, panel_path)
  verdict <- attempt_publication(panel_manifest_for())
  chk(verdict$refused, "a declared person key that is gone refuses to publish")
  chk(grepl("schema_invalid", verdict$message), "as a schema failure")

  # INVERTED half: a source that declares NO person key must still publish.
  # The Medicaid concordance is a year-by-classification aggregate.
  declared_keyless <- panel_manifest_for()
  declared_keyless$npi_field <- NA_character_
  declared_keyless$state_field <- NA_character_
  keyless_verdict <- attempt_publication(declared_keyless)
  chk(!keyless_verdict$refused,
      "but an aggregate that declares neither key nor state still publishes")
  chk(all(is.na(keyless_verdict$audit$unique_npi_count)),
      "counting no persons rather than inventing some")
}

saboteur(26, "damage the panel so readr parses it but reports problems")
{
  # A corrupt PANEL must say it is corrupt, not "missing npi or the declared
  # state column" -- that message names a fix (rerun the harvester to restore
  # a column) that would not help, and hides one that would.
  coverage_restore_scene()
  writeLines(c("npi,snapshot_year,practice_state",
               "1000000001,2021,CO",
               "1000000002,2022"), panel_path)
  verdict <- attempt_publication(panel_manifest_for(2021:2022))
  chk(verdict$refused, "a short row in the panel refuses to publish")
  chk(grepl("UNPARSEABLE", verdict$message),
      "and the refusal says unparseable")
  chk(!grepl("missing npi", verdict$message),
      "not 'missing npi', which would name a fix that cannot help")
}

unlink(sabotage_dir, recursive = TRUE)
cat(sprintf("\n%s (%d failures across 26 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
