#!/usr/bin/env Rscript
#' @title Figure: what the unused temporal signal can and cannot see
#'
#' @description
#' D17 asks whether a certification-date-versus-first-seen-year comparison may
#' separate candidates tied at the strongest evidence class, and at what grace
#' period. This figure is the evidence for the first half of that question --
#' the VALIDATION half, over matches already accepted -- and it is drawn so the
#' two facts that decide it cannot be missed.
#'
#' Panel A is the censoring. The panel opens in 2007 and NPPES began enumerating
#' in 2006, so an NPI first seen in the earliest snapshot may have enumerated
#' before it. Those rows are a BOUND, not a date, and no grace period can ever
#' make them informative. They are drawn in neutral gray because they are absent
#' information rather than a category competing with the other one.
#'
#' Panel B is the reason the default flags nothing. `lead_years` is
#' `cert_year - first_seen_year`: positive means the NPI appeared BEFORE the
#' certification, which is the direction that would be suspicious. The
#' distribution tops out at +17, and the shipped default grace is 25 -- above
#' every observed value -- so the measurement cannot flag a single record at its
#' own default no matter what the data said.
#'
#' Panel C sweeps the grace period so the trade is visible as a curve rather
#' than as one number.
#'
#' @section Why lead_years is mostly negative:
#' An RN enumerates for an NPI years before she certifies as a midwife, so the
#' normal career order puts first-seen BEFORE certification and the median lead
#' at -1. Only a long POSITIVE lead is informative, which is why the grace
#' period is one-sided and why a generous default was chosen in the first place.
#'
#' Person-level input, aggregate output: the figure and its backing CSV carry
#' counts only, so both are publishable.
#'
#' Output: docs/figures/temporal_plausibility.{pdf,png,svg}
#'         artifacts/temporal_plausibility_grace_sweep.csv
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(patchwork)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "amcb_resolver.R"))   # amcb_certification_year()

tpf_arg <- function(k, d) {
  h <- grep(paste0("^--", k, "="), commandArgs(TRUE), value = TRUE)
  if (length(h)) sub(paste0("^--", k, "="), "", h[1]) else d
}
CROSSWALK <- tpf_arg("crosswalk", file.path("artifacts", "amcb_npi_linkage_FROZEN.csv"))
PANEL     <- tpf_arg("panel", "midwife_panel.csv")
GRACE_DEF <- as.numeric(tpf_arg("grace", "25"))
OUT <- file.path("docs", "figures", "temporal_plausibility")
CSV <- file.path("artifacts", "temporal_plausibility_grace_sweep.csv")

for (f in c(CROSSWALK, PANEL))
  if (!file.exists(f))
    stop("Missing ", f, "\n",
         "  Person-level and gitignored, so a fresh clone does not have it.\n",
         "  Run on the machine holding the panel and the frozen crosswalk.",
         call. = FALSE)

x <- read_csv(CROSSWALK, show_col_types = FALSE, guess_max = 50000)
p <- read_csv(PANEL, show_col_types = FALSE, guess_max = 50000,
              col_select = any_of(c("npi", "snapshot_year")))
message(sprintf("crosswalk %s rows | panel %s rows",
                format(nrow(x), big.mark = ","), format(nrow(p), big.mark = ",")))

PANEL_MIN <- min(p$snapshot_year, na.rm = TRUE)

first_seen <- p %>%
  filter(!is.na(.data$npi), !is.na(.data$snapshot_year)) %>%
  group_by(.data$npi) %>%
  summarise(first_seen_year = min(.data$snapshot_year), .groups = "drop") %>%
  mutate(left_censored = .data$first_seen_year == PANEL_MIN)

cert_year <- amcb_certification_year

acc <- x %>%
  filter(!is.na(.data$npi), nzchar(as.character(.data$npi))) %>%
  mutate(cert_year = cert_year(.data$certification_date)) %>%
  left_join(first_seen, by = "npi") %>%
  mutate(lead_years = .data$cert_year - .data$first_seen_year)

assessable <- acc %>% filter(!is.na(.data$lead_years), !.data$left_censored)
n_acc <- nrow(acc); n_ass <- nrow(assessable)
n_cen <- sum(acc$left_censored, na.rm = TRUE)
n_na  <- n_acc - n_ass - n_cen
MAXLEAD <- max(assessable$lead_years, na.rm = TRUE)

stopifnot(n_ass + n_cen + n_na == n_acc, n_ass > 0)

# ACCENT carries the data; NEUTRAL carries absent information. This is
# deliberately not a categorical identity palette -- gray means "cannot be
# assessed", not "the other group" -- and both segments are directly labelled so
# identity never rests on colour alone.
INK <- "#111820"; MUT <- "#5b6875"; RULE <- "#c8d0d9"
ACCENT <- "#12706a"; NEUTRAL <- "#b9c4cd"; FLAG <- "#a8442a"

tp_theme <- function() {
  theme_minimal(base_size = 10) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major = element_line(colour = RULE, linewidth = .3),
          axis.title = element_text(colour = MUT, size = 9),
          axis.text = element_text(colour = INK),
          plot.title = element_text(face = "bold", size = 11, colour = INK),
          plot.subtitle = element_text(colour = MUT, size = 8.5, lineheight = 1.25),
          plot.title.position = "plot")
}

# --- Panel A: what the signal can see at all --------------------------------
seg <- tibble::tibble(
  what = factor(c("Assessable", "Left-censored (bound only)"),
                levels = c("Left-censored (bound only)", "Assessable")),
  n = c(n_ass, n_cen))

pA <- ggplot(seg, aes(.data$n, .data$what, fill = .data$what)) +
  geom_col(width = .6) +
  geom_text(aes(label = sprintf("%s  (%.1f%%)", scales::comma(.data$n),
                                100 * .data$n / n_acc)),
            hjust = -0.06, size = 3.1, fontface = "bold", colour = INK) +
  scale_fill_manual(values = c("Assessable" = ACCENT,
                               "Left-censored (bound only)" = NEUTRAL),
                    guide = "none") +
  scale_x_continuous(labels = scales::label_comma(),
                     expand = expansion(mult = c(0, .28))) +
  labs(title = "A. Over a third of accepted matches can never be assessed",
       subtitle = sprintf(paste0("The panel opens in %d, so an NPI first seen ",
                                 "in that snapshot may have enumerated earlier. ",
                                 "Those rows are a bound,\nnot a date, and no ",
                                 "grace period can make them informative."),
                          PANEL_MIN),
       x = sprintf("Accepted matches (n = %s)", scales::comma(n_acc))) +
  tp_theme() + theme(axis.title.y = element_blank())

# --- Panel B: why the shipped default flags nothing --------------------------
# The negative tail reaches -54 but is a handful of rows; drawn to full extent
# it squashes the mass near zero into an unreadable spike. Clip the view and SAY
# how many rows fall outside it, rather than silently cropping them.
XLO <- -25
XHI <- GRACE_DEF + 9          # headroom so the default's label sits clear of it
n_below <- sum(assessable$lead_years < XLO)
hist_df <- assessable %>%
  filter(.data$lead_years >= XLO) %>%
  count(.data$lead_years, name = "n")
YTOP <- max(hist_df$n)

pB <- ggplot(hist_df, aes(.data$lead_years, .data$n)) +
  geom_col(width = .85, fill = ACCENT) +
  geom_vline(xintercept = MAXLEAD + .5, colour = FLAG,
             linetype = "22", linewidth = .45) +
  geom_vline(xintercept = GRACE_DEF, colour = INK,
             linetype = "22", linewidth = .45) +
  annotate("text", x = MAXLEAD - 1, y = YTOP * .95,
           label = sprintf("largest observed\nlead: +%d", MAXLEAD),
           hjust = 1, size = 2.9, colour = FLAG, fontface = "bold",
           lineheight = 1.1) +
  annotate("text", x = GRACE_DEF + 1, y = YTOP * .95,
           label = sprintf("shipped default\ngrace = %g", GRACE_DEF),
           hjust = 0, size = 2.9, colour = INK, lineheight = 1.1) +
  scale_x_continuous(limits = c(XLO - 1, XHI), breaks = seq(-24, 32, 4)) +
  scale_y_continuous(labels = scales::label_comma(),
                     expand = expansion(mult = c(0, .18))) +
  labs(title = "B. The default grace sits above every value in the data",
       subtitle = sprintf(paste0("lead_years = certification year - NPI ",
                                 "first-seen year. Positive means the NPI ",
                                 "existed BEFORE the certification,\nwhich is ",
                                 "the suspicious direction. Negative is the ",
                                 "normal career order: an RN enumerates before ",
                                 "she certifies.\nView clipped at %d; %s ",
                                 "further-negative rows (to %d) fall outside ",
                                 "it and are never flagged by a one-sided rule."),
                          XLO, scales::comma(n_below),
                          min(assessable$lead_years, na.rm = TRUE)),
       x = "lead_years", y = "Accepted matches") +
  tp_theme()

# --- Panel C: the grace sweep ------------------------------------------------
GR <- 0:26
sweep <- tibble::tibble(
  grace = GR,
  flagged = vapply(GR, function(g) sum(assessable$lead_years > g), integer(1))) %>%
  mutate(pct = 100 * .data$flagged / n_ass)

pC <- ggplot(sweep, aes(.data$grace, .data$flagged)) +
  geom_line(colour = ACCENT, linewidth = .9) +
  geom_point(colour = ACCENT, size = 1.7) +
  geom_vline(xintercept = GRACE_DEF, colour = INK,
             linetype = "22", linewidth = .45) +
  annotate("text", x = GRACE_DEF - .6, y = max(sweep$flagged) * .8,
           label = sprintf("default grace = %g\nflags 0 records", GRACE_DEF),
           hjust = 1, size = 2.9, colour = INK, lineheight = 1.1) +
  scale_x_continuous(breaks = seq(0, 26, 2)) +
  scale_y_continuous(labels = scales::label_comma(),
                     expand = expansion(mult = c(0, .12))) +
  labs(title = "C. What a stricter grace period would actually flag",
       subtitle = paste0("Accepted matches called implausibly early, as the ",
                         "grace period tightens. These are candidate false ",
                         "positives\nthe name rules had no way to see -- not ",
                         "confirmed errors."),
       x = "Grace period (years an NPI may precede certification)",
       y = sprintf("Flagged (of %s assessable)", scales::comma(n_ass))) +
  tp_theme()

fig <- (pA / pB / pC) +
  plot_annotation(
    title = "What the unused temporal signal would buy (D17)",
    subtitle = paste0(
      "The matcher blocks on names and taxonomy only: certification_date ",
      "appears zero times in match_amcb_to_npi.R. This measures what a ",
      "temporal\ncomparison would add, over matches ALREADY ACCEPTED. Nothing ",
      "in the published linkage is changed by it."),
    caption = paste0(
      "Reads the frozen crosswalk and the NPPES panel. first-seen is a BOUND, ",
      "not a date: the panel opens in ", PANEL_MIN, " and NPPES began ",
      "enumerating in 2006.\n",
      "This is the VALIDATION half of D17 only. The SEPARATION half -- whether ",
      "the signal breaks quarantined ties, and how many pools it would EMPTY ",
      "in doing so --\nrequires artifacts/linkage_candidate_audit.csv with a ",
      "populated first_year column, which the committed audit does not yet ",
      "have.\n",
      "Source: ", CROSSWALK, " + ", PANEL),
    theme = theme(
      plot.title = element_text(face = "bold", size = 14, colour = INK),
      plot.subtitle = element_text(colour = MUT, size = 9, lineheight = 1.3),
      plot.caption = element_text(colour = MUT, size = 7.5, hjust = 0,
                                  lineheight = 1.35, margin = margin(t = 14)),
      plot.title.position = "plot", plot.caption.position = "plot"))

dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)
ggsave(paste0(OUT, ".pdf"), fig, width = 9.6, height = 11.4, device = cairo_pdf)
ggsave(paste0(OUT, ".png"), fig, width = 9.6, height = 11.4, dpi = 200, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), fig, width = 9.6, height = 11.4),
         error = function(e) NULL)
message("wrote ", OUT, ".{pdf,png,svg}")

out <- sweep %>%
  transmute(grace_years = .data$grace, flagged = .data$flagged,
            pct_of_assessable = round(.data$pct, 3),
            n_assessable = n_ass, n_left_censored = n_cen,
            n_not_assessable = n_na, n_accepted = n_acc,
            max_observed_lead_years = MAXLEAD, panel_floor_year = PANEL_MIN)
write_with_provenance(out, CSV, inputs = c(CROSSWALK, PANEL))
message("wrote ", CSV)
