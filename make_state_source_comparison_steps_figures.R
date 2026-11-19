#!/usr/bin/env Rscript
# =============================================================================
# Three figures showing HOW the cross-source comparison is built, step by step
# =============================================================================
# The published figures show the audit's RESULTS. These show its MECHANISM,
# which until now existed only as prose in the appendix's Design section --
# and the mechanism is where the 2026-11-12 defect lived: a reader who could
# see which source-years were declared, which became comparisons, and which
# were dropped on the way would have seen a one-year Open Payments series at
# a glance.
#
#   Step 1  What is DECLARED. Every source-year the audit may use, from
#           config/state_source_audit_sources.csv, with the two kinds of
#           declared absence distinguished: a year excluded by law, and a
#           year for which no file can ever exist.
#   Step 2  What became a COMPARISON. The same grid drawn from the agreement
#           artifact, so the difference between the two grids is exactly what
#           the declaration rules removed.
#   Step 3  What the comparisons SAID. Agreement and its denominator, on two
#           panels rather than two axes, because a percentage and a count do
#           not share a scale.
#
# Step 1 reads the manifest, Steps 2 and 3 read the audit's own tracked
# aggregate outputs. None of the three restates a number: if the manifest or
# the audit moves, these move with it.
#
# Output: docs/figures/comparison_step1_declared_window.{png,pdf,svg}
#         docs/figures/comparison_step2_pairs_formed.{png,pdf,svg}
#         docs/figures/comparison_step3_agreement_and_base.{png,pdf,svg}
# =============================================================================
suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(tidyr)
  library(stringr)
})

source(file.path("R", "lib", "audit_figure_style.R"))  # AUDIT_SERIES,
# gloss(), save_audit_fig() -- shared with make_state_source_audit_figures.R
# so the two scripts cannot drift on size, dpi or label fitting.
source(file.path("R", "lib", "source_coverage.R"))     # read_source_manifest()

AGREEMENT <- file.path("artifacts", "state_source_audit_agreement.csv")
MEDICAID <- file.path("artifacts",
                      "state_source_audit_medicaid_classification_by_year.csv")

# SHORT LABELS, AND A HARD STOP IF A SOURCE HAS NONE. The manifest's own
# source_name is the authority for what a source IS, but those names run to
# sixty characters and an axis tick has no room for them. This maps each
# declared source_id to the short form appendix section 2 uses. It is not a
# second inventory: it adds no source and declares no window, and
# source_label() stops the build if the manifest ever carries an id this does
# not cover, so a new source cannot appear in a figure as a blank row.
SOURCE_LABEL <- c(
  nppes                    = "NPPES (reference)",
  dac_physician_compare    = "DAC / Physician Compare",
  open_payments            = "Open Payments",
  pecos_revalidation       = "PECOS revalidation",
  facility_affiliation_ccn = "Facility affiliation (CCN)",
  healthgrades             = "Healthgrades",
  doximity                 = "Doximity",
  state_boards_of_nursing  = "State Boards of Nursing",
  cms_ndh_fhir             = "CMS NDH (FHIR)",
  medicaid_enrollment      = "Medicaid (T-MSIS)",
  medicare_claims          = "Medicare claims (Parts B and D)")

#' Short axis label for a declared source id
#'
#' @param source_id [character] ids from the manifest or the artifacts.
#' @return [character] the short labels, in the same order.
source_label <- function(source_id) {
  unknown <- setdiff(unique(source_id), names(SOURCE_LABEL))
  if (length(unknown))
    stop(sprintf(paste0("source_label(): no short label for %s. Add it to ",
                        "SOURCE_LABEL rather than letting the figure draw a ",
                        "blank row."), paste(unknown, collapse = ", ")),
         call. = FALSE)
  unname(SOURCE_LABEL[source_id])
}

# Rows are ordered by how far back the source reaches, reference standard
# first, so the staircase of coverage is the shape of the figure.
source_axis <- function(source_id) {
  factor(source_label(source_id), levels = rev(unname(SOURCE_LABEL)))
}

# ---------------------------------------------------------------------------
# Step 1: the declared window
# ---------------------------------------------------------------------------
manifest_rows <- suppressMessages(read_source_manifest())

declared <- manifest_rows %>%
  dplyr::filter(!is.na(.data$expected_year)) %>%
  dplyr::transmute(
    source_id = .data$source_id,
    year = .data$expected_year,
    # THREE DECLARED STATES, ORDERED BY WHAT THEY ARE WORTH AS EVIDENCE. A
    # year excluded by law was read and found empty on purpose; a year
    # declared unavailable has no file that could ever be read. Collapsing
    # the two would hide the distinction the manifest exists to record.
    state = dplyr::case_when(
      .data$availability_status == "unavailable" ~ "No file can exist",
      .data$availability_status == "ineligible" ~ "Read, excluded by law",
      TRUE ~ "Declared usable")) %>%
  dplyr::distinct()

# One shade per state, and a GLYPH as well, so the three are told apart
# without relying on fill: an ordinal blue ramp for the two that carry
# evidence, a neutral for the one that cannot.
DECLARED_FILL <- c("Declared usable" = "#1c5cab",
                   "Read, excluded by law" = "#86b6ef",
                   "No file can exist" = "#e2e1dc")
DECLARED_GLYPH <- c("Declared usable" = "", "Read, excluded by law" = "\u2013",
                    "No file can exist" = "×")
DECLARED_INK <- c("Declared usable" = "white",
                  "Read, excluded by law" = "#0d366b",
                  "No file can exist" = "#52514e")

declared$state <- factor(declared$state, levels = names(DECLARED_FILL))
year_breaks <- seq(min(declared$year), max(declared$year), by = 2L)

step1 <- ggplot(declared, aes(x = .data$year, y = source_axis(.data$source_id),
                              fill = .data$state)) +
  geom_tile(colour = "white", linewidth = 0.9) +
  geom_text(aes(label = DECLARED_GLYPH[as.character(.data$state)],
                colour = .data$state), size = 3.1, show.legend = FALSE) +
  scale_fill_manual(values = DECLARED_FILL, name = NULL, drop = FALSE) +
  scale_colour_manual(values = DECLARED_INK, guide = "none") +
  scale_x_continuous(breaks = year_breaks, expand = expansion(add = 0.5)) +
  labs(
    title = "Step 1. The window is declared before any file is opened",
    subtitle = paste("Every source-year the audit may use, from",
                     "config/state_source_audit_sources.csv.",
                     "A blank cell was never declared."),
    x = NULL, y = NULL,
    caption = paste0(
      "\u2013 = read and excluded by a stated scientific decision; ",
      "× = no file for that year can ever carry a state. ",
      "Declaring the two apart is what stops a gap in the source from ",
      "reading as a year nobody noticed was missing",
      gloss("NPPES", "DAC", "PECOS", "CCN", "NDH", "FHIR"))) +
  theme_minimal(base_size = 13) +
  theme(panel.grid = element_blank(),
        legend.position = "top",
        axis.text.y = element_text(hjust = 1))

save_audit_fig(step1, "comparison_step1_declared_window", height = 5.0)

# ---------------------------------------------------------------------------
# Step 2: which declared years actually became comparisons
# ---------------------------------------------------------------------------
agreement_rows <- readr::read_csv(AGREEMENT,
                                  col_types = readr::cols(.default = "c"),
                                  progress = FALSE)

# A CURRENT-ONLY SOURCE CARRIES A LABEL, NOT A YEAR. Its `year` field reads
# "2026-10 (bulk pull; ...)", so the integer is taken from the first four
# characters and the basis is kept, because the two are compared differently:
# a same-year row is matched to the registry's own snapshot for that year, a
# current-only row to the registry's most recent snapshot whatever year the
# source was gathered.
compared <- agreement_rows %>%
  dplyr::transmute(
    source_id = .data$source,
    # THE FIRST FOUR CHARACTERS ARE NOT THE YEAR. Healthgrades' label reads
    # "~2026-10 (scrape, undated per-record)", so substr(1, 4) gave "~202",
    # NA, and the source silently vanished from the figure -- a row missing
    # from a coverage grid is exactly the failure this audit is about.
    year = suppressWarnings(as.integer(
      stringr::str_extract(.data$year, "\\d{4}"))),
    basis = dplyr::if_else(.data$comparison_basis == "current_only",
                           "Matched to the current registry snapshot",
                           "Matched to the registry's own year"),
    n_comparable = as.numeric(.data$n_comparable),
    pct_agree = as.numeric(.data$pct_agree)) %>%
  dplyr::filter(!is.na(.data$year))

# Medicaid is compared, but by classification rather than by a percentage, so
# it earns its own basis instead of being left out of a figure about which
# years are compared at all.
medicaid_rows <- readr::read_csv(MEDICAID,
                                 col_types = readr::cols(.default = "c"),
                                 progress = FALSE)
medicaid_years <- sort(unique(as.integer(medicaid_rows$year)))
compared <- dplyr::bind_rows(compared, tibble::tibble(
  source_id = "medicaid_enrollment", year = medicaid_years,
  basis = "Classified per provider-year, not a percentage",
  n_comparable = NA_real_, pct_agree = NA_real_))

# The reference standard is drawn too: it is the one row every comparison
# above is formed against, and leaving it out would make the grid look like
# nine independent series.
compared <- dplyr::bind_rows(compared, tibble::tibble(
  source_id = "nppes",
  year = sort(unique(as.integer(
    manifest_rows$expected_year[manifest_rows$source_id == "nppes"]))),
  basis = "The reference standard itself",
  n_comparable = NA_real_, pct_agree = NA_real_))

BASIS_FILL <- c(
  "The reference standard itself" = "#0d366b",
  "Matched to the registry's own year" = "#2a78d6",
  "Matched to the current registry snapshot" = "#d2551f",
  "Classified per provider-year, not a percentage" = "#0f8f62")
compared$basis <- factor(compared$basis, levels = names(BASIS_FILL))

step2 <- ggplot(compared, aes(x = .data$year,
                              y = source_axis(.data$source_id),
                              fill = .data$basis)) +
  geom_tile(colour = "white", linewidth = 0.9) +
  scale_fill_manual(values = BASIS_FILL, name = NULL, drop = FALSE) +
  scale_x_continuous(breaks = year_breaks, expand = expansion(add = 0.5)) +
  guides(fill = guide_legend(ncol = 2, byrow = TRUE)) +
  labs(
    title = "Step 2. A comparison forms only where both sides carry a state",
    subtitle = paste("The same grid, drawn from the audit's own output.",
                     "What Step 1 declared and this does not show is",
                     "exactly what the declaration rules removed."),
    x = NULL, y = NULL,
    caption = paste0(
      "Three sources are matched to the registry's most recent snapshot ",
      "because they have no per-record date. Doximity has one, but every ",
      "matched row falls in 2026, so it is a single snapshot too and the ",
      "four together can support no claim about change over time",
      gloss("NPPES", "DAC", "PECOS", "CCN", "NDH", "FHIR"))) +
  theme_minimal(base_size = 13) +
  theme(panel.grid = element_blank(),
        legend.position = "top",
        axis.text.y = element_text(hjust = 1))

save_audit_fig(step2, "comparison_step2_pairs_formed", height = 5.2)

# ---------------------------------------------------------------------------
# Step 3: what the comparisons said, and on how many records
# ---------------------------------------------------------------------------
# TWO PANELS, NOT TWO AXES. A percentage and a record count do not share a
# scale, and a second y-axis invites the reader to see a crossing that is an
# artefact of where the two were anchored. Only the five sources with a
# multi-year series appear: a single snapshot has no trend to draw.
multi_year <- compared %>%
  dplyr::filter(.data$basis == "Matched to the registry's own year") %>%
  dplyr::group_by(.data$source_id) %>%
  dplyr::filter(dplyr::n() >= 3L) %>%
  dplyr::ungroup()

trend_panels <- multi_year %>%
  dplyr::transmute(
    source_id = .data$source_id, year = .data$year,
    # SHORT ENOUGH FOR THE PANEL IT IS ROTATED INTO. fit_plot_labels()
    # measures the title, subtitle and caption; a facet strip is neither, and
    # the first draft's "Agreement with the reference standard (%)" was drawn
    # taller than its own panel and published reading "eement with the
    # reference standard". The subtitle carries the full sense instead.
    `Agreement (%)` = .data$pct_agree,
    `Records compared (000s)` = .data$n_comparable / 1000) %>%
  tidyr::pivot_longer(cols = -c("source_id", "year"),
                      names_to = "panel", values_to = "value") %>%
  dplyr::filter(!is.na(.data$value))

series_levels <- c("dac_physician_compare", "facility_affiliation_ccn",
                   "medicare_claims", "open_payments", "pecos_revalidation")
# HUE FOLLOWS THE SOURCE, NEVER ITS RANK. Assigned by this fixed order, so
# dropping a series cannot repaint the ones that remain.
series_colours <- stats::setNames(AUDIT_SERIES[seq_along(series_levels)],
                                  source_label(series_levels))
trend_panels$series <- factor(source_label(trend_panels$source_id),
                              levels = names(series_colours))

last_points <- trend_panels %>%
  dplyr::group_by(.data$panel, .data$series) %>%
  dplyr::slice_max(.data$year, n = 1, with_ties = FALSE) %>%
  dplyr::ungroup()

step3 <- ggplot(trend_panels, aes(x = .data$year, y = .data$value,
                                  colour = .data$series)) +
  geom_line(linewidth = 0.9) +
  geom_point(size = 1.6) +
  geom_text(data = last_points,
            aes(label = .data$series), hjust = 0, nudge_x = 0.35,
            size = 3.1, show.legend = FALSE) +
  scale_colour_manual(values = series_colours, name = NULL) +
  scale_x_continuous(breaks = year_breaks,
                     expand = expansion(mult = c(0.02, 0.28))) +
  facet_wrap(~ .data$panel, ncol = 1, scales = "free_y",
             strip.position = "left") +
  labs(
    title = "Step 3. The comparison, and the base it rests on",
    subtitle = paste("Agreement and its denominator on separate panels.",
                     "A rate and a count share no scale, so they are never",
                     "drawn against two axes."),
    x = NULL, y = NULL,
    caption = paste0(
      "The five sources with a multi-year series. Reading the upper panel ",
      "without the lower one invites a trend claim that the number of ",
      "records compared may not support",
      gloss("DAC", "PECOS", "CCN"))) +
  theme_minimal(base_size = 13) +
  theme(legend.position = "none",
        strip.placement = "outside",
        strip.text.y.left = element_text(angle = 90, size = 10),
        panel.grid.minor = element_blank(),
        panel.spacing.y = unit(1.1, "lines"))

save_audit_fig(step3, "comparison_step3_agreement_and_base", height = 6.2)

cat("done\n")
