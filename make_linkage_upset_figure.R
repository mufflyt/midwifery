#!/usr/bin/env Rscript
#' @title Figure: the linkage strata as a ladder of properties
#'
#' @description
#' The cohort flow figure shows where records went. This shows *why* each group
#' stopped where it did, by naming the properties a record must accumulate to
#' reach the analytic cohort and marking which ones each stratum actually has.
#'
#' Ported from `create_registry_upset_figure()` in mufflyt/grace-ent
#' (scripts/ent_registry_7_figures.R:1152), which pairs a bar panel with a dot
#' matrix rather than using UpSetR or ComplexUpset. Two departures, both forced
#' by the data rather than chosen:
#'
#'   - grace-ent's sets are three *registries* a physician may appear in, and its
#'     strata are their intersections. Here there is one registry, so the sets
#'     are the five properties the resolver tests in order. The dot matrix is
#'     consequently a staircase, not a lattice -- each stratum has a strict
#'     prefix of the properties above it, and that monotonicity IS the finding.
#'   - grace-ent's second label is "Audited: n", the telephone-audit subsample.
#'     The analogue here is ACTIVE certificants, the subset every workforce claim
#'     is really about.
#'
#' Two strata share a dot pattern -- tied names and unruled-out component are
#' indistinguishable on these five properties. That is not a defect in the
#' figure. It is the README's point that the 5,411 unresolved are several
#' different things wearing one label, made visible.
#'
#' Output: docs/figures/linkage_strata_upset.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(tidyr); library(patchwork)
})

SRC <- file.path("artifacts", "linkage_completeness_by_status.csv")
OUT <- file.path("docs", "figures", "linkage_strata_upset")

if (!file.exists(SRC)) stop("Missing ", SRC, call. = FALSE)
raw <- read_csv(SRC, show_col_types = FALSE)

# ---- the strata, in ladder order ------------------------------------------
# `col` is the column in the source table; `outcome` drives colour; the five
# logical columns are the properties a record must hold to sit in that stratum.
# Property assignments follow docs/TECHNICAL_APPENDIX_RECORD_LINKAGE.md:
# contested records ARE uniquely resolved individually and are pruned only by
# the one-to-one constraint (sec. 5), which is why they sit above tied names.
STRATA <- tibble::tribble(
  ~col,                                  ~label,                    ~outcome,
  "matched",                             "Matched",                 "In analytic cohort",
  "matched_nursing_taxonomy",            "Nursing taxonomy only",   "In analytic cohort",
  "candidate_class5_held_out_of_cohort", "Class 5 held out",        "Quarantined",
  "ambiguous_contested_npi",             "Contested NPI",           "Quarantined",
  "ambiguous_tied_names",                "Tied names",              "Quarantined",
  "ambiguous_unruled_out_component",     "Unruled-out component",   "Quarantined",
  "unmatched",                           "No candidate",            "No candidate"
) |>
  mutate(
    `Candidate in NPPES`     = col != "unmatched",
    `Single at best class`   = col %in% c("matched", "matched_nursing_taxonomy",
                                          "candidate_class5_held_out_of_cohort",
                                          "ambiguous_contested_npi"),
    `Survives one-to-one`    = col %in% c("matched", "matched_nursing_taxonomy",
                                          "candidate_class5_held_out_of_cohort"),
    `Midwifery taxonomy`     = col == "matched",
    `In analytic cohort`     = col %in% c("matched", "matched_nursing_taxonomy"))

# Order matters and is not cosmetic: the sets are nested, each strictly
# contained in the one above (candidate 20,201 > single 17,149 > one-to-one
# 17,054 > cohort 16,898 > midwifery 14,764). Listing midwifery taxonomy before
# cohort membership would break that, because the cohort deliberately admits
# nursing-taxonomy matches -- and the matrix would then show a connecting line
# passing through an empty dot, asserting a containment that does not hold.
SETS <- c("Candidate in NPPES", "Single at best class", "Survives one-to-one",
          "In analytic cohort", "Midwifery taxonomy")

counts <- raw |>
  select(status, all_of(STRATA$col)) |>
  pivot_longer(-status, names_to = "col", values_to = "n") |>
  group_by(col) |>
  summarise(total_n = sum(n),
            active_n = sum(n[status == "ACTIVE"]), .groups = "drop") |>
  right_join(STRATA, by = "col") |>
  mutate(label = factor(label, levels = STRATA$label),
         outcome = factor(outcome, levels = c("In analytic cohort", "Quarantined",
                                              "No candidate")))

roster <- sum(raw$n)
stopifnot(sum(counts$total_n) == roster)   # the strata must partition the roster
message(sprintf("Strata partition %s roster records across %d strata.",
                format(roster, big.mark = ","), nrow(counts)))

# ---- palette and theme -----------------------------------------------------
# Okabe-Ito, carried over from grace-ent: colourblind-safe, and the three
# outcomes also differ in lightness so the panel survives greyscale.
PAL <- c("In analytic cohort" = "#009E73", "Quarantined" = "#E69F00",
         "No candidate" = "#CC79A7")
INK <- "#111820"; MUT <- "#5b6875"; RULE <- "#c8d0d9"

ups_theme <- function() {
  theme_minimal(base_size = 10) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(),
          panel.grid.major.y = element_line(colour = RULE, linewidth = .3),
          axis.title = element_text(colour = MUT, size = 9),
          axis.text = element_text(colour = INK),
          plot.title = element_text(face = "bold", size = 12, colour = INK),
          plot.subtitle = element_text(colour = MUT, size = 9, lineheight = 1.15),
          plot.caption = element_text(colour = MUT, size = 7.5, hjust = 0,
                                      lineheight = 1.2),
          plot.title.position = "plot", plot.caption.position = "plot",
          legend.position = "top", legend.title = element_blank(),
          legend.text = element_text(colour = INK, size = 8.5))
}

# ---- bar panel -------------------------------------------------------------
bars <- ggplot(counts, aes(label, total_n, fill = outcome)) +
  geom_col(width = .68) +
  geom_text(aes(label = scales::comma(total_n)), vjust = -.45,
            fontface = "bold", size = 3.2, colour = INK) +
  geom_label(aes(y = 0, label = paste0("ACTIVE: ", scales::comma(active_n))),
             vjust = 1.15, size = 2.6, linewidth = .18, fill = "white",
             colour = MUT) +
  scale_fill_manual(values = PAL) +
  scale_y_continuous(labels = scales::label_comma(),
                     expand = expansion(mult = c(.10, .16))) +
  labs(title = "What each linkage stratum has, and what it lacks",
       subtitle = paste0("All ", scales::comma(roster), " AMCB certificants. The strata ",
                         "partition the roster exactly; each loses one more property\n",
                         "than the one to its left. Bar labels are totals; boxed labels ",
                         "are the actively certified subset."),
       y = "Certificants") +
  ups_theme() +
  theme(axis.title.x = element_blank(), axis.text.x = element_blank(),
        plot.margin = margin(5.5, 5.5, 0, 5.5))

# ---- dot matrix ------------------------------------------------------------
matrix_long <- counts |>
  select(label, outcome, all_of(SETS)) |>
  pivot_longer(all_of(SETS), names_to = "set", values_to = "member") |>
  mutate(set = factor(set, levels = rev(SETS)))

spine <- matrix_long |>
  filter(member) |>
  group_by(label) |>
  summarise(lo = min(as.integer(set)), hi = max(as.integer(set)), .groups = "drop") |>
  filter(hi > lo)

dots <- ggplot(matrix_long, aes(label, set)) +
  geom_point(aes(colour = member), size = 3.4, show.legend = FALSE) +
  geom_segment(data = spine, inherit.aes = FALSE,
               aes(x = label, xend = label, y = lo, yend = hi),
               colour = INK, linewidth = .55) +
  geom_point(data = filter(matrix_long, member), aes(label, set),
             colour = INK, size = 3.4) +
  scale_colour_manual(values = c(`TRUE` = INK, `FALSE` = RULE)) +
  labs(caption = paste0(
    "Properties are tested in order; a stratum holds a strict prefix of them, so the ",
    "matrix is a staircase rather than a lattice.\n",
    "Tied names and unruled-out component share a pattern: they are indistinguishable ",
    "on these five properties, which is why\n",
    "reporting the 5,411 unresolved as one number hides four different causes. ",
    "Contested NPIs resolve uniquely and are pruned\n",
    "by the one-to-one constraint, so they sit above tied names. ",
    "Source: artifacts/linkage_completeness_by_status.csv")) +
  ups_theme() +
  theme(axis.title = element_blank(),
        axis.text.x = element_text(angle = 22, hjust = 1, size = 8.5),
        panel.grid.major.y = element_line(colour = RULE, linewidth = .2),
        plot.margin = margin(0, 5.5, 5.5, 5.5))

fig <- bars / dots + plot_layout(heights = c(2.1, 1))

dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)
ggsave(paste0(OUT, ".pdf"), fig, width = 9, height = 7.6, device = cairo_pdf)
ggsave(paste0(OUT, ".png"), fig, width = 9, height = 7.6, dpi = 300, bg = "white")
ok <- tryCatch({ ggsave(paste0(OUT, ".svg"), fig, width = 9, height = 7.6); TRUE },
               error = function(e) FALSE)
message("Wrote ", OUT, ".{pdf,png", if (ok) ",svg" else "", "}")
