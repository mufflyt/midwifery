#!/usr/bin/env Rscript
#' @title How much of the linkage gap is a matching failure, and how much is a registry boundary
#'
#' @description
#' The study reports linkage at 66.2% and treats the remainder as a limitation
#' of the matching. Part of it is not. NPPES began enumerating providers in
#' 2006-2008; a certificant who qualified in 1995 and lapsed in 2003 never held
#' an NPI, and no name matching recovers a record that was never created.
#'
#' Those are different failures and they license different claims. A matching
#' shortfall could in principle be fixed and its direction is unknown. A
#' registry-coverage boundary cannot be fixed from these data at all, and it
#' falls almost entirely on people who had already left the workforce -- which
#' is precisely the population a workforce estimate is not about.
#'
#' @section What this does not do:
#' It does not measure whether an individual certificant ever had an NPI; that
#' is unobservable here. It compares linkage across certification era and
#' status, and the comparison is informative because era and status vary
#' independently. If the gap were a matching failure, certifying before 2006
#' would depress linkage for everyone. It does not.
#'
#' Person-level input, gitignored. The artifact written is aggregate: counts and
#' percentages by era and status.
#'
#' Output: artifacts/linkage_coverage_floor.csv
#'
#' @family linkage
#' @concept selection
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

LINK <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
OUT  <- file.path("artifacts", "linkage_coverage_floor.csv")

if (!file.exists(LINK))
  stop(sprintf(paste0("%s is absent. It is the person-level frozen linkage, ",
                      "gitignored by design; this runs where the pipeline has run."), LINK),
       call. = FALSE)

# NPPES enumeration opened in 2006. The threshold is the registry's start date,
# not a quantile of this roster -- a data-driven cut would make the comparison
# circular, since the thing being tested is whether the registry's own start
# date explains the gap.
NPPES_START <- 2006L

d <- read_csv(LINK, show_col_types = FALSE, progress = FALSE,
              col_types = cols(.default = col_character())) |>
  distinct(certification_number, .keep_all = TRUE) |>
  mutate(
    # AMCB writes MM/YYYY. Parsing the year positionally would silently return
    # NA for every row and hand back a table of zeroes that still looks valid.
    cert_year = suppressWarnings(as.integer(sub("^\\d{2}/", "", certification_date))),
    era = case_when(is.na(cert_year)        ~ "unknown",
                    cert_year < NPPES_START ~ "pre_nppes",
                    TRUE                    ~ "nppes_era"),
    # Linked means found in NPPES at all. The cross-taxonomy rule that keeps a
    # nursing-only match out of the primary cohort is a cohort decision, not a
    # statement about whether the person was locatable, and folding it in here
    # would count a successful match as a coverage failure.
    is_linked = .data$npi_match_status %in% c("matched", "matched_nursing_taxonomy"),
    never_found = .data$npi_match_status == "unmatched")

if (all(is.na(d$cert_year)))
  stop("INVARIANT: no certification year parsed. The date format has moved and every rate below would be computed on an empty stratum.",
       call. = FALSE)

res <- d |>
  group_by(era, status) |>
  summarise(n = n(), linked = sum(is_linked), never_found = sum(never_found),
            pct_linked = 100 * mean(is_linked), .groups = "drop") |>
  arrange(desc(n))

overall <- d |>
  group_by(era) |>
  summarise(status = "ALL", n = n(), linked = sum(is_linked),
            never_found = sum(never_found), pct_linked = 100 * mean(is_linked),
            .groups = "drop")

out <- bind_rows(overall, res) |> arrange(era, desc(n))

message("--- linkage by certification era and status ---")
print(as.data.frame(out |> filter(n >= 100) |> mutate(pct_linked = round(pct_linked, 1))),
      row.names = FALSE)

act <- d |> filter(status == "ACTIVE")
message(sprintf("\nACTIVE certificants: %s pre-NPPES linked %.1f%%, %s NPPES-era linked %.1f%%",
                format(sum(act$era == "pre_nppes"), big.mark = ","),
                100 * mean(act$is_linked[act$era == "pre_nppes"]),
                format(sum(act$era == "nppes_era"), big.mark = ","),
                100 * mean(act$is_linked[act$era == "nppes_era"])))

write_with_provenance(out, OUT, inputs = LINK)
message("\nwritten: ", OUT)
