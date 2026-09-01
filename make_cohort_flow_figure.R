#!/usr/bin/env Rscript
#' @title Figure: cohort flow from certification roster to rurality strata
#'
#' @description
#' A CONSORT-style flow for a linkage study, drawn from the stats catalog rather
#' than from typed numbers, so the figure cannot drift from the artifacts the
#' manuscript reports. If a disposition moves, this figure moves with it.
#'
#' @section What it is drawn to show:
#' The metropolitan share is taken among the members with an ASSIGNABLE COUNTY,
#' not among the cohort and not among the roster. Reporting it against either
#' wider denominator treats "we could not tell" as "not metropolitan", which is
#' the error that produced the superseded 86.5% figure. The edge carrying that
#' denominator is labelled, and the stratum that leaves the flow is dashed.
#'
#' @section Why this branches where a CONSORT ladder would not:
#' The roster splits three ways, TWO OF THOSE STRATA MERGE into one cohort, and
#' the cohort fans again. The merge is the cross-taxonomy rule made visible: a
#' nursing-only match is found and enters the cohort, and is still not promoted
#' into the primary midwifery stratum. See R/lib/flow_diagram.R for why the
#' existing ladder helpers could not draw it.
#'
#' Output: docs/figures/cohort_flow.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

source(file.path("R", "lib", "flow_diagram.R"))
source(file.path("manuscript", "R", "build_stats_catalog.R"))
source(file.path("manuscript", "R", "inline_stats.R"))
mw_init_stats(".")

NUM <- function(k) suppressWarnings(as.numeric(mw_stat(k, "%f")))
P   <- function(k) mw_stat(k, "%.1f")
fmt <- function(x) formatC(x, format = "d", big.mark = ",")

# Derived, never typed: if a disposition moves, the residual moves with it.
unresolved <- NUM("linkage.total") - NUM("linkage.matched") - NUM("linkage.nursing")
known <- NUM("cohort.known_n")
cohort_derived <- NUM("linkage.matched") + NUM("linkage.nursing")

nodes <- rbind(
  fd_node("roster", 1, "AMCB certification roster", fmt(NUM("linkage.total")),
          at = .44, kind = "lead", w = 236),

  fd_node("mid",  2, "Midwifery taxonomy", fmt(NUM("linkage.matched")),
          sprintf("%s%% of the roster", P("linkage.matched_pct")), at = .13, kind = "keep", w = 216),
  fd_node("nurs", 2, "Nursing taxonomy only", fmt(NUM("linkage.nursing")),
          "found, not promoted to primary", at = .38, kind = "keep", w = 216),
  fd_node("unres", 2, "Unresolved", fmt(unresolved),
          sprintf("%s tied - %s no candidate - %s other",
                  fmt(NUM("linkage.tied")), fmt(NUM("linkage.unmatched")),
                  fmt(NUM("linkage.heldout") + NUM("linkage.contested") + NUM("linkage.component"))),
          at = .78, kind = "drop", w = 330),

  # Derived from the two boxes that feed it, NOT read from panel.cohort_n. The
  # panel constant is pinned to the cohort as it stood when the provider panel
  # was built, and it disagreed with the live linkage table by 6 for three weeks
  # without anything noticing, because this node used to take it on trust.
  fd_node("cohort", 3, "Analytic cohort", fmt(cohort_derived),
          at = .28, kind = "lead", w = 260),

  fd_node("geo",  4, "County assignable", fmt(known), at = .20, kind = "keep", w = 226),
  fd_node("nogeo", 4, "No assignable county", fmt(NUM("cohort.unknown_n")),
          "never imputed -- law L3; excluded from every rurality percentage",
          at = .62, kind = "drop", w = 350),

  fd_node("met", 5, "Metropolitan - RUCC 1-3", fmt(NUM("cohort.metro_n")),
          sprintf("%s%%", P("cohort.metro_pct")), at = .14, kind = "band", w = 190),
  fd_node("adj", 5, "Nonmetro adjacent - 4-6",
          fmt(round(known * NUM("cohort.adj_pct") / 100)),
          sprintf("%s%%", P("cohort.adj_pct")), at = .36, kind = "band", w = 190),
  fd_node("rem", 5, "Nonmetro remote - 7-9",
          fmt(round(known * NUM("cohort.remote_pct") / 100)),
          sprintf("%s%%", P("cohort.remote_pct")), at = .58, kind = "band", w = 190)
)

edges <- rbind(
  fd_edge("roster", "mid",   "resolved to one provider record", "accent"),
  fd_edge("roster", "nurs",  NA, "accent"),
  fd_edge("roster", "unres", "not resolved"),
  fd_edge("mid",    "cohort", "both enter the cohort", "accent"),
  fd_edge("nurs",   "cohort", NA, "accent"),
  fd_edge("cohort", "geo",   "practice ZIP > ZCTA > county > RUCC 2023", "accent"),
  fd_edge("cohort", "nogeo", NA),
  fd_edge("geo",    "met",   "denominator of the metropolitan share", "accent"),
  fd_edge("geo",    "adj",   NA, "accent"),
  fd_edge("geo",    "rem",   NA, "accent")
)

# The counts must still add up after the catalog moved them, or the figure is a
# tidy picture of a roster that does not exist.
#
# THE CHECK THAT USED TO BE HERE COULD NOT FAIL. It read
#
#   unresolved <- total - matched - nursing
#   stopifnot(matched + nursing + unresolved == total)
#
# which substitutes to total == total for every possible input. It was the only
# assertion in this script, and the edge it did not cover -- "both enter the
# cohort" -- was wrong by 6 from 2026-08-10 until it was found on 2026-08-31.
# Both real identities are asserted below.
stopifnot(identical(unresolved, NUM("linkage.total") - cohort_derived))

if (!isTRUE(all.equal(cohort_derived, NUM("cohort.known_n") + NUM("cohort.unknown_n")))) {
  stop(sprintf(paste0(
    "MERGE DOES NOT RECONCILE, refusing to draw the flow.\n",
    "  midwifery %s + nursing %s = %s   (linkage_completeness_by_status.csv)\n",
    "  county assignable %s + none %s = %s   (composition_rucc_cat.csv)\n",
    "  difference: %+d\n\n",
    "These come from opposite sides of a re-freeze. The geography artifacts\n",
    "descend from artifacts/frozen_cohort/, which is pinned to an earlier\n",
    "cohort than the crosswalk. Re-pin it with repin_frozen_cohort.R on the\n",
    "machine holding the person-level files, then rebuild the composition\n",
    "table. tests/test_cohort_vintage.R reports which artifacts disagree."),
    fmt(NUM("linkage.matched")), fmt(NUM("linkage.nursing")), fmt(cohort_derived),
    fmt(NUM("cohort.known_n")), fmt(NUM("cohort.unknown_n")),
    fmt(NUM("cohort.known_n") + NUM("cohort.unknown_n")),
    cohort_derived - (NUM("cohort.known_n") + NUM("cohort.unknown_n"))),
    call. = FALSE)
}

lay <- fd_write(nodes, edges, file.path("docs", "figures", "cohort_flow"))

message(sprintf("roster reconciles: %s = %s + %s + %s",
                fmt(NUM("linkage.total")), fmt(NUM("linkage.matched")),
                fmt(NUM("linkage.nursing")), fmt(unresolved)))
message(sprintf("merge reconciles:  %s = %s + %s",
                fmt(cohort_derived), fmt(NUM("cohort.known_n")),
                fmt(NUM("cohort.unknown_n"))))
for (f in c("pdf", "png", "svg"))
  message(sprintf("written: docs/figures/cohort_flow.%-4s %s bytes", f,
                  format(file.size(file.path("docs", "figures", paste0("cohort_flow.", f))), big.mark = ",")))
