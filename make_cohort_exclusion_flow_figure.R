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
acog_excluded_n <- stat_num("exclusion.acog_excluded_n")
final_cohort_n  <- stat_num("exclusion.final_cohort_n")

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
if (is.na(acog_excluded_n) || is.na(final_cohort_n)) {
  stop(paste0(
    "exclusion.acog_excluded_n / exclusion.final_cohort_n are not in the\n",
    "catalog. build_geography_by_amcb_status.R needs to be re-run (it now\n",
    "writes n_acog_unmapped) before this figure can draw the ACOG-district\n",
    "exclusion stage -- see its own header for why nppes_state is required."),
    call. = FALSE)
}

# Roster reconciles all the way down, asserted again here (not just in the
# catalog builder) because this is the figure a reviewer will check by eye
# against the numbers in the boxes.
stopifnot(
  active_n + inactive_n == roster_n,
  matched_n + unmatched_n == active_n,
  geocoded_n + not_geocoded_n == matched_n,
  final_cohort_n + acog_excluded_n == geocoded_n
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

# A disposition currently at zero is not published as its own line -- an
# itemised "N = 0" reads as if that failure mode is being watched for and
# simply didn't occur this run, when in this codebase's dispositions it
# usually means the category has been superseded/renamed (see "Held out of
# cohort" below) rather than that zero people hit it. The itemisation stays
# exhaustive in the underlying stat (nothing is dropped from the catalog),
# only the zero-count line is suppressed on the figure.
nonzero_lines <- function(counts, labels) {
  keep <- counts > 0
  if (!any(keep)) return("")
  paste(sprintf("%s, N = %s", labels[names(counts)][keep], fmt(counts[keep])),
        collapse = "\n")
}

# "No NPI match" here means match_status != "primary" -- six structurally
# different failure modes, not one undifferentiated bucket: three are
# genuine non-matches (unmatched, tied names, contested NPI, unruled-out
# component) and two are candidate NPIs that WERE found but held to a
# stricter identity-confidence bar (fuzzy surname, nursing-only taxonomy) --
# see reconcile_linkage.R's header comment for why those two are excluded
# from "matched" rather than counted as confirmed identity.
unmatched_by_reason <- .mw_get("exclusion.active_unmatched_by_reason", .mw_catalog)
unmatched_reason_labels <- c(
  unmatched                       = "Unmatched, no candidate found",
  ambiguous_tied_names            = "Tied names, evidence could not separate",
  ambiguous_contested_npi         = "Contested NPI, claimed by 2+ certificants",
  ambiguous_unruled_out_component = "Unruled-out component",
  sensitivity_fuzzy               = "Fuzzy surname match (weak identity evidence)",
  sensitivity_nursing_taxonomy    = "Nursing-only taxonomy (not confirmed midwifery)"
)
exc_unmatched_lines <- nonzero_lines(unmatched_by_reason, unmatched_reason_labels)

# Match evidence tiers among the PRIMARY-matched only (exclusion.
# active_matched_by_tier): "matched" is not one undifferentiated confidence
# level even after excluding the sensitivity tiers above. Tiers are the
# ordered name-evidence classes from match_amcb_to_npi.R (1 strongest, 5
# weakest) -- see that script's own comment block above strategy 5 for the
# exact definitions.
matched_by_tier <- .mw_get("exclusion.active_matched_by_tier", .mw_catalog)
tier_labels <- c(
  exact_name_plus_middle        = "Exact name, middle corroborates",
  exact_name_no_middle_info     = "Exact name, no middle to compare",
  exact_last_first_initial      = "Exact last name + first initial",
  fuzzy_last_exact_first        = "Fuzzy last name, exact first",
  surname_component_exact_first = "Surname component, exact first"
)
matched_tier_lines <- nonzero_lines(matched_by_tier, tier_labels)

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
    N = geocoded_n, label = "Geocodable address",
    text_pattern = "{label}\nN = {n} ({perc}%)",
    show_exc = TRUE, label_exc = "No geocodable address",
    text_pattern_exc = "{label}\nN = {n} ({perc}%)"
  ) %>%
  fc_filter(
    N = final_cohort_n, label = "Final analytic cohort",
    text_pattern = "{label}\nN = {n} ({perc}%)",
    show_exc = TRUE, label_exc = "No ACOG district",
    text_pattern_exc = "{label}\nN = {n} ({perc}%)\nOverseas-military or\nUS-territory address"
  )

fc_plot <- fc %>%
  fc_draw(big.mark = ",", box_corners = "sharp")

out_dir <- file.path("docs", "figures")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
# Taller than the box content alone would suggest: flowchart lays rows out
# at even FRACTIONS of total canvas height regardless of how many lines a
# box's text_pattern carries, so adding stages/itemised lines (which this
# figure has both of) shrinks the room between rows unless the canvas grows
# to compensate. A canvas too short for its content overlaps neighbouring
# boxes rather than erroring -- verified visually, not assumed.
for (f in c("cohort_exclusion_flow.png", "cohort_exclusion_flow.pdf")) {
  fc_export(fc_plot, f, path = out_dir, width = 11, height = 16, units = "in", res = 300)
}

counts <- data.frame(
  stage = c("roster", "active", "inactive", "matched", "unmatched",
           "geocoded", "not_geocoded", "final_cohort", "acog_excluded"),
  n = c(roster_n, active_n, inactive_n, matched_n, unmatched_n,
       geocoded_n, not_geocoded_n, final_cohort_n, acog_excluded_n)
)
counts_path <- file.path("docs", "figures", "cohort_exclusion_flow_counts.csv")
write_with_provenance(
  counts, counts_path,
  inputs = c(file.path("artifacts", "linkage_completeness_by_status.csv"),
            file.path("artifacts", "geography_by_amcb_status.csv"))
)

# Match evidence tiers, as a companion table rather than crammed into the
# "Matched to an NPI" box: the flowchart package lays boxes out on a fixed
# grid, and the 5-line tier breakdown made that box overflow into its
# neighbours (clipped/overlapping text) -- a tabular breakdown is also just a
# better fit for this than a flowchart node.
tiers <- data.frame(
  tier = names(matched_by_tier),
  label = unname(tier_labels[names(matched_by_tier)]),
  n = as.integer(matched_by_tier),
  pct_of_matched = round(100 * as.integer(matched_by_tier) / matched_n, 1)
)
tiers_path <- file.path("docs", "figures", "cohort_exclusion_flow_evidence_tiers.csv")
write_with_provenance(
  tiers, tiers_path,
  inputs = c(file.path("artifacts", "amcb_npi_linkage_FROZEN.csv"))
)

message(sprintf("roster reconciles:   %s = %s + %s", fmt(roster_n), fmt(active_n), fmt(inactive_n)))
message(sprintf("active reconciles:   %s = %s + %s", fmt(active_n), fmt(matched_n), fmt(unmatched_n)))
message(sprintf("matched reconciles:  %s = %s + %s", fmt(matched_n), fmt(geocoded_n), fmt(not_geocoded_n)))
message(sprintf("geocoded reconciles: %s = %s + %s", fmt(geocoded_n), fmt(final_cohort_n), fmt(acog_excluded_n)))
for (f in c("cohort_exclusion_flow.png", "cohort_exclusion_flow.pdf")) {
  p <- file.path(out_dir, f)
  if (file.exists(p))
    message(sprintf("written: %-40s %s bytes", p, format(file.size(p), big.mark = ",")))
}
message(sprintf("written: %-40s", counts_path))
