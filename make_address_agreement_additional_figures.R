#!/usr/bin/env Rscript
# =============================================================================
# Four more views of the DAC / Open Payments / NPPES address comparison
# =============================================================================
# Figures A-C re-plot the existing pairwise comparison artifact
# (artifacts/dac_openpayments_vs_nppes_address_agreement.csv, written by
# compare_dac_openpayments_to_nppes_address.R) from three different angles.
# Figure D is new: it is not a replot. For midwives present in ALL THREE
# sources at once -- DAC x that year's Open Payments x that year's NPPES --
# does the city reported by all three agree, or does agreement split along
# a pairwise fault line (e.g. NPPES and DAC agree but Open Payments doesn't)?
# The pairwise table alone can't show that; it only ever compares two
# sources at a time.
#
# Inputs : artifacts/dac_openpayments_vs_nppes_address_agreement.csv (tracked)
#          dac_midwives.csv                                  (person-level, gitignored; extract_dac_midwives.R)
#          artifacts/cohort_midwives_open_payments_general_<year>.csv (person-level, gitignored)
#          midwife_panel.csv                                 (person-level, gitignored; NPPES annual snapshots)
# Outputs: docs/figures/address_agreement_heatmap.png
#          docs/figures/address_agreement_cascade.png
#          docs/figures/address_agreement_power.png
#          docs/figures/address_agreement_threeway_concordance.png
#          artifacts/dac_openpayments_nppes_threeway_city_concordance.csv (aggregate, tracked)
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
  library(purrr); library(ggplot2); library(scales); library(cli)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))

dir.create("docs/figures", showWarnings = FALSE, recursive = TRUE)

COMPARISON_LABELS <- c(
  vs_nppes_same_year = "vs. NPPES (same year)",
  open_payments_yoy = "Open Payments vs. itself",
  dac_vs_open_payments = "DAC vs. Open Payments"
)

# =============================================================================
# A-C: re-plot the existing pairwise agreement table
# =============================================================================
IN <- "artifacts/dac_openpayments_vs_nppes_address_agreement.csv"
stopifnot(file.exists(IN))
d <- read_csv(IN, show_col_types = FALSE)
d$level <- factor(d$level, levels = c("state", "city", "zip5", "street"),
                   labels = c("State", "City", "ZIP5", "Street"))

cli_alert_info("A. Heatmap: every source pair x every geographic level")
heat <- ggplot(d, aes(x = level, y = source_pair, fill = agree_pct)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = sprintf("%.0f%%", agree_pct)), size = 3) +
  facet_grid(rows = vars(comparison_type), scales = "free_y", space = "free_y",
             labeller = labeller(comparison_type = COMPARISON_LABELS)) +
  scale_fill_distiller(palette = "RdYlBu", direction = 1, limits = c(0, 100), name = "Agreement %") +
  labs(title = "Every source pair, every geographic level, one view",
       subtitle = "DAC / Open Payments / NPPES address agreement (%)",
       x = NULL, y = NULL,
       caption = "See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md for n per cell.") +
  theme_minimal(base_size = 11) +
  theme(strip.text.y = element_text(angle = 0, size = 8, face = "bold"),
        panel.grid = element_blank())
ggsave("docs/figures/address_agreement_heatmap.png", heat, width = 9, height = 6.5, dpi = 200)

cli_alert_info("B. Cascade: agreement by geographic grain, every source pair")
cascade <- ggplot(d, aes(x = level, y = agree_pct, group = source_pair, color = comparison_type)) +
  geom_line(alpha = 0.85, linewidth = 0.7) +
  geom_point(size = 1.8) +
  scale_color_brewer(palette = "Dark2", name = NULL, labels = COMPARISON_LABELS) +
  scale_y_continuous(limits = c(0, 100), expand = expansion(mult = c(0.02, 0.05))) +
  labs(title = "Agreement falls apart at finer geography -- for every source pair",
       subtitle = "Each line is one source-pair/year comparison, State through Street",
       x = NULL, y = "Agreement (%)") +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
ggsave("docs/figures/address_agreement_cascade.png", cascade, width = 9, height = 6, dpi = 200)

cli_alert_info("C. Power check: agreement vs. how many records it's based on")
power <- ggplot(d, aes(x = comparable_n, y = agree_pct, color = level, size = comparable_n)) +
  geom_point(alpha = 0.75) +
  scale_x_log10(labels = comma) +
  scale_size_continuous(range = c(2, 8), guide = "none") +
  scale_y_continuous(limits = c(0, 100)) +
  scale_color_brewer(palette = "Set1", name = "Level") +
  labs(title = "No headline number in this comparison rests on a tiny sample",
       subtitle = "Every row of the agreement table, by how many comparable records it's based on",
       x = "Comparable records (log scale)", y = "Agreement (%)") +
  theme_minimal(base_size = 12)
ggsave("docs/figures/address_agreement_power.png", power, width = 8.5, height = 6, dpi = 200)

# =============================================================================
# D: three-way concordance -- NPPES x DAC x Open Payments, same NPI, city level
# =============================================================================
# DAC has one vintage (2026); Open Payments and NPPES are matched to the same
# program year. DAC is therefore never year-matched to the other two here --
# same caveat as the pairwise DAC-vs-Open-Payments comparison. City (not
# street) is used: it is comparable across all three sources without the
# normalization dependence street-level matching has, and gives a large
# enough evaluable n to be informative.
cli_alert_info("D. Three-way concordance: NPPES x DAC x Open Payments (new computation)")

stopifnot(file.exists("dac_midwives.csv"), file.exists("midwife_panel.csv"))

dac_city <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, dac_city = str_to_upper(str_squish(practice_city))) %>%
  filter(nzchar(dac_city))

nppes_all <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE)

op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_years <- str_extract(op_files, "(?<=general_)[0-9]{4}")

# Same modal-address tie-break as compare_dac_openpayments_to_nppes_address.R's
# collapse_to_modal_address(): Open Payments is one row per payment
# transaction, so the representative address per NPI-year is the
# (state,city,zip,street) combination reported on the most transactions that
# year, ties broken alphabetically. Named differently here (not
# collapse_to_modal_address) so this isn't a second top-level definition of
# that function -- see R/lib/ci_hygiene.R H4.
modal_op_record <- function(path) {
  read_csv(path, col_types = cols(.default = "c"), progress = FALSE) %>%
    count(npi, recipient_state, recipient_city, recipient_zip, recipient_address, name = "n_txn") %>%
    arrange(npi, desc(n_txn), recipient_state, recipient_city, recipient_zip, recipient_address) %>%
    group_by(npi) %>%
    slice(1) %>%
    ungroup() %>%
    transmute(npi, op_city = str_to_upper(str_squish(recipient_city))) %>%
    filter(nzchar(op_city))
}

threeway <- map_dfr(seq_along(op_files), function(i) {
  yr <- op_years[i]
  op_city <- modal_op_record(op_files[i])
  nppes_yr <- nppes_all %>% filter(snapshot_year == yr)
  nppes_yr <- assert_unique_keys(nppes_yr, "npi", label = paste("midwife_panel.csv", yr), dedupe = TRUE) %>%
    transmute(npi, nppes_city = str_to_upper(str_squish(practice_city))) %>%
    filter(nzchar(nppes_city))
  dac_city %>%
    inner_join(op_city, by = "npi") %>%
    inner_join(nppes_yr, by = "npi") %>%
    mutate(
      op_year = yr,
      pattern = case_when(
        dac_city == op_city & op_city == nppes_city ~ "All three agree",
        nppes_city == dac_city ~ "NPPES + DAC only",
        nppes_city == op_city ~ "NPPES + Open Payments only",
        dac_city == op_city ~ "DAC + Open Payments only",
        TRUE ~ "All three differ"
      )
    )
})

PATTERN_LEVELS <- c("All three agree", "NPPES + DAC only", "NPPES + Open Payments only",
                     "DAC + Open Payments only", "All three differ")

threeway_summary <- threeway %>%
  count(op_year, pattern, name = "n") %>%
  group_by(op_year) %>%
  mutate(pct = 100 * n / sum(n), total_n = sum(n)) %>%
  ungroup() %>%
  mutate(pattern = factor(pattern, levels = PATTERN_LEVELS))

print(as.data.frame(threeway_summary), row.names = FALSE)

write_with_provenance(
  threeway_summary,
  "artifacts/dac_openpayments_nppes_threeway_city_concordance.csv",
  inputs = c("dac_midwives.csv", "midwife_panel.csv", op_files)
)

n_label <- threeway_summary %>%
  distinct(op_year, total_n) %>%
  arrange(op_year) %>%
  mutate(lab = sprintf("%s: %s", op_year, comma(total_n))) %>%
  pull(lab) %>%
  paste(collapse = ", ")

fig_d <- ggplot(threeway_summary, aes(x = op_year, y = pct, fill = pattern)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = ifelse(pct >= 3, sprintf("%.0f%%", pct), "")),
            position = position_stack(vjust = 0.5), size = 3, color = "white") +
  scale_fill_manual(values = c(
    "All three agree" = "#1b7837",
    "NPPES + DAC only" = "#5aae61",
    "NPPES + Open Payments only" = "#9970ab",
    "DAC + Open Payments only" = "#c2a5cf",
    "All three differ" = "#b2182b"
  ), name = NULL) +
  scale_y_continuous(labels = label_percent(scale = 1), expand = expansion(mult = c(0, 0.02))) +
  labs(title = "When all three sources are checked at once, who agrees with whom?",
       subtitle = "City-level, midwives present in DAC (2026), NPPES and Open Payments that year",
       x = "Open Payments program year", y = "Share of comparable midwives",
       caption = paste0(
         "n (midwives present in DAC, NPPES and Open Payments that year): ", n_label, ".\n",
         "DAC is a single 2026 vintage -- never year-matched here, same caveat as the pairwise DAC-vs-Open-Payments comparison.")) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom",
        plot.caption = element_text(size = 7, color = "grey40", hjust = 0))
ggsave("docs/figures/address_agreement_threeway_concordance.png", fig_d, width = 9, height = 6.5, dpi = 200)

cli::cli_alert_success("wrote 4 figures to docs/figures/ and artifacts/dac_openpayments_nppes_threeway_city_concordance.csv")
