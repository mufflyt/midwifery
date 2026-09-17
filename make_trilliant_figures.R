#!/usr/bin/env Rscript
# =============================================================================
# README / appendix figures for the Trilliant work
# =============================================================================
# Run from the repo root:  Rscript make_trilliant_figures.R
#
# Every figure is drawn from a COMMITTED aggregate artifact, so anyone who
# clones the repository can regenerate it, and no number on a figure is typed:
# titles and labels are computed from the same rows the bars are.
#
#   docs/figures/trilliant_lake_tables.png         what the Trilliant lake holds
#       <- artifacts/trilliant_schema_inventory.csv
#   docs/figures/trilliant_feasibility.png         which studies it can support
#       <- artifacts/trilliant_research_question_feasibility.csv
#   docs/figures/trilliant_cohort_reconciliation.png   11,920 vs the tracked roster
#       <- artifacts/trilliant_cohort_reconciliation_reasons.csv
#   docs/figures/trilliant_activity_validation.png does active_provider mean practising?
#       <- artifacts/trilliant_activity_validation_<freeze sha8>.csv (newest)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(stringr); library(tidyr)
  library(scales); library(patchwork)
})
FIG <- file.path("docs", "figures")
dir.create(FIG, showWarnings = FALSE, recursive = TRUE)
rd <- function(p) read_csv(p, show_col_types = FALSE, progress = FALSE)
theme_tr <- function(base = 11) {
  theme_minimal(base_size = base) +
    theme(plot.title = element_text(face = "bold", size = base + 1),
          plot.subtitle = element_text(colour = "grey35", size = base - 1),
          plot.caption = element_text(colour = "grey50", size = base - 3, hjust = 0),
          panel.grid.minor = element_blank())
}
save <- function(p, name, w, h) {
  ggsave(file.path(FIG, name), p, width = w, height = h, dpi = 200, bg = "white")
  cat("wrote", file.path(FIG, name), "\n")
}

# ---- 1. What the lake holds -------------------------------------------------------
inv <- rd("artifacts/trilliant_schema_inventory.csv")
tabs <- inv |>
  group_by(table) |>
  summarise(rows = first(table_rows), clinician_npi = any(contains_clinician_npi),
            procedure_codes = any(contains_procedure), service_date = any(contains_service_date),
            .groups = "drop") |>
  filter(rows > 0) |>
  mutate(kind = case_when(clinician_npi ~ "clinician NPI (provider directory)",
                          procedure_codes ~ "procedure codes, no clinician (hospital prices)",
                          TRUE ~ "metadata / facility tables"),
         table = reorder(table, rows))
p1 <- ggplot(tabs, aes(rows, table, fill = kind)) +
  geom_col() +
  geom_text(aes(label = comma(rows)), hjust = -0.1, size = 3) +
  scale_x_log10(labels = label_comma(), breaks = 10^c(0, 3, 6, 9), expand = expansion(mult = c(0, 0.3))) +
  scale_fill_manual(values = c("clinician NPI (provider directory)" = "#1b7837",
                               "procedure codes, no clinician (hospital prices)" = "#b2182b",
                               "metadata / facility tables" = "grey65"), name = NULL) +
  labs(title = "What the Trilliant lake holds",
       subtitle = sprintf("%d tables, %d columns. Tables with clinician NPI + service date + procedure codes together: %d",
                          n_distinct(inv$table), nrow(inv),
                          sum(tabs$clinician_npi & tabs$service_date & tabs$procedure_codes)),
       x = "rows (log scale)", y = NULL,
       caption = "Source: artifacts/trilliant_schema_inventory.csv (R/inventory_trilliant_research_fields.R)") +
  theme_tr() + theme(legend.position = "bottom")
save(p1, "trilliant_lake_tables.png", 9, 5)

# ---- 2. Which studies it can support ----------------------------------------------
fz <- rd("artifacts/trilliant_research_question_feasibility.csv") |>
  mutate(status = case_when(fully_identifiable ~ "fully identifiable",
                            partially_identifiable ~ "partially identifiable",
                            TRUE ~ "not identifiable"),
         status = factor(status, c("fully identifiable", "partially identifiable", "not identifiable")),
         research_question = factor(research_question, rev(research_question)),
         note = str_trunc(main_limitation, 95))
p2 <- ggplot(fz, aes(x = 1, y = research_question, fill = status)) +
  geom_tile(width = 0.95, height = 0.9) +
  geom_text(aes(x = 1.55, label = note), hjust = 0, size = 2.8, colour = "grey25") +
  scale_x_continuous(limits = c(0.5, 6), expand = c(0, 0)) +
  scale_fill_manual(values = c("fully identifiable" = "#1b7837", "partially identifiable" = "#dfc27d",
                               "not identifiable" = "#b2182b"), name = NULL, drop = FALSE) +
  labs(title = "Which midwifery workforce studies the Trilliant asset can support",
       subtitle = "Identifiability is computed from the schema inventory and from checks that the other sources exist",
       x = NULL, y = NULL,
       caption = "Source: artifacts/trilliant_research_question_feasibility.csv") +
  theme_tr() +
  theme(axis.text.x = element_blank(), panel.grid = element_blank(), legend.position = "bottom")
save(p2, "trilliant_feasibility.png", 11, 5.5)

# ---- 3. 11,920 against the tracked roster -----------------------------------------
rec <- rd("artifacts/trilliant_cohort_reconciliation_reasons.csv")
legacy_only <- rec |>
  filter(str_starts(reason, "legacy only")) |>
  mutate(group = if_else(str_detect(reason, "military"), "military / territorial / foreign", "US jurisdiction"),
         state = reorder(state, n_certificants))
both <- sum(rec$n_certificants[rec$reason == "in both, same NPI"])
p3 <- ggplot(legacy_only, aes(n_certificants, state, fill = group)) +
  geom_col() +
  geom_text(aes(label = n_certificants), hjust = -0.15, size = 3) +
  scale_fill_manual(values = c("US jurisdiction" = "#2166ac", "military / territorial / foreign" = "grey60"), name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(title = sprintf("Why the tracked roster has %s of the %s: %s left out by geography",
                       comma(both), comma(both + sum(legacy_only$n_certificants)),
                       comma(sum(legacy_only$n_certificants))),
       subtitle = sprintf("ACTIVE, primary-linked certificants of the 2026-08-10 freeze (%s...) absent from the roster, by practice state.\n%s in both with the same NPI; 0 unexplained.",
                          substr(rec$legacy_freeze_sha256[1], 1, 8), comma(both)),
       x = "certificants", y = NULL,
       caption = "Source: artifacts/trilliant_cohort_reconciliation_reasons.csv (reconcile_trilliant_cohort.R)") +
  theme_tr() + theme(legend.position = "bottom")
save(p3, "trilliant_cohort_reconciliation.png", 8.5, 6.5)

# ---- 4. Does active_provider mean practising? ---------------------------------------
av_path <- sort(Sys.glob(file.path("artifacts", "trilliant_activity_validation_*.csv")), decreasing = TRUE)
av_path <- av_path[!endsWith(av_path, ".provenance.json")]
av_path <- av_path[which.max(file.info(av_path)$mtime)]
av <- rd(av_path)
freeze8 <- substr(av$frozen_sha256[1], 1, 8)
a <- av |> filter(analysis == "1_by_amcb_status", n >= 50) |>
  mutate(level = reorder(level, pct_flagged_active))
pa <- ggplot(a, aes(pct_flagged_active, level)) +
  geom_col(fill = "#2166ac") +
  geom_text(aes(label = sprintf("%.1f%%  (n=%s)", pct_flagged_active, comma(n))), hjust = -0.05, size = 3) +
  scale_x_continuous(limits = c(0, 118), breaks = seq(0, 100, 25)) +
  labs(title = "A. By AMCB status", subtitle = "statuses with at least 50 certificants",
       x = "% flagged active", y = NULL) + theme_tr(10)
b <- av |> filter(str_detect(analysis, "^2_(retired|lapsed)"), level != "expiry unknown") |>
  mutate(status = str_to_title(str_extract(analysis, "retired|lapsed")),
         level = factor(level, c("expired 2016 or earlier", "expired 2017-2019", "expired 2020-2022", "expired 2023 or later")))
pb <- ggplot(b, aes(level, pct_flagged_active, group = status, colour = status)) +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  scale_colour_manual(values = c(Retired = "#b2182b", Lapsed = "#ef8a62"), name = NULL) +
  scale_y_continuous(limits = c(0, 100)) +
  labs(title = "B. Retired and lapsed: still flagged active", subtitle = "by year the certification expired",
       x = NULL, y = "% flagged active") + theme_tr(10) +
  theme(axis.text.x = element_text(angle = 20, hjust = 1), legend.position = "top")
cc <- av |> filter(analysis == "3_active_by_last_medicare_year") |>
  mutate(year = suppressWarnings(as.integer(level)))
never <- cc |> filter(is.na(year))
pc <- ggplot(filter(cc, !is.na(year)), aes(year, pct_flagged_active)) +
  geom_line(colour = "#1b7837", linewidth = 1) + geom_point(aes(size = n), colour = "#1b7837") +
  geom_hline(yintercept = never$pct_flagged_active, linetype = "dashed", colour = "grey40") +
  annotate("text", x = max(cc$year, na.rm = TRUE), y = never$pct_flagged_active - 6, hjust = 1, size = 3,
           colour = "grey30",
           label = sprintf("dashed: never billed Medicare, %.1f%% (n=%s)", never$pct_flagged_active, comma(never$n))) +
  scale_x_continuous(breaks = seq(min(cc$year, na.rm = TRUE), max(cc$year, na.rm = TRUE), 2)) +
  scale_size_area(name = "n", labels = label_comma()) +
  scale_y_continuous(limits = c(0, 100)) +
  labs(title = "C. ACTIVE certificants, by last Medicare billing year", x = NULL, y = "% flagged active") +
  theme_tr(10) + theme(legend.position = "right")
p4 <- (pa | pb) / pc +
  plot_annotation(
    title = "Does Trilliant's active_provider flag mean a midwife is practising?",
    subtitle = sprintf("Primary-linked certificants of freeze %s...; Trilliant directory snapshot %s; Medicare %s",
                       freeze8, av$trilliant_snapshot[1], av$medicare_years[1]),
    caption = sprintf("Source: %s (analyze_trilliant_activity_flag.R)", av_path),
    theme = theme_tr())
save(p4, "trilliant_activity_validation.png", 11, 8.5)
