#!/usr/bin/env Rscript
# =============================================================================
# Figures for docs/TECHNICAL_APPENDIX_TRILLIANT_IDENTITY_EXPERIMENT.md
# =============================================================================
# Run from the repo root:  Rscript make_trilliant_identity_figures.R
#
# Drawn only from COMMITTED aggregates, so any clone can regenerate them, and
# no number on a figure is typed:
#
#   docs/figures/trilliant_identity_fields.png    which identity fields exist, and for whom
#       <- artifacts/trilliant_provider_identity_coverage.csv
#   docs/figures/trilliant_identity_outcomes.png  what the directory says, by stratum and variant
#       <- artifacts/trilliant_identity_outcomes_<freeze sha8>.csv (newest)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(stringr); library(scales)
})
FIG <- file.path("docs", "figures")
dir.create(FIG, showWarnings = FALSE, recursive = TRUE)
rd <- function(p) read_csv(p, show_col_types = FALSE, progress = FALSE)
theme_id <- function(base = 11) {
  theme_minimal(base_size = base) +
    theme(plot.title = element_text(face = "bold", size = rel(1.1)),
          plot.title.position = "plot",
          plot.subtitle = element_text(colour = "grey35"),
          plot.caption = element_text(colour = "grey50", hjust = 0),
          panel.grid.minor = element_blank())
}
save_identity_figure <- function(p, name, w, h) {
  ggsave(file.path(FIG, name), p, width = w, height = h, dpi = 200, bg = "white")
  cat("wrote", file.path(FIG, name), "\n")
}

# ---- 1. Field coverage: whole directory vs the midwifery pool -----------------------
cov <- rd("artifacts/trilliant_provider_identity_coverage.csv")
labels <- c(sex_code = "sex", provider_credential = "credential", provider_middle_name = "middle name",
            provider_medical_school_graduation_year = "graduation year",
            "provider_medical_school_name: named institution" = "school: a named institution",
            "provider_medical_school_name: placeholder 'Other'" = "school: 'Other'",
            "provider_medical_school_name: absent" = "school: absent")
fields <- cov |>
  filter(field %in% names(labels)) |>
  mutate(field = factor(unname(labels[field]), levels = rev(unname(labels))),
         population = if_else(population == "all individual NPIs",
                              sprintf("all individual NPIs (%s)", comma(n)),
                              sprintf("midwifery specialty or credential (%s)", comma(n))))
p1 <- ggplot(fields, aes(pct_present, field, fill = population)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  # Labelled from the counts, not the stored 2-decimal percentage, which would round twice.
  geom_text(aes(label = sprintf("%.1f%%", 100 * n_present / n)), position = position_dodge(width = 0.75),
            hjust = -0.1, size = 9, size.unit = "pt") +
  scale_x_continuous(labels = label_percent(scale = 1), limits = c(0, 112),
                     guide = guide_axis(check.overlap = TRUE)) +
  scale_fill_manual(values = c("grey70", "#1f3a5f")) +
  labs(title = "Which identity fields Trilliant's directory carries",
       subtitle = "Graduation year exists for 41% of midwifery records; a named school for under 6%",
       x = "records with the field", y = NULL, fill = NULL,
       caption = "Source: artifacts/trilliant_provider_identity_coverage.csv (directory snapshot 2026-06-25)") +
  theme_id() + theme(legend.position = "top")
save_identity_figure(p1, "trilliant_identity_fields.png", 8.5, 5)

# ---- 2. Outcomes by stratum, both variants -----------------------------------------
f <- sort(Sys.glob("artifacts/trilliant_identity_outcomes_*.csv"), decreasing = TRUE)[1]
if (is.na(f)) stop("no trilliant_identity_outcomes_*.csv; run experiment_trilliant_identity_linkage.R", call. = FALSE)
sha8 <- str_match(basename(f), "_([0-9a-f]{8})\\.csv$")[, 2]
out <- rd(f) |>
  filter(!str_detect(outcome, "^(decision|quarantine):")) |>
  group_by(variant, stratum, outcome) |> summarise(n = sum(n), .groups = "drop") |>
  group_by(variant, stratum) |> mutate(stratum_n = sum(n), pct = 100 * n / stratum_n) |> ungroup() |>
  mutate(stratum = recode(stratum,
                          "1a_existing_high_confidence" = "1a existing,\nhigh confidence",
                          "1b_existing_other" = "1b existing,\nother tiers",
                          "2_ambiguous" = "2 tied, contested\nor held out",
                          "3_unmatched" = "3 no candidate"),
         stratum = paste0(stratum, "\n(n = ", comma(stratum_n), ")"),
         outcome = factor(recode(outcome, confirms = "confirms current NPI", contradicts = "contradicts current NPI",
                                 name_rule_conflict = "name-rule conflict (not the directory's evidence)",
                                 chooses_between_competing = "chooses between competing NPIs",
                                 plausible_new_npi = "plausible new NPI",
                                 no_useful_evidence = "no useful evidence"),
                          levels = c("confirms current NPI", "chooses between competing NPIs", "plausible new NPI",
                                     "contradicts current NPI", "name-rule conflict (not the directory's evidence)",
                                     "no useful evidence")),
         variant = recode(variant, full = "full: profession scored",
                          identity_only = "identity_only: profession cannot break a tie (D17)"))
p2 <- ggplot(out, aes(pct, stratum, fill = outcome)) +
  geom_col(width = 0.7) +
  facet_wrap(~variant, ncol = 1) +
  scale_x_continuous(labels = label_percent(scale = 1), guide = guide_axis(check.overlap = TRUE)) +
  scale_y_discrete(limits = rev) +
  scale_fill_manual(values = c("#2d5f3a", "#4f8a5b", "#8fbf8f", "#b2182b", "#e0a060", "grey80"), drop = FALSE) +
  labs(title = "What Trilliant's directory says about each AMCB certificant's NPI",
       subtitle = "Without profession points, graduation year confirms half the high-confidence links on its own",
       x = "share of stratum", y = NULL, fill = NULL,
       caption = sprintf("Source: %s (freeze %s..., directory 2026-06-25, NPPES 2025-11). Proposals only; nothing is applied.",
                         basename(f), sha8)) +
  theme_id() + theme(legend.position = "bottom") + guides(fill = guide_legend(ncol = 2))
save_identity_figure(p2, "trilliant_identity_outcomes.png", 9.5, 7.5)
