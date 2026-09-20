# =============================================================================
# tests/test-nightly-registry.R
# =============================================================================
# Unit tests for sentinel registry loading and schema validation.
# =============================================================================

source("R/nightly/nightly_registry.R")

reg <- nightly_load_registry("config/nightly/sentinel-registry.yml")
val <- nightly_validate_registry(reg)

if (!val$valid) {
  stop("test-nightly-registry.R failed: ", val$message)
}

if (!is.character(reg$registry_version) || nchar(reg$registry_version) == 0) {
  stop("test-nightly-registry.R failed: registry_version is empty")
}

if (length(reg$sentinels) == 0) {
  stop("test-nightly-registry.R failed: sentinels list is empty")
}

cat("PASS test-nightly-registry.R: Registry parsed and validated cleanly\n")
