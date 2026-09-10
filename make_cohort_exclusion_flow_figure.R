#!/usr/bin/env Rscript
#' @title Figure: exclusion flow from the AMCB roster to the analytic cohort
#'
#' @description
#' A CONSORT-style ladder, drawn from the stats catalog rather than typed
#' numbers, showing every reason a certificant was excluded on the way from
#' the raw AMCB roster to the final analytic cohort: (1) not currently
#' certified (deceased or inactive), (2) no NPI match, (3) no geocodable
#' address. This is deliberately separate from `make_cohort_flow_figure.R`,
#' which is strata-focused (metro/nonmetro composition of the cohort) rather
#' than exclusion-focused.
#'
#' @section Built on the flowchart package, not R/lib/flow_diagram.R:
#' The first version of this figure used this repo's own hand-rolled grid
#' renderer (built for `make_cohort_flow_figure.R`'s branching/merging
#' shape). This figure's shape is a strict ladder -- every stage a subset of
#' the one before it -- which needed none of that renderer's branching
#' machinery, and every hand-tuned box width / line-height / label-halo
#' choice it DID need turned into a real, user-visible bug at least once
#' (labels overlapping each other, a two-line sub-label printing on top of
#' the line below it, an arrow crossing through a label it was meant to sit
#' behind). `flowchart` (CRAN; already installed here; already used by
#' ~/isochrones/manuscript/R/create_figure1_consort_flow.R for the same
#' purpose) computes N and % itself from pre-computed counts
#' (`as_fc(N = ...)` / `fc_filter(N = ...)`, no row-level data required),
#' sizes every box to its own text automatically, and needed none of the
#' above hand-maintained layout logic.
#'
#' @section Why "active" means AMCB status == ACTIVE:
#' Every other AMCB certification status (LAPSED, RETIRED, EMERITUS,
#' DEACTIVATED, REVOKED, SURRENDERED, SUSPENDED) is folded into "deceased or
#' inactive" alongside DECEASED, because ACTIVE is the only status meaning
#' "currently certified." That's a judgement call for EMERITUS in particular
#' (27 people) -- the per-status breakdown is itemised inside the exclusion
#' box specifically so it's auditable rather than buried in one total.
#'
#' Output: docs/figures/cohort_exclusion_flow.png (+ .pdf)
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(flowchart)
  library(dplyr)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("manuscript", "R", "build_stats_catalog.R"))
source(file.path("manuscript", "R", "inline_stats.R"))
mw_init_stats(".")

stat_num <- function(k) suppressWarnings(as.numeric(mw_stat(k, "%f")))
fmt <- function(x) format(x, big.mark = ",", trim = TRUE)

roster_n   <- stat_num("exclusion.roster_n")
active_n   <- stat_num("exclusion.active_n")
inactive_n <- stat_num("exclusion.inactive_n")
matched_n   <- stat_num("exclusion.active_matched_n")
unmatched_n <- stat_num("exclusion.active_unmatched_n")
geocoded_n     <- stat_num("exclusion.geocoded_n")
not_geocoded_n <- stat_num("exclusion.not_geocoded_n")

if (is.na(geocoded_n) || is.na(not_geocoded_n)) {
  stop(paste0(
    "exclusion.geocoded_n / exclusion.not_geocoded_n are not in the catalog.\n",
    "This figure requires artifacts/geography_by_amcb_status.csv, which is\n",
    "not yet a committed artifact. Run build_geography_by_amcb_status.R on\n",
    "the machine holding the frozen person-level linkage and geography\n",
    "files, commit its output, then re-run this script. A figure that\n",
    "silently omitted this stage would misrepresent who was excluded and\n",
    "why -- so this stops rather than drawing three of the four stages."),
    call. = FALSE)
}

# Roster reconciles all the way down, asserted again here (not just in the
# catalog builder) because this is the figure a reviewer will check by eye
# against the numbers in the boxes.
stopifnot(
  active_n + inactive_n == roster_n,
  matched_n + unmatched_n == active_n,
  geocoded_n + not_geocoded_n == matched_n
)

inactive_by_status <- .mw_get("exclusion.inactive_by_status", .mw_catalog)
# Lapsed / Retired / Deceased each get their own line, each stated as
# "N = ####"; the remaining five statuses (emeritus, deactivated, revoked,
# surrendered, suspended -- 72 people combined) are folded into one "Other"
# line so the three the user asked to see by name stay legible.
named3 <- c("lapsed", "retired", "deceased")
other_n <- sum(inactive_by_status[setdiff(names(inactive_by_status), named3)])
exc_inactive_lines <- paste(
  sprintf("%s, N = %s", tools::toTitleCase(named3), fmt(inactive_by_status[named3])),
  collapse = "\n"
)
exc_inactive_lines <- paste0(exc_inactive_lines, sprintf("\nOther, N = %s", fmt(other_n)))

# "No NPI match" is three structurally different failure modes plus one
# deliberate hold-out (exclusion.active_unmatched_by_reason), not one
# undifferentiated bucket -- itemised the same way inactive_by_status is
# above, each stated as its own "N = ####" line.
unmatched_by_reason <- .mw_get("exclusion.active_unmatched_by_reason", .mw_catalog)
unmatched_reason_labels <- c(
  unmatched = "Unmatched, no candidate found",
  tied      = "Tied names, evidence could not separate",
  contested = "Contested NPI, claimed by 2+ certificants",
  component = "Unruled-out component",
  held_out  = "Held out of cohort"
)
exc_unmatched_lines <- paste(
  sprintf("%s, N = %s",
          unmatched_reason_labels[names(unmatched_by_reason)],
          fmt(unmatched_by_reason)),
  collapse = "\n"
)

# Overseas-military / US-territory addresses ARE geocodable and ARE in the
# cohort -- they just have no ACOG district, so they're a note on the KEPT
# side, not an exclusion. Denominator is deliberately stated alongside the
# count: table1.n (11,920, ACTIVE + PRIMARY-linked only) is a narrower
# population than this box's own N (geocoded_n, ACTIVE + primary-OR-nursing
# match), so the two must not be presented as sharing one percentage base.
acog_excluded_n   <- stat_num("table1.acog_excluded_n")
acog_excluded_pct <- stat_num("table1.acog_excluded_pct")
acog_note <- if (!is.na(acog_excluded_n)) {
  sprintf("\nIncludes %s (%s%%) with an overseas-military or\nUS-territory address (no ACOG district),\nof %s ACTIVE, primary-linked midwives",
          fmt(acog_excluded_n), formatC(acog_excluded_pct, digits = 1, format = "f"),
          fmt(stat_num("table1.n")))
} else ""

fc <- as_fc(
    N = roster_n, label = "AMCB certification roster",
    text_pattern = "{label}\nN = {N}"
  ) %>%
  fc_filter(
    N = active_n, label = "Active certification",
    text_pattern = "{label}\nN = {n} ({perc}%)",
    show_exc = TRUE, label_exc = "Deceased or inactive",
    text_pattern_exc = paste0("{label}\nN = {n} ({perc}%)\n", exc_inactive_lines)
  ) %>%
  fc_filter(
    N = matched_n, label = "Matched to an NPI",
    text_pattern = "{label}\nN = {n} ({perc}%)",
    show_exc = TRUE, label_exc = "No NPI match",
    text_pattern_exc = paste0("{label}\nN = {n} ({perc}%)\n", exc_unmatched_lines)
  ) %>%
  fc_filter(
    N = geocoded_n, label = "Final analytic cohort",
    text_pattern = paste0("{label}\nN = {n} ({perc}%)\nGeocodable address", acog_note),
    show_exc = TRUE, label_exc = "No geocodable address",
    text_pattern_exc = "{label}\nN = {n} ({perc}%)"
  )

fc_plot <- fc %>%
  fc_draw(big.mark = ",", box_corners = "sharp",
          title = "Cohort Selection Flowchart", title_fs = 14, title_fface = 1)

out_dir <- file.path("docs", "figures")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
for (f in c("cohort_exclusion_flow.png", "cohort_exclusion_flow.pdf")) {
  fc_export(fc_plot, f, path = out_dir, width = 10, height = 9, units = "in", res = 300)
}

counts <- data.frame(
  stage = c("roster", "active", "inactive", "matched", "unmatched",
           "geocoded", "not_geocoded"),
  n = c(roster_n, active_n, inactive_n, matched_n, unmatched_n,
       geocoded_n, not_geocoded_n)
)
counts_path <- file.path("docs", "figures", "cohort_exclusion_flow_counts.csv")
write_with_provenance(
  counts, counts_path,
  inputs = c(file.path("artifacts", "linkage_completeness_by_status.csv"),
            file.path("artifacts", "geography_by_amcb_status.csv"))
)

message(sprintf("roster reconciles:   %s = %s + %s", fmt(roster_n), fmt(active_n), fmt(inactive_n)))
message(sprintf("active reconciles:   %s = %s + %s", fmt(active_n), fmt(matched_n), fmt(unmatched_n)))
message(sprintf("matched reconciles:  %s = %s + %s", fmt(matched_n), fmt(geocoded_n), fmt(not_geocoded_n)))
for (f in c("cohort_exclusion_flow.png", "cohort_exclusion_flow.pdf")) {
  p <- file.path(out_dir, f)
  if (file.exists(p))
    message(sprintf("written: %-40s %s bytes", p, format(file.size(p), big.mark = ",")))
}
message(sprintf("written: %-40s", counts_path))
