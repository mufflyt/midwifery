#!/usr/bin/env Rscript
# =============================================================================
# What is actually behind an interior Medicare billing gap?
# =============================================================================
# audit_billing_gaps_vs_registry_status.R established that 27.1% of Part D
# midwives have an interior gap and that NPI deactivation explains 0% of
# them. It did not establish what DOES. This tests the leading hypothesis
# against the data rather than asserting it, and stratifies every gap by
# whether another dated source shows the midwife working during it.
#
# THE TWO THRESHOLDS ARE NOT THE SAME RULE, verified empirically on the files
# themselves rather than assumed:
#
#   Part D  admits a prescriber on CLAIMS: min(Tot_Clms) = 11. The
#           beneficiary cell is suppressed SEPARATELY -- 132,957 of
#           1,240,595 rows in 2019 (10.7%) are present in the file with a
#           BLANK Tot_Benes. So a midwife can be in Part D with >= 11 claims
#           and fewer than 11 beneficiaries.
#   Part B  admits on BENEFICIARIES AND SERVICES: min(Tot_Benes) = 11,
#           min(Tot_Srvcs) = 11.
#
# Using Tot_Benes as the Part D inclusion criterion would therefore test the
# wrong threshold. Part D volume is read as Tot_Clms here.
#
# WHAT THIS CANNOT SHOW. A midwife below the threshold is invisible, so the
# claim count in the gap year is unobservable by construction -- that is what
# a suppression threshold means. The test available is indirect: if
# suppression drives gaps, midwives who disappear should sit close to the
# threshold in the years on either side, and midwives far above it should
# rarely disappear. That is a gradient, not a proof, and it is reported as
# one.
#
# NOTHING HERE MEANS "LEFT THE WORKFORCE." The subject is intermittent
# OBSERVED Medicare billing. A midwife may bill no Medicare at all, bill
# under an organization's NPI, move to a Medicaid-dominant or commercial
# caseload, or change employment setting, and remain in full practice
# throughout.
#
# Inputs : artifacts/cohort_midwives_part_d_state_by_year.csv
#          artifacts/cohort_midwives_part_b_state_by_year.csv
#          artifacts/medicaid_enrollment_cohort_state_by_year.csv
#          Part D by-provider CSVs + warehouse medicare_part_d_{2022,2023}
# Outputs: artifacts/part_d_cohort_volume_by_year.csv
#          artifacts/billing_gap_mechanism.csv
#          artifacts/billing_gap_mechanism_summary.csv
#          artifacts/billing_gap_denominator_decomposition.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "billing_gaps.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

PART_D   <- "artifacts/cohort_midwives_part_d_state_by_year.csv"
PART_B   <- "artifacts/cohort_midwives_part_b_state_by_year.csv"
MEDICAID <- "artifacts/medicaid_enrollment_cohort_state_by_year.csv"
# CMS's published floor. Used only to BAND observed volume; nothing is
# imputed below it, because below it nothing is observable.
CMS_FLOOR <- 11L

#' Part D claim and beneficiary volume per cohort NPI-year
#'
#' @param con [DBIConnection] DuckDB with `cohort_npi` present.
#' @return [data.frame] npi, year, tot_clms, tot_benes. tot_benes is NA where
#'   CMS suppressed the cell, which is information and is kept as NA rather
#'   than zero.
part_d_volume <- function(con) {
  src <- function(y) {
    if (y %in% 2022:2023) {
      tb <- sprintf("medicare_part_d_%d", y)
      ok <- nrow(DBI::dbGetQuery(con, sprintf(
        "SELECT 1 FROM duckdb_tables() WHERE table_name=%s",
        DBI::dbQuoteString(con, tb)))) > 0L
      if (!ok) return(NULL)
      return(DBI::dbQuoteIdentifier(con, tb))
    }
    p <- samsung_volume_path(file.path("medicare_part_d_by_provider",
           sprintf("part_d_by_provider_%d.csv", y)), must_exist = FALSE)
    if (is.na(p) || !file.exists(p)) return(NULL)
    sprintf("read_csv(%s, all_varchar = true)", DBI::dbQuoteString(con, p))
  }
  out <- lapply(2013:2024, function(y) {
    s <- src(y)
    if (is.null(s)) { base::message(sprintf("  %d absent", y)); return(NULL) }
    r <- DBI::dbGetQuery(con, sprintf("
      SELECT trim(CAST(t.Prscrbr_NPI AS VARCHAR)) AS npi,
             TRY_CAST(t.Tot_Clms AS BIGINT)  AS tot_clms,
             TRY_CAST(t.Tot_Benes AS BIGINT) AS tot_benes
        FROM %s t JOIN cohort_npi c
          ON trim(CAST(t.Prscrbr_NPI AS VARCHAR)) = c.npi", s))
    if (!nrow(r)) return(NULL)
    r$year <- as.integer(y)
    base::message(sprintf("  %d  %s rows, %.1f%% with a suppressed bene cell",
                          y, format(nrow(r), big.mark = ","),
                          100 * mean(is.na(r$tot_benes))))
    r
  })
  dplyr::bind_rows(out)
}

if (sys.nframe() == 0L) {
  rd <- function(p) readr::read_csv(p, col_types = readr::cols(.default = "c"),
                                    progress = FALSE)
  pd <- rd(PART_D) %>% transmute(npi = trimws(npi), year = as.integer(year)) %>%
    distinct()
  pb <- rd(PART_B) %>% transmute(npi = trimws(npi), year = as.integer(year)) %>%
    distinct()
  mc <- if (file.exists(MEDICAID))
    rd(MEDICAID) %>% transmute(npi = trimws(npi), year = as.integer(year)) %>%
      distinct() else NULL

  con <- duckdb_connect(resolve_midwifery_duckdb(), read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "cohort_npi", data.frame(npi = unique(pd$npi)),
                    temporary = TRUE, overwrite = TRUE)
  base::message("Part D volume by year:")
  vol <- part_d_volume(con)
  write_with_provenance(vol, "artifacts/part_d_cohort_volume_by_year.csv",
                        inputs = PART_D, na = "")

  ep <- gap_episodes(pd)
  # Volume in the year immediately before and after each gap.
  before <- vol %>% transmute(npi, year_before = year,
                              clms_before = tot_clms, benes_before = tot_benes)
  after  <- vol %>% transmute(npi, year_after = year,
                              clms_after = tot_clms, benes_after = tot_benes)
  ep <- ep %>%
    mutate(year_before = gap_start - 1L, year_after = gap_end + 1L) %>%
    left_join(before, by = c("npi", "year_before")) %>%
    left_join(after,  by = c("npi", "year_after")) %>%
    mutate(
      gap_len_band = dplyr::case_when(gap_len == 1L ~ "1 year",
                                      gap_len == 2L ~ "2 years",
                                      TRUE ~ "3+ years"),
      # Bands are of OBSERVED claims in the flanking year. "11-15" is the
      # band adjacent to the floor: a midwife here needs to lose very little
      # volume to drop out of the file entirely.
      clms_before_band = dplyr::case_when(
        is.na(clms_before)        ~ "unknown",
        clms_before < CMS_FLOOR   ~ "below floor (unexpected)",
        clms_before <= 15         ~ "11-15 (adjacent to floor)",
        clms_before <= 30         ~ "16-30",
        clms_before <= 100        ~ "31-100",
        TRUE                      ~ "100+"))

  # INDEPENDENT EVIDENCE OF ACTIVITY DURING THE GAP. For each episode, does
  # another dated source place her anywhere during the missing years?
  yrs_in_gap <- function(a, b) Map(seq.int, a, b)
  gap_years <- yrs_in_gap(ep$gap_start, ep$gap_end)
  in_src <- function(src, npi_v, yl) {
    if (is.null(src)) return(rep(NA, length(npi_v)))
    key <- paste(src$npi, src$year)
    vapply(seq_along(npi_v), function(i)
      any(paste(npi_v[i], yl[[i]]) %in% key), logical(1))
  }
  ep$active_part_b_during_gap  <- in_src(pb, ep$npi, gap_years)
  ep$enrolled_medicaid_during_gap <- in_src(mc, ep$npi, gap_years)
  # NAMING MATTERS HERE. Part B is BILLING -- a claim was paid. Medicaid is
  # ENROLMENT -- she was registered to bill, which is not the same as having
  # billed. The spec is explicit that registry presence and documented
  # billing be kept apart, so they are reported separately and the combined
  # flag is named for the weaker of the two.
  ep$any_independent_evidence <- (ep$active_part_b_during_gap %in% TRUE) |
                                 (ep$enrolled_medicaid_during_gap %in% TRUE)

  summ <- ep %>%
    group_by(gap_len_band, clms_before_band) %>%
    summarise(n_episodes = n(),
              median_clms_before = suppressWarnings(median(clms_before, na.rm = TRUE)),
              pct_any_evidence_elsewhere = round(100 * mean(any_independent_evidence), 1),
              .groups = "drop") %>%
    arrange(gap_len_band, desc(n_episodes))

  # DENOMINATOR DECOMPOSITION. The Part B-or-D rate is LOWER than Part D
  # alone, which is counter-intuitive until the two populations are
  # separated: adding Part B adds midwives who never appear in Part D, and
  # it can also fill or create gaps in those who do.
  both <- distinct(bind_rows(pd, pb))
  ep_both <- gap_episodes(both)
  only_pb <- setdiff(unique(pb$npi), unique(pd$npi))
  dec <- tibble::tibble(
    quantity = c("midwives in Part D",
                 "midwives in Part B or Part D",
                 "midwives added by Part B (never in Part D)",
                 "Part D midwives with an interior gap",
                 "Part B-or-D midwives with an interior gap",
                 "Part-B-only midwives with an interior gap",
                 "Part D gaps FILLED by Part B activity",
                 "single-year episodes (Part D)",
                 "midwives with only one observed year (cannot have a gap)"),
    n = c(dplyr::n_distinct(pd$npi),
          dplyr::n_distinct(both$npi),
          length(only_pb),
          dplyr::n_distinct(ep$npi),
          dplyr::n_distinct(ep_both$npi),
          dplyr::n_distinct(ep_both$npi[ep_both$npi %in% only_pb]),
          sum(ep$active_part_b_during_gap %in% TRUE),
          sum(ep$gap_len == 1L),
          sum(table(pd$npi) == 1L)))

  # A midwife observed in only one year CANNOT have an interior gap. Leaving
  # her in the denominator understates the rate among those at risk of one.
  eligible <- sum(table(pd$npi) >= 2L)
  dec <- dplyr::bind_rows(dec, tibble::tibble(
    quantity = c("midwives ELIGIBLE for a gap (>=2 observed years)",
                 "gap rate among eligible midwives (%)"),
    n = c(eligible, round(100 * dplyr::n_distinct(ep$npi) / eligible, 1))))

  # BASELINE the suppression gradient needs. "45% of gaps follow a year with
  # 11-15 claims" means nothing without knowing what share of ALL observed
  # midwife-years sit in that band.
  base_band <- vol %>%
    mutate(band = dplyr::case_when(
      is.na(tot_clms)      ~ "unknown",
      tot_clms <= 15       ~ "11-15 (adjacent to floor)",
      tot_clms <= 30       ~ "16-30",
      tot_clms <= 100      ~ "31-100",
      TRUE                 ~ "100+")) %>%
    count(band, name = "all_npi_years") %>%
    mutate(pct_of_all = round(100 * all_npi_years / sum(all_npi_years), 1))
  gap_band <- ep %>% count(clms_before_band, name = "gap_episodes") %>%
    mutate(pct_of_gaps = round(100 * gap_episodes / sum(gap_episodes), 1))
  grad <- dplyr::full_join(base_band, gap_band,
                           by = c("band" = "clms_before_band")) %>%
    mutate(enrichment = round(pct_of_gaps / pct_of_all, 2))
  write_with_provenance(grad,
    "artifacts/billing_gap_volume_gradient.csv", inputs = PART_D, na = "")
  cat("\n=== is a gap more likely just above the floor? (enrichment > 1 = yes) ===\n")
  print(as.data.frame(grad), row.names = FALSE)

  write_with_provenance(ep, "artifacts/billing_gap_mechanism.csv",
                        inputs = c(PART_D, PART_B), na = "")
  write_with_provenance(summ, "artifacts/billing_gap_mechanism_summary.csv",
                        inputs = c(PART_D, PART_B), na = "")
  write_with_provenance(dec,
    "artifacts/billing_gap_denominator_decomposition.csv",
    inputs = c(PART_D, PART_B), na = "")

  cat("\n=== claims in the year BEFORE the gap, by gap length ===\n")
  print(as.data.frame(summ), row.names = FALSE)
  cat("\n=== independent evidence DURING the gap (Part B = billed; Medicaid = enrolled) ===\n")
  print(as.data.frame(ep %>% group_by(gap_len_band) %>%
    summarise(n = n(),
              pct_part_b_BILLED = round(100 * mean(active_part_b_during_gap %in% TRUE), 1),
              pct_medicaid_ENROLLED = round(100 * mean(enrolled_medicaid_during_gap %in% TRUE), 1),
              pct_any = round(100 * mean(any_independent_evidence), 1),
              .groups = "drop")), row.names = FALSE)
  cat("\n=== denominator decomposition ===\n")
  print(as.data.frame(dec), row.names = FALSE)
}
