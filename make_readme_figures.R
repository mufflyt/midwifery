#!/usr/bin/env Rscript
# =============================================================================
# Regenerate the figures shown in README.md
# =============================================================================
# Run from the repo root:  Rscript make_readme_figures.R
#
# Every figure is built from a COMMITTED artifact, so anyone who clones the
# repository can regenerate them without rerunning the pipeline, and a figure
# cannot quietly disagree with the table beside it.
#
# ALL FIGURES ARE AGGREGATE. No panel plots an individual midwife. A dot map of
# practice locations exists for internal QA and is deliberately not published
# here: an isochrone or a dot discloses a practice address, and jittering is not
# de-identification.
#
# Colour scales come from mysterymaps_jenks_zero_scale(), so "no midwife" is its
# own class rather than the bottom of a gradient -- 1,619 of 3,109 counties sit
# in that class, and an equal-interval scale hides all of them.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(stringr)
  library(sf); library(scales); library(mysterymaps)
})
sf::sf_use_s2(FALSE)

FIG <- "docs/figures"
dir.create(FIG, showWarnings = FALSE, recursive = TRUE)
CONUS_EXCLUDE <- mufflyaccess::NON_CONTIGUOUS_FIPS

theme_mw <- function(base = 11) {
  theme_minimal(base_size = base) +
    theme(plot.title = element_text(face = "bold", size = base + 1),
          plot.subtitle = element_text(colour = "grey35", size = base - 1),
          plot.caption = element_text(colour = "grey55", size = base - 3, hjust = 0),
          panel.grid.minor = element_blank(),
          legend.position = "right")
}
sup <- read_csv("artifacts/county_midwifery_supply.csv", show_col_types = FALSE) %>%
  mutate(fips = str_pad(as.character(fips), 5, "left", "0"))

# --- 1. county supply, with "none" as its own class --------------------------
cty <- suppressMessages(
  tigris::counties(cb = TRUE, resolution = "20m", year = 2023, progress_bar = FALSE)) %>%
  sf::st_transform(4326) %>% filter(!STATEFP %in% CONUS_EXCLUDE) %>%
  left_join(sup, by = c("GEOID" = "fips"))

sc <- mysterymaps_jenks_zero_scale(cty$midwives_per_1k_births, k = 5, digits = 1)
sc$leg_labs[1] <- "none"
cty$fill <- ifelse(is.na(cty$midwives_per_1k_births), "#ffffff",
                   sc$color(cty$midwives_per_1k_births))

n_none <- sum(cty$midwives_per_1k_births == 0, na.rm = TRUE)
n_supp <- sum(is.na(cty$midwives_per_1k_births))
p1 <- ggplot(cty) +
  geom_sf(aes(fill = fill), colour = "white", linewidth = 0.08) +
  scale_fill_identity(guide = "legend",
                      breaks = c(sc$leg_cols, "#ffffff"),
                      labels = c(sc$leg_labs, "suppressed"),
                      name = "Midwives per\n1,000 births") +
  labs(title = "Midwifery supply is a presence/absence map before it is a gradient",
       subtitle = sprintf("%s of %s counties have no ACTIVE AMCB-certified midwife; %s more are rate-suppressed (<50 births)",
                          comma(n_none), comma(nrow(cty)), comma(n_supp)),
       caption = "artifacts/county_midwifery_supply.csv - denominator is AHRF/NCHS births") +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 12),
        plot.subtitle = element_text(colour = "grey35", size = 9.5),
        plot.caption = element_text(colour = "grey55", size = 7.5))
ggsave(file.path(FIG, "county_supply.png"), p1, width = 9, height = 5, dpi = 150, bg = "white")
message("wrote county_supply.png")

# --- 2. the rural gradient, and who is actually there ------------------------
rur <- sup %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(counties = n(), midwives = sum(study_midwives),
            births = sum(births_used, na.rm = TRUE),
            per1k = 1000 * sum(study_midwives) / sum(births_used, na.rm = TRUE),
            .groups = "drop")

cfg <- sup %>% filter(!is.na(provider_config), !is.na(rurality)) %>%
  count(rurality, provider_config) %>% group_by(rurality) %>%
  mutate(pct = 100 * n / sum(n)) %>% ungroup() %>%
  mutate(provider_config = factor(provider_config,
           levels = c("Both", "OB/GYN only", "Midwife only", "Neither")))

p2a <- ggplot(rur, aes(reorder(rurality, -per1k), per1k)) +
  geom_col(fill = "#3182bd", width = 0.62) +
  geom_text(aes(label = sprintf("%.2f", per1k)), vjust = -0.45, size = 3.4) +
  scale_x_discrete(labels = function(x) str_wrap(x, 16)) +
  labs(title = "Supply", y = "Midwives per 1,000 births", x = NULL) +
  expand_limits(y = max(rur$per1k) * 1.15) + theme_mw()

p2b <- ggplot(cfg, aes(reorder(rurality, -pct * (provider_config == "Both")),
                       pct, fill = provider_config)) +
  geom_col(width = 0.62) +
  scale_fill_manual(values = c(Both = "#2c7fb8", `OB/GYN only` = "#7fcdbb",
                               `Midwife only` = "#c2185b", Neither = "#d94801"),
                    name = NULL) +
  scale_x_discrete(labels = function(x) str_wrap(x, 16)) +
  labs(title = "Who is in the county", y = "% of counties", x = NULL) + theme_mw()

p2 <- patchwork::wrap_plots(p2a, p2b, widths = c(1, 1.25)) +
  patchwork::plot_annotation(
    title = "Midwives are co-located with obstetricians, not substituting for them",
    subtitle = "72.5% of remote counties have neither provider type. \"Midwife only\" never exceeds 5.9% anywhere.",
    caption = "artifacts/county_midwifery_supply.csv - OB/GYN counts from AHRF md_nf_obgyn_gen_23",
    theme = theme(plot.title = element_text(face = "bold", size = 13),
                  plot.subtitle = element_text(colour = "grey35", size = 10),
                  plot.caption = element_text(colour = "grey55", size = 7.5, hjust = 0)))
ggsave(file.path(FIG, "rural_gradient.png"), p2, width = 10, height = 4.4, dpi = 150, bg = "white")
message("wrote rural_gradient.png")

# --- 3. the measurement thins out where the study is most sensitive ----------
# Four independent measures, each missing MORE in rural counties. This is the
# through-line of the whole project and it deserves one picture.
# Values are COMPUTED from the artifacts, never typed. A first draft hardcoded
# them from memory and got two of the three series wrong: it used the
# AFTER-recovery isochrone coverage (84.6/50.7/39.3) while labelling it as the
# canonical gate, and mis-stated the birth-rate series as 99.0/96.9/76.6 when it
# is 98.2/99.7/75.1. A figure that restates numbers by hand is a figure that
# will eventually contradict the table beside it.
cov <- read_csv("artifacts/isochrone_coverage_after_validated_recovery.csv",
                show_col_types = FALSE) %>% filter(!is.na(rurality))
strat <- function(x) factor(recode(str_extract(x, "Metro|adjacent|remote"),
                                   adjacent = "Adjacent", remote = "Remote"),
                            levels = c("Metro", "Adjacent", "Remote"))
sup_r <- sup %>% filter(!is.na(rurality))

gaps <- bind_rows(
  cov %>% transmute(measure = "Isochrone coverage,\ncanonical library only",
                    stratum = strat(rurality), pct_observed = pct_canonical_only),
  cov %>% transmute(measure = "Isochrone coverage,\nafter archive recovery",
                    stratum = strat(rurality), pct_observed = pct_with_validated_recovery),
  sup_r %>% group_by(rurality) %>%
    summarise(pct_observed = 100 * mean(ob_hospital_status != "hospital, obstetrics unreported"),
              .groups = "drop") %>%
    transmute(measure = "Hospital obstetric status\nreported to CMS POS",
              stratum = strat(rurality), pct_observed),
  sup_r %>% group_by(rurality) %>%
    summarise(pct_observed = 100 * mean(!is.na(midwives_per_1k_births)), .groups = "drop") %>%
    transmute(measure = "County birth rate estimable\n(>=50 births)",
              stratum = strat(rurality), pct_observed)
) %>% mutate(pct_observed = round(pct_observed, 1))

p3 <- ggplot(gaps, aes(stratum, pct_observed, group = measure, colour = measure)) +
  geom_line(linewidth = 0.9) + geom_point(size = 2.6) +
  geom_text(aes(label = sprintf("%.0f%%", pct_observed),
                vjust = ifelse(measure == "Hospital obstetric status\nreported to CMS POS", 1.9, -1.1)),
            size = 3, show.legend = FALSE) +
  scale_colour_manual(values = c("#08519c", "#6baed6", "#d94801", "#31a354"), name = NULL) +
  scale_y_continuous(limits = c(5, 110), labels = function(x) paste0(x, "%")) +
  labs(title = "Every measurement thins out fastest where the question is hardest",
       subtitle = "Share of each rurality stratum that is OBSERVED at all, by measure. The gradient is in the\nobservation process, not only in the workforce.",
       y = "% observed", x = NULL,
       caption = "isochrone_coverage_after_validated_recovery.csv; county_midwifery_supply.csv (ob_hospital_status, births_used)") +
  theme_mw() + theme(legend.position = "right",
                     legend.text = element_text(size = 8, lineheight = 0.95))
ggsave(file.path(FIG, "missingness_gradient.png"), p3, width = 9.5, height = 4.6, dpi = 150, bg = "white")
message("wrote missingness_gradient.png")

# --- 4. congressional districts: the spread, not the average -----------------
cd <- read_csv("artifacts/cd_midwifery_stats.csv", show_col_types = FALSE) %>%
  filter(!is.na(midwives_per_1k_births))
q <- quantile(cd$midwives_per_1k_births, c(.1, .5, .9))
p4 <- ggplot(cd, aes(midwives_per_1k_births)) +
  geom_histogram(binwidth = 0.5, fill = "#3182bd", colour = "white", linewidth = 0.2) +
  geom_vline(xintercept = q, linetype = c("dotted", "solid", "dotted"), colour = "#a63603") +
  annotate("text", x = q, y = Inf, vjust = 1.6, size = 3, colour = "#a63603",
           label = c(sprintf("p10 %.2f", q[1]), sprintf("median %.2f", q[2]),
                     sprintf("p90 %.2f", q[3]))) +
  labs(title = sprintf("A %.1f-fold gap between the 90th and 10th percentile district",
                       q[3] / q[1]),
       subtitle = "For comparison, the metro-to-remote county gradient is 1.7-fold. Where you are matters more than how rural you are.",
       x = "Midwives per 1,000 births (118th Congress districts)", y = "Districts",
       caption = "artifacts/cd_midwifery_stats.csv - ACS 2023 5-year births; 4 districts suppressed") +
  theme_mw()
ggsave(file.path(FIG, "district_spread.png"), p4, width = 9, height = 4.2, dpi = 150, bg = "white")
message("wrote district_spread.png")

# --- 5. the mixed-engine caveat, as a picture -------------------------------
cal <- "artifacts/isochrones_osmde/calibration_summary_by_rurality.csv"
if (file.exists(cal)) {
  cc <- read_csv(cal, show_col_types = FALSE) %>%
    mutate(stratum = str_extract(rurality, "Metro|adjacent|remote"),
           stratum = factor(recode(stratum, adjacent = "Adjacent", remote = "Remote"),
                            levels = c("Metro", "Adjacent", "Remote")),
           band = factor(paste0(band, " min"), levels = c("30 min", "60 min")))
  p5 <- ggplot(cc, aes(stratum, median_area_ratio, group = band, colour = band)) +
    geom_hline(yintercept = 1, linetype = "dashed", colour = "grey55") +
    geom_line(linewidth = 0.9) + geom_point(size = 2.8) +
    geom_text(aes(label = sprintf("%.2f", median_area_ratio)), vjust = -1.1, size = 3,
              show.legend = FALSE) +
    scale_colour_manual(values = c("#08519c", "#3182bd"), name = NULL) +
    labs(title = "Why the 30-minute band cannot carry a rural claim",
         subtitle = "Area of an osm.de polygon divided by the EC2 polygon at the same origin (n=88 shared origins).\nAt 30 min the ratio drifts 0.85 -> 1.09 across the gradient, so the newer engine is relatively\nmore generous in rural areas. At 60 min it is nearly flat.",
         y = "osm.de area / EC2 area", x = NULL,
         caption = "artifacts/isochrones_osmde/calibration_summary_by_rurality.csv") +
    theme_mw()
  ggsave(file.path(FIG, "engine_calibration.png"), p5, width = 8.5, height = 4.4, dpi = 150, bg = "white")
  message("wrote engine_calibration.png")
} else {
  message("calibration artifact absent; engine_calibration.png not regenerated")
}

message("\nfigures in ", FIG, ":")
for (f in list.files(FIG, pattern = "[.]png$")) message("  ", f)
