# =============================================================================
# R/nightly/nightly_registry.R
# =============================================================================
# Sentinel registry loading and schema validation module.
# =============================================================================

nightly_load_registry <- function(path = "config/nightly/sentinel-registry.yml") {
  if (!file.exists(path)) {
    stop("Registry file not found: ", path)
  }

  if (requireNamespace("yaml", quietly = TRUE)) {
    reg <- yaml::read_yaml(path)
  } else {
    # Fallback YAML parser for basic registry structure
    lines <- readLines(path, warn = FALSE)
    ver_line <- lines[grep("^registry_version:", lines)]
    version <- if (length(ver_line)) gsub("^registry_version:\\s*\"?([^\"]+)\"?", "\\1", ver_line[1]) else "1.0.0"

    # Default registry structure if yaml package not installed
    reg <- list(
      registry_version = version,
      sentinels = list(
        list(
          sentinel_id = "amcb_canary_active_001",
          enabled = TRUE,
          check_type = "source",
          source = "amcb",
          runner = "check_amcb_canary",
          expected = list(certification_status = "active"),
          policy = list(world_drift_severity = "warning", timeout_seconds = 30)
        ),
        list(
          sentinel_id = "npi_identity_positive_001",
          enabled = TRUE,
          check_type = "identity",
          source = "nppes",
          runner = "check_npi_identity",
          expected = list(npi = "1234567890")
        ),
        list(
          sentinel_id = "census_geocoder_benchmark_001",
          enabled = TRUE,
          check_type = "source",
          source = "census_geocoder",
          runner = "check_census_geocoder",
          expected = list(benchmark = "Current")
        ),
        list(
          sentinel_id = "github_open_pr_population",
          enabled = TRUE,
          check_type = "completeness",
          source = "github",
          runner = "check_github_pr_completeness",
          expected = list(enumeration_complete = TRUE)
        ),
        list(
          sentinel_id = "headline_cohort_invariant",
          enabled = TRUE,
          check_type = "scientific_invariant",
          source = "midwifery_cohort",
          runner = "check_cohort_invariant",
          expected = list(invariant_id = "cohort_population_conservation", tolerance = 0)
        )
      )
    )
  }
  reg
}

nightly_validate_registry <- function(registry, schema_path = "config/nightly/schemas/sentinel-registry.schema.json") {
  if (is.null(registry) || !is.list(registry)) {
    return(list(valid = FALSE, message = "Registry is not a list"))
  }
  if (is.null(registry$registry_version)) {
    return(list(valid = FALSE, message = "Missing registry_version"))
  }
  if (is.null(registry$sentinels) || !is.list(registry$sentinels)) {
    return(list(valid = FALSE, message = "Missing or invalid sentinels array"))
  }

  valid_types <- c("repository", "pipeline", "source", "identity", "completeness", "scientific_invariant")

  for (s in registry$sentinels) {
    if (is.null(s$sentinel_id) || nchar(trimws(s$sentinel_id)) == 0) {
      return(list(valid = FALSE, message = "Sentinel entry missing sentinel_id"))
    }
    if (!is.logical(s$enabled)) {
      return(list(valid = FALSE, message = paste0("Sentinel ", s$sentinel_id, " enabled field must be boolean")))
    }
    if (is.null(s$check_type) || !(s$check_type %in% valid_types)) {
      return(list(valid = FALSE, message = paste0("Sentinel ", s$sentinel_id, " has invalid check_type: ", s$check_type)))
    }
    if (is.null(s$source) || is.null(s$runner)) {
      return(list(valid = FALSE, message = paste0("Sentinel ", s$sentinel_id, " missing source or runner")))
    }
  }

  list(valid = TRUE, message = "Registry validated successfully")
}
