#!/usr/bin/env Rscript
#' @title Figure: state board licensure, where a board was actually queried
#'
#' @description
#' Replaces artifacts/plots/plot1_scraped_bon_state_volumes.png, which drew
#' per-state row counts of a synthetic 20-state "scrape" under the subtitle
#' "Total Verified Certified Nurse-Midwives Scraped Across 20 State BONs
#' (N = 9,037)". No board was queried for it.
#'
#' This draws only the three states where a board's own open-data file was
#' queried -- WA DOH, Colorado DORA, the Texas BON -- and shows, for the
#' midwives each query covered, whether a licence came back and what status
#' the board reported. Everything else is absent from the figure because it is
#' absent from the evidence.
#'
#' THE THREE BARS ARE NOT THE SAME POPULATION. Washington's query ran over the
#' tracked roster (ACTIVE, primary-linked, 2026-08-10 freeze); Colorado's and
#' Texas's over every roster row whose NPPES state is CO or TX in the current
#' freeze, whatever its AMCB status. The subtitle says so, and the counts file
#' carries the cohort beside each number.
#'
#' Output: docs/figures/board_licensure_observed.png
#'         docs/figures/board_licensure_observed_counts.csv (+ provenance)
#'
#' @family figures

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

FILES <- c(
  WA = "artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv",
  CO = "artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv",
  TX = "artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv")
COHORT <- c(
  WA = "tracked roster (ACTIVE, primary-linked, 2026-08-10 freeze), NPPES state WA",
  CO = "current FROZEN linkage, NPPES state CO, any AMCB status",
  TX = "current FROZEN linkage, NPPES state TX, any AMCB status")
BOARD <- c(WA = "WA DOH", CO = "Colorado DORA", TX = "Texas BON")
# The board's own words for a licence in force. Anything else it returned
# (Expired, Inactive, ...) is reported as "other status", never dropped.
IN_FORCE <- c("Active", "CURRENT")

OUT_PNG <- file.path("docs", "figures", "board_licensure_observed.png")
OUT_CSV <- file.path("docs", "figures", "board_licensure_observed_counts.csv")

LEVELS <- c("Licence returned, in force", "Licence returned, other status",
            "No name match", "Ambiguous name, not assigned")

counts <- bind_rows(lapply(names(FILES), function(st) {
  read_csv(FILES[[st]], col_types = cols(.default = col_character()),
           na = character(), progress = FALSE) %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    mutate(state = st,
           outcome = case_when(
             live_bon_match_status == "VERIFIED_LIVE_BON" & live_bon_status %in% IN_FORCE ~ LEVELS[1],
             live_bon_match_status == "VERIFIED_LIVE_BON" ~ LEVELS[2],
             live_bon_match_status == "AMBIGUOUS" ~ LEVELS[4],
             TRUE ~ LEVELS[3]))
})) %>%
  count(state, outcome, name = "n") %>%
  group_by(state) %>%
  mutate(queried = sum(n)) %>%
  ungroup() %>%
  mutate(board = unname(BOARD[state]), cohort = unname(COHORT[state]),
         outcome = factor(outcome, levels = LEVELS))
stopifnot(!anyNA(counts$outcome))

write_with_provenance(counts %>% arrange(state, outcome), OUT_CSV, inputs = unname(FILES))

totals <- counts %>% distinct(state, board, queried) %>%
  left_join(counts %>% filter(outcome %in% LEVELS[1:2]) %>%
              group_by(state) %>% summarise(returned = sum(n), .groups = "drop"),
            by = "state") %>%
  mutate(label = sprintf("%s\n%s (%s of %s)", state, board,
                         format(returned, big.mark = ","), format(queried, big.mark = ",")))
counts <- counts %>% left_join(totals %>% select(state, label), by = "state")

INK <- "#0b0b0b"; MUT <- "#52514e"; RULE <- "#e4e3df"
FILL <- setNames(c("#2a78d6", "#eb6834", "#c3c2b7", "#4a3aa7"), LEVELS)

p <- ggplot(counts, aes(x = n, y = label, fill = outcome)) +
  geom_col(width = 0.6, colour = "white", linewidth = 0.5,
           position = position_stack(reverse = TRUE)) +
  scale_fill_manual(values = FILL, drop = FALSE, name = NULL) +
  guides(fill = guide_legend(nrow = 2)) +
  scale_x_continuous(labels = scales::comma, expand = expansion(mult = c(0, 0.04))) +
  labs(
    title = sprintf("State board licensure was observed in %d of 51 jurisdictions",
                    n_distinct(counts$state)),
    subtitle = paste0(
      "Midwives each query covered, by what the board's open-data file returned (distinct certificants).\n",
      "WA covers the tracked roster (ACTIVE, primary-linked, 2026-08-10 freeze); CO and TX cover every\n",
      "roster row with that NPPES state in the current freeze. Matched by name. No other board was queried."),
    x = "Midwives", y = NULL,
    caption = "Sources: data.wa.gov qxh8-f4bd; data.colorado.gov 7s5z-vewr; data.texas.gov jnzg-cr4w") +
  theme_minimal(base_size = 10) +
  theme(panel.grid.minor = element_blank(), panel.grid.major.y = element_blank(),
        panel.grid.major.x = element_line(colour = RULE, linewidth = .3),
        axis.text = element_text(colour = INK), axis.title = element_text(colour = MUT, size = 9),
        plot.title = element_text(face = "bold", size = 11.5, colour = INK),
        plot.subtitle = element_text(colour = MUT, size = 8.5, lineheight = 1.15),
        plot.caption = element_text(colour = MUT, size = 7.5),
        legend.position = "bottom", legend.text = element_text(colour = INK, size = 8.5),
        plot.background = element_rect(fill = "white", colour = NA))

ggsave(OUT_PNG, p, width = 8, height = 3.8, dpi = 300, bg = "white")
cat(sprintf("written: %s\nwritten: %s\n", OUT_PNG, OUT_CSV))
print(counts %>% select(state, outcome, n, queried), n = Inf)
