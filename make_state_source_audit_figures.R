#!/usr/bin/env Rscript
# =============================================================================
# Four figures for the ten-source practice-state audit vignette
# =============================================================================
# WHY THIS PARSES A MARKDOWN FILE. Every other figure script in this repository
# reads a CSV. This one reads the published appendix
# (docs/TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md) and parses its
# section 2 and section 3 tables. That is deliberate, and it is not a
# convenience:
#
#   1. The appendix IS the canonical published table for this audit. Its
#      backing artifacts (artifacts/state_source_audit_agreement.csv and
#      artifacts/state_source_audit_coverage.csv) are not tracked, are absent
#      from origin/main, and cannot be regenerated in a clone that lacks the
#      five NBER Physician Compare CSVs that head their dependency chain --
#      see artifacts/mrost_sources_unavailable.csv, which documents exactly
#      that gap. A figure script that read those CSVs would simply not run.
#   2. A figure drawn from the appendix cannot disagree with the appendix.
#      The vignette makes that promise in its own first paragraph; this file
#      is what makes the promise true rather than decorative. If someone edits
#      a number in the appendix table, these figures move with it, and if they
#      break the table's shape, this script fails loudly instead of drawing a
#      stale picture.
#
# The two figures that need a per-provider computation rather than a published
# summary read tracked artifacts in the ordinary way.
#
#   Figure 1  Coverage: which years each of the sources actually has
#   Figure 2  Agreement with NPPES by year, the five multi-year sources
#   Figure 3  Address disagreement by granularity, against OIG's 2011 benchmark
#   Figure 4  Multi-state Medicaid enrolment, the independent multi-state check
#
# Output: docs/figures/state_source_coverage_by_year.png (+pdf/svg)
#         docs/figures/state_source_agreement_by_year.png (+pdf/svg)
#         docs/figures/address_granularity_vs_oig_benchmark.png (+pdf/svg)
#         docs/figures/medicaid_multistate_footprint.png (+pdf/svg)
# =============================================================================
suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(tidyr); library(stringr)
})

source(file.path("R", "lib", "audit_figure_style.R"))  # AUDIT_SERIES,
# fit_plot_labels(), gloss(), save_audit_fig() -- shared with
# make_state_source_comparison_steps_figures.R, see that file's header.

APPENDIX <- file.path("docs", "TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md")
OUT_DIR  <- AUDIT_FIG_DIR

# CATEGORICAL HUES, FIXED ORDER, NEVER CYCLED. Five series, assigned by the
# factor order of `source` so a hue follows the source and not its rank -- a
# filter that drops a series must not repaint the survivors. These are the
# blue/orange/aqua/amber/violet slots of the house categorical ramp, each
# stepped darker until it clears 3:1 against white (violet #7a5195 = 6.1:1).
#' Read one pipe-table out of a markdown file by its header row
#'
#' Finds the FIRST table whose header contains every name in `must_have`, then
#' takes the contiguous run of pipe rows after the separator. Anchoring on the
#' header rather than a line number means inserting a paragraph into the
#' appendix cannot silently shift which table gets drawn.
#'
#' @param path [character]: markdown file.
#' @param must_have [character]: column names that identify the wanted table.
#' @return [data.frame] character columns, named from the header row.
md_table <- function(path, must_have) {
  ln <- readLines(path, warn = FALSE)
  cells <- function(s) trimws(strsplit(sub("\\|\\s*$", "", sub("^\\s*\\|", "", s)), "|", fixed = TRUE)[[1]])
  is_sep <- function(s) grepl("^\\s*\\|[-: |]+\\|?\\s*$", s)
  hdr <- NA_integer_
  for (i in seq_along(ln)) {
    if (!grepl("^\\s*\\|", ln[i]) || is_sep(ln[i])) next
    if (all(vapply(must_have, function(m) any(grepl(m, cells(ln[i]), fixed = TRUE)), logical(1)))) {
      if (i < length(ln) && is_sep(ln[i + 1])) { hdr <- i; break }
    }
  }
  if (is.na(hdr))
    stop(sprintf("md_table(): no table in %s whose header holds %s.",
                 basename(path), paste(must_have, collapse = " + ")), call. = FALSE)
  nms <- cells(ln[hdr])
  out <- list(); j <- hdr + 2L
  while (j <= length(ln) && grepl("^\\s*\\|", ln[j])) {
    r <- cells(ln[j])
    if (length(r) == length(nms)) out[[length(out) + 1L]] <- r
    j <- j + 1L
  }
  if (!length(out))
    stop(sprintf("md_table(): header found in %s but no data rows under it.",
                 basename(path)), call. = FALSE)
  d <- as.data.frame(do.call(rbind, out), stringsAsFactors = FALSE)
  names(d) <- nms
  d
}

md_num <- function(x) as.numeric(gsub("[^0-9.]", "", x))

stopifnot(file.exists(APPENDIX))
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

# --- Figure 1: coverage -------------------------------------------------------
# The appendix states each source's span in prose ("2013-2026, every year",
# "2026 only", "2018-2024"), because the spans have exceptions a single pair of
# columns could not carry. Every explicit 4-digit year and every YYYY-YYYY
# range in the cell is expanded; a cell naming no year is dropped rather than
# guessed at.
cov_raw <- md_table(APPENDIX, c("Source", "Years covered"))
expand_years <- function(s) {
  rng <- str_match_all(s, "(\\d{4})\\s*[-–]\\s*(\\d{4})")[[1]]
  yrs <- integer(0)
  if (nrow(rng)) yrs <- unlist(Map(seq, as.integer(rng[, 2]), as.integer(rng[, 3])))
  loose <- as.integer(str_extract_all(gsub("(\\d{4})\\s*[-–]\\s*(\\d{4})", "", s), "\\d{4}")[[1]])
  sort(unique(c(yrs, loose[loose >= 2000 & loose <= 2100])))
}
cov <- bind_rows(lapply(seq_len(nrow(cov_raw)), function(i) {
  y <- expand_years(cov_raw[["Years covered"]][i])
  if (!length(y)) return(NULL)
  data.frame(source = cov_raw$Source[i], year = y, stringsAsFactors = FALSE)
}))
# The appendix writes one source name with a U+2194 arrow, which the PDF and
# PNG devices render as a missing-glyph box. Spelled out rather than fixed by
# switching fonts, so the figure does not depend on what is installed.
cov$source <- gsub("\u2194", " to ", cov$source, fixed = FALSE)
cov$source <- factor(cov$source, levels = rev(sort(unique(cov$source))))

# COLOUR CARRIES THE CUSTODIAN, which is information the grid otherwise hides.
# Whether a record is federal, state or commercial determines what it can be
# held to: a federal register has a statutory update duty, a commercial
# directory has none. A reader comparing coverage needs that on the same
# picture, not two pages away in a table.
CUSTODIAN <- c(
  "NPPES" = "Federal", "DAC / Physician Compare" = "Federal",
  "Open Payments" = "Federal", "PECOS revalidation" = "Federal",
  "Facility Affiliation (CCN)" = "Federal", "CMS NDH (FHIR)" = "Federal",
  "Medicaid" = "Federal", "State Boards of Nursing" = "State",
  "Healthgrades" = "Commercial", "Doximity" = "Commercial")
cov$custodian <- factor(
  ifelse(as.character(cov$source) %in% names(CUSTODIAN),
         CUSTODIAN[as.character(cov$source)], "Federal"),
  levels = c("Federal", "State", "Commercial"))

p1 <- ggplot(cov, aes(x = year, y = source, fill = custodian)) +
  geom_tile(width = 0.85, height = 0.6) +
  scale_x_continuous(breaks = seq(min(cov$year), max(cov$year), by = 2)) +
  scale_fill_manual(values = c(Federal = AUDIT_SERIES[1],
                               State = AUDIT_SERIES[3],
                               Commercial = AUDIT_SERIES[2])) +
  labs(caption = paste0("Parsed from \u00a72 of ", basename(APPENDIX),
                        gloss("NPPES", "DAC", "PECOS", "CCN", "CMS", "NDH", "FHIR")),
       x = "Program year", y = "Record system", fill = "Custodian") +
  theme_minimal(base_size = 13) +
  theme(panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
        legend.position = "bottom")
save_audit_fig(p1, "state_source_coverage_by_year", height = 5.2)

# --- Figure 2: agreement with NPPES by year -----------------------------------
agr_raw <- md_table(APPENDIX, c("Source", "% agree", "n comparable"))
agr <- agr_raw %>%
  transmute(source = Source, period = Period,
            n = md_num(`n comparable`), pct = md_num(`% agree`)) %>%
  filter(grepl("^\\d{4}$", period)) %>%
  mutate(year = as.integer(period)) %>%
  group_by(source) %>% filter(n() >= 2) %>% ungroup()

# A SOURCE'S LINE MUST BREAK WHERE IT HAS NO DATA. Facility Affiliation has no
# comparable year 2023-2025 (CMS dropped the CCN columns from the file), and
# geom_line will happily join 2022 straight to 2026 across the hole, drawing a
# four-year segment asserting agreement nobody measured. Padding the absent
# years with NA makes the gap visible instead of interpolated.
agr <- agr %>%
  tidyr::complete(source, year = seq(min(agr$year), max(agr$year))) %>%
  group_by(source) %>%
  filter(any(!is.na(pct)),
         year >= min(year[!is.na(pct)]), year <= max(year[!is.na(pct)])) %>%
  ungroup()

# THE TREND IS TESTED, NOT EYEBALLED. An earlier draft of the vignette called
# this panel a flat line. Weighted least squares over the thirteen DAC years
# through 2025 gives -0.248 points a year, p = 0.0002 -- a real decline -- so
# the fitted line is drawn to keep the corrected claim visible in the figure.
# The slope and p in the subtitle are COMPUTED from the parsed table, never
# typed; this comment records what they were on 2026-11-15 so a reader can
# tell at a glance whether a regenerated figure has moved. They did move:
# the table this is parsed from was three vintages stale until
# refresh_state_source_appendix_section3.R made it a rendering of
# artifacts/state_source_audit_agreement.csv, and it had been reporting
# -0.228 at p = 0.0014 from data that no longer existed.
dac_fit <- agr %>% filter(grepl("^DAC", source), year <= 2025, !is.na(pct))
dac_lm  <- lm(pct ~ year, data = dac_fit, weights = n)
dac_p   <- summary(dac_lm)$coefficients[2, 4]

p2 <- ggplot(agr, aes(x = year, y = pct, colour = source, group = source)) +
  geom_line(data = transform(dac_fit, pct = fitted(dac_lm)),
            linewidth = 1.7, colour = "grey74", alpha = 0.9) +
  geom_line(linewidth = 0.7, na.rm = TRUE) +
  geom_point(size = 1.9, na.rm = TRUE) +
  scale_x_continuous(breaks = seq(min(agr$year), max(agr$year), by = 2)) +
  scale_colour_manual(values = AUDIT_SERIES) +
  labs(caption = paste0("Parsed from \u00a73 of ", basename(APPENDIX),
                        "; trend by weighted least squares, weights = n comparable",
                        gloss("NPPES", "DAC", "PECOS", "CCN")),
       x = "Year", y = "Agreement with NPPES (%)", colour = "Record system") +
  theme_minimal(base_size = 13) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank(),
        plot.subtitle = element_text(size = 9.3, lineheight = 1.2))
save_audit_fig(p2, "state_source_agreement_by_year", height = 5.8)

# --- Figure 3: address granularity against the OIG benchmark ------------------
# Reads the OIG remake's own table 4 rather than the vignette's hand-built row.
# That table carries the 2011 benchmark per attribute AND separates two
# estimands the single number could not: `any_shared` (at least one reported
# value matches) and `same_set` (the complete reported value sets agree). A
# provider with several reported addresses cannot be reduced to one value, so
# both bars are drawn and neither is called "the" disagreement rate.
oig4 <- "artifacts/oig_remake/oig_table4_consistency_2019_and_2026.csv"
if (file.exists(oig4)) {
  t4 <- read_csv(oig4, show_col_types = FALSE, progress = FALSE) %>%
    filter(year == 2026, source_b == "dac",
           attribute %in% c("practice_state", "practice_zip5")) %>%
    # LABELS NAME WHAT THE BAR MEASURES, which is DISAGREEMENT. Naming these
    # columns after the matching rule ("at least one value matches") puts an
    # agreement phrase on a disagreement bar and inverts the figure's meaning
    # for anyone reading the legend before the axis.
    transmute(attribute,
              `no reported value in common` = pct_inconsistent_any_shared,
              `reported value sets differ`  = pct_inconsistent_same_set) %>%
    pivot_longer(-attribute, names_to = "basis", values_to = "pct")
  bench <- 88.6
  p3 <- ggplot(t4, aes(x = attribute, y = pct, fill = basis)) +
    geom_col(position = position_dodge(width = 0.7), width = 0.6) +
    geom_hline(yintercept = bench, linetype = "dashed", colour = "grey35") +
    # WHAT IS 88.6% A PERCENTAGE OF? The old label said "OIG 2011, all
    # Medicare providers, ZIP only: 88.6%" and never named the denominator or
    # the quantity, so a reader could not tell whether it was agreement or
    # disagreement, nor among whom. It is the share of the 987,266 providers
    # listed in BOTH federal systems whose practice-location ZIP did not match
    # between them.
    scale_y_continuous(limits = c(0, 100),
                       expand = expansion(mult = c(0, 0.02))) +
    # BELOW the benchmark rule, not above it: placed above, the three wrapped
    # lines ran off the top of the panel and the first one was cut in half.
    annotate("text", x = 0.55, y = bench - 5, hjust = 0, vjust = 1, size = 3.6,
             colour = "grey20", lineheight = 1.05,
             label = sprintf(paste0(
               "Inspector General 2011 benchmark: %.1f%% of 987,266 providers\n",
               "listed in both federal systems had a practice-location ZIP\n",
               "that did not match between them"), bench)) +
    geom_text(aes(label = sprintf("%.1f%%", pct)),
              position = position_dodge(width = 0.7), vjust = -0.5, size = 3.8) +
    scale_fill_manual(values = c(`no reported value in common` = AUDIT_SERIES[2],
                                 `reported value sets differ` = AUDIT_SERIES[1])) +
    scale_x_discrete(labels = c(practice_state = "Practice state",
                                practice_zip5 = "Practice ZIP code")) +
    labs(caption = paste0("artifacts/oig_remake/oig_table4_consistency_2019_and_2026.csv; ",
                          "benchmark OEI-07-09-00440 table 4", gloss("OIG")),
         x = "Geographic unit compared", y = "Records disagreeing (%)",
         fill = "Matching rule") +
    theme_minimal(base_size = 13) +
    theme(legend.position = "bottom", panel.grid.major.x = element_blank(),
          plot.subtitle = element_text(size = 9.5, lineheight = 1.2))
  save_audit_fig(p3, "address_granularity_vs_oig_benchmark", height = 5.2)
} else {
  message("SKIP figure 3: ", oig4, " absent")
}

# --- Figure 4: the independent multi-state check ------------------------------
# The vignette's multi-state finding rests on Open Payments licence columns,
# whose artifact is not tracked. This draws the same claim from a source that
# IS tracked and provenance-stamped: the Medicaid enrolment footprint, which
# counts the states a midwife was actually enrolled to bill in.
fp <- "artifacts/medicaid_enrollment_cohort_state_footprint.csv"
if (file.exists(fp)) {
  ms <- read_csv(fp, show_col_types = FALSE, progress = FALSE) %>%
    group_by(npi) %>% summarise(n_states = n_distinct(state), .groups = "drop") %>%
    mutate(band = cut(n_states, c(0, 1, 2, 3, 4, Inf),
                      labels = c("1 state", "2", "3", "4", "5 or more"))) %>%
    count(band) %>% mutate(pct = 100 * n / sum(n))
  p4 <- ggplot(ms, aes(x = band, y = pct)) +
    geom_col(fill = "grey30", width = 0.62) +
    geom_text(aes(label = sprintf("%.1f%%\n(%s)", pct, format(n, big.mark = ","))),
              vjust = -0.3, size = 3.1, lineheight = 0.95) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.16))) +
    labs(title = "Multi-state practice is not an edge case",
         subtitle = sprintf("State Medicaid programs each midwife was enrolled in, among %s midwives with any Medicaid enrollment. %.1f%% were enrolled in two or more at some point.",
                            format(sum(ms$n), big.mark = ","),
                            sum(ms$pct[ms$band != "1 state"])),
         caption = paste0(fp, " (set-membership footprint, not the modal reduction)"),
         x = NULL, y = "% of enrolled midwives") +
    theme_minimal(base_size = 13) +
    theme(panel.grid.major.x = element_blank(), panel.grid.minor = element_blank())
  save_audit_fig(p4, "medicaid_multistate_footprint", height = 5.0)
} else {
  message("SKIP figure 4: ", fp, " absent")
}

# --- Figure 5: what the one-state reduction costs --------------------------
# The vignette's strongest single illustration, rebuilt from data by
# analyze_medicaid_vs_ndh_state_reduction.R after the original figure's
# artifact was lost. Two questions, same records, same afternoon.
red <- "artifacts/medicaid_vs_ndh_state_reduction.csv"
if (file.exists(red)) {
  r <- read_csv(red, show_col_types = FALSE, progress = FALSE) %>%
    filter(band != "all") %>%
    mutate(band = factor(band, levels = c("1", "2", "3", "4", "5+")))
  long <- r %>%
    select(band, n_midwives,
           `Enrolled in a state NDH lists` = pct_enrolled_where_listed,
           `Her LARGEST Medicaid state is one NDH lists` = pct_largest_is_listed) %>%
    pivot_longer(c(-band, -n_midwives), names_to = "question", values_to = "pct")
  gap5 <- r$gap_points[r$band == "5+"]
  p5 <- ggplot(long, aes(x = band, y = pct, colour = question, group = question)) +
    geom_line(linewidth = 0.8) +
    geom_point(size = 2.4) +
    geom_text(data = subset(long, band == "5+"),
              aes(label = sprintf("%.1f%%", pct)), hjust = -0.25, size = 3.3, show.legend = FALSE) +
    geom_text(data = r, aes(x = band, y = 52, label = format(n_midwives, big.mark = ",")),
              inherit.aes = FALSE, size = 3, colour = "grey40") +

    scale_colour_grey(start = 0.1, end = 0.62) +
    scale_y_continuous(limits = c(50, 102)) +
    expand_limits(x = 5.75) +
    labs(title = sprintf("Same records, two questions, a %.0f-point gap", gap5),
         subtitle = paste0("Asked whether a midwife is enrolled in Medicaid somewhere CMS's directory lists her, the answer barely\n",
                           "moves with how many states she works in. Asked whether her LARGEST Medicaid state is one of them, it\n",
                           "falls away -- because reducing a multi-state provider to one state is a choice the comparison makes."),
         caption = paste0(red, "; counts below each point are midwives. ",
                          "NDH is treated as a set of states, not reduced to one",
                          gloss("NDH", "CMS")),
         x = "State Medicaid programs she is enrolled in", y = NULL, colour = NULL) +
    theme_minimal(base_size = 13) +
    theme(legend.position = "bottom", panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(),
          plot.subtitle = element_text(size = 9.3, lineheight = 1.2))
  save_audit_fig(p5, "medicaid_state_reduction_cost", height = 5.6)
} else {
  message("SKIP figure 5: ", red, " absent")
}

# --- Figure 6: consensus tier by licence count -----------------------------
# Rebuilt by analyze_consensus_tier_by_license_count.R from two artifacts that
# are now tracked. COMPOSITIONAL DATA, so 100% stacked bars: the question is
# how each group's midwives distribute across three ORDERED tiers, not how
# large the groups are (the n is given in the axis label instead). The fill is
# an ordered grey ramp because the tiers are ordered, which is a sequential
# encoding, not a categorical one.
lic <- "artifacts/consensus_tier_by_license_count.csv"
if (file.exists(lic)) {
  L <- read_csv(lic, show_col_types = FALSE, progress = FALSE)
  L <- L %>%
    # The artifact spells it "licence"; this journal is American. Relabelled
    # for display rather than rewriting the artifact, because the artifact is
    # the producer's output and a spelling is not a reason to move a number.
    mutate(tier = factor(tier, levels = c("split", "majority", "unanimous")),
           lic_band = sub("licence", "license", lic_band, fixed = TRUE),
           lic_band = sprintf("%s\n(n = %s)", lic_band, format(n_in_band, big.mark = ",")))
  sp <- L %>% filter(tier == "split") %>% arrange(pct)
  ratio <- max(sp$pct) / min(sp$pct)
  p6 <- ggplot(L, aes(x = lic_band, y = pct, fill = tier)) +
    geom_col(width = 0.58, colour = "white", linewidth = 0.9) +
    geom_text(aes(label = ifelse(pct >= 3.5, sprintf("%.1f%%", pct), "")),
              position = position_stack(vjust = 0.5), size = 3.3,
              colour = c("grey15", "grey15", "white")[as.integer(L$tier)]) +
    scale_fill_grey(start = 0.55, end = 0.2,
                    breaks = c("unanimous", "majority", "split")) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.02))) +
    coord_flip() +
    labs(title = "Midwives licensed in several states are the ones the sources disagree about",
         subtitle = sprintf(paste0("Consensus across the eleven-source comparison, by how many states CMS's Open Payments profile\n",
                                   "says she is licensed in. The split rate is %.1f times higher among multi-state licensees.\n",
                                   "chi-square(%d, n = %s) = %.0f, p < 2.2e-16. An association, not a per-case adjudication."),
                            ratio, L$chisq_df[1], format(L$chisq_n[1], big.mark = ","), L$chisq[1]),
         caption = paste0(lic, "; tiers from artifacts/mrost_consensus_tier_by_npi.csv",
                          gloss("CMS")),
         x = NULL, y = "% of midwives in each license group", fill = NULL) +
    theme_minimal(base_size = 13) +
    theme(legend.position = "bottom", panel.grid.major.y = element_blank(),
          panel.grid.minor = element_blank(),
          plot.subtitle = element_text(size = 9.3, lineheight = 1.2))
  save_audit_fig(p6, "consensus_tier_by_license_count", height = 5.0)
} else {
  message("SKIP figure 6: ", lic, " absent")
}

cat("done\n")
