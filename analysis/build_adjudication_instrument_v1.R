# =============================================================================
# Truth-set instrument v1: the first adjudicated AMCB->NPI ground truth
# =============================================================================
# WHY THIS EXISTS. The 2026-09-07 nickname ablation (mysterynpi, matcher
# fa7216f) established that midwifery holds NO adjudicated person-level
# match/nonmatch truth: all four review templates carry empty verdict
# columns. This script turns those 456 template rows into ONE person-level
# adjudication instrument, blinded per the isochrones benchmark-schema
# discipline: nothing the MATCHER concluded (method, confidence, evidence
# class, match_reason, risk band) may reach the adjudicator, because a
# reviewer who can see the matcher's confidence is grading the matcher's
# homework with the answer key open.
#
# CONTRACT:
#   * Matching thresholds are NOT changed while truth is constructed.
#   * adjudication_id is immutable and content-derived: ADJ-<amcb_id>-<npi>.
#   * reviewer_verdict vocabulary: match | nonmatch | indeterminate
#     (the isochrones benchmark_schema.yml vocabulary, adopted verbatim).
#   * The SEALED key file re-joins matcher internals AFTER verdicts land;
#     it must not be given to the adjudicator.
#   * Outputs are gitignored person-level data (the same policy that keeps
#     the input templates out of git); the canonical copies live in the
#     repo's artifacts/truth/ and the Dropbox evidence folder.
#
# Run from the repo root:  Rscript analysis/build_adjudication_instrument_v1.R
# =============================================================================

inputs <- c(
  c5guard   = "artifacts/amcb_crosswalk_review_sample_c5guard.csv",
  baseline  = "artifacts/amcb_crosswalk_review_sample.csv",
  component = "artifacts/amcb_crosswalk_review_sample_component.csv",
  class5    = "artifacts/amcb_class5_review_census.csv")
missing <- inputs[!file.exists(inputs)]
if (length(missing)) {
  stop("input template(s) missing: ", paste(missing, collapse = ", "),
       "\n  These are local-only review artifacts; run on the machine ",
       "that built the crosswalk.", call. = FALSE)
}

# Columns the ADJUDICATOR may see: identity and registry facts, never
# matcher conclusions. nppes_* are registry-side facts a reviewer needs;
# npi_tax_class is a registry fact (taxonomy), not a matcher score.
BLINDED_KEEP <- c("amcb_id", "amcb_customer_id", "amcb_name_original",
                  "normalized_first_name", "normalized_middle_name",
                  "normalized_last_name", "npi", "nppes_first_name",
                  "nppes_middle_name", "nppes_last_name", "nppes_credential",
                  "nppes_city", "nppes_state", "nppes_location_year",
                  "npi_tax_class")
# Columns that must NOT reach the adjudicator; sealed for post-hoc scoring.
SEALED_KEEP <- c("name_evidence_class", "npi_match_method",
                 "npi_match_confidence", "match_reason", "linkage_tier",
                 "ambiguity_flag", "candidate_count", "n_at_best_class",
                 "review_stratum", "risk_band", "shared_token",
                 "shared_token_npi_count", "compound_side", "review_order",
                 "nppes_name_changed_since_match", "nppes_matched_first",
                 "nppes_matched_last")

frames <- lapply(names(inputs), function(nm) {
  d <- utils::read.csv(inputs[[nm]], stringsAsFactors = FALSE,
                       colClasses = "character")
  d$source_template <- nm
  d
})
all_cols <- unique(unlist(lapply(frames, names)))
frames <- lapply(frames, function(d) {
  for (col in setdiff(all_cols, names(d))) d[[col]] <- NA_character_
  d[all_cols]
})
pool <- do.call(rbind, frames)
stopifnot(nrow(pool) == 456L)     # 100 + 100 + 100 + 156; a change here is
                                  # a changed sampling frame, reviewed first
pool$adjudication_id <- paste0("ADJ-", pool$amcb_id, "-", pool$npi)

# One row per (amcb_id, npi); overlapping templates recorded, never lost
key <- pool$adjudication_id
first_of <- !duplicated(key)
templates <- vapply(split(pool$source_template, key), function(x)
  paste(sort(unique(x)), collapse = "|"), character(1))
inst <- pool[first_of, c("adjudication_id", BLINDED_KEEP), drop = FALSE]
inst$source_templates <- templates[inst$adjudication_id]
# Reviewer fields, empty by construction; disagreement_status supports a
# second-reviewer pass (blank | agreed | disagreed_resolved | escalated)
for (col in c("reviewer_verdict", "evidence_source", "evidence_locator",
              "adjudicator", "adjudicated_at", "adjudication_reason",
              "disagreement_status")) inst[[col]] <- ""
inst <- inst[order(inst$adjudication_id), , drop = FALSE]
rownames(inst) <- NULL

sealed <- pool[first_of, c("adjudication_id",
                           intersect(SEALED_KEEP, names(pool))), drop = FALSE]
sealed <- sealed[order(sealed$adjudication_id), , drop = FALSE]
rownames(sealed) <- NULL
stopifnot(identical(sealed$adjudication_id, inst$adjudication_id),
          !anyDuplicated(inst$adjudication_id),
          !any(BLINDED_KEEP %in% SEALED_KEEP))

dir.create("artifacts/truth", showWarnings = FALSE, recursive = TRUE)
out_inst   <- "artifacts/truth/adjudication_instrument_v1.csv"
out_sealed <- "artifacts/truth/adjudication_key_v1_SEALED.csv"
utils::write.csv(inst, out_inst, row.names = FALSE, na = "")
utils::write.csv(sealed, out_sealed, row.names = FALSE, na = "")

sha <- function(f) unname(tools::md5sum(f))  # md5 for speed; sha256 below
sha256 <- function(f) {
  con <- file(f, "rb"); on.exit(close(con))
  # base R has no sha256; shell out deterministically
  trimws(strsplit(system2("shasum", c("-a", "256", shQuote(f)),
                          stdout = TRUE), " ")[[1]][1])
}
manifest <- list(
  instrument_version = "v1",
  built = format(Sys.time(), tz = "UTC", usetz = TRUE),
  builder = "analysis/build_adjudication_instrument_v1.R",
  matching_frozen_at = "mysterynpi fa7216f8966214cf8e1cc4e265b1b5efe56e2c88",
  rows_pooled = nrow(pool), rows_instrument = nrow(inst),
  verdict_vocabulary = c("match", "nonmatch", "indeterminate"),
  inputs = lapply(as.list(inputs), function(f)
    list(file = f, sha256 = sha256(f))),
  outputs = list(instrument = list(file = out_inst, sha256 = sha256(out_inst)),
                 sealed_key = list(file = out_sealed,
                                   sha256 = sha256(out_sealed))))
writeLines(jsonlite::toJSON(manifest, auto_unbox = TRUE, pretty = TRUE),
           "artifacts/truth/adjudication_instrument_v1.manifest.json")
cat(sprintf("instrument: %d rows (%d pooled, %d overlap-deduped)\n",
            nrow(inst), nrow(pool), nrow(pool) - nrow(inst)))
cat("blinded columns:", length(names(inst)), "| sealed columns:",
    length(names(sealed)), "\n")
