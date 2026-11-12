# =============================================================================
# oig_phase2_candidate_set.R -- pure helpers for the OIG remake Phase 2
# candidate-set cardinality & source-intersection analysis (spec Sections
# 4-5). No I/O here; all functions operate on character vectors of ZIP5
# strings so they are unit-testable without a database connection.
# =============================================================================

#' Union two or more ZIP5 character vectors into one candidate set.
#'
#' ponytail: replaces the tier-priority pick in
#' remake_oig_07_09_00440_midwifery.R (`ifelse(has_direct, direct_zip5_set,
#' group_zip5_set)`), which silently drops group-reassignment ZIPs for any
#' clinician who has both. This is the Phase 2 bug fix.
#'
#' @param ... character vectors of ZIP5 strings; `NA` entries are dropped.
#' @return sorted unique character vector (possibly `character(0)`).
union_zip5_sets <- function(...) {
  combined <- unlist(list(...), use.names = FALSE)
  combined <- combined[!is.na(combined) & nzchar(combined)]
  sort(unique(combined))
}

#' Classify a clinician's candidate-set intersection across 2+ sources
#' (spec 5.2). Works for the pairwise P-vs-C intersection and the three-way
#' P-vs-N-vs-C intersection alike -- pass as many ZIP5 sets as sources.
#'
#' Each `...` argument is one source's ZIP5 observations for one clinician.
#' An empty vector means that source has NO observation for this clinician
#' (not that it disagrees) -- per the spec, "source unavailability must not
#' be classified as disagreement", so `"source_unavailable"` always takes
#' precedence over `"no_common_zip5"`.
#'
#' ponytail: when NPPES (always <=1 ZIP5/clinician) is one of the sets, the
#' intersection is structurally empty-or-singleton -- "two"/"three_to_five"/
#' "more_than_five" are only reachable when every set passed in can itself
#' hold >1 value (e.g. the pairwise PECOS-vs-Physician-Compare case).
#'
#' @return one of "exactly_one", "two", "three_to_five", "more_than_five",
#'   "no_common_zip5", "source_unavailable".
classify_intersection_cardinality <- function(...) {
  sets <- lapply(list(...), function(s) s[!is.na(s) & nzchar(s)])
  if (any(lengths(sets) == 0L)) return("source_unavailable")
  shared <- Reduce(intersect, sets)
  n_shared <- length(shared)
  if (n_shared == 0L) return("no_common_zip5")
  if (n_shared == 1L) return("exactly_one")
  if (n_shared == 2L) return("two")
  if (n_shared <= 5L) return("three_to_five")
  "more_than_five"
}

#' Classify the effect of adding one more source to a candidate set
#' (spec 5.3's sequential-resolution buckets).
#'
#' @param before_set candidate ZIP5 set before the new source is added.
#' @param new_source_set the ZIP5 set reported by the source being added;
#'   `character(0)` means that source has no observation for this clinician.
#' @return one of "zero_to_new_candidate", "source_unavailable_no_change",
#'   "multiple_to_one", "multiple_to_fewer_still_multiple",
#'   "multiple_no_narrowing", "multiple_to_disagreement", "one_to_agreement",
#'   "one_to_disagreement", "still_zero". Never counts
#'   `"zero_to_new_candidate"` as PECOS recovery -- it is new information
#'   introduced by the source being added.
classify_sequential_transition <- function(before_set, new_source_set) {
  before_set <- before_set[!is.na(before_set) & nzchar(before_set)]
  new_source_set <- new_source_set[!is.na(new_source_set) & nzchar(new_source_set)]
  n_before <- length(before_set)
  n_new <- length(new_source_set)
  if (n_before == 0L && n_new == 0L) return("still_zero")
  if (n_before == 0L && n_new > 0L) return("zero_to_new_candidate")
  if (n_new == 0L) return("source_unavailable_no_change")
  after_set <- intersect(before_set, new_source_set)
  n_after <- length(after_set)
  if (n_before == 1L) {
    return(if (n_after == 1L) "one_to_agreement" else "one_to_disagreement")
  }
  if (n_after == 0L) return("multiple_to_disagreement")
  if (n_after == 1L) return("multiple_to_one")
  if (n_after < n_before) return("multiple_to_fewer_still_multiple")
  "multiple_no_narrowing"
}

#' Assert a data frame has at most one row per `id_col` value; stop with a
#' clear message naming the duplicates if not.
#'
#' ponytail: used in place of `distinct(id, .keep_all = TRUE)`, which
#' silently keeps an arbitrary row (in whatever order the data happens to
#' arrive) when duplicates exist -- the project's own debt-ceiling test
#' (`tests/test_cycle5_key_resolution.R`, T44) flags new `.keep_all = TRUE`
#' usage for exactly this reason: it is the same class of bug as the
#' PECOS dedup-determinism issue (D13 in DEBT.md). This fails loudly instead.
assert_one_row_per_id <- function(data, id_col, context) {
  dup_ids <- data[[id_col]][duplicated(data[[id_col]])]
  if (length(dup_ids) > 0L) {
    stop(sprintf(
      "%s: expected exactly one row per %s, found %d duplicated value(s): %s",
      context, id_col, length(unique(dup_ids)),
      paste(utils::head(unique(dup_ids), 5L), collapse = ", ")
    ), call. = FALSE)
  }
  invisible(data)
}

#' Bucket a candidate-ZIP5-count into the Section 4.3 cardinality strata.
#' @return ordered factor-free character label.
classify_zip5_count_bucket <- function(n_zip5) {
  dplyr::case_when(
    is.na(n_zip5) | n_zip5 == 0L ~ "zero",
    n_zip5 == 1L ~ "single_zip5",
    n_zip5 >= 2L ~ "multiple_zip5"
  )
}
