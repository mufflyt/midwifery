# =============================================================================
# tables_equivalent(): unordered relational comparison
# =============================================================================
# Proves the helper treats row ORDER as insignificant while still catching
# every other kind of divergence -- added/missing rows, changed values,
# changed duplicate counts (the case a naive setdiff()-based implementation
# would miss entirely), type mismatches masked by identical rendered text,
# and real NA vs the literal string "NA" (the case a naive paste0()-based
# hash would confuse).
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "table_equivalence.R"))

base <- data.frame(
  id = c(1L, 2L, 3L, 2L, 4L, 5L, 2L),
  name = c("alice", "bob", "carol", "bob", "dave", "erin", "bob"),
  score = c(10.5, 20.0, 30.25, 20.0, 40.0, 50.0, 20.0),
  stringsAsFactors = FALSE
)
# The (id=2, bob, 20.0) row is a genuine, fully-identical DUPLICATE, deliberately
# repeated 3x -- every column, including id, matches -- so multiplicity tests
# have something to change without altering the distinct row set. A unique id
# per row would make every row already distinct and defeat this fixture entirely.

ci_section("Pure permutation and column reordering")

set.seed(1)
shuffled <- base[sample(nrow(base)), ]
r <- tables_equivalent(base, shuffled)
if (isTRUE(r$equivalent)) {
  ci_ok("row-shuffled copy of the same table is equivalent")
} else {
  ci_fail("row-shuffled copy was reported NOT equivalent (reason: %s)", r$reason)
}

col_reordered <- base[, rev(names(base))]
r <- tables_equivalent(base, col_reordered)
if (isTRUE(r$equivalent)) {
  ci_ok("reversed column order does not cause a false mismatch")
} else {
  ci_fail("reversed column order was reported NOT equivalent (reason: %s)", r$reason)
}

ci_section("Added / missing rows")

added <- rbind(base, data.frame(id = 8L, name = "frank", score = 99.0))
r <- tables_equivalent(base, added)
if (!isTRUE(r$equivalent) && identical(r$reason, "added_rows")) {
  ci_ok("an extra row in b is detected as added_rows")
} else {
  ci_fail("extra row in b was not detected as added_rows (got equivalent=%s reason=%s)",
          r$equivalent, r$reason)
}

missing <- base[-1, ]
r <- tables_equivalent(base, missing)
if (!isTRUE(r$equivalent) && identical(r$reason, "missing_rows")) {
  ci_ok("a missing row in b is detected as missing_rows")
} else {
  ci_fail("missing row in b was not detected as missing_rows (got equivalent=%s reason=%s)",
          r$equivalent, r$reason)
}

ci_section("Changed value")

changed_value <- base
changed_value$score[1] <- 999
r <- tables_equivalent(base, changed_value)
if (!isTRUE(r$equivalent) && !is.null(r$detail)) {
  ci_ok("a single changed cell value is detected (equivalent=FALSE, reason=%s, detail present)", r$reason)
} else {
  ci_fail("a changed cell value was not detected")
}

ci_section("Duplicate multiplicity (the setdiff trap)")

fewer_dupes <- base[-match(TRUE, duplicated(base[, c("name","score")]) & base$name == "bob"), ]
# base has "bob"/20.0 three times; fewer_dupes has it twice, same distinct rows otherwise.
stopifnot(nrow(fewer_dupes) == nrow(base) - 1L)
r <- tables_equivalent(base, fewer_dupes)
if (!isTRUE(r$equivalent) && identical(r$reason, "duplicate_multiplicity_mismatch")) {
  ci_ok("a changed duplicate count (same distinct rows) is detected as duplicate_multiplicity_mismatch, not missed as row_count_mismatch masking the real cause")
} else {
  ci_fail("changed duplicate multiplicity was not correctly detected (got equivalent=%s reason=%s)",
          r$equivalent, r$reason)
}
# Explicit trap check: a naive setdiff() on distinct rows would see no
# difference here at all, because removing one copy of a row that still
# appears twice elsewhere does not change the DISTINCT set -- only the count.
key_of <- function(df) do.call(paste, c(df[, c("name", "score")], sep = "\x03"))
distinct_a <- sort(unique(key_of(base)))
distinct_b <- sort(unique(key_of(fewer_dupes)))
if (identical(distinct_a, distinct_b)) {
  ci_ok("confirmed this is genuinely the setdiff-blind-spot case (distinct sets are identical; only the count differs)")
} else {
  ci_fail("test construction error: the multiplicity case was not actually setdiff-invisible")
}

ci_section("Type mismatch masked by identical rendered text")

type_a <- data.frame(id = 1:3, code = c(1L, 2L, 3L))
type_b <- data.frame(id = 1:3, code = c("1", "2", "3"), stringsAsFactors = FALSE)
r <- tables_equivalent(type_a, type_b)
if (!isTRUE(r$equivalent) && identical(r$reason, "type_mismatch")) {
  ci_ok("integer vs character column with identical rendered digits is detected as type_mismatch")
} else {
  ci_fail("type mismatch with matching rendered text was not detected (got equivalent=%s reason=%s)",
          r$equivalent, r$reason)
}

ci_section("Schema mismatch")

schema_b <- base; names(schema_b)[names(schema_b) == "score"] <- "points"
r <- tables_equivalent(base, schema_b)
if (!isTRUE(r$equivalent) && identical(r$reason, "schema_mismatch")) {
  ci_ok("a renamed column is detected as schema_mismatch")
} else {
  ci_fail("renamed column was not detected as schema_mismatch (got equivalent=%s reason=%s)",
          r$equivalent, r$reason)
}

ci_section("NA handling (the paste0(NA) trap)")

na_a <- data.frame(id = 1:2, note = c("hello", NA), stringsAsFactors = FALSE)
na_b <- data.frame(id = 1:2, note = c("hello", NA), stringsAsFactors = FALSE)
r <- tables_equivalent(na_a, na_b)
if (isTRUE(r$equivalent)) {
  ci_ok("genuine NA in both tables compares equal (NA does not cause a spurious mismatch)")
} else {
  ci_fail("two tables with the same genuine NA were reported NOT equivalent (reason: %s)", r$reason)
}

na_vs_string <- data.frame(id = 1:2, note = c("hello", "NA"), stringsAsFactors = FALSE)
r <- tables_equivalent(na_a, na_vs_string)
if (!isTRUE(r$equivalent)) {
  ci_ok("real NA vs the literal string \"NA\" is correctly detected as a mismatch (not silently equated by paste0())")
} else {
  ci_fail("real NA and the literal string \"NA\" were incorrectly treated as equivalent -- this is the paste0(NA) trap")
}

ci_section("Empty tables")

empty_a <- base[0, ]
empty_b <- base[0, ]
r <- tables_equivalent(empty_a, empty_b)
if (isTRUE(r$equivalent)) {
  ci_ok("two zero-row tables with the same schema are equivalent")
} else {
  ci_fail("two empty tables with identical schema were reported NOT equivalent (reason: %s)", r$reason)
}

ci_finish()
