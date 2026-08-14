#!/usr/bin/env Rscript
# =============================================================================
# Visualizations Suite for Scraped State Board of Nursing (BON) Workforce
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(stringr)
})

cat("=== Generating Visualizations for Scraped 20-State BON Data ===\n")

df <- read_csv("artifacts/scraped_20_state_bons_midwives_master.csv", show_col_types = FALSE)

dir.create("artifacts/plots", showWarnings = FALSE, recursive = TRUE)

# -----------------------------------------------------------------------------
# PLOT 1: Top 20 Scraped State Boards of Nursing (BON) Midwife Workforce Volume
# -----------------------------------------------------------------------------
st_counts <- df %>%
  group_by(scraped_bon_state) %>%
  summarise(total_midwives = n(), .groups = "drop") %>%
  arrange(desc(total_midwives))

p1 <- ggplot(st_counts, aes(x = reorder(scraped_bon_state, total_midwives), y = total_midwives, fill = total_midwives)) +
  geom_col(show.legend = FALSE) +
  geom_text(aes(label = scales::comma(total_midwives)), hjust = -0.15, size = 3.5, fontface = "bold") +
  coord_flip() +
  scale_fill_gradient(low = "#93C5FD", high = "#1D4ED8") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15)), labels = scales::comma) +
  theme_minimal(base_size = 13) +
  labs(
    title = "Top 20 Scraped State Boards of Nursing (BON) Midwife Workforce",
    subtitle = "Total Verified Certified Nurse-Midwives Scraped Across 20 State BONs (N = 9,037)",
    x = "State Board of Nursing Jurisdiction",
    y = "Verified Midwives (N)",
    caption = "Source: National Midwifery Workforce Study 2026 | State BON Scrapers"
  ) +
  theme(
    plot.title = element_text(face = "bold", size = 15),
    panel.grid.major.y = element_blank(),
    plot.margin = margin(15, 20, 15, 15)
  )

p1_path <- "artifacts/plots/plot1_scraped_bon_state_volumes.png"
ggsave(p1_path, plot = p1, width = 10, height = 7, dpi = 300)
cat(sprintf("Generated Plot 1: %s\n", p1_path))

# -----------------------------------------------------------------------------
# PLOT 2: Active CPT Delivery Attenders vs Non-Delivery Practice by State
# -----------------------------------------------------------------------------
attender_df <- df %>%
  mutate(Delivery_Status = ifelse(has_cpt_delivery_claim == TRUE, "Active CPT Delivery Attender", "Outpatient / Non-Delivery Practice")) %>%
  group_by(scraped_bon_state, Delivery_Status) %>%
  summarise(count = n(), .groups = "drop")

p2 <- ggplot(attender_df, aes(x = reorder(scraped_bon_state, count, sum), y = count, fill = Delivery_Status)) +
  geom_col(position = "stack") +
  coord_flip() +
  scale_fill_manual(values = c("Active CPT Delivery Attender" = "#2563EB", "Outpatient / Non-Delivery Practice" = "#94A3B8")) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.05)), labels = scales::comma) +
  theme_minimal(base_size = 13) +
  labs(
    title = "State BON Midwife Workforce by Clinical Practice Role",
    subtitle = "Active Labor & Delivery Attenders vs Outpatient Practice Midwives Across 20 States",
    x = "State Jurisdiction",
    y = "Midwives (N)",
    fill = "Clinical Practice Role",
    caption = "Source: National Midwifery Workforce Study 2026 | CMS Claims Linkage"
  ) +
  theme(
    plot.title = element_text(face = "bold", size = 15),
    legend.position = "bottom",
    panel.grid.major.y = element_blank()
  )

p2_path <- "artifacts/plots/plot2_bon_delivery_attenders_by_state.png"
ggsave(p2_path, plot = p2, width = 10, height = 7, dpi = 300)
cat(sprintf("Generated Plot 2: %s\n", p2_path))

cat("=== Visualizations Suite Execution Complete ===\n")
