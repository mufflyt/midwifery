# =============================================================================
# The adjudication queue: resumable, lossless mechanics around 327 decisions
# =============================================================================
# The 327 verdicts are human work; everything AROUND them is machinery, and
# machinery must leave zero bookkeeping: the repository, not a person's
# memory, proves how many remain.
#
# ONE SOURCE OF TRUTH. This module never copies the truth-set semantics: the
# canonical population is artifacts/truth/adjudication_instrument_v1.csv
# (frozen, hash-pinned), the canonical opinions are the append-only
# adjudication_reviews_v1.csv, disputes settle only in the resolution
# artifact, and every guard comes from R/truth_set_checks.R. `case_id` IS
# the frozen `adjudication_id` (content-derived, ADJ-<amcb_id>-<npi>) --
# inventing a second id system would be the second source of truth this
# design exists to prevent.
#
# WORKFLOW STATE IS DERIVED, NEVER AUTHORITY. A case's state is computed
# from the reviews and resolution tables on every read; the instrument's
# workflow_state column is refreshed to match (and the custody manifest
# rehashed) only through import_adjudication_verdicts(), which first proves
# the population hash and every blinded identity column unchanged.
#
# BLINDING HOLDS AT EVERY SURFACE. The queue a reviewer sees carries NO
# machine recommendation, score, method, or difficulty signal -- the frozen
# protocol (and its T4/T9 mutants) forbids it, and the importer re-scans
# incoming free text for matcher vocabulary and board contamination BEFORE
# any row is appended, so a contaminated batch is rejected at the door.
#
# ENTRY VOCABULARY. Reviewers write exactly MATCH / NONMATCH / INSUFFICIENT
# in a batch file; the importer maps them by fixed bijection onto the
# frozen storage vocabulary (match / nonmatch / indeterminate). Anything
# else -- blanks in a started row, yes/no, booleans, other spellings --
# fails the import.
# =============================================================================

ENTRY_VERDICTS <- c(MATCH = "match", NONMATCH = "nonmatch",
                    INSUFFICIENT = "indeterminate")
ENTRY_FIELDS <- c("reviewer_id", "verdict", "evidence_source", "locator",
                  "reason", "review_date")

.truth_paths <- function(truth_dir) {
  list(instrument = file.path(truth_dir, "adjudication_instrument_v1.csv"),
       reviews    = file.path(truth_dir, "adjudication_reviews_v1.csv"),
       resolution = file.path(truth_dir, "adjudication_resolution_v1.csv"),
       batches    = file.path(truth_dir, "adjudication_batches_v1.csv"),
       manifest   = file.path(truth_dir,
                              "adjudication_instrument_v1.manifest.json"))
}

.read_truth <- function(truth_dir) {
  p <- .truth_paths(truth_dir)
  for (f in unlist(p)) if (!file.exists(f)) {
    stop("canonical truth artifact missing: ", f,
         " -- the queue never runs against a partial world", call. = FALSE)
  }
  rd <- function(f) utils::read.csv(f, stringsAsFactors = FALSE,
                                    colClasses = "character")
  w <- list(instrument = rd(p$instrument), reviews = rd(p$reviews),
            resolution = rd(p$resolution), batches = rd(p$batches),
            manifest = jsonlite::fromJSON(p$manifest,
                                          simplifyVector = FALSE))
  check_population(w$instrument, w$manifest)
  w
}

# Derived per-case state, computed from the canonical tables every time.
# Returns a data.frame: adjudication_id, n_opinions, state, final_verdict.
# States: not_started | complete | needs_resolution | resolved.
derive_case_state <- function(instrument, reviews, resolution) {
  ids <- instrument$adjudication_id
  per <- split(reviews$verdict, reviews$adjudication_id)
  n_op <- vapply(ids, function(i)
    length(per[[i]] %||% character(0)), integer(1))
  split_case <- vapply(ids, function(i)
    length(unique(per[[i]] %||% character(0))) > 1L, logical(1))
  has_res <- ids %in% resolution$adjudication_id
  state <- ifelse(n_op == 0L, "not_started",
           ifelse(has_res, "resolved",
           ifelse(split_case, "needs_resolution", "complete")))
  final <- rep(NA_character_, length(ids))
  uni <- vapply(ids, function(i) {
    v <- unique(per[[i]] %||% character(0))
    if (length(v) == 1L) v else NA_character_
  }, character(1))
  final[state == "complete"] <- uni[state == "complete"]
  ri <- match(ids, resolution$adjudication_id)
  final[has_res] <- resolution$final_verdict[ri[has_res]]
  data.frame(adjudication_id = ids, n_opinions = unname(n_op),
             state = state, final_verdict = final,
             stringsAsFactors = FALSE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Build the queue of UNRESOLVED cases, blinded, batch-tagged, byte-stable
#'
#' One row per case that has no recorded opinion yet, in frozen instrument
#' order, carrying the blinded identity/registry evidence, the batch label
#' (workflow metadata only), and empty MATCH/NONMATCH/INSUFFICIENT entry
#' columns. Re-running against unchanged inputs is byte-identical; a case
#' never changes identity, and a case leaves the queue only because the
#' reviews table records a verdict for it.
adjudication_queue <- function(truth_dir = "artifacts/truth") {
  w <- .read_truth(truth_dir)
  st <- derive_case_state(w$instrument, w$reviews, w$resolution)
  unresolved <- w$instrument[st$state == "not_started", , drop = FALSE]
  bi <- match(unresolved$adjudication_id, w$batches$adjudication_id)
  if (anyNA(bi)) {
    stop("QUEUE: ", sum(is.na(bi)), " unresolved case(s) carry no batch ",
         "assignment; regenerate batches from the frozen population",
         call. = FALSE)
  }
  q <- unresolved
  q$adjudication_batch <- w$batches$batch[bi]
  for (col in ENTRY_FIELDS) q[[col]] <- ""
  q <- q[order(q$adjudication_id), , drop = FALSE]
  rownames(q) <- NULL
  check_reviewer_export_blinded(q)   # no matcher signal reaches a reviewer
  q
}

#' Import a filled batch: validated, contamination-scanned, idempotent
#'
#' Reads a reviewer-filled queue/batch CSV and appends the verdicts to the
#' canonical append-only reviews table. Fully blank entry rows are "not yet
#' reviewed" and are skipped; a partially blank started row is invalid.
#' Unknown case ids, off-vocabulary verdicts, matcher-vocabulary leakage,
#' and board contamination each fail the WHOLE import before any write.
#' Re-importing the same file is a no-op; changing an already-recorded
#' verdict for the same (case, reviewer) fails closed, naming the cases --
#' opinions are append-only and revisions go through the resolution
#' protocol, never through re-import.
import_adjudication_verdicts <- function(file,
                                         truth_dir = "artifacts/truth") {
  w <- .read_truth(truth_dir)
  p <- .truth_paths(truth_dir)
  identity_cols <- setdiff(names(w$instrument),
                           c("workflow_state", ENTRY_FIELDS))
  before_identity <- w$instrument[identity_cols]

  filled <- utils::read.csv(file, stringsAsFactors = FALSE,
                            colClasses = "character")
  need <- c("adjudication_id", ENTRY_FIELDS)
  missing_cols <- setdiff(need, names(filled))
  if (length(missing_cols)) {
    stop("IMPORT: file lacks column(s): ",
         paste(missing_cols, collapse = ", "), call. = FALSE)
  }
  blank <- function(x) is.na(x) | !nzchar(trimws(x))
  started <- !Reduce(`&`, lapply(filled[ENTRY_FIELDS], blank))
  rows <- filled[started, need, drop = FALSE]
  if (!nrow(rows)) {
    message("import: no started rows; nothing to do")
    return(invisible(adjudication_status(truth_dir)))
  }
  unknown <- setdiff(rows$adjudication_id, w$instrument$adjudication_id)
  if (length(unknown)) {
    stop("IMPORT: unknown case id(s): ",
         paste(utils::head(unknown, 5), collapse = ", "),
         if (length(unknown) > 5) " ..." else "",
         " -- not in the frozen population", call. = FALSE)
  }
  incomplete <- vapply(seq_len(nrow(rows)), function(i)
    any(blank(unlist(rows[i, ENTRY_FIELDS]))), logical(1))
  if (any(incomplete)) {
    stop("IMPORT: ", sum(incomplete), " started row(s) have blank entry ",
         "fields (need every one of: ",
         paste(ENTRY_FIELDS, collapse = ", "), "); first offender: ",
         rows$adjudication_id[which(incomplete)[1]], call. = FALSE)
  }
  bad_v <- !rows$verdict %in% names(ENTRY_VERDICTS)
  if (any(bad_v)) {
    stop("IMPORT: invalid verdict(s): ",
         paste(unique(rows$verdict[bad_v]), collapse = ", "),
         " -- the entry vocabulary is exactly MATCH / NONMATCH / ",
         "INSUFFICIENT", call. = FALSE)
  }
  dup_in_file <- rows[duplicated(rows[c("adjudication_id", "reviewer_id")]) |
                      duplicated(rows[c("adjudication_id", "reviewer_id")],
                                 fromLast = TRUE), , drop = FALSE]
  if (nrow(dup_in_file) &&
      nrow(unique(dup_in_file)) != length(unique(
        dup_in_file$adjudication_id))) {
    conf <- unique(dup_in_file$adjudication_id[
      ave(dup_in_file$verdict, dup_in_file$adjudication_id,
          dup_in_file$reviewer_id,
          FUN = function(v) length(unique(v))) > 1])
    if (length(conf)) {
      stop("IMPORT: conflicting verdicts inside the file for case(s): ",
           paste(conf, collapse = ", "), call. = FALSE)
    }
  }
  rows <- unique(rows)
  new_rows <- data.frame(
    adjudication_id = rows$adjudication_id,
    reviewer_id = rows$reviewer_id,
    verdict = unname(ENTRY_VERDICTS[rows$verdict]),
    evidence_source = rows$evidence_source,
    locator = rows$locator, reason = rows$reason,
    review_date = rows$review_date, stringsAsFactors = FALSE)

  # contamination and leakage are rejected at the door, before any write
  check_board_contamination(new_rows)
  check_reviewer_export_blinded(
    new_rows[setdiff(names(new_rows), "verdict")])

  existing <- w$reviews
  key <- function(d) paste(d$adjudication_id, d$reviewer_id, sep = "\r")
  ek <- key(existing); nk <- key(new_rows)
  clash <- nk %in% ek
  if (any(clash)) {
    same <- vapply(which(clash), function(i) {
      j <- which(ek == nk[i])[1]
      identical(unname(unlist(existing[j, names(new_rows)])),
                unname(unlist(new_rows[i, ])))
    }, logical(1))
    if (any(!same)) {
      stop("IMPORT: verdict already recorded and DIFFERS for case(s): ",
           paste(new_rows$adjudication_id[which(clash)[!same]],
                 collapse = ", "),
           " -- opinions are append-only; a change of mind goes through ",
           "the resolution protocol with its reason preserved",
           call. = FALSE)
    }
    new_rows <- new_rows[!clash, , drop = FALSE]   # idempotent re-import
  }
  if (nrow(new_rows)) {
    out <- rbind(existing, new_rows)
    utils::write.csv(out, p$reviews, row.names = FALSE, na = "")
  }

  # refresh DERIVED workflow_state on the instrument, prove identity intact
  w2 <- list(instrument = w$instrument,
             reviews = utils::read.csv(p$reviews, stringsAsFactors = FALSE,
                                       colClasses = "character"),
             resolution = w$resolution)
  st <- derive_case_state(w2$instrument, w2$reviews, w2$resolution)
  inst <- w$instrument
  inst$workflow_state <- ifelse(st$state == "not_started" &
                                  inst$workflow_state == "in_review",
                                "in_review", st$state)
  stopifnot(identical(inst[identity_cols], before_identity))
  utils::write.csv(inst, p$instrument, row.names = FALSE, na = "")

  # custody: rehash the two working files; frozen hashes stay frozen
  man <- w$manifest
  for (nm in c("instrument", "reviews")) {
    f <- man$files[[nm]]$file
    man$files[[nm]]$sha256 <- sha256_file(f)
  }
  stopifnot(identical(man$population_hash,
                      population_hash(inst$adjudication_id)))
  writeLines(jsonlite::toJSON(man, auto_unbox = TRUE, pretty = TRUE),
             p$manifest)
  invisible(adjudication_status(truth_dir))
}

#' The machine-readable completion authority
#'
#' Counts derive ONLY from the canonical tables; `complete` can be TRUE
#' only at 327/327 with zero unresolved, zero duplicates, zero conflicts,
#' zero invalid rows. 326/327 is not complete, and nothing here rounds up.
adjudication_status <- function(truth_dir = "artifacts/truth",
                                out_dir = "artifacts/adjudication") {
  w <- .read_truth(truth_dir)
  st <- derive_case_state(w$instrument, w$reviews, w$resolution)
  invalid <- sum(!w$reviews$verdict %in% TRUTH_VERDICTS)
  conflicts <- sum(st$state == "needs_resolution")
  unresolved <- sum(st$state == "not_started")
  adjudicated <- sum(st$state %in% c("complete", "resolved"))
  finals <- st$final_verdict[st$state %in% c("complete", "resolved")]
  sha <- tryCatch(system2("git", c("rev-parse", "HEAD"), stdout = TRUE),
                  error = function(e) NA_character_)
  status <- list(
    git_sha = sha,
    generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
    source_checksum = w$manifest$population_hash,
    total_cases = nrow(w$instrument),
    adjudicated_cases = adjudicated,
    match = sum(finals == "match"),
    nonmatch = sum(finals == "nonmatch"),
    insufficient = sum(finals == "indeterminate"),
    unresolved_cases = unresolved,
    needs_resolution = conflicts,
    duplicate_case_ids = as.integer(anyDuplicated(
      w$instrument$adjudication_id)),
    conflicting_verdicts = conflicts,
    invalid_verdicts = invalid,
    complete = adjudicated == nrow(w$instrument) && unresolved == 0L &&
      conflicts == 0L && invalid == 0L &&
      !anyDuplicated(w$instrument$adjudication_id))
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(jsonlite::toJSON(status, auto_unbox = TRUE, pretty = TRUE),
             file.path(out_dir, "adjudication_status.json"))
  status
}
