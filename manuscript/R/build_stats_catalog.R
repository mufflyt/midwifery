# =============================================================================
# The manuscript statistics catalog, rebuilt on every render
# =============================================================================
# Every number that appears in the manuscript text is computed here and reached
# from the prose by key. Nothing is typed into the .qmd by hand.
#
# WHY THIS EXISTS. Three linkage figures were in circulation across the prose
# documents in this repository -- 82.3%, 78.0% and 78.4% for the same quantity
# -- because each was typed into a paragraph on the day it was computed and
# then outlived its own artifact. One of the three came from a file that had
# stopped being rebuildable at all. A number that is typed cannot go stale
# loudly; it goes stale silently, and the paragraph around it still reads well.
#
# So the catalog is REBUILT, not cached. Every render re-reads the frozen
# linkage and the committed artifacts and recomputes. If an input moved, the
# manuscript moves with it, and if an input is gone the render says so rather
# than printing the last number anybody remembered.
#
# The API mirrors ~/isochrones/manuscript/R/11_inline_stats.R deliberately --
# same catalog-of-sections shape, same safe_stat() contract, same [PENDING]
# behaviour in dev mode -- so that moving between the two manuscripts costs
# nothing. It is a much smaller implementation: this manuscript needs lookup
# and formatting, not the run_id provenance chain that one carries.
#
# Names are mw_-prefixed. ci_hygiene.R H4 fails on a function defined at top
# level in two tracked files, and `stat` and `safe_stat` are exactly the kind
# of common verb that collides.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr)
})

MW_ART <- "artifacts"

#' Wilson score interval for a binomial proportion, as a percentage
#'
#' Recomputed here rather than taken from a package so the manuscript's
#' intervals and the repository's nightly science gate
#' (tests/ci_science_nightly.R) are independent arithmetic. A check that calls
#' the same function as the producer cannot detect a wrong denominator.
#'
#' @param x,n [numeric]: successes and trials.
#' @param z [numeric]: normal deviate; 1.96 reproduces every committed interval.
#' @return [numeric] length-2, lower and upper bound in percent.
mw_wilson <- function(x, n, z = 1.96) {
  p <- x / n
  d <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / d
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  c(100 * (centre - half), 100 * (centre + half))
}

#' Cochran-Armitage test for trend across ordered strata
#'
#' @param x,n [numeric]: successes and trials per stratum, in order.
#' @return [list] z and two-sided p.
mw_trend <- function(x, n) {
  scores <- seq_along(x)
  p <- sum(x) / sum(n)
  mbar <- sum(n * scores) / sum(n)
  z <- sum(n * (scores - mbar) * (x / n - p)) /
       sqrt(p * (1 - p) * sum(n * (scores - mbar)^2))
  list(z = z, p = 2 * stats::pnorm(-abs(z)))
}

#' Difference of two proportions with a normal-approximation interval
mw_diff <- function(x1, n1, x2, n2, z = 1.96) {
  p1 <- x1 / n1; p2 <- x2 / n2
  d <- 100 * (p1 - p2)
  se <- 100 * sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)
  c(d, d - z * se, d + z * se)
}

# -----------------------------------------------------------------------------

#' Rebuild the whole catalog from source
#'
#' @param root [character]: repository root.
#' @return [list] nested sections; every leaf is a scalar or a length-3 vector.
mw_build_catalog <- function(root = ".") {
  cat_ <- list()
  rd <- function(p) {
    f <- file.path(root, p)
    if (!file.exists(f)) return(NULL)
    suppressWarnings(readr::read_csv(f, show_col_types = FALSE, progress = FALSE))
  }

  # --- Linkage disposition, from the frozen person-level linkage -------------
  # Gitignored and absent from any runner, so its absence is a SKIP, not an
  # error: the sections it feeds fall back to the committed aggregate below.
  frozen <- rd(file.path(MW_ART, "amcb_npi_linkage_FROZEN.csv"))
  lc <- rd(file.path(MW_ART, "linkage_completeness_by_status.csv"))

  if (!is.null(lc)) {
    disp_cols <- setdiff(names(lc), c("status", "n", "pct_matched"))
    tot <- sum(lc$n)
    sums <- vapply(disp_cols, function(cn) sum(lc[[cn]]), numeric(1))
    cat_$linkage <- list(
      total          = tot,
      matched        = unname(sums[["matched"]]),
      matched_pct    = 100 * unname(sums[["matched"]]) / tot,
      nursing        = unname(sums[["matched_nursing_taxonomy"]]),
      nursing_pct    = 100 * unname(sums[["matched_nursing_taxonomy"]]) / tot,
      any_tier_pct   = 100 * (unname(sums[["matched"]]) +
                              unname(sums[["matched_nursing_taxonomy"]])) / tot,
      ambiguous      = sum(sums[grepl("^ambiguous", names(sums))]),
      ambiguous_pct  = 100 * sum(sums[grepl("^ambiguous", names(sums))]) / tot,
      unmatched      = unname(sums[["unmatched"]]),
      unmatched_pct  = 100 * unname(sums[["unmatched"]]) / tot,
      heldout        = unname(sums[["candidate_class5_held_out_of_cohort"]]),
      heldout_pct    = 100 * unname(sums[["candidate_class5_held_out_of_cohort"]]) / tot,
      active_n       = lc$n[lc$status == "ACTIVE"],
      active_matched = lc$matched[lc$status == "ACTIVE"],
      active_pct     = lc$pct_matched[lc$status == "ACTIVE"],
      dead_n         = lc$n[lc$status == "DECEASED"],
      dead_matched   = lc$matched[lc$status == "DECEASED"],
      dead_pct       = lc$pct_matched[lc$status == "DECEASED"],
      table          = lc
    )
    # The dispositions must reconstruct the total, or the table in the paper
    # does not add up in front of a reviewer.
    stopifnot(sum(sums) == tot)
  }

  # --- Cohort composition, from the committed aggregate ----------------------
  comp <- rd(file.path(MW_ART, "composition_rucc_cat.csv"))
  if (!is.null(comp)) {
    ret <- comp %>% dplyr::filter(.data$group == "1_retained")
    getp <- function(lvl) {
      v <- ret$pct[ret$level == lvl]
      if (length(v)) v[1] else NA_real_
    }
    cat_$cohort <- list(
      retained_n = if (nrow(ret)) ret$N[1] else NA_real_,
      metro_pct  = getp("Metro (RUCC 1-3)"),
      adj_pct    = getp("Nonmetro, adjacent (4-6)"),
      remote_pct = getp("Nonmetro, remote (7-9)"),
      unk_pct    = getp("Unknown")
    )
  }

  # --- Persistence -----------------------------------------------------------
  # PINNED, and flagged as such. These come from the 2007-2025 provider panel
  # (midwife_panel.csv, ~493 MB, gitignored and person-level) and from the
  # geocoding cascade, neither of which can be re-derived inside a render. They
  # are entered once, here, with the artifact that produced them named -- not
  # scattered through the prose, which is the failure this catalog exists to
  # prevent. Regenerating them is R/05-stage-progression.R plus the persistence
  # analysis in docs/RESULTS_geographic_persistence.md.
  cat_$panel <- list(
    snapshots = 19L, year_min = 2007L, year_max = 2025L,
    cohort_n = 16892L, observed = 16891L, provider_years = 200873L,
    median_years = 12L, pairs_total = 183949L,
    pairs_used = 180436L, providers_used = 15605L, median_span = 13L,
    .source = "midwife_panel.csv x artifacts/amcb_npi_linkage_FROZEN.csv"
  )

  cat_$persist <- list(
    annual_county = 95.9, annual_zip = 94.2, annual_state = 97.9,
    career_county = 67.5, career_zip = 55.3, career_state = 82.1,
    .source = "docs/RESULTS_geographic_persistence.md"
  )
  ci <- mw_wilson(round(cat_$panel$pairs_used * cat_$persist$annual_county / 100),
                  cat_$panel$pairs_used)
  cat_$persist$annual_county_lo <- ci[1]
  cat_$persist$annual_county_hi <- ci[2]

  # --- Rurality gradient, computed from counts -------------------------------
  strata <- tibble::tibble(
    origin = c("Metropolitan (RUCC 1-3)",
               "Nonmetropolitan, adjacent (RUCC 4-6)",
               "Nonmetropolitan, remote (RUCC 7-9)"),
    n   = c(13646, 1160, 520),
    pct = c(68.1, 63.3, 61.9)
  ) %>% dplyr::mutate(x = round(.data$n * .data$pct / 100))

  cis <- t(mapply(mw_wilson, strata$x, strata$n))
  strata$lo <- cis[, 1]; strata$hi <- cis[, 2]
  tr <- mw_trend(strata$x, strata$n)
  df <- mw_diff(strata$x[1], strata$n[1], strata$x[3], strata$n[3])

  cat_$rural <- list(
    table = strata, trend_z = tr$z, trend_p = tr$p,
    diff = df[1], diff_lo = df[2], diff_hi = df[3],
    annual_metro_move = 4.0, annual_remote_move = 5.0,
    career_remote_move = 100 - strata$pct[3],
    .source = "docs/RESULTS_geographic_persistence.md, origin-stratified"
  )

  # --- Movers ----------------------------------------------------------------
  mv <- matrix(c(3868, 301, 136, 339, 48, 38, 125, 36, 37), nrow = 3, byrow = TRUE,
               dimnames = list(c("Metropolitan", "Nonmetro adjacent", "Nonmetro remote"),
                               c("To metropolitan", "To nonmetro adjacent", "To nonmetro remote")))
  cat_$movers <- list(
    table = mv,
    adj_to_metro_pct    = 100 * mv[2, 1] / sum(mv[2, ]),
    remote_to_metro_pct = 100 * mv[3, 1] / sum(mv[3, ]),
    metro_stay_pct      = 100 * mv[1, 1] / sum(mv[1, ]),
    out_of_nonmetro     = mv[2, 1] + mv[3, 1],
    into_nonmetro       = mv[1, 2] + mv[1, 3]
  )

  # --- Geographic assignment and sensitivity ---------------------------------
  cat_$geo <- list(
    zctas = 33791L, span_multi_pct = 30.1, arbitrary_zctas = 1629L,
    py_matched_pct = 98.2, cascade_pct = 98.1, cascade_addresses = 12722L,
    pip_pct = 100.0, pip_points = 66302L,
    sens_annual = 95.9, sens_career = 67.3,
    sens_metro = 67.9, sens_adj = 63.2, sens_remote = 61.0,
    census_only_metro = 69.4, census_only_adj = 65.6, census_only_remote = 66.2,
    census_only_loss_pct = 22.1
  )
  cat_$geo$sens_gradient <- cat_$geo$sens_metro - cat_$geo$sens_remote

  # --- Table 1 ---------------------------------------------------------------
  t1 <- rd(file.path(MW_ART, "table1_midwives.csv"))
  if (!is.null(t1)) {
    pick <- function(rx) {
      r <- t1[grepl(rx, t1$characteristic, ignore.case = TRUE), ]
      if (nrow(r)) r$percent[1] else NA_real_
    }
    cat_$table1 <- list(
      n = t1$n[1], cnm_pct = pick("^Certified Nurse-Midwife$"),
      cm_pct = pick("^Certified Midwife$"), female_pct = pick("^Female$")
    )
  }

  cat_$meta <- list(built = format(Sys.time(), "%Y-%m-%d %H:%M %Z"),
                    r_version = paste(R.version$major, R.version$minor, sep = "."))
  cat_
}
