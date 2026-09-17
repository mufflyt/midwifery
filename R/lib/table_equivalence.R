#' Compare two data.frames as unordered relational tables
#'
#' DuckDB (and SQL generally) makes no row-order guarantee absent an explicit
#' ORDER BY. Two runs of the same deterministic query can legitimately return
#' the same rows in a different sequence. Comparing such outputs byte-for-byte,
#' or demanding an arbitrary ORDER BY purely to make a byte comparison pass,
#' both miss the actual invariant that matters: same schema, same rows, same
#' duplicate counts. This function checks exactly that, treating row order as
#' insignificant and everything else -- including how many times a duplicated
#' row appears -- as significant.
#'
#' Column ORDER (physical position) never causes a mismatch by itself; only
#' the column NAME SET and each shared column's type matter for schema
#' equality. Row hashing uses a fixed canonical column order (sorted by name)
#' so the comparison is well-defined regardless of which physical order
#' either data.frame arrived in.
#'
#' @param a,b [data.frame] the two tables to compare.
#' @return a list:
#'   - `equivalent` [logical]: TRUE iff schema, row count, and the full
#'     multiset of rows (respecting duplicate multiplicity) match exactly.
#'   - `reason` [character or NULL]: NULL if equivalent; otherwise one of
#'     "schema_mismatch", "type_mismatch", "added_rows", "missing_rows", or
#'     "duplicate_multiplicity_mismatch" (row-count differences are always
#'     reported as one of these three more specific multiset reasons, never
#'     as a bare count mismatch).
#'   - `detail` [list or NULL]: structured detail for the failing reason.
tables_equivalent <- function(a, b) {
  stopifnot(is.data.frame(a), is.data.frame(b))

  names_a <- sort(names(a))
  names_b <- sort(names(b))
  if (!identical(names_a, names_b)) {
    return(list(equivalent = FALSE, reason = "schema_mismatch",
                detail = list(only_in_a = setdiff(names_a, names_b),
                              only_in_b = setdiff(names_b, names_a))))
  }
  cols <- names_a

  classes_a <- vapply(a[cols], function(x) paste(class(x), collapse = "/"), character(1))
  classes_b <- vapply(b[cols], function(x) paste(class(x), collapse = "/"), character(1))
  type_mismatch <- cols[classes_a != classes_b]
  if (length(type_mismatch)) {
    return(list(equivalent = FALSE, reason = "type_mismatch",
                detail = list(columns = type_mismatch,
                              class_in_a = classes_a[type_mismatch],
                              class_in_b = classes_b[type_mismatch])))
  }

  # No standalone nrow() gate here: every way two tables can differ in row
  # count -- an added row, a missing row, or a duplicated row appearing a
  # different number of times -- is already a more specific case the
  # multiset comparison below identifies directly. A bare "row_count_mismatch"
  # would only ever hide which of those three actually happened.

  # A value's row-hash must not collide with a DIFFERENT value's, and a
  # genuine NA must never collide with the literal string "NA" (paste0(NA)
  # renders as "NA", which a naive hash would confuse with a real "NA" value
  # in a character column). Prefixing every value with its is.na() status
  # keeps the two cases apart.
  cell_token <- function(x) ifelse(is.na(x), "\x01NA\x01", paste0("\x02", as.character(x)))
  row_hash <- function(df) {
    if (nrow(df) == 0L) return(character(0))
    tokens <- lapply(df[cols], cell_token)
    do.call(paste, c(tokens, sep = "\x03"))
  }

  hash_a <- row_hash(a)
  hash_b <- row_hash(b)

  # A multiset comparison, not a set comparison: table() keeps each distinct
  # row's COUNT, so two tables sharing the same distinct rows but differing
  # in how many times one of them repeats are NOT treated as equal. A
  # setdiff()-based implementation would miss this entirely -- setdiff on
  # the distinct values shows no difference when only counts changed.
  counts_a <- table(hash_a)
  counts_b <- table(hash_b)

  added <- setdiff(names(counts_b), names(counts_a))
  missing <- setdiff(names(counts_a), names(counts_b))
  if (length(added)) {
    return(list(equivalent = FALSE, reason = "added_rows",
                detail = list(n_added_distinct = length(added),
                              example = b[match(added[1], hash_b), cols, drop = FALSE])))
  }
  if (length(missing)) {
    return(list(equivalent = FALSE, reason = "missing_rows",
                detail = list(n_missing_distinct = length(missing),
                              example = a[match(missing[1], hash_a), cols, drop = FALSE])))
  }

  common <- intersect(names(counts_a), names(counts_b))
  mismatched_counts <- common[as.integer(counts_a[common]) != as.integer(counts_b[common])]
  if (length(mismatched_counts)) {
    h <- mismatched_counts[1]
    return(list(equivalent = FALSE, reason = "duplicate_multiplicity_mismatch",
                detail = list(n_rows_with_changed_multiplicity = length(mismatched_counts),
                              example = a[match(h, hash_a), cols, drop = FALSE],
                              count_in_a = as.integer(counts_a[h]),
                              count_in_b = as.integer(counts_b[h]))))
  }

  list(equivalent = TRUE, reason = NULL, detail = NULL)
}
