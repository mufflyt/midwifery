#!/usr/bin/env Rscript
# =============================================================================
# FDA Debarment List (Drug Product Applications) cross-reference -- by name
# =============================================================================
# The FDA debarment list carries no NPI, no license number, no identifier of
# any kind other than a name (load_fda_debarment_to_duckdb.R) -- unlike the
# CMS NDH and CMS PECOS sources, this is a name match, not a join, and a name
# match can go wrong in two ways a join cannot: a common cohort name can
# collide with one debarred person (one FDA name, several candidate NPIs), or
# the debarment list itself can carry two different people under the same
# name (rare here: 158 rows). Either kind of collision is reported as
# AMBIGUOUS and EXCLUDED FROM THE FLAG -- fda_debarred is TRUE only for a
# clean one-to-one match, same discipline the state BON scripts
# (harvest_live_*_bon_from_tracked_roster.py) use for VERIFIED vs AMBIGUOUS,
# but stricter about what counts as a flag: a BON lookup missing a tie just
# loses a credential fact, while an exclusion flag wrongly applied to the
# wrong person of the same name is the failure mode worth refusing outright.
#
# Matched on last+first name, normalized with mysterynpi::blank_na(fold_hyphens
# = TRUE) -- the SAME function (and the same fold_hyphens argument) that built
# amcb_npi_linkage_FROZEN.csv's own normalized_last_name/normalized_first_name
# columns (match_amcb_to_npi.R, via R/amcb_name_keys.R's amcb_blank_na alias),
# so the two sides of this match are not two independently-invented name
# normalizers quietly disagreeing. The FDA file's "First & Middle Names"
# column is not split the way AMCB's own first-name field is (amcb_split_
# first()) -- there is no equivalent splitter for a format this project does
# not otherwise see, so only the first whitespace-separated token is compared,
# which only costs a match for someone whose only published FDA first name is
# a middle name alone (a tier-2 fallback not currently wired in -- see the
# no-match reporting below).
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (cohort_member == TRUE)
#          DuckDB table fda_debarment_drug_applications
#          (load_fda_debarment_to_duckdb.R; the raw FDA file lives outside the
#          repo)
# Output : artifacts/fda_debarment_match_cohort.csv (tracked, no names: npi +
#          flag + match_status + debarment term/date as FDA published them --
#          names add nothing a join needs, same as the PECOS cohort file)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))

FROZEN <- "artifacts/amcb_npi_linkage_FROZEN.csv"
OUT    <- "artifacts/fda_debarment_match_cohort.csv"

coh_raw <- read_csv(FROZEN, col_types = cols(.default = "c"), show_col_types = FALSE,
                     progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  distinct(npi, .keep_all = TRUE) %>%
  transmute(npi,
            last_key  = normalized_last_name,
            first_key = normalized_first_name)
cat(sprintf("cohort NPIs (analytic cohort, cohort_member == TRUE): %s\n",
            format(nrow(coh_raw), big.mark = ",")))

DB <- resolve_midwifery_duckdb()
con <- tryCatch(
  duckdb_connect(DB, read_only = TRUE),
  error = function(e) stop(sprintf(
    "Could not open the DuckDB warehouse at %s: %s", DB, conditionMessage(e)),
    call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
if (!"fda_debarment_drug_applications" %in% dbListTables(con)) {
  stop(paste0("Table fda_debarment_drug_applications not found in the warehouse.\n",
              "  Run load_fda_debarment_to_duckdb.R first."), call. = FALSE)
}

fda <- dbGetQuery(con, "SELECT * FROM fda_debarment_drug_applications") %>%
  mutate(
    last_key  = mysterynpi::blank_na(last_name, fold_hyphens = TRUE),
    first_key = mysterynpi::blank_na(
      sub("\\s.*$", "", trimws(first_middle_names)), fold_hyphens = TRUE)
  ) %>%
  filter(!is.na(last_key), !is.na(first_key))
cat(sprintf("FDA debarment rows with a usable name key: %s of %s\n",
            format(nrow(fda), big.mark = ","), format(nrow(dbGetQuery(con,
            "SELECT COUNT(*) AS n FROM fda_debarment_drug_applications")), big.mark = ",")))

# How many DISTINCT people (debarment rows) share each name key, and how many
# cohort NPIs share each name key -- a key is safe to flag only when BOTH
# sides are singletons; see the file header for why a collision on either
# side is reported, not guessed.
fda_key_n <- fda %>% count(last_key, first_key, name = "n_fda")
coh_key_n <- coh_raw %>% count(last_key, first_key, name = "n_cohort")

fda_detail <- fda %>%
  group_by(last_key, first_key) %>%
  summarise(
    debarment_effective_date = paste(unique(effective_date), collapse = "; "),
    debarment_term           = paste(unique(end_term_of_debarment), collapse = "; "),
    .groups = "drop"
  )

out <- coh_raw %>%
  left_join(fda_key_n, by = c("last_key", "first_key")) %>%
  left_join(coh_key_n, by = c("last_key", "first_key")) %>%
  left_join(fda_detail, by = c("last_key", "first_key")) %>%
  mutate(
    n_fda    = tidyr::replace_na(n_fda, 0L),
    n_cohort = tidyr::replace_na(n_cohort, 1L),
    fda_match_status = case_when(
      n_fda == 0L               ~ "NONE",
      n_fda == 1L & n_cohort == 1L ~ "VERIFIED",
      TRUE                       ~ "AMBIGUOUS"
    ),
    fda_debarred = fda_match_status == "VERIFIED"
  ) %>%
  select(npi, fda_debarred, fda_match_status, debarment_effective_date, debarment_term) %>%
  assert_unique_keys("npi", label = "FDA debarment cohort match, by NPI")

write_with_provenance(out, OUT, inputs = FROZEN)
cat(sprintf(paste0("cohort NPIs checked: %s\n",
                    "VERIFIED (flagged, unique name match both sides): %s\n",
                    "AMBIGUOUS (name collision, NOT flagged): %s\n"),
            format(nrow(out), big.mark = ","),
            format(sum(out$fda_debarred), big.mark = ","),
            format(sum(out$fda_match_status == "AMBIGUOUS"), big.mark = ",")))
