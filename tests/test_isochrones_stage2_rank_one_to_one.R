#!/usr/bin/env Rscript
# =============================================================================
# External-private sentinel: isochrones rank_one_to_one() ordering contract
# =============================================================================
# Stage 2 one-NPI-one-person allocation lives in the private mufflyt/isochrones
# repository. This public repo cannot run it on GitHub without credentials, but
# it can still carry the contract as a discovered test and register it as an
# external-private nightly exception. Locally, with ISOCHRONES_HOME or
# ~/isochrones available, this executes the canonical upstream regression file.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

iso_home <- Sys.getenv("ISOCHRONES_HOME")
if (!nzchar(iso_home)) iso_home <- path.expand("~/isochrones")
iso_home <- path.expand(iso_home)

upstream_test <- file.path(iso_home, "tests", "testthat",
                           "test-rank-one-to-one-non-greedy.R")
if (!file.exists(upstream_test)) {
  stop(sprintf(paste0(
    "Cannot run Stage 2 resolver contract: %s is missing.\n",
    "  This test is registered as external-private in tests/ci_nightly_exceptions.txt.\n",
    "  Set ISOCHRONES_HOME to a mufflyt/isochrones checkout to run it locally."),
    upstream_test), call. = FALSE)
}

if (!requireNamespace("testthat", quietly = TRUE)) {
  stop("testthat is required to run the upstream rank_one_to_one() contract.",
       call. = FALSE)
}

owd2 <- setwd(iso_home); on.exit(setwd(owd2), add = TRUE)
source(file.path(iso_home, "R", "npi_resolution.R"))
if (!exists("rank_one_to_one", mode = "function")) {
  stop("Sourced isochrones R/npi_resolution.R but rank_one_to_one() is missing.",
       call. = FALSE)
}
testthat::test_file(upstream_test, stop_on_failure = TRUE)
