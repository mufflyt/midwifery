#!/usr/bin/env Rscript
# =============================================================================
# Plotting Engine for Midwifery Workforce Microsimulation Projections (2026-2040)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2)
})

cat("=== Generating Microsimulation Visual Plot Figure ===\n")

df <- read_csv("artifacts/midwifery_microsimulation_projections_2026_2040.csv", show_col_types = FALSE)

p <- ggplot(df, aes(x = Simulation_Year)) +
  geom_line(aes(y = Total_Active_CNM_Workforce, color = "Total Active CNMs"), linewidth = 1.3) +
  geom_line(aes(y = Urban_Practicing_CNMs, color = "Urban CNM Workforce"), linewidth = 1.1, linetype = "dashed") +
  geom_line(aes(y = Rural_Practicing_CNMs * 5, color = "Rural CNM Workforce (5x Scale)"), linewidth = 1.1, linetype = "dotted") +
  scale_color_manual(values = c("Total Active CNMs" = "#2563eb", "Urban CNM Workforce" = "#059669", "Rural CNM Workforce (5x Scale)" = "#dc2626")) +
  theme_minimal(base_family = "sans") +
  labs(
    title = "National Certified Nurse-Midwife (CNM) Workforce Microsimulation (2026–2040)",
    subtitle = "Projected 15-Year Growth, Urban Agglomeration, and Rural Supply Drift (N = 12,211 Baseline)",
    x = "Simulation Year",
    y = "Active Midwife Workforce Count",
    color = "Workforce Cohort"
  ) +
  theme(
    plot.title = element_text(face = "bold", size = 14, color = "#0f172a"),
    plot.subtitle = element_text(size = 10, color = "#475569"),
    legend.position = "bottom",
    panel.grid.minor = element_blank()
  )

out_png <- "artifacts/plots/plot3_microsimulation_workforce_projections.png"
ggsave(out_png, p, width = 9, height = 5.5, dpi = 300)

cat(paste0("=== Successfully saved microsimulation plot figure to: ", out_png, " ===\n"))
