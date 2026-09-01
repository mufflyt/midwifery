#!/usr/bin/env Rscript
#' @title Figure: which name rule actually carried each accepted match
#'
#' @description
#' The linkage is reported as one number, 66.2%, and the strata figure shows
#' where records stopped. Neither says what the accepted matches actually rest
#' on. This does: every accepted link, split by the evidence class that carried
#' it, so a reader can see how much of the cohort is held up by an exact name
#' with a corroborating middle name and how much by a surname plus one letter.
#'
#' @section Why this figure and not a candidate-universe one:
#' The candidate universe is dominated by class 3 -- 76% of all pairs, and the
#' source of the 348-way ties -- but almost none of it survives ranking, so a
#' figure of the pool describes work discarded rather than evidence relied on.
#' What licenses a downstream claim is the class of the match that was ACCEPTED.
#'
#' Person-level input, aggregate output: the figure and its backing CSV carry
#' counts only, so both are publishable.
#'
#' Output: docs/figures/evidence_class_accepted.{pdf,png,svg}
#'         artifacts/accepted_by_evidence_class.csv
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(tidyr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

CROSSWALK <- local({
  a <- grep("^--crosswalk=", commandArgs(TRUE), value = TRUE)
  if (length(a)) sub("^--crosswalk=", "", a[1])
  else file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
})
OUT <- file.path("docs", "figures", "evidence_class_accepted")
CSV <- file.path("artifacts", "accepted_by_evidence_class.csv")

if (!file.exists(CROSSWALK))
  stop("Frozen crosswalk not found at ", CROSSWALK, "\n",
       "  It is person-level and gitignored, so a fresh clone does not have it.\n",
       "  Rebuild with match_amcb_to_npi.R, or pass --crosswalk=<path>.", call. = FALSE)

x <- read_csv(CROSSWALK, show_col_types = FALSE, guess_max = 50000)
message(sprintf("read %s rows", format(nrow(x), big.mark = ",")))

# Accepted = an NPI was recorded. Quarantined and unmatched rows carry none and
# are out of frame here by construction; the strata figure is where they live.
acc <- x %>%
  filter(!is.na(.data$npi), nzchar(as.character(.data$npi)),
         !is.na(.data$name_evidence_class))

CLASS <- tibble::tribble(
  ~name_evidence_class, ~label,                                   ~conf,
  1L, "Exact surname and given name,\nmiddle name agrees",          1.00,
  2L, "Exact surname and given name,\nno usable middle name",       0.90,
  3L, "Exact surname, FIRST INITIAL only\n(given names differ)",    0.70,
  4L, "Surname within 2 edits,\nexact given name",                  0.50,
  5L, "Shared surname component,\nexact given name",                0.35
)

by_class <- acc %>%
  count(.data$name_evidence_class, name = "n") %>%
  right_join(CLASS, by = "name_evidence_class") %>%
  mutate(n = coalesce(.data$n, 0L),
         pct = 100 * .data$n / sum(.data$n),
         cls = factor(.data$name_evidence_class, levels = 5:1))

# Taxonomy split within each class: a class-3 accept that is also nursing-only
# is two sensitivity decisions stacked, and that is worth seeing separately.
by_tax <- acc %>%
  mutate(tax = if_else(.data$npi_match_status == "matched",
                       "Midwifery taxonomy", "Nursing taxonomy")) %>%
  count(.data$name_evidence_class, .data$tax, name = "n") %>%
  left_join(CLASS, by = "name_evidence_class") %>%
  mutate(cls = factor(.data$name_evidence_class, levels = 5:1))

stopifnot(sum(by_class$n) == nrow(acc), sum(by_tax$n) == nrow(acc))

INK <- "#111820"; MUT <- "#5b6875"; RULE <- "#c8d0d9"
PAL <- c("Midwifery taxonomy" = "#1f6360", "Nursing taxonomy" = "#7fb3ae")

ecf_theme <- function() {
  theme_minimal(base_size = 10) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.y = element_blank(),
          panel.grid.major.x = element_line(colour = RULE, linewidth = .3),
          axis.title = element_text(colour = MUT, size = 9),
          axis.text = element_text(colour = INK, lineheight = 1.2),
          plot.title = element_text(face = "bold", size = 12, colour = INK),
          plot.subtitle = element_text(colour = MUT, size = 9, lineheight = 1.2),
          plot.caption = element_text(colour = MUT, size = 7.5, hjust = 0,
                                      lineheight = 1.35, margin = margin(t = 16)),
          plot.title.position = "plot", plot.caption.position = "plot",
          legend.position = "top", legend.title = element_blank(),
          legend.text = element_text(colour = INK, size = 8.5))
}

p <- ggplot(by_tax, aes(n, cls, fill = tax)) +
  geom_col(width = .66) +
  geom_text(data = by_class, aes(x = n, y = cls,
                                 label = sprintf("%s  (%.1f%%)",
                                                 scales::comma(n), pct)),
            inherit.aes = FALSE, hjust = -0.08, size = 3.1,
            fontface = "bold", colour = INK) +
  scale_y_discrete(drop = FALSE,
                   labels = setNames(CLASS$label, CLASS$name_evidence_class)) +
  scale_fill_manual(values = PAL) +
  scale_x_continuous(labels = scales::label_comma(),
                     expand = expansion(mult = c(0, .22))) +
  labs(title = "What the accepted matches actually rest on",
       subtitle = paste0(
         scales::comma(nrow(acc)), " accepted links, by the evidence class that ",
         "carried each one. Classes are ordered, not scored:\na record resolves ",
         "only when exactly ONE candidate sits at its strongest available class."),
       x = "Accepted matches",
       caption = paste0(
         "Confidence attached to each class in the resolver: ",
         paste(sprintf("class %d = %.2f", CLASS$name_evidence_class, CLASS$conf),
               collapse = " · "), ".\n",
         "Class 3 is a first-initial rule, NOT a nickname dictionary -- same ",
         "surname, same first letter, different given name. It generates 76% of\n",
         "the candidate universe and the widest ties (348-way on one SMITH), so ",
         "what survives ranking here is a small remainder of a large pool.\n",
         "A nursing-taxonomy accept at class 3 or below is two sensitivity ",
         "decisions stacked. Source: ", CROSSWALK)) +
  ecf_theme() +
  theme(axis.title.y = element_blank())

dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)
ggsave(paste0(OUT, ".pdf"), p, width = 9.6, height = 6.2, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 9.6, height = 6.2, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 9.6, height = 6.2),
         error = function(e) NULL)

out <- by_tax %>%
  select(name_evidence_class, evidence = label, taxonomy = tax, n) %>%
  mutate(evidence = gsub("\n", " ", .data$evidence)) %>%
  arrange(.data$name_evidence_class, .data$taxonomy)
write_with_provenance(out, CSV, inputs = CROSSWALK)

message("\naccepted matches by class:")
for (i in seq_len(nrow(by_class)))
  message(sprintf("  class %d  %6s  %5.1f%%  %s",
                  by_class$name_evidence_class[i],
                  format(by_class$n[i], big.mark = ","), by_class$pct[i],
                  gsub("\n", " ", by_class$label[i])))
message(sprintf("\nwrote %s.{pdf,png,svg} and %s", OUT, CSV))
