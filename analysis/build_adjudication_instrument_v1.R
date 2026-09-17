# =============================================================================
# Truth-set instrument v1.1: population, provenance, blinding, custody
# =============================================================================
# WHY THIS EXISTS. The 2026-09-07 nickname ablation (mysterynpi, matcher
# fa7216f) established that midwifery holds NO adjudicated person-level
# match/nonmatch truth: all four review templates carry empty verdict
# columns. This builder turns those 456 template rows into a governed
# adjudication population with the contracts a benchmark needs:
#
#   * POPULATION: 327 unique (amcb_id, npi) pairs, immutable content-derived
#     adjudication_ids, frozen by population_hash. Any later addition or
#     removal is a NEW truth-set version.
#   * PROVENANCE: a child table reconstructs all 456 original review rows
#     exactly (round-trip checked), not merely a count.
#   * BLINDING: matcher internals (17 columns) go ONLY to the sealed key,
#     which re-joins by adjudication_id after verdicts land. The reviewer
#     surface is schema-checked against a banned-column list.
#   * OPINIONS =/= RESOLUTION: reviewer opinions accumulate in a reviews
#     table (one row per reviewer x adjudication) and are never overwritten;
#     disputes are settled ONLY in the resolution artifact, and the scorer
#     consumes only final_verdict.
#   * CUSTODY: every emitted file is hashed into one manifest; the
#     unblinding gate (analysis/unblind_truth_set.R) verifies custody,
#     blinding, contamination, and completeness before ANY rejoin. No
#     partial unblinding, no force flag.
#
# Matching stays frozen (mysterynpi fa7216f, nickname-policy-2026-09-07)
# while truth is constructed. Run from the repo root:
#   Rscript analysis/build_adjudication_instrument_v1.R
# =============================================================================

source(file.path("R", "truth_set_checks.R"))

BUILDER_VERSION <- "1.1.0"
MATCHER_SHA <- "fa7216f8966214cf8e1cc4e265b1b5efe56e2c88"
POLICY_VERSION <- "nickname-policy-2026-09-07"

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

# Identity and registry facts the adjudicator may see; matcher conclusions
# are banned (BANNED_REVIEWER_COLUMNS in R/truth_set_checks.R governs).
BLINDED_KEEP <- c("amcb_id", "amcb_customer_id", "amcb_name_original",
                  "normalized_first_name", "normalized_middle_name",
                  "normalized_last_name", "npi", "nppes_first_name",
                  "nppes_middle_name", "nppes_last_name", "nppes_credential",
                  "nppes_city", "nppes_state", "nppes_location_year",
                  "npi_tax_class")
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
  d$source_row_id <- as.character(seq_len(nrow(d)))
  d$source_file_hash <- sha256_file(inputs[[nm]])
  d
})
all_cols <- unique(unlist(lapply(frames, names)))
frames <- lapply(frames, function(d) {
  for (col in setdiff(all_cols, names(d))) d[[col]] <- NA_character_
  d[all_cols]
})
pool <- do.call(rbind, frames)
stopifnot(nrow(pool) == 456L)     # a change here is a changed sampling
                                  # frame: reviewed first, versioned second
pool$adjudication_id <- paste0("ADJ-", pool$amcb_id, "-", pool$npi)

first_of <- !duplicated(pool$adjudication_id)
inst <- pool[first_of, c("adjudication_id", BLINDED_KEEP), drop = FALSE]
inst$workflow_state <- "not_started"
inst <- inst[order(inst$adjudication_id), , drop = FALSE]
rownames(inst) <- NULL

# The provenance child table: EVERY one of the 456 original rows, so the
# original review frames are reconstructible exactly, not just countable.
prov <- pool[, c("adjudication_id", "source_template", "source_row_id",
                 "source_file_hash"), drop = FALSE]
prov$source_review_status <- "unadjudicated"
prov <- prov[order(prov$adjudication_id, prov$source_template,
                   as.integer(prov$source_row_id)), , drop = FALSE]
rownames(prov) <- NULL

sealed <- pool[first_of, c("adjudication_id",
                           intersect(SEALED_KEEP, names(pool))),
               drop = FALSE]
sealed <- sealed[order(sealed$adjudication_id), , drop = FALSE]
rownames(sealed) <- NULL
stopifnot(identical(sealed$adjudication_id, inst$adjudication_id),
          !anyDuplicated(inst$adjudication_id),
          !any(BLINDED_KEEP %in% SEALED_KEEP))

dir.create("artifacts/truth", showWarnings = FALSE, recursive = TRUE)
out <- list(
  instrument  = "artifacts/truth/adjudication_instrument_v1.csv",
  sealed_key  = "artifacts/truth/adjudication_key_v1_SEALED.csv",
  provenance  = "artifacts/truth/adjudication_provenance_v1.csv",
  reviews     = "artifacts/truth/adjudication_reviews_v1.csv",
  resolution  = "artifacts/truth/adjudication_resolution_v1.csv",
  evidence    = "artifacts/truth/adjudication_evidence_v1.csv",
  links       = "artifacts/truth/adjudication_evidence_links_v1.csv",
  eligibility = "artifacts/truth/evidence_source_eligibility_v1.csv")

utils::write.csv(inst, out$instrument, row.names = FALSE, na = "")
utils::write.csv(sealed, out$sealed_key, row.names = FALSE, na = "")
utils::write.csv(prov, out$provenance, row.names = FALSE, na = "")

empty <- function(cols) {
  as.data.frame(stats::setNames(rep(list(character(0)), length(cols)), cols))
}
# Reviewer opinions: one row PER REVIEWER per adjudication; append-only.
if (!file.exists(out$reviews)) {
  utils::write.csv(empty(c("adjudication_id", "reviewer_id", "verdict",
                           "evidence_source", "locator", "reason",
                           "review_date")),
                   out$reviews, row.names = FALSE)
}
# Resolution: the ONLY place final_verdict may exist.
if (!file.exists(out$resolution)) {
  utils::write.csv(empty(c("adjudication_id", "final_verdict",
                           "resolution_method", "resolver",
                           "resolution_date", "resolution_reason")),
                   out$resolution, row.names = FALSE)
}
# Evidence: one adjudication may cite many sources; one source may support
# many judgments -- hence the link table.
if (!file.exists(out$evidence)) {
  utils::write.csv(empty(c("evidence_id", "source_class", "source_url",
                           "source_type", "locator", "notes",
                           "retrieved_at", "evidence_sha256")),
                   out$evidence, row.names = FALSE)
}
if (!file.exists(out$links)) {
  utils::write.csv(empty(c("adjudication_id", "evidence_id")),
                   out$links, row.names = FALSE)
}
# Governed eligibility: policy encoded as data, never reviewer convention,
# never URL inference. board_source is INELIGIBLE for this exercise (the
# contamination principle from the retirement gold-standard work).
if (!file.exists(out$eligibility)) {
  utils::write.csv(data.frame(
    source_class = c("primary_person_source", "institutional_profile",
                     "professional_directory", "board_source",
                     "secondary_source", "other"),
    eligible = c(TRUE, TRUE, TRUE, FALSE, TRUE, FALSE),
    policy_note = c("person's own site/CV/announcement",
                    "employer or university profile",
                    "professional directory listing",
                    "PROHIBITED: board-derived knowledge contaminates truth",
                    "supporting only; must accompany a primary class",
                    "ineligible until classified"),
    stringsAsFactors = FALSE), out$eligibility, row.names = FALSE)
}

manifest <- list(
  instrument_version = "v1.1",
  builder_version = BUILDER_VERSION,
  matcher_sha = MATCHER_SHA,
  policy_version = POLICY_VERSION,
  created_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  rows_pooled = nrow(pool),
  rows_instrument = nrow(inst),
  rows_provenance = nrow(prov),
  deduplicated_overlap_rows = nrow(pool) - nrow(inst),
  population_hash = population_hash(inst$adjudication_id),
  sealed_key_sha256 = sha256_file(out$sealed_key),
  verdict_vocabulary = TRUTH_VERDICTS,
  workflow_states = WORKFLOW_STATES,
  inputs = lapply(as.list(inputs), function(f)
    list(file = f, sha256 = sha256_file(f))),
  files = lapply(out, function(f) list(file = f, sha256 = sha256_file(f))))
writeLines(jsonlite::toJSON(manifest, auto_unbox = TRUE, pretty = TRUE),
           "artifacts/truth/adjudication_instrument_v1.manifest.json")

# The surface the reviewer sees must already satisfy the blinding contract.
check_reviewer_export_blinded(inst)
cat(sprintf("instrument: %d rows | provenance: %d | overlap deduped: %d\n",
            nrow(inst), nrow(prov), nrow(pool) - nrow(inst)))
cat("population_hash:", manifest$population_hash, "\n")
