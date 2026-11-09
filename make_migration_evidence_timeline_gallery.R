#!/usr/bin/env Rscript
#' @title Figure 4: individual evidence timelines, one per classification type
#'
#' @description
#' Figures 1-3 (migration_classification_national_trends/composition/source_
#' sensitivity) are all aggregate. This is the one remaining diagnostic figure
#' from the originating specification (S13D) -- and it is necessarily
#' PERSON-LEVEL: one representative real NPI per classification type
#' (confirmed, possible, likely administrative artifact, indeterminate),
#' showing every source's actual claimed state and vintage/year near that
#' NPI's transition, so a reader can see WHY the classifier called it what it
#' called it without trusting the label.
#'
#' OUTPUT IS PERSON-LEVEL. It carries real NPIs and real per-source state
#' claims, and is written only into qa/, which is gitignored. Do not commit
#' it, publish it, or paste it into an issue or the README. Use --redact for
#' a shareable copy (NPI replaced with a seed-keyed, one-way hash via the same
#' method build_linkage_case_gallery.R already uses) -- redacted output still
#' stays in qa/, never promoted to docs/figures/, since the state/year pattern
#' itself can remain identifying even with the NPI removed.
#'
#' Reads classify_migration_moves_full_panel.R's two person-level outputs
#' (Deliverable A, the evidence table, and Deliverable B, the classification)
#' -- picks one example per target rule_id, deterministically by seed.
#'
#' Usage:
#'   Rscript make_migration_evidence_timeline_gallery.R
#'   Rscript make_migration_evidence_timeline_gallery.R --seed=20261109
#'   Rscript make_migration_evidence_timeline_gallery.R --redact
#'
#' Output: qa/migration_evidence_timelines.{pdf,png}   the figure
#'         qa/migration_evidence_timelines_cases.csv   the 4 selected cases' raw evidence, for review
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(dplyr); library(readr); library(ggplot2); library(digest); library(ggrepel)})

# tl_*-prefixed to avoid ci_hygiene H4 (duplicate top-level function names
# across files) -- build_linkage_case_gallery.R already defines gal_arg/gal_flag.
tl_arg <- function(key, default) {
  hit <- grep(paste0("^--", key, "="), commandArgs(TRUE), value = TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", key, "="), "", hit[1])
}
tl_flag <- function(key) paste0("--", key) %in% commandArgs(TRUE)

SEED <- as.integer(tl_arg("seed", "20261109"))
REDACT <- tl_flag("redact")
OUTDIR <- tl_arg("outdir", "qa")

if (!identical(OUTDIR, "qa") && !tl_flag("allow-unsafe-outdir")) {
  stop("Refusing to write person-level output outside qa/, which is gitignored.\n",
       "  qa/ is the only directory this script writes to by default. If you have\n",
       "  a reason to put it elsewhere, pass --allow-unsafe-outdir and make sure\n",
       "  the destination is ignored by git.", call. = FALSE)
}
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)

CLASSIFICATION_CSV <- file.path("artifacts", "migration_move_classification_full_panel.csv")
EVIDENCE_CSV <- file.path("artifacts", "migration_move_evidence_table.csv")
if (!file.exists(CLASSIFICATION_CSV) || !file.exists(EVIDENCE_CSV))
  stop("Missing classify_migration_moves_full_panel.R outputs -- run that script first.", call. = FALSE)

classified <- read_csv(CLASSIFICATION_CSV, col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(year_from = as.integer(year_from), year_to = as.integer(year_to),
         n_support = as.integer(n_support), n_contradict = as.integer(n_contradict))
evidence <- read_csv(EVIDENCE_CSV, col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(year = as.integer(year))

# One target rule_id per classification -- the clearest, most evidence-rich
# member of each bucket (e.g. ART-CONTRA over the weaker ART-GAP, MIXED-SPLIT
# over the abstention-driven IND-ABSTAIN), so the timeline actually shows
# cross-source evidence rather than an absence of it.
TARGETS <- tibble::tibble(
  label = c("Confirmed (held out)", "Possible", "Likely administrative artifact", "Indeterminate"),
  rule_id = c("CONF-2FAM", "POSS-SINGLE", "ART-CONTRA", "MIXED-SPLIT")
)

set.seed(SEED)
pick_one <- function(rid) {
  pool <- classified %>% filter(rule_id == rid)
  if (nrow(pool) == 0) return(NULL)
  pool[sample(nrow(pool), 1), ]
}
cases <- bind_rows(lapply(TARGETS$rule_id, pick_one))
if (nrow(cases) == 0) stop("No cases found for any target rule_id -- check classify_migration_moves_full_panel.R's output.", call. = FALSE)
cases <- cases %>% left_join(TARGETS, by = "rule_id")
cat(sprintf("Selected %d cases (seed=%d):\n", nrow(cases), SEED))
print(as.data.frame(cases %>% select(label, rule_id, npi, year_from, year_to, state_from, state_to, n_support, n_contradict)))

# Pull each case NPI's full evidence across a window around its transition,
# from EVERY source family the claims table carries (including nppes itself
# -- not used for corroboration/contradiction by the classifier, but worth
# SHOWING as the thing actually being tested).
WINDOW <- 3L
case_evidence <- bind_rows(lapply(seq_len(nrow(cases)), function(i) {
  cs <- cases[i, ]
  evidence %>% filter(npi == cs$npi, year >= cs$year_from - WINDOW, year <= cs$year_to + WINDOW) %>%
    mutate(case_label = cs$label, case_npi = cs$npi, case_year_from = cs$year_from, case_year_to = cs$year_to,
           case_state_from = cs$state_from, case_state_to = cs$state_to)
}))

write_csv(case_evidence %>% select(case_label, npi = case_npi, source_family, year, claimed_value,
                                    evidence_status, location_type, date_precision),
          file.path(OUTDIR, "migration_evidence_timelines_cases.csv"))
cat(sprintf("-> %s (%d rows, PERSON-LEVEL -- gitignored, do not commit/publish)\n",
            file.path(OUTDIR, "migration_evidence_timelines_cases.csv"), nrow(case_evidence)))

# ---- redaction (same one-way, seed-keyed hash as build_linkage_case_gallery.R) ----
case_id_map <- cases %>% distinct(npi) %>%
  mutate(case_display = if (REDACT) {
    substr(vapply(paste0(SEED, "|", npi), digest::digest, character(1), algo = "sha256"), 1, 8)
  } else npi)
case_evidence <- case_evidence %>% left_join(case_id_map, by = c("case_npi" = "npi"))
cases <- cases %>% left_join(case_id_map, by = "npi")
if (REDACT) cat("Redacted: NPI replaced with a seed-keyed hash in the figure labels.\n")

FAMILY_LABELS <- c(nppes = "NPPES", dac_pecos_combined = "DAC + PECOS", open_payments = "Open Payments",
                    tmsis_medicaid = "T-MSIS Medicaid", facility_affiliation = "Facility affiliation")

# A source can carry >1 distinct claimed_value for the same (family, year) --
# T-MSIS's documented multi-affiliation pattern is the usual cause (see
# TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md S2). Plotting each as its own
# overlapping point+label is illegible and, worse, visually implies a single
# resolved value where the classifier itself never picks one -- collapse to
# ONE point per (family, year), labeled with every distinct value joined, and
# marked "ambiguous" rather than silently keeping just one on the page.
case_evidence <- case_evidence %>%
  group_by(case_display, case_label, source_family, year, case_year_from, case_year_to, case_state_from, case_state_to) %>%
  summarise(n_vals = dplyr::n_distinct(claimed_value),
            claimed_value = paste(sort(unique(claimed_value)), collapse = "/"), .groups = "drop") %>%
  mutate(family_label = factor(FAMILY_LABELS[source_family], levels = rev(FAMILY_LABELS)),
         panel_title = sprintf("%s\ncase %s, %d→%d (%s → %s)",
                                case_label, case_display, case_year_from, case_year_to,
                                case_state_from, case_state_to),
         matches = case_when(
           n_vals > 1 ~ "ambiguous (multiple claims)",
           claimed_value == case_state_from ~ "origin state",
           claimed_value == case_state_to ~ "destination state",
           TRUE ~ "other state"
         ))

p <- ggplot(case_evidence, aes(x = year, y = family_label, color = matches)) +
  geom_vline(aes(xintercept = case_year_from - 0.5), linetype = "dashed", color = "grey70", linewidth = 0.3) +
  geom_vline(aes(xintercept = case_year_to + 0.5), linetype = "dashed", color = "grey70", linewidth = 0.3) +
  geom_point(size = 2.6) +
  ggrepel::geom_text_repel(aes(label = claimed_value), size = 2.9, show.legend = FALSE,
                            seed = SEED, min.segment.length = 0, segment.size = 0.2,
                            max.overlaps = Inf, force = 2) +
  facet_wrap(~panel_title, scales = "free_x", ncol = 2) +
  scale_color_manual(values = c("origin state" = "#4A6B8A", "destination state" = "#B4473E",
                                 "other state" = "#8A8A8A", "ambiguous (multiple claims)" = "#C9A227"), name = NULL) +
  labs(
    title = "Why the classifier called it what it called it: one example per classification",
    subtitle = sprintf("Every source's directly-observed claim within %d years of the transition (dashed lines). %s",
                        WINDOW, if (REDACT) "NPI redacted to a seed-keyed hash." else "PERSON-LEVEL -- qa/ only, not for publication."),
    x = NULL, y = NULL
  ) +
  theme_minimal(base_size = 10) +
  theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
        strip.text = element_text(face = "bold", size = 8.5))

ggsave(file.path(OUTDIR, "migration_evidence_timelines.pdf"), p, width = 11, height = 7.5,
       device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(file.path(OUTDIR, "migration_evidence_timelines.png"), p, width = 11, height = 7.5, dpi = 300, bg = "white")
cat(sprintf("-> %s{.pdf,.png} (PERSON-LEVEL%s -- gitignored, do not commit/publish)\n",
            file.path(OUTDIR, "migration_evidence_timelines"), if (REDACT) ", NPI redacted" else ""))
cat("\nDone.\n")
