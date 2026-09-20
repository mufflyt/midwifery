# =============================================================================
# tests/test-nightly-completeness.R
# =============================================================================
# Unit tests for population completeness and set equality assertions.
# Section 7 & 23: evidence-over-memory invariant.
# =============================================================================

source("R/nightly/nightly_completeness.R")

# Case 1: Matching totals -> PASS
res_ok <- nightly_assert_completeness(
  authoritative_total = 58,
  retrieved_total = 58,
  pagination_complete = TRUE
)
if (res_ok$classification != "PASS") {
  stop("test-nightly-completeness.R failed on matching totals case")
}

# Case 2: Mismatched totals -> PIPELINE_FAILURE
res_trunc <- nightly_assert_completeness(
  authoritative_total = 58,
  retrieved_total = 30,
  pagination_complete = TRUE
)
if (res_trunc$classification != "PIPELINE_FAILURE" || res_trunc$event_code != "ENUMERATION_INCOMPLETE") {
  stop("test-nightly-completeness.R failed on mismatched totals case")
}

# Case 3: Incomplete pagination -> PIPELINE_FAILURE
res_pag <- nightly_assert_completeness(
  authoritative_total = 58,
  retrieved_total = 58,
  pagination_complete = FALSE
)
if (res_pag$classification != "PIPELINE_FAILURE" || res_pag$event_code != "ENUMERATION_PAGINATION_INCOMPLETE") {
  stop("test-nightly-completeness.R failed on incomplete pagination case")
}

# Case 4: Set mismatch -> PIPELINE_FAILURE
res_set <- nightly_assert_completeness(
  authoritative_total = 3,
  retrieved_total = 3,
  authoritative_set = c("A", "B", "C"),
  retrieved_set = c("A", "B", "D"),
  pagination_complete = TRUE
)
if (res_set$classification != "PIPELINE_FAILURE" || res_set$event_code != "ENUMERATION_SET_MISMATCH") {
  stop("test-nightly-completeness.R failed on set mismatch case")
}

cat("PASS test-nightly-completeness.R: Completeness and set equality rules verified\n")
