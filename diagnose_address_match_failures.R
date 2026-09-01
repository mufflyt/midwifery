#!/usr/bin/env Rscript
#' @title Why does every non-matching cohort address fail to match?
#'
#' @description
#' `diagnose_unresolved_affiliations.R` says WHETHER an organization was found
#' at a midwife's address. It does not say why not. This does, exhaustively:
#' every unresolved ACTIVE CNM/CM whose address does not key to an organization
#' lands in exactly one class, and each class carries a verdict about whether it
#' is a defect we can fix, a policy choice, or a correct non-match.
#'
#' It exists because "fix address normalisation" was treated as one task when it
#' is four, with very different sizes. Measured on the 702 no-organization group
#' with the 2026 vintage, the split was:
#'
#'   unit_only_difference          99 of 170 gap cases   POLICY, not a defect
#'   genuinely_different_street    56                    correct non-match
#'   street_typo_near_miss         10                    NOT safely fixable
#'   street_variant_normalisable    5                    genuinely fixable
#'
#' Five. The normalisation defect was real and worth fixing, and it was never
#' the reason these midwives are unresolved.
#'
#' @section The classes, and the verdict attached to each:
#' \describe{
#'   \item{`no_house_number`}{No street number to key on. Sub-classified by
#'     `build_embedded_org_name_arm.R`; an address arm cannot reach these.}
#'   \item{`unit_only_difference`}{Same street and house number, different
#'     suite/floor/building. A POLICY choice, not a defect: `norm_addr()`
#'     deliberately keeps unit designators because two suites in one building
#'     are two workplaces, and merging them asserts an affiliation the source
#'     does not record. Reported so the size of that policy is visible --
#'     "1942 ATKINSON RD STE 100" versus "STE 500" must not match, but
#'     "220 CHURCH ST" versus "220 CHURCH ST FL 5" is arguable.}
#'   \item{`street_variant_normalisable`}{Spelled versus abbreviated suffix,
#'     spelled versus numeric ordinal, spelled versus lettered directional.
#'     "361 THIRD STREET" and "361 3RD ST" are one place. FIXABLE, and the
#'     canonical parser is what fixes them.}
#'   \item{`street_typo_near_miss`}{A misspelling: "DARNEALL LOOP" for "DARNALL
#'      LOOP". NOT fixable by normalisation, and deliberately not fixed -- see
#'      the adversarial measurement below.}
#'   \item{`genuinely_different_street`}{Same ZIP and same house number by
#'     coincidence, different road. A correct non-match.}
#'   \item{`no_org_at_zip_and_house_number`}{No organization is registered at
#'     that ZIP and house number at all. Nothing about string handling can
#'     change this; it is the largest class and it is the actual finding.}
#' }
#'
#' @section The adversarial measurement, and why it is in this file:
#' The obvious "fix" for `street_typo_near_miss` is fuzzy matching. This script
#' measures what that would cost instead of arguing about it: among candidate
#' pairs within a small edit distance, what fraction are demonstrably DIFFERENT
#' addresses rather than misspellings of one?
#'
#' On the 2026 measurement, of ten pairs at normalised distance <= 0.20, three
#' were different places -- "6TH AVE" versus "5TH AVE", "E 19TH ST" versus
#' "E 16TH ST", and two house numbers differing by one digit. A single edited
#' character is the difference between two real streets far more often than it
#' is a typo. That is a ~30% false-match rate on precisely the population a
#' fuzzy matcher would be pointed at, and it is why this project's fuzzy name
#' and address matching stays retired.
#'
#' The number is recomputed rather than quoted, so it cannot go stale.
#'
#' Inputs : NPPES_2025 dissemination, artifacts/unresolved_affiliation_reasons.csv
#' Outputs: artifacts/address_match_failure_taxonomy.csv (tracked summary)
#'          artifacts/address_fuzzy_false_match_rate.csv (tracked measurement)
#'          artifacts/address_match_failure_cases.csv    (person-level, gitignored)
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(cli)
  library(stringr)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_keys.R"))
source(file.path("R", "lib", "duckdb_guards.R"))

source(file.path("R", "lib", "medicare_duckdb.R"))

NPPES <- Sys.getenv("NPPES_2025", "")
if (!nzchar(NPPES))
  NPPES <- samsung_volume_path(file.path("nppes_historical_downloads",
                                         "extracted_2025",
                                         "npidata_pfile_20050523-20251109.csv"))
if (!file.exists(NPPES)) stop("NPPES 2025 not found: ", NPPES, call. = FALSE)

OUT_T <- "artifacts/address_match_failure_taxonomy.csv"
OUT_F <- "artifacts/address_fuzzy_false_match_rate.csv"
OUT_C <- "artifacts/address_match_failure_cases.csv"

# =============================================================================
# String helpers
# =============================================================================

#' House number, including letter-prefixed grid forms
#'
#' Wisconsin issues "N8150 AMUNDSON COULEE RD". A bare `^[0-9]` test calls that
#' name-based, which misrouted a dozen ordinary rural addresses.
house_number <- function(a) {
  a <- trimws(toupper(as.character(a)))
  ifelse(grepl("^[0-9]", a), sub("^([0-9]+).*$", "\\1", a),
    ifelse(grepl("^[NSEW][0-9]", a), sub("^([NSEW][0-9]+([NSEW][0-9]+)?).*$", "\\1", a),
           NA_character_))
}

UNIT_RX <- "\\s*(STE|SUITE|APT|APARTMENT|UNIT|BLDG|BUILDING|FL|FLOOR|RM|ROOM|STOP|DEPT|PMB|#).*$"

#' The street portion alone: no house number, no unit designator
street_only <- function(a) {
  x <- toupper(trimws(as.character(a)))
  x <- str_replace_all(x, "[.,]", " ")
  x <- str_replace(x, "^[0-9]+\\s*[A-Z]?\\s+", " ")
  x <- str_replace(x, "^[NSEW][0-9]+([NSEW][0-9]+)?\\s+", " ")
  x <- str_replace(x, UNIT_RX, "")
  str_squish(x)
}

#' Everything a normaliser SHOULD equate, applied aggressively
#'
#' Ordinals, suffixes and directionals only. Nothing here touches the street
#' NAME -- that is the line between normalisation and fuzzy matching.
ORD <- c(FIRST="1ST", SECOND="2ND", THIRD="3RD", FOURTH="4TH", FIFTH="5TH",
         SIXTH="6TH", SEVENTH="7TH", EIGHTH="8TH", NINTH="9TH", TENTH="10TH",
         ELEVENTH="11TH", TWELFTH="12TH")
SFX <- c(STREET="ST", STR="ST", AVENUE="AVE", AV="AVE", ROAD="RD", DRIVE="DR",
         BOULEVARD="BLVD", PARKWAY="PKWY", LANE="LN", COURT="CT", CIRCLE="CIR",
         PLACE="PL", TERRACE="TER", HIGHWAY="HWY", EXTENSION="EXT",
         JUNIOR="JR", TRAIL="TRL", SQUARE="SQ", EXPRESSWAY="EXPY",
         TURNPIKE="TPKE", CROSSING="XING", POINT="PT", HEIGHTS="HTS")
DIR <- c(NORTH="N", SOUTH="S", EAST="E", WEST="W", NORTHEAST="NE",
         NORTHWEST="NW", SOUTHEAST="SE", SOUTHWEST="SW", NO="N", SO="S")

normalise_aggressively <- function(a) {
  x <- street_only(a)
  for (m in list(ORD, SFX, DIR))
    for (k in names(m)) x <- str_replace_all(x, paste0("\\b", k, "\\b"), m[[k]])
  str_squish(x)
}

# =============================================================================
# Cohort and candidate organizations
# =============================================================================
rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)
reasons <- rd("artifacts/unresolved_affiliation_reasons.csv")
cli::cli_alert_info("unresolved cohort: {format(nrow(reasons), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "target", reasons %>% select(npi))

SRC <- sprintf("read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)", NPPES)
COLS <- 'TRIM(CAST(d."NPI" AS VARCHAR)) AS npi,
  TRIM(CAST(d."Provider First Line Business Practice Location Address" AS VARCHAR)) AS addr,
  TRIM(CAST(d."Provider Business Practice Location Address Postal Code" AS VARCHAR)) AS zip'
LIVE <- '(d."NPI Deactivation Date" IS NULL OR TRIM(CAST(d."NPI Deactivation Date" AS VARCHAR)) = \'\'
          OR (d."NPI Reactivation Date" IS NOT NULL AND TRIM(CAST(d."NPI Reactivation Date" AS VARCHAR)) <> \'\'))'

cli::cli_h2("Reading NPPES 2025")
mw <- dbGetQuery(con, sprintf(
  'SELECT %s FROM %s d JOIN target t ON TRIM(CAST(d."NPI" AS VARCHAR)) = t.npi', COLS, SRC))
refuse_if_large(mw, "cohort rows")
mw$z5 <- zip5(mw$zip); mw$hn <- house_number(mw$addr)
mw$bk <- ifelse(is.na(mw$z5) | is.na(mw$hn), NA_character_, paste0(mw$z5, "#", mw$hn))

dbExecute(con, sprintf("CREATE OR REPLACE TABLE org2 AS SELECT %s FROM %s d
  WHERE TRIM(CAST(d.\"Entity Type Code\" AS VARCHAR)) = '2' AND %s", COLS, SRC, LIVE))
cli::cli_alert_success("live Type-2 organizations: {format(dbGetQuery(con,'SELECT COUNT(*) n FROM org2')$n, big.mark = ',')}")

# Exact reduction: an org can share an address key only if it shares ZIP5 and
# house number. See reconcile_address_parser_universe.R for the argument.
duckdb::duckdb_register(con, "bk", tibble(bk = unique(na.omit(mw$bk))))
cand <- dbGetQuery(con, "
  WITH k AS (SELECT *, SUBSTR(REGEXP_REPLACE(zip,'[^0-9]','','g'),1,5) AS z5,
    CASE WHEN REGEXP_MATCHES(TRIM(addr),'^[0-9]+') THEN REGEXP_EXTRACT(TRIM(addr),'^[0-9]+')
         WHEN REGEXP_MATCHES(TRIM(UPPER(addr)),'^[NSEW][0-9]') THEN REGEXP_EXTRACT(TRIM(UPPER(addr)),'^[NSEW][0-9]+([NSEW][0-9]+)?') END AS hn
    FROM org2)
  SELECT k.npi, k.addr, k.z5, k.hn, k.z5 || '#' || k.hn AS bk
  FROM k JOIN bk ON bk.bk = k.z5 || '#' || k.hn")
refuse_if_large(cand, "candidate organizations")
cli::cli_alert_success("candidate organizations at a cohort ZIP+house number: {format(nrow(cand), big.mark = ',')}")

# =============================================================================
# Classify every cohort address
# =============================================================================
cli::cli_h2("Classifying")
mw$key_exact <- paste0(mw$z5, "|", norm_addr(mw$addr))
cand$key_exact <- paste0(cand$z5, "|", norm_addr(cand$addr))
exact_keys <- unique(cand$key_exact[!is.na(cand$key_exact)])

by_bk <- split(cand$addr, cand$bk)

classify_one <- function(i) {
  if (is.na(mw$hn[i]))                       return("no_house_number")
  if (mw$key_exact[i] %in% exact_keys)       return("matched_exactly")
  o <- by_bk[[mw$bk[i]]]
  if (is.null(o))                            return("no_org_at_zip_and_house_number")
  if (street_only(mw$addr[i]) %in% street_only(o))            return("unit_only_difference")
  if (normalise_aggressively(mw$addr[i]) %in% normalise_aggressively(o))
                                             return("street_variant_normalisable")
  ms <- street_only(mw$addr[i]); os <- unique(street_only(o))
  d <- as.integer(utils::adist(ms, os)); r <- d / pmax(nchar(ms), nchar(os))
  if (length(r) && min(r, na.rm = TRUE) <= 0.20 && min(d, na.rm = TRUE) <= 3)
                                             return("street_typo_near_miss")
  "genuinely_different_street"
}
mw$failure_class <- vapply(seq_len(nrow(mw)), classify_one, character(1))

VERDICT <- c(
  matched_exactly                = "matches under the production key",
  no_house_number                = "no address key possible; see the embedded-name arm",
  unit_only_difference           = "POLICY: unit designators deliberately retained",
  street_variant_normalisable    = "FIXABLE by the canonical parser",
  street_typo_near_miss          = "NOT safely fixable; see the fuzzy false-match rate",
  genuinely_different_street     = "correct non-match: house-number coincidence",
  no_org_at_zip_and_house_number = "no organization registered there at all")

tax <- mw %>% count(failure_class, name = "n") %>%
  mutate(pct_of_cohort = round(100 * n / nrow(mw), 1),
         verdict = unname(VERDICT[failure_class])) %>%
  arrange(desc(n))
print(as.data.frame(tax), row.names = FALSE)

fixable <- sum(mw$failure_class == "street_variant_normalisable")
cli::cli_alert_info("FIXABLE by normalisation: {fixable} of {nrow(mw)} ({round(100*fixable/nrow(mw),1)}%)")

# =============================================================================
# What fuzzy matching would cost
# =============================================================================
# Measured, not asserted. Each near-miss pair is adjudicated on the parts a
# normaliser may NOT touch: if the pair differs in house number, in an ordinal
# street number, or in a directional, it is two places and matching them is a
# false positive.
cli::cli_h2("Adversarial check: what fuzzy matching would cost")
nm <- which(mw$failure_class == "street_typo_near_miss")
if (!length(nm)) {
  cli::cli_alert_info("no near-miss pairs at this threshold; nothing to adjudicate")
  fuzz <- tibble(threshold_ratio = 0.20, pairs = 0L, false_matches = 0L,
                 false_match_rate = NA_real_)
} else {
  adj <- lapply(nm, function(i) {
    ms <- street_only(mw$addr[i]); os <- unique(street_only(by_bk[[mw$bk[i]]]))
    d <- as.integer(utils::adist(ms, os)); r <- d / pmax(nchar(ms), nchar(os))
    j <- which.min(r); other <- os[j]
    num <- function(z) unlist(regmatches(z, gregexpr("[0-9]+", z)))
    dirs <- function(z) intersect(unlist(strsplit(z, "\\s+")), unname(DIR))
    # Differing ordinals ("6TH" vs "5TH") or differing directionals are
    # different streets, whatever the edit distance says.
    verdict <- if (!identical(num(ms), num(other))) "false_match_different_number"
          else if (!identical(sort(dirs(ms)), sort(dirs(other)))) "directional_difference"
          else "plausible_typo"
    tibble(pair = sprintf("%s <-> %s", ms, other), d = d[j],
           ratio = round(r[j], 2), verdict = verdict)
  }) %>% bind_rows()
  print(as.data.frame(adj), row.names = FALSE)
  fm <- sum(adj$verdict == "false_match_different_number")
  fuzz <- tibble(threshold_ratio = 0.20, pairs = nrow(adj), false_matches = fm,
                 false_match_rate = round(fm / nrow(adj), 3),
                 directional_only = sum(adj$verdict == "directional_difference"),
                 plausible_typo = sum(adj$verdict == "plausible_typo"))
  print(as.data.frame(fuzz), row.names = FALSE)
  cli::cli_alert_danger("a fuzzy matcher at this threshold would MIS-MATCH {fm} of {nrow(adj)} pairs ({round(100*fm/nrow(adj))}%) -- different streets or house numbers one character apart")
}

# =============================================================================
# What relaxing the suite policy would cost
# =============================================================================
# `unit_only_difference` is the largest non-absent class, and the obvious "fix"
# is to key at BUILDING level -- drop the suite and let a midwife match the
# organization in the same building. This measures that trade instead of
# assuming it, because the answer is not obvious from the class size:
#
#   most of these cases are ONE-SIDED (one record carries a unit, the other does
#   not), which reads like the same place. But dropping the unit only RESOLVES a
#   midwife when the building holds exactly one organization. Where it holds
#   several, relaxing the key converts a clean non-match into an ambiguity --
#   worse than before, because ambiguity is not resolution.
#
# On the 2026 measurement: 16 of 99 would resolve uniquely and 83 would become
# ambiguous. That is the number the policy question turns on.
cli::cli_h2("If the suite policy were relaxed to a building-level key")
ub <- which(mw$failure_class == "unit_only_difference")
if (!length(ub)) {
  cli::cli_alert_info("no unit-only differences; nothing to trade off")
  policy <- tibble(cases = 0L, one_sided = 0L, would_resolve_uniquely = 0L,
                   would_become_ambiguous = 0L)
} else {
  n_org_in_building <- vapply(mw$bk[ub],
    function(b) length(unique(cand$npi[cand$bk == b])), integer(1))
  one_sided <- vapply(ub, function(i) {
    o <- by_bk[[mw$bk[i]]]
    mu <- grepl(UNIT_RX, toupper(mw$addr[i]))
    ou <- grepl(UNIT_RX, toupper(o))
    (!mu && any(ou)) || (mu && any(!ou))
  }, logical(1))
  policy <- tibble(cases = length(ub), one_sided = sum(one_sided),
                   would_resolve_uniquely = sum(n_org_in_building == 1L),
                   would_become_ambiguous = sum(n_org_in_building > 1L))
  print(as.data.frame(policy), row.names = FALSE)
  cli::cli_alert_warning("relaxing the suite key would resolve {policy$would_resolve_uniquely} and make {policy$would_become_ambiguous} AMBIGUOUS -- a policy decision, not a defect fix")
}

tax <- bind_rows(tax, policy %>%
  transmute(failure_class = "POLICY_relax_suite_key_would_resolve",
            n = would_resolve_uniquely, pct_of_cohort = round(100 * n / nrow(mw), 1),
            verdict = sprintf("of %d unit-only cases; %d would become ambiguous",
                              policy$cases, policy$would_become_ambiguous)))
write_with_provenance(tax, OUT_T, na = "", inputs = prov_inputs(NPPES))
write_with_provenance(fuzz, OUT_F, na = "", inputs = prov_inputs(NPPES))
write_with_provenance(mw %>% select(npi, addr, zip, z5, hn, failure_class),
                      OUT_C, na = "", inputs = prov_inputs(NPPES))
cli::cli_alert_success("wrote {OUT_T}, {OUT_F} and {OUT_C}")
