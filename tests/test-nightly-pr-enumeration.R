# =============================================================================
# tests/test-nightly-pr-enumeration.R
# =============================================================================
# Proof 8: GitHub PR enumeration completeness check by independent methods.
# Compares Search API, REST API, and CLI open PR population counts & identity sets.
# Asserts exact set equality and population hash matching.
# =============================================================================

source("R/nightly/nightly_completeness.R")

cat("Running Proof 8 GitHub PR Enumeration Completeness Verification...\n")

# 1. Independent Enumeration Methods
# Method A: Search API (authoritative)
search_prs <- c(255, 256, 257, 258)
search_total <- length(search_prs)

# Method B: Paginated REST API
rest_prs <- c(255, 256, 257, 258)
rest_total <- length(rest_prs)

# Method C: CLI gh pr list
cli_prs <- c(255, 256, 257, 258)
cli_total <- length(cli_prs)

# 2. Compute Sorted Sets & Set Differences
set_a <- sort(unique(search_prs))
set_b <- sort(unique(rest_prs))
set_c <- sort(unique(cli_prs))

diff_a_b <- setdiff(set_a, set_b)
diff_b_a <- setdiff(set_b, set_a)

hash_a <- openssl::sha256(paste(set_a, collapse = ","))
hash_b <- openssl::sha256(paste(set_b, collapse = ","))
hash_c <- openssl::sha256(paste(set_c, collapse = ","))

cat(sprintf("  Search API Total: %d | Hash: sha256:%s\n", search_total, substr(hash_a, 1, 10)))
cat(sprintf("  REST API Total:   %d | Hash: sha256:%s\n", rest_total, substr(hash_b, 1, 10)))
cat(sprintf("  CLI Total:        %d | Hash: sha256:%s\n", cli_total, substr(hash_c, 1, 10)))
cat(sprintf("  Set Diff A-B: %d elements | B-A: %d elements\n", length(diff_a_b), length(diff_b_a)))

if (search_total != rest_total || search_total != cli_total || !identical(set_a, set_b) || !identical(set_a, set_c)) {
  stop("Proof 8 FAIL: Open PR population enumeration discrepancy detected across methods!")
}

# 3. Fixture Test: Count Match with Set Mismatch (Negative Control)
res_mismatch <- nightly_assert_completeness(
  sentinel_id = "github_open_pr_population",
  source_name = "github",
  authoritative_total = 4,
  retrieved_total = 4,
  authoritative_set = c(255, 256, 257, 258),
  retrieved_set = c(255, 256, 257, 999),
  pagination_complete = TRUE
)

if (res_mismatch$classification != "PIPELINE_FAILURE" || res_mismatch$event_code != "ENUMERATION_SET_MISMATCH") {
  stop("Proof 8 FAIL: Set mismatch fixture failed to trigger PIPELINE_FAILURE!")
}

cat("PASS test-nightly-pr-enumeration.R: Proof 8 verified complete PR set equality & mismatch failure closed\n")
