# =============================================================================
# Truth-set custody, blinding, and completeness checks
# =============================================================================
# The adjudication instrument (analysis/build_adjudication_instrument_v1.R)
# becomes a benchmark only if it cannot be contaminated on the way there.
# Every function below is one discrete, fail-closed guard; the unblinding
# gate (analysis/unblind_truth_set.R) runs all of them and refuses partial
# results. Each guard has a mutation-catalogue entry that hollows it and a
# named killer test that must then fail -- the guard is only as real as the
# mutant it kills.
#
# All guards stop() on violation and return invisible(TRUE) on pass.
# =============================================================================

TRUTH_VERDICTS <- c("match", "nonmatch", "indeterminate")
WORKFLOW_STATES <- c("not_started", "in_review", "complete",
                     "needs_resolution", "resolved")
TERMINAL_STATES <- c("complete", "resolved")

# Matcher internals that must never reach a reviewer-facing surface.
BANNED_REVIEWER_COLUMNS <- c(
  "name_evidence_class", "npi_match_method", "npi_match_confidence",
  "match_reason", "linkage_tier", "ambiguity_flag", "candidate_count",
  "n_at_best_class", "review_stratum", "risk_band", "shared_token",
  "shared_token_npi_count", "compound_side", "review_order",
  "nppes_name_changed_since_match", "nppes_matched_first",
  "nppes_matched_last", "match_score", "candidate_rank",
  "acceptance_status", "final_verdict")

# Matcher vocabulary that must not leak through free-text fields either --
# a banned COLUMN check alone misses "confidence 0.35" pasted into notes.
BANNED_VALUE_PATTERNS <- c(
  "exact_last_first", "fuzzy_last_exact", "surname_component",
  "evidence class", "npi_match", "risk[_ ]band", "linkage[_ ]tier",
  "match[_ ]reason", "confidence[= ]?0\\.[0-9]")

# Board contamination: never inferred from domains alone; these patterns
# scan EVERY free-text field (notes, locators, reasons, urls).
BOARD_PATTERNS <- c(
  "\\bboards?\\b", "medical board", "nursing board", "state board",
  "board of (nursing|medicine|midwifery)", "\\bTMB\\b", "\\bBON\\b",
  "licens[a-z]* board")

sha256_file <- function(f) {
  trimws(strsplit(system2("shasum", c("-a", "256", shQuote(f)),
                          stdout = TRUE), " ")[[1]][1])
}

population_hash <- function(adj_ids) {
  tf <- tempfile(); on.exit(unlink(tf))
  writeLines(sort(adj_ids), tf)
  sha256_file(tf)
}

# ---- T1 / T2: population integrity ------------------------------------------
check_population <- function(instrument, manifest) {
  if (nrow(instrument) != manifest$rows_instrument) {
    stop("POPULATION: instrument has ", nrow(instrument), " rows; manifest ",
         "froze ", manifest$rows_instrument,
         ". Any addition/removal after first adjudication requires a new ",
         "truth-set version.", call. = FALSE)
  }
  if (anyDuplicated(instrument$adjudication_id)) {
    stop("POPULATION: duplicate adjudication_id -- ids are immutable and ",
         "unique by contract", call. = FALSE)
  }
  got <- population_hash(instrument$adjudication_id)
  if (!identical(got, manifest$population_hash)) {
    stop("POPULATION: hash mismatch (", got, " vs frozen ",
         manifest$population_hash, "); the adjudication population has ",
         "changed since it was frozen", call. = FALSE)
  }
  invisible(TRUE)
}

# ---- T3: provenance round-trip ----------------------------------------------
check_provenance_roundtrip <- function(provenance, instrument,
                                       expected = c(c5guard = 100L,
                                                    baseline = 100L,
                                                    component = 100L,
                                                    class5 = 156L)) {
  if (nrow(provenance) != sum(expected)) {
    stop("PROVENANCE: ", nrow(provenance), " child rows cannot reconstruct ",
         "the ", sum(expected), " original review rows", call. = FALSE)
  }
  got <- table(provenance$source_template)
  for (tpl in names(expected)) {
    n <- if (tpl %in% names(got)) as.integer(got[[tpl]]) else 0L
    if (n != expected[[tpl]]) {
      stop("PROVENANCE: template '", tpl, "' contributes ", n, " rows, ",
           "expected ", expected[[tpl]], call. = FALSE)
    }
    ids <- sort(as.integer(
      provenance$source_row_id[provenance$source_template == tpl]))
    if (!identical(ids, seq_len(expected[[tpl]]))) {
      stop("PROVENANCE: template '", tpl, "' source_row_ids are not the ",
           "complete sequence 1..", expected[[tpl]], call. = FALSE)
    }
  }
  orphan <- setdiff(provenance$adjudication_id, instrument$adjudication_id)
  if (length(orphan)) {
    stop("PROVENANCE: ", length(orphan), " child row(s) reference ",
         "adjudication_ids absent from the instrument", call. = FALSE)
  }
  invisible(TRUE)
}

# ---- T4 + banned-value leakage: blinding ------------------------------------
check_reviewer_export_blinded <- function(export) {
  leaked <- intersect(BANNED_REVIEWER_COLUMNS, names(export))
  if (length(leaked)) {
    stop("BLINDING: matcher-internal column(s) reached the reviewer ",
         "surface: ", paste(leaked, collapse = ", "), call. = FALSE)
  }
  txt_cols <- names(export)[vapply(export, is.character, logical(1))]
  for (col in txt_cols) {
    for (pat in BANNED_VALUE_PATTERNS) {
      hit <- grepl(pat, export[[col]], ignore.case = TRUE)
      if (any(hit, na.rm = TRUE)) {
        stop("BLINDING: matcher vocabulary ('", pat, "') leaked through ",
             "free text in column '", col, "'", call. = FALSE)
      }
    }
  }
  invisible(TRUE)
}

# ---- T9: board contamination ------------------------------------------------
check_board_contamination <- function(...) {
  frames <- list(...)
  for (fi in seq_along(frames)) {
    d <- frames[[fi]]
    txt_cols <- names(d)[vapply(d, is.character, logical(1))]
    for (col in txt_cols) {
      for (pat in BOARD_PATTERNS) {
        hit <- grepl(pat, d[[col]], ignore.case = TRUE)
        if (any(hit, na.rm = TRUE)) {
          stop("BOARD CONTAMINATION: pattern '", pat, "' found in column '",
               col, "' (frame ", fi, "). Board-derived knowledge may not ",
               "enter this truth exercise through any field -- notes, ",
               "locator, reason, or url -- regardless of the source's ",
               "domain.", call. = FALSE)
        }
      }
    }
  }
  invisible(TRUE)
}

# ---- T8 / T11: evidence integrity and governed eligibility -------------------
check_evidence <- function(evidence, links, instrument, eligibility) {
  if (nrow(evidence) == 0L) return(invisible(TRUE))
  orphan_link <- setdiff(links$evidence_id, evidence$evidence_id)
  if (length(orphan_link)) {
    stop("EVIDENCE: link rows reference missing evidence_id(s): ",
         paste(utils::head(orphan_link, 3), collapse = ", "), call. = FALSE)
  }
  unlinked <- setdiff(evidence$evidence_id, links$evidence_id)
  if (length(unlinked)) {
    stop("EVIDENCE: ", length(unlinked), " evidence row(s) support no ",
         "adjudication (orphaned)", call. = FALSE)
  }
  bad_adj <- setdiff(links$adjudication_id, instrument$adjudication_id)
  if (length(bad_adj)) {
    stop("EVIDENCE: link rows reference adjudication_ids outside the ",
         "frozen population", call. = FALSE)
  }
  # Eligibility is decided by the DECLARED source_class against the
  # governed table -- never inferred from URL text. A clean-looking URL
  # does not launder an ineligible class, and a suspicious-looking URL
  # does not condemn an eligible one (contamination is a separate check).
  i <- match(evidence$source_class, eligibility$source_class)
  if (anyNA(i)) {
    stop("EVIDENCE: undeclared source_class value(s): ",
         paste(unique(evidence$source_class[is.na(i)]), collapse = ", "),
         "; the eligibility table is the only registry", call. = FALSE)
  }
  ineligible <- which(!eligibility$eligible[i])
  if (length(ineligible)) {
    stop("EVIDENCE: ", length(ineligible), " evidence row(s) carry an ",
         "ineligible source_class (",
         paste(unique(evidence$source_class[ineligible]), collapse = ", "),
         ") for this truth exercise", call. = FALSE)
  }
  invisible(TRUE)
}

# ---- T6 / T7 / T10: completeness, disagreement, immutability ------------------
check_completeness <- function(instrument, reviews, resolution) {
  # T10 structural guard: verdicts are never finalized IN the reviews --
  # a final_verdict column on reviews or instrument means someone
  # overwrote opinions instead of resolving them.
  if ("final_verdict" %in% c(names(reviews), names(instrument))) {
    stop("IMMUTABILITY: final_verdict belongs ONLY in the resolution ",
         "artifact; reviewer opinions are never overwritten", call. = FALSE)
  }
  nonterminal <- which(!instrument$workflow_state %in% TERMINAL_STATES)
  if (length(nonterminal)) {
    stop("COMPLETENESS: ", length(nonterminal), " of ", nrow(instrument),
         " rows lack a terminal workflow state; partial truth never ",
         "unblinds", call. = FALSE)
  }
  if (nrow(reviews)) {
    bad_v <- which(!reviews$verdict %in% TRUTH_VERDICTS)
    if (length(bad_v)) {
      stop("COMPLETENESS: invalid reviewer verdict(s): ",
           paste(unique(reviews$verdict[bad_v]), collapse = ", "),
           call. = FALSE)
    }
    for (col in c("reviewer_id", "review_date", "reason")) {
      if (any(is.na(reviews[[col]]) | !nzchar(reviews[[col]]))) {
        stop("COMPLETENESS: reviewer ", col, " missing on at least one ",
             "opinion row", call. = FALSE)
      }
    }
  }
  covered <- unique(c(reviews$adjudication_id, resolution$adjudication_id))
  uncovered <- setdiff(instrument$adjudication_id, covered)
  if (length(uncovered)) {
    stop("COMPLETENESS: ", length(uncovered), " adjudication row(s) have ",
         "no reviewer opinion at all", call. = FALSE)
  }
  # T7: disagreement between reviewers demands a resolution row
  if (nrow(reviews)) {
    per <- split(reviews$verdict, reviews$adjudication_id)
    disputed <- names(per)[vapply(per, function(v)
      length(unique(v)) > 1L, logical(1))]
    unresolved <- setdiff(disputed, resolution$adjudication_id)
    if (length(unresolved)) {
      stop("DISAGREEMENT: ", length(unresolved), " disputed row(s) have no ",
           "resolution artifact; the scorer consumes only final_verdict",
           call. = FALSE)
    }
  }
  if (nrow(resolution)) {
    bad_f <- which(!resolution$final_verdict %in% TRUTH_VERDICTS)
    if (length(bad_f)) {
      stop("DISAGREEMENT: invalid final_verdict value(s)", call. = FALSE)
    }
    for (col in c("resolution_method", "resolver", "resolution_reason")) {
      if (any(is.na(resolution[[col]]) | !nzchar(resolution[[col]]))) {
        stop("DISAGREEMENT: resolution ", col, " missing -- a resolution ",
             "without its reasoning is an overwrite wearing a hat",
             call. = FALSE)
      }
    }
  }
  invisible(TRUE)
}

# ---- T5 / T12: custody --------------------------------------------------------
check_custody <- function(manifest, root = ".") {
  for (nm in names(manifest$files)) {
    f <- manifest$files[[nm]]$file
    if (!startsWith(f, "/")) f <- file.path(root, f)
    if (!file.exists(f)) {
      stop("CUSTODY: manifest names '", nm, "' at ", f,
           " but the file is absent", call. = FALSE)
    }
    got <- sha256_file(f)
    if (!identical(got, manifest$files[[nm]]$sha256)) {
      stop("CUSTODY: hash mismatch for '", nm, "' (", f, "): ", got,
           " vs manifest ", manifest$files[[nm]]$sha256,
           "; the scorer must not read truth whose custody fails",
           call. = FALSE)
    }
  }
  invisible(TRUE)
}
