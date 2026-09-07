# =============================================================================
# The unblinding gate: matcher internals rejoin ONLY behind every guard
# =============================================================================
# The sealed key (matcher method, confidence, evidence class...) may rejoin
# the adjudicated truth ONLY when every contract below holds. There is no
# force flag, no subset argument, no partial unblinding, no manual override
# -- deliberately: the function's formals are part of the contract and a
# test pins them. If a guard fails, fix the data, never the gate.
#
#   1. custody: every file hash matches the frozen manifest
#   2. population: 327 rows, unique immutable ids, population_hash matches
#   3. provenance: the 456 original review rows reconstruct exactly
#   4. blinding: no matcher column or vocabulary on the reviewer surface
#   5. contamination: no board-derived knowledge in any free-text field
#   6. evidence: no orphans; eligibility by governed class, never URL text
#   7. completeness: 327/327 terminal states, valid verdicts, reviewer
#      identity/date/reason present, every disagreement resolved
#
# On success it writes the FINAL truth artifact (adjudication_id +
# final_verdict + provenance stamp) and records its hash. Scoring is a
# separate phase in a separate PR and consumes only that artifact.
# =============================================================================

source(file.path("R", "truth_set_checks.R"))

unblind_truth_set <- function(truth_dir = "artifacts/truth") {
  rd <- function(f) utils::read.csv(file.path(truth_dir, f),
                                    stringsAsFactors = FALSE,
                                    colClasses = "character")
  manifest <- jsonlite::fromJSON(
    file.path(truth_dir, "adjudication_instrument_v1.manifest.json"),
    simplifyVector = FALSE)
  check_custody(manifest, root = ".")
  instrument <- rd("adjudication_instrument_v1.csv")
  provenance <- rd("adjudication_provenance_v1.csv")
  reviews    <- rd("adjudication_reviews_v1.csv")
  resolution <- rd("adjudication_resolution_v1.csv")
  evidence   <- rd("adjudication_evidence_v1.csv")
  links      <- rd("adjudication_evidence_links_v1.csv")
  eligibility <- utils::read.csv(
    file.path(truth_dir, "evidence_source_eligibility_v1.csv"),
    stringsAsFactors = FALSE)

  check_population(instrument, manifest)
  check_provenance_roundtrip(provenance, instrument)
  check_reviewer_export_blinded(instrument)
  check_board_contamination(reviews, resolution, evidence)
  check_evidence(evidence, links, instrument, eligibility)
  check_completeness(instrument, reviews, resolution)

  # Final verdict: the resolution artifact where one exists; otherwise the
  # UNANIMOUS reviewer verdict (check_completeness has already proven that
  # every dispute carries a resolution and every row carries an opinion).
  per <- split(reviews$verdict, reviews$adjudication_id)
  unanimous <- vapply(per, function(v) unique(v)[1], character(1))
  final <- data.frame(adjudication_id = instrument$adjudication_id,
                      stringsAsFactors = FALSE)
  final$final_verdict <- unname(unanimous[final$adjudication_id])
  r_i <- match(final$adjudication_id, resolution$adjudication_id)
  final$final_verdict[!is.na(r_i)] <-
    resolution$final_verdict[r_i[!is.na(r_i)]]
  final$verdict_source <- ifelse(!is.na(r_i), "resolution", "unanimous")
  stopifnot(!anyNA(final$final_verdict),
            all(final$final_verdict %in% TRUTH_VERDICTS))

  out <- file.path(truth_dir, "truth_set_v1_final.csv")
  utils::write.csv(final, out, row.names = FALSE)
  stamp <- list(final_truth_sha256 = sha256_file(out),
                population_hash = manifest$population_hash,
                sealed_key_sha256 = manifest$sealed_key_sha256,
                matcher_sha = manifest$matcher_sha,
                policy_version = manifest$policy_version,
                unblinded_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
                n = nrow(final),
                verdicts = as.list(table(final$final_verdict)))
  writeLines(jsonlite::toJSON(stamp, auto_unbox = TRUE, pretty = TRUE),
             file.path(truth_dir, "truth_set_v1_final.manifest.json"))
  cat("UNBLINDED:", nrow(final), "verdicts ->", out, "\n")
  invisible(final)
}

if (sys.nframe() == 0L || identical(Sys.getenv("RUN_UNBLIND"), "1")) {
  if (!interactive() && identical(Sys.getenv("RUN_UNBLIND"), "1")) {
    unblind_truth_set()
  }
}
