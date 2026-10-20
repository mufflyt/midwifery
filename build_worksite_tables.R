#!/usr/bin/env Rscript
# =============================================================================
# Supplemental work-site tables for the midwifery manuscript
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})

ART <- "artifacts"
DOC <- "docs"
dir.create(DOC, showWarnings = FALSE, recursive = TRUE)
sites <- read_csv(file.path(ART, "midwife_work_sites_summary.csv"),
                  show_col_types = FALSE, progress = FALSE)
N <- nrow(sites)
fmt <- function(x) format(x, big.mark = ",", trim = TRUE, scientific = FALSE)
write_table <- function(d, title, note, stem) {
  d <- d %>% mutate(percent = if_else(is.na(percent), NA_real_, round(percent, 1)))
  write_csv(d, file.path(ART, paste0(stem, ".csv")), na = "")
  md <- c(paste0("# ", title), "", note, "",
          "| Setting | n | % |", "|---|---:|---:|")
  md <- c(md, vapply(seq_len(nrow(d)), function(i) {
    paste0("| ", d$setting[i], " | ", fmt(d$n[i]), " | ",
           ifelse(is.na(d$percent[i]), "—", sprintf("%.1f", d$percent[i])), " |")
  }, character(1)))
  md_path <- file.path(DOC, paste0(stem, ".md"))
  html_path <- file.path(DOC, paste0(stem, ".html"))
  writeLines(md, md_path)
  if (nzchar(Sys.which("pandoc"))) {
    css <- tempfile(fileext = ".html")
    writeLines(c(
      "<style>",
      "body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:52rem;margin:2rem auto;padding:0 1.5rem;line-height:1.5;color:#1a1a1a}",
      "table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}",
      "th,td{padding:.35rem .6rem;border-bottom:1px solid #e3e3e3;text-align:left}",
      "td:nth-child(2),td:nth-child(3),th:nth-child(2),th:nth-child(3){text-align:right}",
      "thead th{border-bottom:2px solid #333}",
      "h1{font-size:1.5rem;border-bottom:2px solid #333;padding-bottom:.4rem}",
      "</style>"), css)
    status <- system2("pandoc", c(md_path, "-s", "--embed-resources", "-H", css,
                                   "-o", html_path), stdout = FALSE, stderr = FALSE)
    if (status != 0L) warning("pandoc failed for ", stem)
  }
  cat("wrote", stem, "\n")
}

# 1. Each midwife contributes once; 5+ is collapsed for readability.
topology <- sites %>%
  mutate(setting = case_when(
    n_distinct_sites == 0 ~ "0",
    n_distinct_sites == 1 ~ "1",
    n_distinct_sites == 2 ~ "2",
    n_distinct_sites == 3 ~ "3",
    n_distinct_sites == 4 ~ "4",
    n_distinct_sites >= 5 ~ "5+",
    TRUE ~ NA_character_)) %>%
  count(setting, name = "n") %>%
  right_join(tibble(setting = c("0", "1", "2", "3", "4", "5+")), by = "setting") %>%
  mutate(n = coalesce(n, 0L), percent = 100 * n / N) %>%
  select(setting, n, percent)
write_table(topology, "Supplemental Table A. Number of classified work sites per midwife",
            paste0("Cohort denominator: **", fmt(N), "** midwives. Each midwife contributes once."),
            "table_worksite_topology")

# 2. A midwife can contribute to more than one row; percentages are of the full cohort.
settings <- tibble(
  setting = c("Hospital", "Clinic/practice", "FQHC/community health", "Birth center"),
  flag = c("any_hospital", "any_clinic", "any_fqhc", "any_birth_center")) %>%
  rowwise() %>%
  mutate(n = sum(sites[[flag]] %in% TRUE), percent = 100 * n / N) %>%
  ungroup() %>%
  select(setting, n, percent)
write_table(settings, "Supplemental Table B. Any observed work-site setting",
            paste0("Cohort denominator: **", fmt(N), "** midwives. Rows are nonexclusive; percentages do not sum to 100%."),
            "table_worksite_settings")

# 3. Setting combinations preserve blended practice patterns.
label_combo <- function(x) {
  x <- str_replace_all(x, "^no classified site$", "No classified setting")
  x <- str_replace_all(x, "fqhc_community_health", "FQHC/community health")
  x <- str_replace_all(x, "clinic_practice", "clinic/practice")
  x <- str_replace_all(x, "birth_center", "birth center")
  x <- str_replace_all(x, "other_facility", "other facility")
  x <- str_replace_all(x, "\\bhospital\\b", "Hospital")
  x <- str_replace_all(x, "^clinic/practice$", "Clinic/practice")
  x <- str_replace_all(x, "^birth center$", "Birth center")
  x <- str_replace_all(x, "^other facility$", "Other facility")
  str_replace_all(x, " \\+ ", " + ")
}
combos <- sites %>%
  mutate(setting = if_else(is.na(setting_combination) | setting_combination == "",
                           "No classified setting", label_combo(setting_combination))) %>%
  count(setting, sort = TRUE, name = "n") %>%
  mutate(percent = 100 * n / N) %>%
  select(setting, n, percent)
write_table(combos, "Supplemental Table C. Observed work-setting combinations",
            paste0("Cohort denominator: **", fmt(N), "** midwives. Each midwife contributes once; combinations reflect all classified work sites."),
            "table_worksite_combinations")

# Companion UpSet-style chart for Table C. The chart shows the four main
# setting types plus other facilities; rows with no classified setting are
# retained in the table above but omitted from the intersection matrix.
if (requireNamespace("ggplot2", quietly = TRUE) &&
    requireNamespace("cowplot", quietly = TRUE)) {
  library(ggplot2)
  library(cowplot)
  sets <- c("Hospital", "Clinic/practice", "FQHC/community health",
            "Birth center", "Other facility")
  set_palette <- c("Hospital" = "#2B6CB0",
                   "Clinic/practice" = "#D97706",
                   "FQHC/community health" = "#2F855A",
                   "Birth center" = "#805AD5",
                   "Other facility" = "#C53030")
  raw_combo <- sites %>%
    mutate(combo = if_else(is.na(setting_combination) | setting_combination == "" |
                             setting_combination == "no classified site",
                           "No classified setting", setting_combination))
  intersections <- raw_combo %>%
    filter(combo != "No classified setting") %>%
    transmute(
      Hospital = str_detect(combo, "hospital"),
      `Clinic/practice` = str_detect(combo, "clinic_practice"),
      `FQHC/community health` = str_detect(combo, "fqhc_community_health"),
      `Birth center` = str_detect(combo, "birth_center"),
      `Other facility` = str_detect(combo, "other_facility")) %>%
    count(across(everything()), name = "n", sort = TRUE) %>%
    slice_head(n = 15) %>%
    mutate(intersection = factor(seq_len(n()), levels = rev(seq_len(n()))))
  long <- intersections %>%
    tidyr::pivot_longer(all_of(sets), names_to = "setting", values_to = "active") %>%
    mutate(setting = factor(setting, levels = rev(sets)))
  set_sizes <- tibble(setting = sets, n = c(
    sum(str_detect(raw_combo$combo, "hospital")),
    sum(str_detect(raw_combo$combo, "clinic_practice")),
    sum(str_detect(raw_combo$combo, "fqhc_community_health")),
    sum(str_detect(raw_combo$combo, "birth_center")),
    sum(str_detect(raw_combo$combo, "other_facility")))
  )
  top <- ggplot(intersections, aes(intersection, n)) +
    geom_col(fill = "#2c5282", width = 0.7) +
    geom_text(aes(label = fmt(n)), vjust = -0.35, size = 3.8) +
    scale_x_discrete(drop = FALSE) +
    scale_y_continuous(expand = expansion(mult = c(0, .16))) +
    labs(x = NULL, y = "Midwives") +
    theme_minimal(base_size = 12) +
    theme(axis.text.x = element_blank(), axis.ticks.x = element_blank(),
          panel.grid.major.x = element_blank(), panel.grid.minor = element_blank())
  matrix <- ggplot(long, aes(intersection, setting)) +
    geom_point(aes(fill = ifelse(active, as.character(setting), "Inactive")),
               shape = 21, size = 3.5, colour = "#1a202c") +
    geom_segment(data = intersections %>% rowwise() %>%
                   mutate(first = min(which(c_across(all_of(sets)) == TRUE)),
                          last = max(which(c_across(all_of(sets)) == TRUE))) %>% ungroup(),
                 aes(x = intersection, xend = intersection,
                     y = factor(sets[first], levels = rev(sets)),
                     yend = factor(sets[last], levels = rev(sets))),
                 inherit.aes = FALSE, colour = "#4A5568", linewidth = 1) +
    scale_fill_manual(values = c(set_palette, "Inactive" = "white"), guide = "none") +
    scale_x_discrete(drop = FALSE) +
    labs(x = "Largest intersections", y = NULL) +
    theme_minimal(base_size = 12) +
    theme(panel.grid = element_blank(), axis.text.x = element_blank(),
          axis.ticks.x = element_blank())
  sizes <- ggplot(set_sizes, aes(n, factor(setting, levels = rev(sets)), fill = setting)) +
    geom_col(width = 0.7, show.legend = FALSE) +
    geom_text(aes(label = fmt(n)), hjust = -0.15, size = 3.8) +
    scale_x_continuous(expand = expansion(mult = c(0, .28))) +
    labs(x = "Set size", y = NULL) +
    scale_fill_manual(values = set_palette, guide = "none") +
    theme_minimal(base_size = 12) +
    theme(panel.grid.major.y = element_blank(), panel.grid.minor = element_blank())
  aligned_right <- align_plots(top, matrix, align = "v", axis = "lr")
  right_panel <- plot_grid(plotlist = aligned_right, ncol = 1,
                           rel_heights = c(3, 2), align = "v")
  chart <- plot_grid(sizes, right_panel, ncol = 2, rel_widths = c(1.8, 4))
  png <- file.path(DOC, "table_worksite_combinations_upset.png")
  ggsave(png, chart, width = 12, height = 7.5, dpi = 180, bg = "white")
  md <- c("# Supplemental Table C. Work-setting intersections", "",
          paste0("Top 15 intersections among **", fmt(N),
                 "** midwives. Bars show intersection size; filled dots show which settings are included. Midwives with no classified setting are shown in the combination table but omitted from the intersection matrix."), "",
          "![](table_worksite_combinations_upset.png)")
  md_path <- file.path(DOC, "table_worksite_combinations_upset.md")
  html_path <- file.path(DOC, "table_worksite_combinations_upset.html")
  writeLines(md, md_path)
  if (nzchar(Sys.which("pandoc"))) {
    css <- tempfile(fileext = ".html")
    writeLines(c(
      "<style>",
      "body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:92rem;margin:2rem auto;padding:0 2rem;line-height:1.5;color:#1a1a1a}",
      "img{display:block;width:100%;height:auto;margin:1.5rem auto 0}",
      "h1{font-size:1.7rem;border-bottom:2px solid #333;padding-bottom:.4rem}",
      "</style>"), css)
    system2("pandoc", c(md_path, "-s", "--embed-resources", "-H", css, "-o", html_path),
            stdout = FALSE, stderr = FALSE)
  }
  cat("wrote table_worksite_combinations_upset\n")
}
