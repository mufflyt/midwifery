#!/usr/bin/env Rscript
# =============================================================================
# Repository integrity gates -- the midwifery configuration
# =============================================================================
# The gates themselves live in R/ci_repo_integrity_gates.R and are repo-neutral.
# This file is only the configuration, and it is deliberately small.
#
# Branch protection is NOT here. Required checks and protection of main belong
# in GitHub settings, not in R: a gate that runs only after someone has already
# merged cannot stop the merge. The same applies to the pre-commit hook, which
# invokes this file rather than reimplementing any of it -- one privacy and
# integrity implementation for local commits and for CI.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "ci_repo_integrity_gates.R"))

# Every suite ci.yml runs in the r-unit-tests job. The package gate follows the
# source() chain out of these, which is how checkmate would have been caught
# before CI caught it.
ci_entrypoints <- file.path("tests", c(
  "test_cycle2_dates_keys.R", "test_cycle3_denominators.R",
  "test_cycle4_ct_apportionment.R", "test_cycle5_geocode_conflicts.R",
  "test_cycle7_units.R", "test_cycle8_filter_bias.R",
  "test_cycle13_cohort_wonder.R", "test_cycle16_acs_variables.R",
  "test_cycle17_acs_labels.R", "test_cycle20_congress_vintage.R",
  "test_cycle21_provenance_wiring.R", "test_cycle23_geocode_precision.R",
  "test_birth_activity.R", "test_license_resolution.R",
  "test_open_payments_type2_bulk.R", "test_table1_blk_hg.R",
  "test_pip_materialization.R", "test_safe_divide_types.R",
  "test_amcb_license_bridge.R", "test_build_amcb_state_licenses.R",
  "test_adapt_license_bridge_to_reconcile.R",
  "test_expand_former_name_candidates.R",
  "test_validate_age_at_certification.R", "test_cross_taxonomy_hierarchy.R",
  "test_checkpoint_merge.R", "test_lib_keys.R", "test_table1_bands.R",
  "test_adversarial_keys.R",
  "test-retraction-bugs-9-14.R", "test-safe-divide-zero-threshold-bva.R",
  "test-safe-percent-zero-default-family-bva.R",
  "test-consort-audit-rounds-61-thru-65-2026-05-21.R",
  "test-den-032-safe-pct-manu-na-semantics.R", "test-join-safety.R",
  "test-join-safety-semantic-extended.R", "test-step2-npi-dedup-bug.R",
  "test-tract-vintage-boundary-bva-2019-2020-2021.R",
  "test-step8-tract-vintage-routing.R"
))

# Must match .github/workflows/ci.yml exactly. When they disagree, CI is red on
# the next push -- which is the point.
ci_packages <- c(
  "dplyr", "jsonlite", "purrr", "readr", "scales", "stringi", "stringr",
  "testthat", "tibble", "tidyr", "checkmate", "DBI", "digest", "duckdb",
  "geosphere", "here", "httr", "openssl", "xml2", "assertthat", "withr", "fs",
  # rlang: reached through R/lib/ct_county_crosswalk.R. It resolves today only
  # because dplyr drags it in; the gate found it undeclared, which is the same
  # class of latent break as checkmate.
  "rlang",
  # readxl: reached through R/build_amcb_state_licenses.R. Not installed in CI
  # today -- it passes only because that code path is not exercised, which is
  # the same latent break checkmate was before it fired.
  "readxl"
)

# chk(), ok() and check() are this repo's hand-rolled assertion helpers. Four
# passing suites read as vacuous without them, and a gate that cries wolf on
# working tests gets switched off within a week.
assertion_patterns <- c("chk", "ok", "check")

# The isochrones and mysterymaps path dependencies resolve a sibling checkout
# from the home directory BY DESIGN, and fail loudly with instructions when it
# is absent. That is the documented contract, not a hermeticity defect.
absolute_path_allow <- c(
  "ISOCHRONES_HOME", "ISOCHRONES_R", "ISOCHRONES_DIR", "MYSTERYMAPS_HOME",
  "mufflyaccess", "path.expand", "Sys.getenv"
)

# A checker that stores the forbidden patterns as data matches itself. These two
# files are the checkers; exempting anything else here defeats the gate.
self_referential <- c(
  "R/ci_repo_integrity_gates\\.R",
  "tests/ci_hygiene\\.R"
)

# Scanning every loose script at the repo root would report hundreds of inputs
# that live on an external volume and are gitignored by design. The gate is
# scoped to the numbered pipeline and its libraries, where a vanished input is
# a real regression -- which is where ct_legacy_to_region_weights.csv was.
missing_input_ignore <- c(
  "^[^/]*$", "/\\.quarantine/", "/qa/", "/vignettes/", "/docs/"
)

read_baseline <- function(path) {
  if (!file.exists(path)) return(character())
  x <- readLines(path, warn = FALSE)
  x <- trimws(x[!grepl("^\\s*#", x)])
  x[nzchar(x)]
}

# Two ratchets, both the same rule as tests/ci_leak_baseline.txt: the list may
# shrink and must never grow.
#
# The access-date gate covers DOWNLOADED SOURCE DATA, not derived output. The
# distinction is origin, not directory: data/county_base.csv lives under data/
# but is built by R/01-build-county-base.R, and its inputs+sha256 sidecar is the
# right provenance for it -- a download date would be meaningless. Derived
# artifacts stay with ci_artifact_contracts A3, which already ratchets sidecar
# coverage; policing them here as well meant two gates measuring the same debt
# with incompatible field names.
#
# The 17 files below predate the requirement. Their dates cannot be invented,
# and several publishers revise in place, so re-downloading would not recover
# when the committed copy was fetched.
grandfathered_sources <- read_baseline(
  file.path(root, "tests", "ci_integrity_source_access_baseline.txt")
)
abs_path_baseline <- read_baseline(
  file.path(root, "tests", "ci_integrity_abs_path_baseline.txt")
)
missing_input_baseline <- read_baseline(
  file.path(root, "tests", "ci_integrity_missing_inputs_baseline.txt")
)

run_repo_integrity_gates(
  root = root,
  ci_entrypoints = ci_entrypoints,
  ci_packages = ci_packages,
  vendored_pairs = NULL,
  absolute_path_allow = absolute_path_allow,
  absolute_path_exclude = c(self_referential, abs_path_baseline),
  assertion_patterns = assertion_patterns,
  missing_input_ignore = missing_input_ignore,
  access_date_grandfathered = grandfathered_sources,
  access_date_scope = "data",
  missing_input_baseline = missing_input_baseline,
  safe_percent_allow = c("R/safe_divide\\.R", self_referential)
)
