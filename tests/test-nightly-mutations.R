# =============================================================================
# tests/test-nightly-mutations.R
# =============================================================================
# Mutation tests for the sentinel framework itself (Section 32).
# Plant defects in classifier and completeness engines and ensure they fail closed.
# =============================================================================

source("R/nightly/nightly_classify.R")
source("R/nightly/nightly_completeness.R")

# Planted Mutation 1: Misclassify PIPELINE_FAILURE as PASS
planted_events <- data.frame(
  classification = c("PIPELINE_FAILURE"),
  severity = c("ERROR"),
  stringsAsFactors = FALSE
)
mutated_summary <- nightly_classify(planted_events)
if (mutated_summary$overall_classification == "PASS") {
  stop("MUTATION DETECTED FAILED: Classifier allowed PIPELINE_FAILURE to pass as PASS!")
}

# Planted Mutation 2: Misclassify set mismatch as PASS
mutated_completeness <- nightly_assert_completeness(
  authoritative_total = 10,
  retrieved_total = 10,
  authoritative_set = c(1, 2, 3),
  retrieved_set = c(1, 2, 999),
  pagination_complete = TRUE
)
if (mutated_completeness$classification == "PASS") {
  stop("MUTATION DETECTED FAILED: Completeness engine allowed set mismatch to pass!")
}

cat("PASS test-nightly-mutations.R: Framework mutation tests passed cleanly\n")
