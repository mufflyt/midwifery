#!/usr/bin/env Rscript
# =============================================================================
# Rebuild every artifact derived from the frozen cohort, in a declared order
# =============================================================================
#
# DRY RUN BY DEFAULT. This script does NOT execute anything unless
# REBUILD_APPLY=1. A rebuild runner that acts on import is a footgun in a repo
# where two sessions have been writing concurrently all day.
#
# WHY A DECLARED ORDER AND NOT A DISCOVERED ONE. Static analysis can find WHO
# reads the frozen cohort; it cannot reliably infer the order they must run in,
# because paths are built with file.path()/sprintf() and some stages depend on
# each other's outputs rather than on the cohort directly. So the order is
# declared here, by hand, and the runner FAILS if the declared set and the
# discovered set disagree -- drift is caught rather than assumed away.
#
# WHAT THIS DELIBERATELY WILL NOT DO:
#   * touch or promote artifacts/amcb_npi_linkage_FROZEN.csv
#   * run network/scraping scripts. Re-running a scraper is not a rebuild, it
#     is a NEW OBSERVATION, and it would move inputs the freeze holds still.
#     They are listed and skipped.
#
# Usage:
#   Rscript rebuild_frozen_dependents.R              # dry run: plan + coverage
#   REBUILD_APPLY=1 Rscript rebuild_frozen_dependents.R
#   REBUILD_VERIFY_ONLY=1 Rscript rebuild_frozen_dependents.R
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(digest)})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)
source(file.path(root_dir, "R", "frozen_dependency_graph.R"))
source(file.path(root_dir, "R", "lib", "artifact_provenance.R"))
source(file.path(root_dir, "R", "amcb_match_rules.R"))   # assert_nonempty_selection

APPLY       <- identical(Sys.getenv("REBUILD_APPLY", "0"), "1")
VERIFY_ONLY <- identical(Sys.getenv("REBUILD_VERIFY_ONLY", "0"), "1")

# --- The declared order ------------------------------------------------------
# Grouped by dependency layer. Within a layer order does not matter; between
# layers it does. Derived from the read/write graph plus the chain established
# empirically when county_base changed: R/01 -> R/10 -> R/02 -> R/05 -> R/03.
REBUILD_ORDER <- list(
  list(layer = "1-linkage-audit", why = "re-audit the cohort itself before anything consumes it",
       # reconcile_linkage.R is NOT here: it PRODUCES the freeze from
       # amcb_npi_matched.csv. Running it inside a rebuild regenerates FROZEN
       # from stale inputs and destroys the promotion the rebuild exists to
       # propagate -- which is exactly what happened on 2026-08-10.
       scripts = c("audit_amcb_crosswalk.R", "verify_linkage_arms.R")),
  list(layer = "2-cohort-structure", why = "cohort flow/composition/progression read FROZEN directly",
       scripts = c("R/05-stage-progression.R", "R/06-cohort-flow.R",
                   "R/07-cohort-composition.R")),
  list(layer = "3-geography", why = "geography hierarchy depends on the cohort membership above",
       scripts = c("R/03-geography-hierarchy.R", "geocode_panel_addresses.R",
                   "audit_coordinate_provenance.R", "compare_geography_versions.R")),
  list(layer = "4-derived-products", why = "products that consume cohort + geography",
       scripts = c("load_obstetric_providers.R", "match_midwives_to_isochrones.R",
                   "characterize_isochrone_representation.R",
                   "map_midwife_geography.R", "render_midwifery_map.R",
                   # Added 2026-08-15, by the same completeness gate and for the
                   # same reason as match_medicare_partb_partd.R below: these
                   # four appeared since the order was declared and all read
                   # amcb_npi_linkage_FROZEN. Undeclared, a rebuild would have
                   # left them holding the previous cohort while reporting
                   # success -- the exact failure this gate exists to prevent.
                   #
                   # Order within the layer is a real dependency, not a guess:
                   # extract_dac writes dac_facility_affiliations.csv and
                   # link_practice_locations writes midwife_org_person.csv,
                   # and resolve_org_ambiguity reads BOTH, so it must follow.
                   "extract_dac_facility_affiliations.R",
                   "link_practice_locations_to_org_npi.R",
                   "resolve_org_ambiguity.R",
                   "match_open_payments_to_facility.R")),
  list(layer = "5-enrichment-recompute", why = "age/enrichment recomputes from cached inputs (no network)",
       scripts = c("calibrate_amcb_certification_ages.R", "enrich_doximity_cnm_ages.R",
                   "match_florida_voter_ages.R", "sweep_healthgrades_enrichment.R",
                   # Added 2026-08-10: the completeness gate discovered this
                   # consumer had appeared since the order was declared, and
                   # REFUSED to rebuild until it was placed. That is the gate
                   # doing its job -- undeclared, it would have been left
                   # holding the old cohort with the rebuild reporting success.
                   "match_medicare_partb_partd.R")),
  list(layer = "6-publication", why = "tables last: they read everything above",
       # export_amcb_npi_geography.R writes the tracked state aggregate and
       # the gitignored person-level export, both of which read the crosswalk
       # and its geography. It is a publication product, so it belongs after
       # everything it summarises.
       scripts = c("build_table1_midwives.R", "export_amcb_npi_geography.R",
                   "provenance_manifest.R"))
)
declared <- unlist(lapply(REBUILD_ORDER, `[[`, "scripts"))

# --- Completeness: declared vs discovered ------------------------------------
rep <- frozen_dependency_report(".")
reb <- frozen_rebuildable(rep$consumers)
discovered <- reb$script
assert_nonempty_selection(discovered, "FROZEN consumer discovery")

missing_from_declared <- setdiff(discovered, declared)
declared_not_discovered <- setdiff(declared, discovered)

cat("================ FROZEN DEPENDENCY RUNNER ================\n")
cat(sprintf("mode: %s\n\n", if (VERIFY_ONLY) "VERIFY ONLY" else if (APPLY) "APPLY (will execute)" else "DRY RUN (default; nothing executes)"))
cat(sprintf("FROZEN               : %s\n", FROZEN_PATH))
cat(sprintf("FROZEN sha256        : %s\n", digest::digest(file = FROZEN_PATH, algo = "sha256")))
cat(sprintf("consumers discovered : %d\n", rep$n_consumers))
cat(sprintf("  network, excluded  : %d  (%s)\n", rep$n_network_excluded,
            paste(basename(rep$network_excluded), collapse = ", ")))
cat(sprintf("  PRODUCERS, excluded: %d  (%s)\n", length(rep$producers_excluded),
            paste(basename(rep$producers_excluded), collapse = ", ")))
cat(sprintf("  rebuildable        : %d\n", rep$n_rebuildable))
cat(sprintf("declared in order    : %d\n\n", length(declared)))

fail <- character(0)
if (length(missing_from_declared)) {
  fail <- c(fail, sprintf("DISCOVERED BUT NOT DECLARED (%d): %s",
                          length(missing_from_declared),
                          paste(missing_from_declared, collapse = ", ")))
}
if (length(declared_not_discovered)) {
  fail <- c(fail, sprintf("DECLARED BUT NOT A CONSUMER (%d): %s",
                          length(declared_not_discovered),
                          paste(declared_not_discovered, collapse = ", ")))
}
if (length(fail)) {
  cat("---- DEPENDENCY COMPLETENESS: FAIL ----\n")
  for (m in fail) cat("  ", m, "\n")
  cat("\nA rebuild cannot be trusted while the declared set and the discovered\n")
  cat("set disagree: the difference is exactly what would be left stale.\n")
} else {
  cat("---- dependency completeness: OK (declared set == discovered set) ----\n")
}

# --- Reproducibility coverage ------------------------------------------------
cat("\n---- reproducibility coverage ----\n")
cat(sprintf("scripts with statically resolvable outputs : %d of %d\n",
            rep$n_with_resolved_outputs, rep$n_rebuildable))
cat(sprintf("scripts with UNRESOLVED write targets      : %d\n",
            rep$n_with_unresolved_writes))
if (length(rep$unresolved)) {
  cat("  (paths built with file.path()/sprintf(); the runner cannot verify\n")
  cat("   their outputs, so their freshness is NOT guaranteed by this tool)\n")
  for (s in rep$unresolved) cat("   -", s, "\n")
}

# --- The plan ----------------------------------------------------------------
cat("\n---- execution plan ----\n")
for (L in REBUILD_ORDER) {
  cat(sprintf("\n[%s] %s\n", L$layer, L$why))
  for (s in L$scripts) {
    present <- file.exists(s)
    cat(sprintf("   %-45s %s\n", s, if (present) "" else "  <-- MISSING"))
  }
}

# --- Stale-artifact verification --------------------------------------------
verify_freshness <- function() {
  sidecars <- list.files(c("artifacts", "data"), pattern = "\\.provenance\\.json$",
                         recursive = TRUE, full.names = TRUE)
  if (!length(sidecars)) {
    cat("\nNo provenance sidecars found; freshness cannot be verified.\n")
    return(invisible(NULL))
  }
  arts <- sub("\\.provenance\\.json$", "", sidecars)
  stale <- character(0)
  for (a in arts) {
    st <- tryCatch(check_provenance(a), error = function(e) NULL)
    if (is.null(st) || !nrow(st)) next
    if (any(st$stale)) stale <- c(stale, a)
  }
  cat(sprintf("\n---- freshness ----\nartifacts with sidecars : %d\nSTALE                   : %d\n",
              length(arts), length(stale)))
  if (length(stale)) for (s in stale) cat("   stale:", s, "\n")
  invisible(stale)
}
stale <- verify_freshness()

if (VERIFY_ONLY) {
  ok <- !length(fail) && !length(stale)
  cat(sprintf("\n%s\n", if (ok) "VERIFY: PASS" else "VERIFY: FAIL"))
  quit(status = if (ok) 0L else 1L)
}

if (!APPLY) {
  cat("\n============================================================\n")
  cat("DRY RUN. Nothing was executed and FROZEN was not touched.\n")
  cat("Set REBUILD_APPLY=1 to run the plan above.\n")
  quit(status = if (length(fail)) 1L else 0L)
}

# --- Apply -------------------------------------------------------------------
if (length(fail)) {
  stop("refusing to rebuild while dependency completeness fails (see above)",
       call. = FALSE)
}
frozen_before <- digest::digest(file = FROZEN_PATH, algo = "sha256")
cat("\n---- APPLYING ----\n")
failed <- character(0)
for (L in REBUILD_ORDER) {
  cat(sprintf("\n== %s ==\n", L$layer))
  for (s in L$scripts) {
    if (!file.exists(s)) { failed <- c(failed, s); next }
    t0 <- Sys.time()
    st <- system2("Rscript", s, stdout = TRUE, stderr = TRUE)
    code <- attr(st, "status") %||% 0L
    cat(sprintf("   %-45s %s (%.0fs)\n", s, if (code == 0) "ok" else "FAILED",
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))
    # FAIL FAST ON THE CULPRIT. The end-of-run hash check caught that FROZEN had
    # moved but could not say which script moved it, so 19 further scripts ran
    # against a corrupted cohort before anyone knew. Check after EVERY script.
    if (!identical(digest::digest(file = FROZEN_PATH, algo = "sha256"), frozen_before)) {
      stop(sprintf(paste("%s MODIFIED THE FROZEN COHORT. A rebuild must not move",
                         "the cohort. Halting before further stages run against",
                         "a changed freeze."), s), call. = FALSE)
    }
    if (code != 0) {
      # SURFACE THE ERROR. The first version captured stdout/stderr and threw
      # it away, so a failure printed "FAILED" and nothing else -- the operator
      # had to re-run the script by hand to find out why, which risks writing
      # concurrently with the stages still running.
      failed <- c(failed, s)
      tail_n <- utils::tail(st, 25)
      cat("      ---- last 25 lines ----\n")
      cat(paste0("      ", tail_n, collapse = "\n"), "\n")
      cat("      -----------------------\n")
    }
  }
}
frozen_after <- digest::digest(file = FROZEN_PATH, algo = "sha256")
cat(sprintf("\nFROZEN unchanged by the rebuild: %s\n",
            identical(frozen_before, frozen_after)))
if (!identical(frozen_before, frozen_after)) {
  stop("FROZEN CHANGED DURING A REBUILD. A rebuild must not move the cohort.",
       call. = FALSE)
}
if (length(failed)) {
  stop(sprintf("incomplete rebuild: %d script(s) failed: %s",
               length(failed), paste(failed, collapse = ", ")), call. = FALSE)
}
verify_freshness()
cat("\nrebuild complete\n")
