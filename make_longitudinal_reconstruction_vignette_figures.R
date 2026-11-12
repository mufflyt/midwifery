#!/usr/bin/env Rscript
# =============================================================================
# Five figures for the longitudinal source-reconstruction vignette
# =============================================================================
# Reads only tracked aggregate CSVs already written by
# extract_medicaid_enrollment_state_by_year.R, audit_medicaid_set_membership.R,
# audit_a2_medicaid_before_after.R, and audit_billing_gap_headline_figures.R.
# Draws no new numbers; visualizes figures already in the merged NEWS.md entry.
#
#   Figure 1  Year-by-year disagreement, modal pick vs year-specific state
#   Figure 2  The set-membership fix: three ways of scoring the same data
#   Figure 3  Where the 59,380 discarded state memberships went
#   Figure 4  Billing gaps: naive rate vs the denominator that can show one
#   Figure 5  What corroborates a billing gap, and what doesn't
#
# Output: docs/figures/longitudinal_medicaid_yearly_disagreement.png (+pdf/svg)
#         docs/figures/longitudinal_medicaid_membership_fix.png (+pdf/svg)
#         docs/figures/longitudinal_medicaid_discarded_memberships.png (+pdf/svg)
#         docs/figures/longitudinal_billing_gap_denominator.png (+pdf/svg)
#         docs/figures/longitudinal_billing_gap_corroboration.png (+pdf/svg)
# =============================================================================
suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(tidyr)
})

OUT_DIR <- file.path("docs", "figures")

save_longitudinal_fig <- function(p, name, width = 8.5, height = 5.4) {
  out <- file.path(OUT_DIR, name)
  ggsave(paste0(out, ".pdf"), p, width = width, height = height,
         device = if (capabilities("cairo")) cairo_pdf else pdf)
  ggsave(paste0(out, ".png"), p, width = width, height = height, dpi = 300, bg = "white")
  tryCatch(ggsave(paste0(out, ".svg"), p, width = width, height = height),
           error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
}

ACCENT <- "#2E6F8E"
WARN <- "#B4473E"
NEUTRAL <- "#B9B0A0"

# -- Figure 1: year-by-year disagreement, modal pick vs year-specific --------
yearly <- read_csv(file.path("artifacts", "medicaid_enrollment_modal_vs_yearly.csv"), show_col_types = FALSE)

p1 <- ggplot(yearly, aes(x = year, y = pct_differs)) +
  geom_col(aes(fill = left_censored), width = 0.72) +
  scale_fill_manual(values = c(`TRUE` = WARN, `FALSE` = ACCENT),
                     labels = c(`TRUE` = "before PECOS series begins (left-censored)", `FALSE` = "PECOS-comparable"),
                     name = NULL) +
  labs(
    title = "The whole-file modal state disagreed with the year-specific state most in 2013",
    subtitle = "% of Medicaid NPI-years where the modal pick differs from that year's actual state",
    x = NULL, y = "% differing"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top")
save_longitudinal_fig(p1, "longitudinal_medicaid_yearly_disagreement")

# -- Figure 2: the set-membership fix, three ways of scoring the same data ---
membership <- tibble(
  method = c("Equality with\nthe modal pick", "Membership of the\nenrolled set", "Membership of the\nenrolled set (2024 only)"),
  pct = c(74.7, 88.5, 91.4),
  is_fix = c(FALSE, TRUE, TRUE)
) %>% mutate(method = factor(method, levels = method))

p2 <- ggplot(membership, aes(x = method, y = pct, fill = is_fix)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.1f%%", pct)), vjust = -0.5, fontface = "bold", size = 4.2) +
  scale_fill_manual(values = c(`FALSE` = NEUTRAL, `TRUE` = ACCENT), guide = "none") +
  scale_y_continuous(limits = c(0, 100), expand = expansion(mult = c(0, 0.1))) +
  labs(
    title = "Measuring whether Medicaid named the enrolled state, not just the loudest one",
    subtitle = "Agreement with NPPES on 107,386 comparable NPI-years -- no underlying record changed",
    x = NULL, y = "% agreement with NPPES"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11))
save_longitudinal_fig(p2, "longitudinal_medicaid_membership_fix")

# -- Figure 3: where the 59,380 discarded memberships went -------------------
discard <- tibble(
  bucket = c("Kept by the\nmodal rule", "Discarded before\nthe fix"),
  n = c(119527, 59380)
) %>% mutate(bucket = factor(bucket, levels = bucket), pct = round(100 * n / sum(n), 1))

p3 <- ggplot(discard, aes(x = bucket, y = n, fill = bucket)) +
  geom_col(width = 0.55) +
  geom_text(aes(label = sprintf("%s\n(%.1f%%)", format(n, big.mark = ","), pct)), vjust = -0.3, fontface = "bold", size = 4) +
  scale_fill_manual(values = c(ACCENT, WARN), guide = "none") +
  scale_y_continuous(limits = c(0, 190000), expand = expansion(mult = c(0, 0.1)),
                      labels = scales::label_comma()) +
  labs(
    title = "A third of Medicaid's true state memberships were silently thrown away",
    subtitle = "178,907 total (NPI, year, state) memberships in the raw footprint, before the one-per-year reduction",
    x = NULL, y = "state memberships"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11))
save_longitudinal_fig(p3, "longitudinal_medicaid_discarded_memberships")

# -- Figure 4: billing gaps, naive rate vs the denominator that can show one -
denom <- tibble(
  frame = c("All Part D\nmidwives\n(n=8,147)", "Seen in\n>=2 years\n(n=6,465)", "Span covers\n>=3 years\n(n=5,514)"),
  pct = c(27.1, 34.2, 40.1)
) %>% mutate(frame = factor(frame, levels = frame),
             is_right_denominator = frame == "Span covers\n>=3 years\n(n=5,514)")

p4 <- ggplot(denom, aes(x = frame, y = pct, fill = is_right_denominator)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.1f%%", pct)), vjust = -0.5, fontface = "bold", size = 4.2) +
  scale_fill_manual(values = c(`FALSE` = NEUTRAL, `TRUE` = ACCENT), guide = "none") +
  scale_y_continuous(limits = c(0, 50), expand = expansion(mult = c(0, 0.1))) +
  labs(
    title = "27.1% divides by midwives who could never have a gap in the first place",
    subtitle = "A Medicare billing gap requires a span wide enough to have an interior year missing",
    x = NULL, y = "% with an interior billing gap"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11))
save_longitudinal_fig(p4, "longitudinal_billing_gap_denominator")

# -- Figure 5: what corroborates a billing gap, and what doesn't -------------
corrob <- tibble(
  evidence = c("Confirmed dated\nbilling activity", "Medicaid enrollment\nonly", "No corroborating\nevidence"),
  pct = c(10.4, 81.4, 8.2)
) %>% mutate(evidence = factor(evidence, levels = evidence))

p5 <- ggplot(corrob, aes(x = evidence, y = pct, fill = evidence)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.1f%%", pct)), vjust = -0.5, fontface = "bold", size = 4.2) +
  scale_fill_manual(values = c(ACCENT, NEUTRAL, WARN), guide = "none") +
  scale_y_continuous(limits = c(0, 95), expand = expansion(mult = c(0, 0.1))) +
  labs(
    title = "Most 'corroborated' gaps are corroborated by enrollment, not care delivered",
    subtitle = "2,731 interior billing-gap episodes, by the strongest evidence found during the gap",
    x = NULL, y = "% of episodes"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11))
save_longitudinal_fig(p5, "longitudinal_billing_gap_corroboration")

cat("Wrote 5 figures (pdf/png/svg) to", OUT_DIR, "\n")
