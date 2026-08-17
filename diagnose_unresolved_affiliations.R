#!/usr/bin/env Rscript
#' @title Why do the unresolved ACTIVE midwives have no organization?
#'
#' @description
#' 1,544 ACTIVE certificants end the affiliation pipeline with no organization.
#' The obvious next move is to add another evidence source. This exists to test
#' that assumption before anyone spends effort on it, because the answer decides
#' whether the next experiment should ACQUIRE data or DISAMBIGUATE it.
#'
#' Each unresolved midwife is assigned the strongest thing true of them:
#'
#'   unique_org_available  a key resolves to exactly one organization. This
#'                         would be a RESOLVER DEFECT -- the pipeline should
#'                         have found it.
#'   ambiguous_many_orgs   the key matches several organizations. The data
#'                         exists; it does not discriminate. Adding sources
#'                         makes this WORSE, not better.
#'   key_matched_no_org    a usable key that matches no Type-2 organization
#'                         anywhere. The signature of a residential or stale
#'                         address: a practice registered to a house has no
#'                         organizational neighbour by construction.
#'   no_usable_key         no address and no phone.
#'
#' @section COUNTING IS DONE IN SQL, AND THAT IS NOT A PERFORMANCE DETAIL:
#' A first version pulled all 1.87M Type-2 organizations into R for regex
#' keying. It ran 25 minutes without finishing. The second restricted the
#' organization side to the target ZIPs -- fast, but WRONG for telephone keys,
#' because an organization sharing a phone number from another ZIP becomes
#' invisible and a genuinely ambiguous key looks unique. That artifact produced
#' 24 false "resolver defects"; checked nationally, all 24 matched many
#' organizations.
#'
#' So key counts are computed over the FULL national organization set in DuckDB,
#' where the join is cheap and no scoping shortcut can bias the answer. The
#' lesson is the general one: a restriction chosen for speed silently changed a
#' scientific classification.
#'
#' Inputs : NPPES_2025 dissemination, the resolved affiliation table, the
#'          AMCB->NPI crosswalk, the four-way cohort membership file
#' Outputs: artifacts/unresolved_affiliation_reasons.csv         (person-level, gitignored)
#'          artifacts/unresolved_affiliation_reasons_summary.csv (tracked)
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
source(file.path("R", "lib", "address_keys.R"))

NPPES <- Sys.getenv("NPPES_2025",
  "/Volumes/MufflySamsung 1/nppes_historical_downloads/extracted_2025/npidata_pfile_20050523-20251109.csv")
OUT     <- "artifacts/unresolved_affiliation_reasons.csv"
OUT_SUM <- "artifacts/unresolved_affiliation_reasons_summary.csv"

if (!file.exists(NPPES))
  stop(sprintf("NPPES dissemination not found: %s\n  Set NPPES_2025 or mount the volume.", NPPES),
       call. = FALSE)

rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)

# --- who is unresolved -------------------------------------------------------
cw <- Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv")
cw <- cw[!grepl("manifest|provenance", cw)]
cw <- cw[order(file.mtime(cw), decreasing = TRUE)][1]
spine <- rd(cw) %>% filter(!is.na(npi), nzchar(npi)) %>%
  distinct(certification_number = amcb_id, npi)
res <- rd("artifacts/organization_affiliation_resolved.csv")
status <- rd("artifacts/cohort_membership_four_way.csv") %>%
  distinct(certification_number, .keep_all = TRUE) %>% select(certification_number, status)

unres <- spine %>% left_join(status, by = "certification_number") %>%
  filter(status == "ACTIVE", !npi %in% res$npi)
cli::cli_alert_info("ACTIVE and unresolved: {format(nrow(unres), big.mark = ',')}")
if (!nrow(unres)) stop("nothing unresolved; nothing to diagnose", call. = FALSE)

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "target", unres %>% select(npi))

SRC <- sprintf("read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)", NPPES)
COLS <- 'TRIM(CAST(d."NPI" AS VARCHAR)) AS npi,
  TRIM(CAST(d."Provider First Line Business Practice Location Address" AS VARCHAR)) AS addr,
  TRIM(CAST(d."Provider Business Practice Location Address Postal Code" AS VARCHAR)) AS zip,
  TRIM(CAST(d."Provider Business Practice Location Address Telephone Number" AS VARCHAR)) AS phone'
# A deactivated organization with no later reactivation is not somewhere anyone
# practises; counting it would inflate ambiguity with defunct entities.
LIVE <- '(d."NPI Deactivation Date" IS NULL OR TRIM(CAST(d."NPI Deactivation Date" AS VARCHAR)) = \'\'
          OR (d."NPI Reactivation Date" IS NOT NULL AND TRIM(CAST(d."NPI Reactivation Date" AS VARCHAR)) <> \'\'))'

cli::cli_h2("Reading NPPES")
mw <- dbGetQuery(con, sprintf(
  'SELECT %s FROM %s d JOIN target t ON TRIM(CAST(d."NPI" AS VARCHAR)) = t.npi', COLS, SRC))
cli::cli_alert_success("cohort rows: {format(nrow(mw), big.mark = ',')}")

orgs <- dbGetQuery(con, sprintf(
  'SELECT %s FROM %s d WHERE TRIM(CAST(d."Entity Type Code" AS VARCHAR)) = \'2\' AND %s',
  COLS, SRC, LIVE))
cli::cli_alert_success("live Type-2 organizations (national, unrestricted): {format(nrow(orgs), big.mark = ',')}")

# --- keys, from the canonical library on both sides --------------------------
# Named diag_keys, not addkeys: build_nppes_colocation_2025.R already defines
# addkeys() and it computes a ZIP+4 key this one does not. Two functions with
# one name that differ in which keys they build is precisely how a linkage
# silently changes meaning, so they are kept distinct rather than merged.
diag_keys <- function(d) d %>% mutate(
  ka = norm_addr(.data$addr), k5 = zip5(.data$zip), k9 = zip9(.data$zip),
  kp = phone10(.data$phone),
  key_phone = if_else(!is.na(.data$kp), paste0("P:", .data$kp), NA_character_),
  key_zip9  = if_else(!is.na(.data$k9) & !is.na(.data$ka),
                      paste0("9:", .data$k9, "|", .data$ka), NA_character_),
  key_zip5  = if_else(!is.na(.data$k5) & !is.na(.data$ka),
                      paste0("5:", .data$k5, "|", .data$ka), NA_character_))
mw <- diag_keys(mw); orgs <- diag_keys(orgs)

# --- classify ----------------------------------------------------------------
cli::cli_h2("Classifying")
RANK <- c(no_usable_key = 0L, key_matched_no_org = 1L,
          ambiguous_many_orgs = 2L, unique_org_available = 3L)
reason <- setNames(rep("no_usable_key", nrow(mw)), mw$npi)
n_at_key <- setNames(rep(NA_integer_, nrow(mw)), mw$npi)

for (kn in c("key_zip5", "key_zip9", "key_phone")) {
  cnt <- orgs %>% filter(!is.na(.data[[kn]])) %>%
    distinct(key = .data[[kn]], org = .data$npi) %>% count(key, name = "n")
  m <- mw %>% filter(!is.na(.data[[kn]])) %>%
    transmute(npi, key = .data[[kn]]) %>% left_join(cnt, by = "key")
  lab <- if_else(is.na(m$n), "key_matched_no_org",
                 if_else(m$n == 1L, "unique_org_available", "ambiguous_many_orgs"))
  better <- RANK[lab] > RANK[reason[m$npi]]
  reason[m$npi[better]] <- lab[better]
  n_at_key[m$npi[better]] <- as.integer(m$n[better])
}

out <- unres %>%
  left_join(tibble::tibble(npi = names(reason), reason = unname(reason),
                           n_orgs_at_best_key = unname(n_at_key)), by = "npi") %>%
  mutate(reason = tidyr::replace_na(reason, "not_found_in_nppes"))

tab <- out %>% count(reason, sort = TRUE) %>% mutate(pct = round(100 * n / sum(n), 1))
print(as.data.frame(tab), row.names = FALSE)

# A unique organization that the pipeline did not use is a DEFECT, not a
# finding. Say so loudly rather than letting it sit in a percentage column.
n_defect <- sum(out$reason == "unique_org_available")
if (n_defect > 0) {
  cli::cli_alert_danger("{n_defect} midwife/midwives have exactly ONE organization at a key and were NOT resolved -- investigate the resolver")
} else {
  cli::cli_alert_success("no unresolved midwife has an unambiguous organization available: the resolver left nothing on the table")
}

cli::cli_h2("What this implies")
amb <- sum(out$reason == "ambiguous_many_orgs"); noorg <- sum(out$reason == "key_matched_no_org")
cat(sprintf("  ambiguous (%s, %.1f%%) need DISAMBIGUATION -- the data exists and does not\n",
            format(amb, big.mark = ","), 100 * amb / nrow(out)))
cat("  discriminate. Another source adds candidates, which makes this worse.\n")
cat(sprintf("  no-organization (%s, %.1f%%) have addresses with no Type-2 neighbour at all,\n",
            format(noorg, big.mark = ","), 100 * noorg / nrow(out)))
cat("  the signature of a residential or stale address. Another organizational\n")
cat("  source does not reach them either.\n")

write_with_provenance(out, OUT, na = "", inputs = prov_inputs(c(cw, NPPES)))
write_with_provenance(tab, OUT_SUM, na = "", inputs = prov_inputs(OUT))
cli::cli_alert_success("wrote {OUT} and {OUT_SUM}")
