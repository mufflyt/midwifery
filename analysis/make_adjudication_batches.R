# =============================================================================
# Deterministic review batches over the FROZEN v1.1 population
# =============================================================================
# Batch assignment is workflow metadata ONLY: it never touches the frozen
# instrument (custody hashes stay intact), never changes membership, and
# never affects scoring. Rows are split in instrument order (sorted
# adjudication_id): 1-50, 51-100, ..., 301-327.
#
# Each packet is the blinded context for its rows plus empty reviewer-entry
# columns; completed packets are appended to adjudication_reviews_v1.csv
# (append-only -- see the protocol README). The blinding scanner runs on
# every packet BEFORE it is handed to a reviewer.
#
# Run from the repo root:  Rscript analysis/make_adjudication_batches.R
# =============================================================================

source(file.path("R", "truth_set_checks.R"))

inst <- utils::read.csv("artifacts/truth/adjudication_instrument_v1.csv",
                        stringsAsFactors = FALSE, colClasses = "character")
manifest <- jsonlite::fromJSON(
  "artifacts/truth/adjudication_instrument_v1.manifest.json",
  simplifyVector = FALSE)
check_population(inst, manifest)          # never batch a moving population

batch <- ((seq_len(nrow(inst)) - 1L) %/% 50L) + 1L
utils::write.csv(
  data.frame(adjudication_id = inst$adjudication_id, batch = batch),
  "artifacts/truth/adjudication_batches_v1.csv", row.names = FALSE)

dir.create("artifacts/truth/batches", showWarnings = FALSE)
for (b in unique(batch)) {
  rows <- inst[batch == b, , drop = FALSE]
  packet <- rows
  for (col in c("reviewer_id", "verdict", "evidence_source", "locator",
                "reason", "review_date")) packet[[col]] <- ""
  check_reviewer_export_blinded(packet)   # scanner runs BEFORE handover
  check_board_contamination(packet)
  f <- sprintf("artifacts/truth/batches/batch_%02d_rows_%03d-%03d.csv",
               b, min(which(batch == b)), max(which(batch == b)))
  utils::write.csv(packet, f, row.names = FALSE, na = "")
  cat(sprintf("batch %d: %d rows -> %s (blinding scan PASS)\n",
              b, nrow(rows), f))
}
cat("population_hash (unchanged):", manifest$population_hash, "\n")
