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
#' Two strata share a dot pattern, and the reason is worth the figure on its
#' own: the 156 class-5 hold-outs and the 8 "unruled-out component" rows are the
#' same situation booked under two different status strings, which is visible
#' here and stated nowhere else.
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
# Labels say what happened to the person, not what the column is called. The
# column names are the artifact's vocabulary, not a reader's, and "Class 5 held
# out" or "Unruled-out component" tells a co-author nothing about what the
# matcher did. Column names are kept in `col` and mapped in the caption so the
# figure is still traceable to the CSV.
STRATA <- tibble::tribble(
  ~col,                                  ~label,                            ~outcome,
  "matched",
  "Midwifery taxonomy\non the NPI record",                                            "In analytic cohort",
  "matched_nursing_taxonomy",
  "Nursing taxonomy\non the NPI record",                           "In analytic cohort",
  "candidate_class5_held_out_of_cohort",
  "Only part of the\nsurname matched",                                      "Quarantined",
  "ambiguous_unruled_out_component",
  "Same, recorded a\nsecond way",                                           "Quarantined",
  "ambiguous_contested_npi",
  "Two certificants\nclaim one NPI",                                        "Quarantined",
  "ambiguous_tied_names",
  "Several people\nshare the name",                                         "Quarantined",
  "unmatched",
  "No name match in\nthe search pool",                                           "No candidate"
) |>
  mutate(
    `A name rule found at least\none candidate in the pool` = col != "unmatched",
    # ambiguous_unruled_out_component sits with the class-5 hold-outs, not with
    # the tied names. match_amcb_to_npi.R:700 assigns it from
    # npi_demoted_absence_c5, and its ambiguity_flag (line 745) reads
    # "class5_survived_only_by_carrying_no_middle_initial" -- a class-5
    # candidate that was the sole survivor because it carried no middle initial
    # for the veto to act on. The comment at line 690 says these 8 are "the same
    # situation" as the 156, "recorded two different ways".
    #
    # An earlier version of this figure grouped it with the tied names, on the
    # strength of the gloss in manuscript/R/build_stats_catalog.R:127 -- "a
    # connected group the bijection could not decompose". That gloss describes a
    # different thing entirely and contradicts the code that assigns the value.
    # The assigning code wins.
    `Exactly one candidate at\nthe best evidence class` = col %in% c("matched", "matched_nursing_taxonomy",
                                          "candidate_class5_held_out_of_cohort",
                                          "ambiguous_unruled_out_component",
                                          "ambiguous_contested_npi"),
    `No rival certificant\nclaims that same NPI` = col %in% c("matched", "matched_nursing_taxonomy",
                                          "candidate_class5_held_out_of_cohort",
                                          "ambiguous_unruled_out_component"),
    `That NPI carries a\nmidwifery taxonomy code` = col == "matched",
    `Counted in the\nanalytic cohort` = col %in% c("matched", "matched_nursing_taxonomy"))

# Order matters and is not cosmetic: the sets are nested, each strictly
# contained in the one above (candidate 20,201 > single 17,149 > one-to-one
# 17,054 > cohort 16,898 > midwifery 14,764). Listing midwifery taxonomy before
# cohort membership would break that, because the cohort deliberately admits
# nursing-taxonomy matches -- and the matrix would then show a connecting line
# passing through an empty dot, asserting a containment that does not hold.
SETS <- c("A name rule found at least\none candidate in the pool",
          "Exactly one candidate at\nthe best evidence class",
          "No rival certificant\nclaims that same NPI",
          "Counted in the\nanalytic cohort",
          "That NPI carries a\nmidwifery taxonomy code")

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
                                      lineheight = 1.35,
                                      margin = margin(t = 22)),
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
                         "are the actively certified subset.\n",
                         "Every certificant here is a midwife: columns 1 and 2 differ by ",
                         "how the NPI was registered, not by profession."),
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
    "matrix is a staircase rather than a lattice. Candidates come from name rules\n",
    "alone -- the roster carries no address and no date of birth -- searching a panel restricted to midwifery and nursing\ntaxonomies, so a certificant enumerated outside that panel is indistinguishable here from one who is absent.\n",
    "Columns 3 and 4 carry an IDENTICAL pattern because they are the same thing ",
    "recorded twice: both are class-5 candidates\n",
    "held out of the cohort, 156 booked as held-out and 8 as ambiguous. ",
    "The 8 differ only in having carried no middle initial\n",
    "for the veto to act on. Reporting the 5,411 unresolved as one number hides ",
    "causes as different as these.\n\n",
    "Columns, left to right, as named in the source: matched \u00b7 ",
    "matched_nursing_taxonomy \u00b7 candidate_class5_held_out_of_cohort \u00b7\n",
    "ambiguous_unruled_out_component \u00b7 ambiguous_contested_npi \u00b7 ",
    "ambiguous_tied_names \u00b7 unmatched. ",
    "Source: artifacts/linkage_completeness_by_status.csv")) +
  ups_theme() +
  theme(axis.title = element_blank(),
        axis.text.x = element_text(angle = 0, hjust = .5, size = 8,
                                   lineheight = 1.25, colour = INK,
                                   margin = margin(t = 7, b = 4)),
        panel.grid.major.y = element_line(colour = RULE, linewidth = .2),
        plot.margin = margin(0, 5.5, 10, 5.5))

fig <- bars / dots + plot_layout(heights = c(2.1, 1))

dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)
ggsave(paste0(OUT, ".pdf"), fig, width = 10, height = 8.6, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), fig, width = 10, height = 8.6, dpi = 300, bg = "white")
ok <- tryCatch({ ggsave(paste0(OUT, ".svg"), fig, width = 10, height = 8.6); TRUE },
               error = function(e) FALSE)
message("Wrote ", OUT, ".{pdf,png", if (ok) ",svg" else "", "}")
