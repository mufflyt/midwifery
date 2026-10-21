#!/usr/bin/env Rscript
# =============================================================================
# How well do DAC, Open Payments and NPPES agree on a midwife's address?
# =============================================================================
# Three comparisons, each a different question:
#
#   vs_nppes_same_year    DAC or Open Payments against NPPES's OWN panel for
#                         THE SAME YEAR the other source is dated to -- not
#                         today's address, which would conflate disagreement
#                         with any move that happened since.
#   open_payments_yoy     The SAME source (Open Payments), two different
#                         program years, same person: did the address Open
#                         Payments reported for her change year to year? This
#                         is the one genuinely same-source longitudinal check
#                         this repo currently has.
#   dac_vs_open_payments  Two different sources, nearest available years (DAC
#                         has one vintage, 2026; Open Payments has whichever
#                         years are in artifacts/) -- a real year gap, stated
#                         per row, not concealed by calling it "current".
#
# See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md for what
# each of these does and does not establish.
#
# Inputs : dac_midwives.csv                                  (person-level, gitignored; extract_dac_midwives.R)
#          artifacts/cohort_midwives_open_payments_general_<year>.csv (person-level, gitignored, one+ years;
#            OPEN_PAYMENTS_YEAR=<year> python3 match_open_payments_general_payments.py)
#          midwife_panel.csv                                 (person-level, gitignored; NPPES annual snapshots)
# Outputs: artifacts/dac_openpayments_vs_nppes_address_agreement.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr); library(purrr); library(cli)})
source(file.path("R", "lib", "artifact_provenance.R"))
# norm_street(): R/lib/trilliant_org_bridge.R. One normalizer, not a second
# copy -- see that file's own header for exactly why (tests/ci_hygiene.R H4
# exists for this).
source(file.path("R", "lib", "trilliant_org_bridge.R"))
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE):
# a plain distinct(.keep_all = TRUE) silently picks whichever row sorts first
# when two rows for one NPI disagree -- e.g. two Open Payments records with
# different recipient addresses that year. This errors on a real
# disagreement instead, naming it, and only dedupes rows that are identical.

OUT <- "artifacts/dac_openpayments_vs_nppes_address_agreement.csv"

stopifnot(file.exists("dac_midwives.csv"), file.exists("midwife_panel.csv"))

# Each comparable dataset reduced to the same shape: npi, state, city, zip5, street.
shape_dac <- function() {
  read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi, state = str_to_upper(str_squish(practice_state)),
              city = str_to_upper(str_squish(practice_city)),
              zip5 = str_sub(practice_zip, 1, 5),
              street = norm_street(practice_address))
}
# Open Payments is one row per payment TRANSACTION, not one row per
# recipient-year: ~37% of cohort midwives in the 2022 file have more than
# one reported address that same program year (payments from more than one
# employer/site). assert_unique_keys(dedupe = TRUE) correctly refuses to
# collapse that -- it is a real disagreement, not a duplicate -- so picking
# a single representative address per NPI-year needs an explicit, stated
# rule instead of the old distinct(.keep_all = TRUE), which silently kept
# whichever transaction happened to sort first. The rule here: the address
# combination (state, city, zip, street) reported on the MOST transactions
# that year, ties broken alphabetically for determinism.
collapse_to_modal_address <- function(d) {
  d %>%
    count(npi, recipient_state, recipient_city, recipient_zip, recipient_address, name = "n_txn") %>%
    arrange(npi, desc(n_txn), recipient_state, recipient_city, recipient_zip, recipient_address) %>%
    group_by(npi) %>%
    slice(1) %>%
    ungroup() %>%
    select(-n_txn)
}
shape_op <- function(path) {
  d <- read_csv(path, col_types = cols(.default = "c"), progress = FALSE)
  d <- collapse_to_modal_address(d)
  d <- assert_unique_keys(d, "npi", label = basename(path), dedupe = TRUE)
  tibble(npi = d$npi,
         state = str_to_upper(str_squish(d$recipient_state)),
         city = str_to_upper(str_squish(d$recipient_city)),
         zip5 = str_sub(d$recipient_zip, 1, 5),
         street = if ("recipient_address" %in% names(d)) norm_street(d$recipient_address) else NA_character_)
}

op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_years <- str_extract(op_files, "(?<=general_)[0-9]{4}")
cli::cli_alert_info("Open Payments years found: {paste(sort(op_years), collapse = ', ')}")
op <- setNames(lapply(op_files, shape_op), op_years)
dac <- shape_dac()

need_nppes_years <- union("2026", op_years)
cli::cli_alert_info("Scanning midwife_panel.csv for snapshot_year in {paste(need_nppes_years, collapse = ', ')}...")
nppes_all <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year %in% need_nppes_years)
nppes_all <- assert_unique_keys(nppes_all, c("npi", "snapshot_year"), label = "midwife_panel.csv", dedupe = TRUE) %>%
  transmute(npi, snapshot_year,
            state = str_to_upper(str_squish(practice_state)),
            city = str_to_upper(str_squish(practice_city)),
            zip5 = str_sub(practice_zip, 1, 5),
            street = norm_street(practice_address))
nppes <- function(year) nppes_all %>% filter(snapshot_year == year) %>% select(-snapshot_year)

# Two already-shaped (npi,state,city,zip5,street) tables -> one agreement row per level.
compare_two <- function(a, b, label, year_a, year_b, comparison_type, levels = c("state", "city", "zip5", "street")) {
  levels <- levels[!(levels == "street" & (all(is.na(a$street)) | all(is.na(b$street))))]
  joined <- inner_join(a, b, by = "npi", suffix = c("_a", "_b"))
  map_dfr(levels, function(lv) {
    x <- joined[[paste0(lv, "_a")]]; y <- joined[[paste0(lv, "_b")]]
    comparable <- sum(nzchar(x) & nzchar(y), na.rm = TRUE)
    agree <- sum(nzchar(x) & nzchar(y) & x == y, na.rm = TRUE)
    tibble(comparison_type = comparison_type, source_pair = label,
           year_a = year_a, year_b = year_b, level = lv,
           comparable_n = comparable, agree_n = agree,
           agree_pct = if (comparable > 0) round(100 * agree / comparable, 1) else NA_real_)
  })
}

out <- list()

# 1. vs NPPES, same year each source is dated to
out[["dac_vs_nppes"]] <- compare_two(dac, nppes("2026"), "DAC vs NPPES", "2026", "2026", "vs_nppes_same_year")
for (yr in op_years)
  out[[paste0("op_vs_nppes_", yr)]] <- compare_two(op[[yr]], nppes(yr), sprintf("Open Payments (%s) vs NPPES", yr),
                                                   yr, yr, "vs_nppes_same_year")

# 2. Open Payments year-over-year: same source, same person, different program years
# (street included: all op_years now carry recipient_address -- see match_open_payments_general_payments.py)
if (length(op_years) >= 2) {
  pairs <- combn(sort(op_years), 2, simplify = FALSE)
  for (p in pairs)
    out[[paste0("op_yoy_", p[1], "_", p[2])]] <- compare_two(
      op[[p[1]]], op[[p[2]]], sprintf("Open Payments %s vs %s", p[1], p[2]),
      p[1], p[2], "open_payments_yoy")
}

# 3. DAC vs Open Payments directly, nearest available years (a real gap -- DAC is 2026-only)
for (yr in op_years)
  out[[paste0("dac_vs_op_", yr)]] <- compare_two(dac, op[[yr]], sprintf("DAC (2026) vs Open Payments (%s)", yr),
                                                 "2026", yr, "dac_vs_open_payments")

out <- bind_rows(out)
print(as.data.frame(out), row.names = FALSE)

inputs <- c("dac_midwives.csv", "midwife_panel.csv", op_files)
write_with_provenance(out, OUT, inputs = inputs)
cli::cli_alert_success("wrote {OUT}")
