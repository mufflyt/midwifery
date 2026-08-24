#!/usr/bin/env Rscript
#' @title Organization names embedded in the address field: a separate evidence arm
#'
#' @description
#' A minority of NPPES practice-location addresses carry no street number at
#' all. They hold an INSTITUTION NAME where a street belongs -- "LANDSTUHL
#' REGIONAL MEDICAL CENTER", "WOMACK ARMY MEDICAL CENTER", "UNIVERSITY OF
#' WASHINGTON". No address normaliser can reach these: there is no house number
#' to key on, and the canonical parser correctly declines to invent one.
#'
#' But the field still identifies an organization -- just lexically rather than
#' geographically. This arm reads that text as a NAME and matches it against
#' Type-2 legal business names.
#'
#' @section This is not an address arm, and the labels say so:
#' Evidence classes are kept distinct rather than folded into co-location:
#' \describe{
#'   \item{`org_name_embedded_unique`}{civilian institution name in the address
#'     field resolving to exactly one eligible Type-2.}
#'   \item{`military_facility_name_unique`}{a military treatment facility. Held
#'     separate because an MTF is a real practice location that does not behave
#'     like an ordinary private Type-2 -- it may have no Type-2 NPI of its own,
#'     or one registered to a parent command at another address.}
#'   \item{`org_name_embedded_ambiguous`}{several eligible organizations. Stays
#'     ambiguous; nothing picks among them.}
#' }
#'
#' @section Deliberately conservative, and the reason for each rule:
#' \enumerate{
#'   \item A GENERIC name resolves nothing. "NAVAL MEDICAL CENTER" is not an
#'     organization, it is a category -- there are several, and the string alone
#'     cannot say which. A candidate name must retain at least one DISTINCTIVE
#'     token after generic tokens are removed: LANDSTUHL, WOMACK, MADIGAN,
#'     VANDERBILT. This rejects "NAVAL MEDICAL CENTER", "HOSPITAL", "ARMY".
#'   \item EXACT normalised identity, not similarity. `norm_org()` from
#'     R/lib/org_names.R keys both sides. No edit distance, no token overlap
#'     score, no "most plausible" -- the failure mode of every fuzzy name
#'     matcher this project has retired.
#'   \item FAIL-CLOSED. Exactly one eligible organization is a resolution. Two
#'     similarly-named organizations remain ambiguous even when one looks
#'     obviously right.
#'   \item GEOGRAPHIC CONTEXT is required, and reported in tiers. A name match
#'     is only accepted within the same ZIP5 or, separately, the same state. A
#'     nationally unrestricted name match would attach a midwife in Guam to a
#'     same-named hospital in Ohio.
#' }
#'
#' @section What this arm does NOT attempt:
#' Three other classes share the no-house-number property and are counted but
#' never matched, because none is a name:
#'   military postal codes with no institution ("PSC 482 BOX 53", "CMR 402");
#'   unnumbered or letter-prefixed civilian addresses ("HIGHWAY 191 AND
#'   HOSPITAL ROAD", the Wisconsin grid forms "N8150 AMUNDSON COULEE RD");
#'   mail stops, PO boxes and PERSON names ("ATTN: DQS-CR", a certificant's own
#'   name). Reporting them separately is the point -- an arm that silently
#'   returned nothing for 30 of 47 would look like a name-matching failure
#'   rather than 30 inputs that contain no name.
#'
#' Inputs : NPPES_2025 dissemination, artifacts/unresolved_affiliation_reasons.csv
#' Outputs: artifacts/embedded_org_name_yield.csv      (tracked summary)
#'          artifacts/embedded_org_name_candidates.csv (person-level, gitignored)
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
source(file.path("R", "lib", "org_names.R"))
source(file.path("R", "lib", "duckdb_guards.R"))

# The SAME vintage as diagnose_unresolved_affiliations.R. A newer file would
# make this arm's yield incomparable with the decomposition it feeds.
NPPES <- Sys.getenv("NPPES_2025",
  "/Volumes/MufflySamsung 1/nppes_historical_downloads/extracted_2025/npidata_pfile_20050523-20251109.csv")
if (!file.exists(NPPES)) stop("NPPES 2025 not found: ", NPPES, call. = FALSE)

OUT_Y <- "artifacts/embedded_org_name_yield.csv"
OUT_C <- "artifacts/embedded_org_name_candidates.csv"

# =============================================================================
# Classifying the address text
# =============================================================================

#' Does this address begin with a house number?
#'
#' Letter-prefixed grid addresses count. Wisconsin issues "N8150 AMUNDSON
#' COULEE RD" and "S34W34601 COUNTY ROAD C"; a bare `^[0-9]` test calls these
#' name-based, which sent twelve ordinary rural street addresses into a
#' name-matching arm where they can only fail.
has_house_number <- function(a) {
  a <- trimws(toupper(as.character(a)))
  grepl("^[0-9]", a) | grepl("^[NSEW][0-9]+([NSEW][0-9]+)?\\b", a)
}

# Military postal forms carrying no institution name. PSC/CMR/UNIT/BOX with
# only digits after them names a mailbox, not an employer.
MIL_POSTAL <- "^\\s*(PSC|CMR|APO|FPO|DPO|UNIT|BOX|RR|HC)\\b[^A-Z]*([0-9]|BOX|$)"

# Forms that are structurally incapable of naming an organization.
# Box and mail-stop designators are matched ANYWHERE, not anchored. The first
# version anchored them at the start, so "SCHOOL OF NURSING CBX 063" survived
# into name matching with CBX counted as a distinctive token -- a campus-box
# number reading as an organization name. Found by
# tests/test_embedded_org_name_guards.R.
NOT_A_NAME <- paste0(
  "^\\s*(PO BOX|P\\.?O\\.? BOX|ATTN)\\b|",
  "\\b(CBX|MSC|PSC|CMR|PMB|MAIL ?STOP)\\b|",
  "^\\s*(HIGHWAY|HWY|CARR|COUNTY ROAD|CR|RR|ROUTE|INTERSECTION|SOLAR)\\b|",
  "\\b(DNP|CNM|MSN|APRN|WHNP|MD|PHD)\\b")

# Generic tokens. A name made ONLY of these is a category, not an organization:
# "NAVAL MEDICAL CENTER" describes several facilities and identifies none.
GENERIC <- c(
  "HOSPITAL", "HOSPITALS", "CLINIC", "CLINICS", "MEDICAL", "MEDICINE",
  "CENTER", "CENTERS", "CENTRE", "CTR", "HEALTH", "HEALTHCARE", "CARE",
  "NAVAL", "NAVY", "ARMY", "AIR", "FORCE", "MILITARY", "MARINE", "CORPS",
  "US", "USA", "U S", "UNITED", "STATES", "NATIONAL", "REGIONAL", "FEDERAL",
  "DEPT", "DEPARTMENT", "DIVISION", "DIV", "UNIT", "SERVICE", "SERVICES",
  "OF", "THE", "AND", "AT", "FOR", "IN",
  "UNIVERSITY", "COLLEGE", "SCHOOL", "NURSING", "PROGRAM", "ASSOCIATES",
  "GROUP", "PRACTICE", "PHYSICIANS", "TREATMENT", "FACILITY", "COMMAND",
  "GENERAL", "COMMUNITY", "MEMORIAL", "REGION", "SYSTEM", "INC", "LLC")

# Military treatment facility markers, for the separate evidence label.
MIL_MARKER <- paste0(
  "\\b(ARMY|NAVAL|NAVY|AIR FORCE|USAF|MILITARY|MARINE|NMRTC|NAVHOSP|",
  "MEDDAC|MTF|WALTER REED|LANDSTUHL|LRMC|WAMC|WHASC|ACH|USNH)\\b")

#' Extract the organization-like text from an address line
#'
#' Strips a trailing street address where one is appended -- "MADIGAN ARMY
#' MEDICAL CTR 9040 JACKSON AVE" names an organization AND a street, and the
#' street belongs to the address arm, not this one. Returns `NA` when nothing
#' organization-like remains.
embedded_org_text <- function(a) {
  x <- toupper(trimws(as.character(a)))
  x <- str_replace_all(x, "[,/]", " ")
  # Drop an appended street address: the first run of digits and everything
  # after it, but only once at least two words precede it.
  x <- str_replace(x, "(?<=[A-Z]{2}\\s)\\b[0-9]+\\b.*$", "")
  # Drop trailing unit/level/room designators.
  x <- str_replace(x, "\\b(UNIT|BLDG|BUILDING|LEVEL|RM|ROOM|STE|SUITE|BOX)\\b.*$", "")
  x <- str_squish(str_replace_all(x, "[^A-Z0-9 ]", " "))
  x[!nzchar(x)] <- NA_character_
  x
}

#' Does a normalised name retain a distinctive token?
#'
#' The single most important guard in this file. Without it "NAVAL MEDICAL
#' CENTER" matches every Naval medical centre in the country and the arm
#' manufactures affiliations at scale.
has_distinctive_token <- function(key) {
  vapply(strsplit(as.character(key), "\\s+"), function(tok) {
    tok <- tok[nzchar(tok)]
    keep <- setdiff(tok, GENERIC)
    # A retained token must be a word, not a stray digit run.
    any(nchar(keep) >= 3L & grepl("^[A-Z]", keep))
  }, logical(1))
}

# =============================================================================
# Cohort
# =============================================================================
rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)
reasons <- rd("artifacts/unresolved_affiliation_reasons.csv")
cli::cli_alert_info("unresolved cohort: {format(nrow(reasons), big.mark = ',')}")

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
duckdb::duckdb_register(con, "target", reasons %>% select(npi))

SRC <- sprintf("read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)", NPPES)
LIVE <- '("NPI Deactivation Date" IS NULL OR TRIM(CAST("NPI Deactivation Date" AS VARCHAR)) = \'\'
          OR ("NPI Reactivation Date" IS NOT NULL AND TRIM(CAST("NPI Reactivation Date" AS VARCHAR)) <> \'\'))'

cli::cli_h2("Reading NPPES 2025")
mw <- dbGetQuery(con, sprintf('
  SELECT TRIM(CAST(d."NPI" AS VARCHAR)) AS npi,
         TRIM(CAST(d."Provider First Line Business Practice Location Address" AS VARCHAR)) AS addr,
         TRIM(CAST(d."Provider Business Practice Location Address Postal Code" AS VARCHAR)) AS zip,
         TRIM(CAST(d."Provider Business Practice Location Address State Name" AS VARCHAR)) AS st
  FROM %s d JOIN target t ON TRIM(CAST(d."NPI" AS VARCHAR)) = t.npi', SRC))
refuse_if_large(mw, "cohort rows")
mw$z5 <- zip5(mw$zip)

# --- stratify the no-house-number group --------------------------------------
nb <- mw %>% filter(!has_house_number(addr))
cli::cli_alert_success("cohort without a usable house number: {nrow(nb)}")

nb <- nb %>% mutate(
  org_text = embedded_org_text(addr),
  stratum = case_when(
    grepl(MIL_POSTAL, toupper(addr)) & !grepl("[A-Z]{4,}\\s+[A-Z]{4,}", toupper(addr))
                                        ~ "military_postal_no_name",
    grepl(NOT_A_NAME, toupper(addr))    ~ "not_a_name",
    is.na(org_text)                     ~ "not_a_name",
    TRUE                                ~ "name_candidate"))

# The generic guard is applied INSIDE the name_candidate stratum, so a rejected
# generic is reported as generic rather than disappearing into "not a name".
nb <- nb %>% mutate(
  org_key = if_else(stratum == "name_candidate", norm_org(org_text), NA_character_),
  stratum = case_when(
    stratum != "name_candidate"                       ~ stratum,
    is.na(org_key) | !nzchar(org_key)                 ~ "not_a_name",
    !has_distinctive_token(org_key)                   ~ "generic_name_rejected",
    TRUE                                              ~ "name_candidate"))

cli::cli_h2("Strata")
print(as.data.frame(count(nb, stratum, sort = TRUE)), row.names = FALSE)

cli::cli_h2("Name candidates")
cands <- nb %>% filter(stratum == "name_candidate")
if (!nrow(cands)) {
  cli::cli_alert_warning("no name candidates survived the guards; nothing to match")
} else {
  for (i in seq_len(nrow(cands)))
    cat(sprintf("  %-42s -> %s\n", substr(cands$addr[i], 1, 42), cands$org_key[i]))
}

# --- eligible Type-2 organizations, keyed by NAME ----------------------------
cli::cli_h2("Matching against Type-2 legal business names")
orgs <- dbGetQuery(con, sprintf('
  SELECT TRIM(CAST("NPI" AS VARCHAR)) AS org_npi,
         TRIM(CAST("Provider Organization Name (Legal Business Name)" AS VARCHAR)) AS org_name,
         SUBSTR(REGEXP_REPLACE(TRIM(CAST("Provider Business Practice Location Address Postal Code" AS VARCHAR)), \'[^0-9]\', \'\', \'g\'), 1, 5) AS z5,
         TRIM(CAST("Provider Business Practice Location Address State Name" AS VARCHAR)) AS st
  FROM %s WHERE TRIM(CAST("Entity Type Code" AS VARCHAR)) = \'2\' AND %s', SRC, LIVE))
cli::cli_alert_success("eligible Type-2 organizations: {format(nrow(orgs), big.mark = ',')}")

orgs <- orgs %>% mutate(org_key = norm_org(org_name)) %>% filter(nzchar(org_key))

# Two geographic tiers, reported separately. Never pooled: a state-level match
# is weaker evidence than a ZIP-level one and must not inherit its status.
match_tier <- function(join_cols, tier) {
  if (!nrow(cands)) return(tibble())
  cands %>% inner_join(orgs, by = join_cols, relationship = "many-to-many",
                       suffix = c("", "_org")) %>%
    group_by(npi) %>%
    summarise(tier = tier,
              n_orgs = n_distinct(org_npi),
              org_npi = if (n_distinct(org_npi) == 1L) first(org_npi) else NA_character_,
              org_name = if (n_distinct(org_npi) == 1L) first(org_name) else NA_character_,
              .groups = "drop")
}
z <- match_tier(c("org_key", "z5"), "same_zip5")
s <- match_tier(c("org_key", "st"), "same_state")

hits <- bind_rows(z, s) %>%
  left_join(cands %>% select(npi, addr, org_key, st), by = "npi") %>%
  mutate(evidence_class = case_when(
    n_orgs > 1L                     ~ "org_name_embedded_ambiguous",
    grepl(MIL_MARKER, toupper(addr)) ~ "military_facility_name_unique",
    TRUE                            ~ "org_name_embedded_unique"))

cli::cli_h2("Yield by tier and evidence class")
if (!nrow(hits)) {
  cli::cli_alert_info("no name candidate matched an eligible Type-2 organization")
  yield <- tibble(tier = NA_character_, evidence_class = NA_character_, n = 0L)
} else {
  yield <- hits %>% count(tier, evidence_class, name = "n") %>% arrange(tier, desc(n))
  print(as.data.frame(yield), row.names = FALSE)
  res <- hits %>% filter(n_orgs == 1L)
  cli::cli_alert_success("RESOLVED (exactly one eligible organization): {n_distinct(res$npi)} of {nrow(cands)} name candidates, {nrow(nb)} no-house-number cases, {nrow(reasons)} unresolved")
  if (nrow(res)) {
    cat("\n")
    print(as.data.frame(res %>% transmute(tier, evidence_class,
                                          addr = substr(addr, 1, 34),
                                          org = substr(org_name, 1, 34))),
          row.names = FALSE)
  }
  # Disagreement between tiers is a finding: a ZIP-level and a state-level match
  # naming different organizations means the geographic context is doing the
  # work, not the name.
  disagree <- hits %>% filter(n_orgs == 1L) %>% group_by(npi) %>%
    summarise(n_distinct_org = n_distinct(org_npi), n_tier = n(), .groups = "drop") %>%
    filter(n_tier > 1L, n_distinct_org > 1L)
  if (nrow(disagree))
    cli::cli_alert_warning("{nrow(disagree)} case(s) where the ZIP tier and the state tier name DIFFERENT organizations")
}

summary_out <- count(nb, stratum, name = "n") %>%
  mutate(of_no_house_number = nrow(nb), of_unresolved = nrow(reasons)) %>%
  bind_rows(yield %>% transmute(stratum = paste0("matched:", tier, ":", evidence_class),
                                n, of_no_house_number = nrow(nb),
                                of_unresolved = nrow(reasons)))
write_with_provenance(summary_out, OUT_Y, na = "", inputs = prov_inputs(NPPES))
write_with_provenance(nb %>% left_join(hits %>% select(npi, tier, evidence_class, n_orgs,
                                                       org_npi, org_name), by = "npi"),
                      OUT_C, na = "", inputs = prov_inputs(NPPES))
cli::cli_alert_success("wrote {OUT_Y} and {OUT_C}")
