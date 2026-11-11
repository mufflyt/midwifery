# =============================================================================
# The mutation catalogue: plausible bugs, and the tests that must catch them
# =============================================================================
# Every other suite in tests/ asks "is the code right?". This one asks "would we
# notice if it were wrong?", which is a different question and the only one that
# measures the suite itself.
#
# Each entry is a bug a competent person could actually introduce -- an
# inverted operator, a loosened threshold, a disabled guard -- paired with the
# tests that ought to turn red. A mutation that SURVIVES is not a bug in the
# code; it is a hole in the tests, and it is reported as one.
#
# Rules for adding an entry:
#
#   * `find` must occur EXACTLY ONCE in `file`. The runner fails if it occurs
#     zero times (the mutation has rotted and is silently testing nothing) or
#     more than once (it would mutate more than intended). A catalogue that
#     quietly stops applying is worse than no catalogue.
#   * `killers` names the specific tests that SHOULD detect it. Listing the
#     whole suite would make every mutation look caught for the wrong reason
#     and would take an hour.
#   * `why` states the real-world failure. If you cannot write that sentence,
#     the mutation is probably not plausible enough to be worth a slot.
#
# NOTE ON SCOPE. These mutate helper/contract code, not the numbered pipeline
# scripts. Pipeline scripts need person-level inputs that are absent on a
# runner, so mutating them would produce "survived" for want of data rather
# than for want of a test -- a false hole, which is worse than a missed one.
# =============================================================================

MUTATIONS <- list(

  # ---- identity membership -------------------------------------------------
  list(
    id = "membership-and-to-or",
    file = "R/amcb_cohort_membership.R",
    find = "  has_npi & eligible\n}",
    repl = "  has_npi | eligible\n}",
    why = paste("Cohort membership requires an NPI AND an allowlisted tier.",
                "Loosened to OR, every quarantined and unmatched row with an",
                "allowlisted tier joins the analytic cohort, and so does every",
                "held-out class-5 candidate that has an NPI."),
    killers = c("tests/test_amcb_gates.R")
  ),

  list(
    id = "membership-admit-class5",
    file = "R/amcb_cohort_membership.R",
    find = '  "sensitivity_unknown_taxonomy"    # identity evidence present; taxonomy label dirty\n)',
    repl = '  "sensitivity_unknown_taxonomy",   # identity evidence present; taxonomy label dirty\n  "sensitivity_name_component"\n)',
    why = paste("Promotes class-5 (shared surname COMPONENT only) into the",
                "cohort. These are deliberately held out because a shared name",
                "fragment is not an identity claim."),
    killers = c("tests/test_amcb_gates.R")
  ),

  # ---- name matching -------------------------------------------------------
  # RETIRED HERE, NOT RETIRED (2026-09-05). Two mutants used to live in this
  # section, aimed at R/amcb_name_keys.R:
  #
  #   surname-token-min-length   AMCB_MIN_SURNAME_TOKEN 4 -> 2
  #   person-match-and-to-or     same_last & shared -> |
  #
  # That file is now a shim over the mysterynpi package, and the mutable code
  # moved with it. Both mutants run THERE, on every push, as
  # `surname-token-floor` and `person-match-and-to-or` in the package's
  # matching-gate campaign (tools/ci/mutation_campaign.R in mufflyt/mysterynpi)
  # -- same corruption, same kill requirement, no longer gated on a private
  # checkout being present. The behaviour this repository relies on is pinned
  # from the consumer side by tests/test_mysterynpi_contracts.R. A mutant kept
  # here would anchor on text the shim no longer contains and rot into
  # "testing nothing", which this catalogue treats as failure by design.

  # ---- arithmetic ----------------------------------------------------------
  list(
    id = "safe-divide-zero-threshold",
    file = "R/safe_divide.R",
    find = "                        zero_threshold = 1e-10,",
    repl = "                        zero_threshold = 0,",
    why = paste("With the tolerance at zero, a denominator of 1e-300 is no",
                "longer treated as zero and the quotient becomes Inf instead",
                "of the declared default."),
    killers = c("tests/test-safe-divide-zero-threshold-bva.R",
                "tests/test_safe_divide_types.R")
  ),

  # ---- provenance ----------------------------------------------------------
  list(
    id = "provenance-never-stale",
    file = "R/lib/artifact_provenance.R",
    find = "               stale = !identical(cur, i$sha256), stringsAsFactors = FALSE)",
    repl = "               stale = FALSE, stringsAsFactors = FALSE)",
    why = paste("Disables the provenance contract outright: every artifact",
                "reports fresh regardless of whether its inputs changed",
                "underneath it."),
    killers = c("tests/test_cycle18_artifact_freshness.R")
  ),

  # ---- the anti-vacuous guards --------------------------------------------
  list(
    id = "empty-selection-allowed",
    file = "R/amcb_match_rules.R",
    find = '    stop(sprintf(paste("%s selected NOTHING. A selector that matches nothing",\n                       "has not passed -- it has not run."), what), call. = FALSE)',
    repl = "    invisible(x)",
    why = paste("A selector matching nothing would report success. This is the",
                "guard that turns a vacuous pass into a failure; without it a",
                "gate that examines zero rows looks green."),
    killers = c("tests/test_amcb_gates.R")
  ),

  list(
    id = "require-cols-no-op",
    file = "R/amcb_match_rules.R",
    find = "  missing <- setdiff(cols, names(df))\n  if (length(missing)) {",
    repl = "  missing <- character(0)\n  if (length(missing)) {",
    why = paste("An absent join key stops being an error, so a join on a",
                "column that does not exist proceeds and silently produces",
                "nothing."),
    killers = c("tests/test_amcb_gates.R")
  ),

  # ---- the resolver ---------------------------------------------------------
  list(
    id = "resolver-accept-ambiguous",
    file = "R/amcb_resolver.R",
    find = "    dplyr::filter(.data$n_at_best_class == 1L) |>",
    repl = "    dplyr::filter(.data$n_at_best_class >= 1L) |>",
    why = paste("Exactly one candidate at the strongest evidence class is what",
                "makes a match unambiguous. Relaxed to >= 1, every tied person",
                "resolves -- to all of their tied candidates at once -- and the",
                "quarantine that protects ambiguous identities empties."),
    killers = c("tests/test_amcb_resolver_permutation.R")
  ),

  list(
    id = "resolver-class5-outranks-class4",
    file = "R/amcb_resolver.R",
    find = "      confidence_score = c(1.0, 0.9, 0.7, 0.5, 0.35)[.data$name_evidence_class])",
    repl = "      confidence_score = c(1.0, 0.9, 0.7, 0.35, 0.5)[.data$name_evidence_class])",
    why = paste("Swaps the confidence of class 4 and class 5, making a partial",
                "surname fragment more trustworthy than a whole surname within",
                "edit distance 2."),
    killers = c("tests/test_amcb_resolver_permutation.R")
  ),

  # ---- adversarial identity attacks (items 7/45/46) ------------------------
  # Each of these is a way to make the resolver confidently wrong. The
  # adversarial corpus exists to kill them.
  list(
    id = "adversarial-taxonomy-breaks-ties",
    file = "R/amcb_resolver.R",
    find = "    dplyr::filter(.data$name_evidence_class == .data$best_evidence_class) |>\n    dplyr::filter(.data$n_at_best_class == 1L) |>",
    repl = "    dplyr::filter(.data$name_evidence_class == .data$best_evidence_class) |>\n    dplyr::group_by(.data$amcb_id) |>\n    dplyr::filter(dplyr::n() == 1L | .data$taxonomy_axis == \"midwife\") |>\n    dplyr::slice(1L) |> dplyr::ungroup() |>",
    why = paste("Lets taxonomy break an identity tie. Taxonomy says what an NPI",
                "does for a living; it says nothing about WHICH person a name",
                "refers to, so using it to resolve is confidently wrong."),
    killers = c("tests/test_adversarial_identity_resolution.R")
  ),

  list(
    id = "adversarial-class5-eligible",
    file = "R/amcb_cohort_membership.R",
    find = "  \"sensitivity_unknown_taxonomy\"    # identity evidence present; taxonomy label dirty\n)",
    repl = "  \"sensitivity_unknown_taxonomy\",   # identity evidence present; taxonomy label dirty\n  \"sensitivity_name_component\"\n)",
    why = paste("Admits class-5 surname FRAGMENTS to the analytic cohort. A",
                "shared name fragment is not an identity claim, and the corpus",
                "carries an attractive class-5 decoy for exactly this."),
    killers = c("tests/test_adversarial_identity_resolution.R")
  ),

  list(
    id = "adversarial-taxonomy-unknown-becomes-primary",
    file = "R/amcb_resolver.R",
    find = '    has                                    ~ "sensitivity_unknown_taxonomy",',
    repl = '    has                                    ~ "primary_midwifery",',
    why = paste("Promotes dirty or unrecognised taxonomy values into the strongest",
                "tier. Counts may not move, but the published claim about how the",
                "identity was established becomes false."),
    killers = c("tests/test_metamorphic_invariance.R",
                "tests/test_adversarial_identity_resolution.R")
  ),

  list(
    id = "adversarial-tier-fuzzy-becomes-primary",
    file = "R/amcb_resolver.R",
    find = "    has & name_evidence_class == 4L        ~ \"sensitivity_fuzzy\",",
    repl = "    has & name_evidence_class == 4L        ~ \"primary_midwifery\",",
    why = paste("Promotes fuzzy-surname matches to the primary tier, erasing the",
                "distinction between exact identity evidence and a surname",
                "within edit distance 2."),
    killers = c("tests/test_adversarial_identity_resolution.R")
  ),

  list(
    id = "resolver-ambiguous-anchor-dropped",
    file = "R/amcb_resolver.R",
    find = '    grepl("^ambiguous", match_status)      ~ "quarantined",',
    repl = '    grepl("ambiguous", match_status)        ~ "quarantined",',
    why = paste("Drops the start-of-string anchor, so any match_status that merely",
                "MENTIONS \"ambiguous\" anywhere (e.g. a future",
                "'formerly_ambiguous_now_resolved' value) gets quarantined instead",
                "of only the three real ambiguous_* strings match_amcb_to_npi.R",
                "actually writes."),
    killers = c("tests/test_amcb_resolver_saboteur_paths.R")
  ),

  list(
    id = "resolver-demotion-inverted",
    file = "R/amcb_resolver.R",
    find = '    demoted_absence_c5 %in% TRUE           ~ "quarantined",',
    repl = '    demoted_absence_c5 %in% FALSE          ~ "quarantined",',
    why = paste("Inverts the demotion flag, so a class-5 match that was correctly",
                "demoted for being resolved only by the middle-name veto's",
                "manufactured uniqueness falls through to unmatched instead of",
                "quarantined -- the demotion silently stops doing anything."),
    killers = c("tests/test_amcb_resolver_saboteur_paths.R")
  ),

  list(
    id = "cohort-membership-length-guard-removed",
    file = "R/amcb_cohort_membership.R",
    find = paste0('  if (length(npi) != length(linkage_tier)) {\n',
                  '    stop(sprintf("npi and linkage_tier differ in length (%d vs %d)",\n',
                  '                 length(npi), length(linkage_tier)), call. = FALSE)\n',
                  '  }\n'),
    repl = "",
    why = paste("Removes the explicit length-mismatch guard, so a caller passing",
                "mismatched npi/linkage_tier vectors gets silent R recycling",
                "instead of a loud error -- exactly the unguarded hazard",
                "documented for amcb_linkage_tier() in R/amcb_resolver.R, now",
                "reintroduced into the one function that used to guard against it."),
    killers = c("tests/test_amcb_cohort_membership_saboteur.R")
  ),

  list(
    id = "adversarial-missing-is-agreement",
    file = "R/amcb_cohort_membership.R",
    find = "  has_npi <- !is.na(npi) & nzchar(npi)",
    repl = "  has_npi <- is.na(npi) | nzchar(npi)",
    why = paste("Treats a MISSING npi as agreement, so an unresolved person",
                "becomes a cohort member. Missing information must never make a",
                "match more certain."),
    killers = c("tests/test_adversarial_identity_resolution.R")
  ),

  # ---- recovery / resume (item 29) -----------------------------------------
  # This code has already destroyed data once. Every way it could do so again.
  list(
    id = "resume-ignores-prior-output",
    file = "R/lib/resume_state.R",
    find = "  if (is.null(prior) || !nrow(prior) || !id_col %in% names(prior)) return(done)",
    repl = "  return(done)",
    why = paste("Reproduces the 2026-08-09 incident exactly: recovery ignores",
                "the prior output, so a missing checkpoint truncates the CSV",
                "that held the work. 482 KB became 552 bytes and 5,963",
                "completed searches were lost."),
    killers = c("tests/test_recovery_resume_equivalence.R")
  ),

  list(
    id = "resume-stale-file-wins",
    file = "R/lib/resume_state.R",
    find = "  recovered[names(done)] <- done",
    repl = "  recovered <- recovered",
    why = paste("Lets a stale output file overwrite fresher checkpoint entries,",
                "so completed work is silently replaced by older results."),
    killers = c("tests/test_recovery_resume_equivalence.R")
  ),

  list(
    id = "resume-redoes-everything",
    file = "R/lib/resume_state.R",
    find = "  todo <- roster[!as.character(roster[[id_col]]) %in% names(done), , drop = FALSE]",
    repl = "  todo <- roster",
    why = paste("Drops the already-done filter, so every resume re-runs the",
                "entire roster. At 22,309 certificants and a 2-second delay",
                "that is 12 hours of redundant requests per restart."),
    killers = c("tests/test_recovery_resume_equivalence.R")
  ),

  # ---- metamorphic / serialization (item 3) --------------------------------
  list(
    id = "metamorphic-pad5-drops-blank-guard",
    file = "R/lib/common_helpers.R",
    find = "  x <- stringr::str_trim(as.character(x))\n  x[!nzchar(x)] <- NA_character_\n  stringr::str_pad(x, 6, \"left\", \"0\")",
    repl = "  x <- stringr::str_trim(as.character(x))\n  stringr::str_pad(x, 6, \"left\", \"0\")",
    why = paste("Removes the blank guard from pad_ccn(), so an empty string",
                "becomes \"000000\" -- a CCN that does not exist but joins",
                "perfectly to every other blank record."),
    killers = c("tests/test_lib_keys.R", "tests/test_metamorphic_invariance.R")
  ),

  # ---- is_enrolled_dac (retraction-level, docs/HANDOFF_is_enrolled_dac.md) ---
  list(
    id = "enrollment-missing-becomes-false",
    file = "R/lib/match_npi_to_hospitals.R",
    find = "    return(rep(NA, length(npi)))",
    repl = "    return(rep(FALSE, length(npi)))",
    why = paste("Turns 'we did not look' into 'they are not enrolled'.",
                "Collapsing missing evidence into FALSE is exactly how the",
                "original defect read as a finding rather than as missing",
                "data -- a clean logical column, a plausible Table 1 row, and",
                "a wrong number."),
    killers = c("tests/test_is_enrolled_dac_semantics.R")
  ),

  # ---- atomic writes (DEBT.md D1) ------------------------------------------
  list(
    id = "atomic-write-skips-validation",
    file = "R/lib/resume_state.R",
    find = "  if (!is.null(validate) && !isTRUE(validate(tmp))) {",
    repl = "  if (FALSE) {",
    why = paste("Removes the pre-rename validation, so a write that completed",
                "but produced nonsense replaces a good file. An empty CSV",
                "overwriting a complete one is the exact shape of the",
                "2026-08-09 truncation."),
    killers = c("tests/test_recovery_resume_equivalence.R")
  ),

  # ---- geography -----------------------------------------------------------
  list(
    id = "coordinate-lon-lat-swap",
    file = "R/lib/coordinate_plausibility.R",
    find = "classify_coordinate <- function(lon, lat) {",
    repl = "classify_coordinate <- function(lat, lon) {",
    why = paste("Swaps the coordinate order. Every CONUS point reclassifies as",
                "implausible, and this is the single most common spatial bug",
                "there is."),
    killers = c("tests/test_cycle23_geocode_precision.R",
                "tests/test_cycle11_spatial.R")
  ),

  # ---- truth-set infrastructure (T1-T12, spec of 2026-09-08) ---------------
  # The adjudication instrument becomes a benchmark only if these guards are
  # real. Each mutant hollows one; the killer file's matching negative
  # control must then fail.
  list(
    id = "truth-T1-population-row-drop-unnoticed",
    file = "R/truth_set_checks.R",
    find = "  if (nrow(instrument) != manifest$rows_instrument) {",
    repl = "  if (FALSE) {",
    why = paste("A silently shrunken adjudication population scores as if",
                "complete; front truncation of truth is not random."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T1b-population-hash-ignored",
    file = "R/truth_set_checks.R",
    find = "  if (!identical(got, manifest$population_hash)) {",
    repl = "  if (FALSE) {",
    why = paste("Only the hash catches a same-size id swap; without it a",
                "substituted person scores as the frozen population."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T2-duplicate-adjid-admitted",
    file = "R/truth_set_checks.R",
    find = "  if (anyDuplicated(instrument$adjudication_id)) {",
    repl = "  if (FALSE) {",
    why = paste("Duplicate immutable ids double-count one person's verdict",
                "and break every downstream join on adj_id."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T3-provenance-roundtrip-vacuous",
    file = "R/truth_set_checks.R",
    find = "                                                    class5 = 156L)) {",
    repl = "                                                    class5 = 156L)) {\n  return(invisible(TRUE))",
    why = paste("The 456-row reconstruction guarantee silently becomes a",
                "no-op; lost review rows are unrecoverable and unnoticed."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T4-banned-column-reaches-reviewer",
    file = "R/truth_set_checks.R",
    find = "  leaked <- intersect(BANNED_REVIEWER_COLUMNS, names(export))",
    repl = "  leaked <- character(0); intersect(BANNED_REVIEWER_COLUMNS, names(export))",
    why = paste("Matcher confidence lands on the reviewer sheet; the human",
                "grades the matcher's homework with the answer key open."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T5-T12-custody-mismatch-ignored",
    file = "R/truth_set_checks.R",
    find = "    if (!identical(got, manifest$files[[nm]]$sha256)) {",
    repl = "    if (FALSE) {",
    why = paste("A tampered or stale artifact scores as frozen truth; the",
                "scorer must verify custody before reading anything."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T6-partial-unblinding-allowed",
    file = "R/truth_set_checks.R",
    find = "  nonterminal <- which(!instrument$workflow_state %in% TERMINAL_STATES)",
    repl = "  nonterminal <- integer(0)",
    why = paste("Half-adjudicated truth unblinds; the matcher internals",
                "contaminate the remaining reviews."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T7-unresolved-disagreement-passes",
    file = "R/truth_set_checks.R",
    find = "    unresolved <- setdiff(disputed, resolution$adjudication_id)",
    repl = "    unresolved <- character(0)",
    why = paste("Split reviewer verdicts reach the scorer with no",
                "resolution; whichever opinion sorts first becomes truth."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T8-orphan-evidence-ignored",
    file = "R/truth_set_checks.R",
    find = "  unlinked <- setdiff(evidence$evidence_id, links$evidence_id)",
    repl = "  unlinked <- character(0)",
    why = paste("Evidence supporting no judgment accumulates unaudited;",
                "provenance rot starts as orphans."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T9-board-canary-defanged",
    file = "R/truth_set_checks.R",
    find = "  \"\\\\bboards?\\\\b\", \"medical board\", \"nursing board\", \"state board\",",
    repl = "  \"ZZZNEVERMATCHZZZ\", \"medical board\", \"nursing board\", \"state board\",",
    why = paste("The generic board pattern is gone; 'board profile p3' in a",
                "locator sails through and board knowledge contaminates",
                "truth."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T10-final-verdict-overwrites-reviews",
    file = "R/truth_set_checks.R",
    find = "  if (\"final_verdict\" %in% c(names(reviews), names(instrument))) {",
    repl = "  if (FALSE) {",
    why = paste("Reviewer opinions are overwritten in place instead of",
                "resolved; the disagreement history is destroyed."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),
  list(
    id = "truth-T11-eligibility-by-url-string",
    file = "R/truth_set_checks.R",
    find = "  ineligible <- which(!eligibility$eligible[i])",
    repl = "  ineligible <- which(grepl(\"board\", evidence$source_url, ignore.case = TRUE))",
    why = paste("Eligibility inferred from URL text: a board source with a",
                "clean-looking URL is admitted, and an eligible source with",
                "'boardwalk' in its URL is refused."),
    killers = c("tests/test_truth_set_infrastructure.R")
  ),

  # ---- address flow map (R/lib/address_flow_helpers.R) ---------------------
  list(
    id = "flowhelper-classify-distance-check-removed",
    file = "R/lib/address_flow_helpers.R",
    find = paste0('    dist_km < same_place_km ~ "Same city",\n',
                  '    nppes_state != comparison_state ~ "Different state",'),
    repl = '    nppes_state != comparison_state ~ "Different state",',
    why = paste("Reintroduces the exact bug this map's own first draft had:",
                "without the distance override, a city-name SPELLING variant",
                "(SAINT PAUL vs ST PAUL) that geocodes to the identical",
                "building is classified as a real geographic mismatch."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-classify-operator-flipped",
    file = "R/lib/address_flow_helpers.R",
    find = '    dist_km < same_place_km ~ "Same city",',
    repl = '    dist_km > same_place_km ~ "Same city",',
    why = paste("Inverts the distance test. Points far apart now classify as",
                "Same city, and points essentially on top of each other fall",
                "through to the string-equality branches -- exactly",
                "backwards."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-classify-priority-inverted",
    file = "R/lib/address_flow_helpers.R",
    find = paste0('    nppes_state != comparison_state ~ "Different state",\n',
                  '    nppes_city != comparison_city ~ "Different city, same state",'),
    repl = paste0('    nppes_city != comparison_city ~ "Different city, same state",\n',
                  '    nppes_state != comparison_state ~ "Different state",'),
    why = paste("Lets a city-string mismatch win before a state mismatch is",
                "checked, so a pair in two different states (which also, as",
                "nearly all cross-state pairs do, have different city names)",
                "is mislabeled 'Different city, same state' -- the state",
                "disagreement, the more serious one, disappears from the",
                "map's legend entirely."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-aggregate-disclosure-filter-removed",
    file = "R/lib/address_flow_helpers.R",
    find = "  list(all = flow_pairs, displayed = dplyr::filter(flow_pairs, .data$n_midwives >= min_flow_n))",
    repl = "  list(all = flow_pairs, displayed = flow_pairs)",
    why = paste("Removes the min_flow_n disclosure control. Every city-to-city",
                "flow gets drawn, including ones shared by a single midwife --",
                "naming that one person's two addresses on a public map."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-aggregate-median-to-mean",
    file = "R/lib/address_flow_helpers.R",
    find = "                     origin_lon = stats::median(.data$nppes_lon), origin_lat = stats::median(.data$nppes_lat),",
    repl = "                     origin_lon = base::mean(.data$nppes_lon), origin_lat = base::mean(.data$nppes_lat),",
    why = paste("Swaps the robust center (median) for the mean. One wrongly",
                "geocoded address inside an otherwise-tight cluster drags that",
                "flow's displayed origin toward the bad point instead of being",
                "outvoted by the rest of the cluster."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-duplicate-guard-removed",
    file = "R/lib/address_flow_helpers.R",
    find = '  if (nrow(dupes) > 0) stop("Duplicate NPI/year/source records -- resolve before mapping.")',
    repl = '  if (FALSE) stop("Duplicate NPI/year/source records -- resolve before mapping.")',
    why = paste("A midwife with two rows for the same NPI/year/source no",
                "longer stops the pipeline. She silently either double-counts",
                "across whichever flows her two rows disagree on, or loses",
                "one row to whatever later code happens to collapse on."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-required-columns-no-op",
    file = "R/lib/address_flow_helpers.R",
    find = '  if (length(missing_cols) > 0) stop("Missing columns: ", paste(missing_cols, collapse = ", "))',
    repl = '  if (FALSE) stop("Missing columns: ", paste(missing_cols, collapse = ", "))',
    why = paste("An address_pairs table missing a required column (a renamed",
                "field, a failed join) no longer fails loudly at the start --",
                "it fails confusingly wherever the missing column is first",
                "used, several calls downstream."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-coordinate-bounds-removed",
    file = "R/lib/address_flow_helpers.R",
    find = paste0('    dplyr::between(.data$nppes_lon, -180, 180), dplyr::between(.data$comparison_lon, -180, 180),\n',
                  '    dplyr::between(.data$nppes_lat, -90, 90), dplyr::between(.data$comparison_lat, -90, 90))'),
    repl = "    TRUE, TRUE, TRUE, TRUE)",
    why = paste("A corrupted coordinate (a parsing artifact, a swapped",
                "census-tract ID mistaken for a longitude) is no longer",
                "filtered out before it reaches the map."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-census-match-filter-removed",
    file = "R/lib/address_flow_helpers.R",
    find = '  d <- dplyr::filter(d, .data$match_status == "Match")',
    repl = "  d <- d",
    why = paste("Keeps No_Match and Tie rows from the Census batch geocoder.",
                "Those carry no usable coordinate, so a midwife from one of",
                "them joins the flow map with a phantom or NA location",
                "instead of being correctly excluded."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),
  list(
    id = "flowhelper-census-lonlat-swapped",
    file = "R/lib/address_flow_helpers.R",
    find = '  d <- tidyr::separate(d, .data$coords, into = c("lon", "lat"), sep = ",", convert = TRUE)',
    repl = '  d <- tidyr::separate(d, .data$coords, into = c("lat", "lon"), sep = ",", convert = TRUE)',
    why = paste("The Census API returns coordinates as \"lon,lat\", in that",
                "order. Swapping the destructuring order silently flips every",
                "parsed coordinate's lon and lat -- the single most common",
                "spatial bug there is, and the same defect class",
                "coordinate-lon-lat-swap already guards against in a",
                "different file."),
    killers = c("tests/test_address_flow_helpers_saboteur.R")
  ),

  # ---- fuzzy-surname-matching removal (2026-10-22) -------------------------
  # SCOPE NOTE: match_amcb_to_npi.R is one of the "numbered pipeline scripts"
  # this catalogue otherwise avoids mutating (see the file header) because
  # they need person-level inputs absent on a runner. This one entry is safe
  # anyway: its killer is tests/test_fuzzy_surname_removal_saboteur.R's T7a,
  # a pure text-inspection check on the script's OWN SOURCE that needs no
  # data at all -- it would fail identically on a runner or a laptop.
  list(
    id = "fuzzy-match-class4-reintroduced",
    file = "match_amcb_to_npi.R",
    find = "      component_last == 1L                                   ~ 5L),",
    repl = paste0("      component_last == 1L                                   ~ 5L,\n",
                  "      TRUE                                                   ~ 4L),"),
    why = paste("Re-adds the catch-all that used to assign evidence class 4 to",
                "any surname within Levenshtein distance 2 -- the exact rule",
                "this freeze removed by decision because an edit-distance",
                "surname match is too easy to satisfy for a reason unrelated",
                "to shared identity. A silent revert would be invisible in",
                "any run that doesn't specifically check for it."),
    killers = c("tests/test_fuzzy_surname_removal_saboteur.R")
  ),

  # ---- R/lib/address_agreement_compare.R (2026-10-23) -----------------------
  # Extracted from five near-identical copies inside compare_*_address.R
  # (PECOS/DAC-vs-NPPES, Healthgrades-vs-NPPES, Healthgrades-vs-PECOS,
  # PECOS-vs-Doximity, PECOS-vs-BON). Those five scripts themselves stay out
  # of this catalogue (person-level, gitignored inputs; see the file header),
  # but the shared shape_address()/compare_address_pair() helpers need no
  # data at all.

  list(
    id = "aac-zip-trim-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "zip_col_trimmed <- str_trim(df[[zip_col]])",
    repl = "zip_col_trimmed <- df[[zip_col]]",
    why = paste("A leading/trailing space on a zip column (none currently has",
                "one, but state/city both get str_squish() -- zip didn't until",
                "this line) would shift a substr(1,5) extraction by one",
                "character, truncating a real digit."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-zipmode-branches-swapped",
    file = "R/lib/address_agreement_compare.R",
    find = paste0("    zip5 <- if (zip_mode == \"substr\") {\n",
                  "      str_sub(zip_col_trimmed, 1, 5)\n",
                  "    } else {\n",
                  "      str_extract(zip_col_trimmed, \"[0-9]{5}$\")\n",
                  "    }"),
    repl = paste0("    zip5 <- if (zip_mode == \"substr\") {\n",
                  "      str_extract(zip_col_trimmed, \"[0-9]{5}$\")\n",
                  "    } else {\n",
                  "      str_sub(zip_col_trimmed, 1, 5)\n",
                  "    }"),
    why = paste("Swaps which extraction method each zip_mode uses. Every",
                "caller except compare_pecos_to_doximity_address.R relies on",
                "the default \"substr\" mode for a standalone zip column; this",
                "would silently apply the wrong extraction to all of them."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-zip5-substr-truncated",
    file = "R/lib/address_agreement_compare.R",
    find = "str_sub(zip_col_trimmed, 1, 5)",
    repl = "str_sub(zip_col_trimmed, 1, 4)",
    why = paste("Truncates zip5 to 4 digits for every \"substr\"-mode source",
                "(all but Doximity). Two genuinely different ZIPs sharing a",
                "first-4-digit prefix (80238 vs 80231) would wrongly agree."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-trailing5-regex-truncated",
    file = "R/lib/address_agreement_compare.R",
    find = "str_extract(zip_col_trimmed, \"[0-9]{5}$\")",
    repl = "str_extract(zip_col_trimmed, \"[0-9]{4}$\")",
    why = paste("Same truncation as aac-zip5-substr-truncated, for Doximity's",
                "\"trailing5\" mode specifically -- the only caller that uses it."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-state-upper-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "state <- if (is.null(state_col)) rep(NA_character_, nrow(df)) else str_to_upper(str_squish(df[[state_col]]))",
    repl = "state <- if (is.null(state_col)) rep(NA_character_, nrow(df)) else str_squish(df[[state_col]])",
    why = paste("Drops case-folding on state. \"CO\" from one source and \"co\"",
                "from another would wrongly disagree at the coarsest grain",
                "this comparison reports."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-city-squish-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "city = str_to_upper(str_squish(df[[city_col]])),",
    repl = "city = str_to_upper(df[[city_col]]),",
    why = paste("Drops whitespace-squishing on city. \"DENVER \" (trailing",
                "space) from one source and \"DENVER\" from another would",
                "wrongly disagree."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-npi-col-ignored",
    file = "R/lib/address_agreement_compare.R",
    find = "npi = df[[npi_col]],",
    repl = "npi = df[[\"npi\"]],",
    why = paste("Ignores the npi_col parameter and hardcodes \"npi\" instead.",
                "Breaks every caller that reads a differently-named NPI column",
                "(Healthgrades passes \"hg_npi\") with a column-not-found error",
                "instead of using the one the caller actually asked for."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-match-arg-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "zip_mode <- match.arg(zip_mode)",
    repl = "invisible(NULL)  # match.arg removed",
    why = paste("Without match.arg(), a caller that omits zip_mode (every",
                "caller except the Doximity script) gets the raw two-element",
                "default c(\"substr\",\"trailing5\") instead of \"substr\" alone --",
                "the zip_mode==\"substr\" check downstream no longer resolves",
                "to a single TRUE/FALSE the way a scalar argument would."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-zip-mode-default-swapped",
    file = "R/lib/address_agreement_compare.R",
    find = "zip_mode = c(\"substr\", \"trailing5\")",
    repl = "zip_mode = c(\"trailing5\", \"substr\")",
    why = paste("match.arg() resolves an unspecified argument to the FIRST",
                "listed value. Swapping the order flips every caller that",
                "doesn't pass zip_mode explicitly (all but Doximity) from",
                "substr to trailing5 extraction."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-agree-equality-flipped",
    file = "R/lib/address_agreement_compare.R",
    find = "agree <- sum(nzchar(x) & nzchar(y) & x == y, na.rm = TRUE)",
    repl = "agree <- sum(nzchar(x) & nzchar(y) & x != y, na.rm = TRUE)",
    why = paste("Inverts the agreement check. Every comparison's agree_pct",
                "would report roughly its own disagreement rate instead --",
                "wrong in the single most consequential way this function",
                "could be wrong."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-comparable-drops-y-check",
    file = "R/lib/address_agreement_compare.R",
    find = "comparable <- sum(nzchar(x) & nzchar(y), na.rm = TRUE)",
    repl = "comparable <- sum(nzchar(x), na.rm = TRUE)",
    why = paste("Stops checking whether the SECOND side has a value at all.",
                "A row where only side A has data would wrongly count toward",
                "comparable_n, inflating the denominator and understating",
                "agree_pct."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-comparable-drops-x-check",
    file = "R/lib/address_agreement_compare.R",
    find = "comparable <- sum(nzchar(x) & nzchar(y), na.rm = TRUE)",
    repl = "comparable <- sum(nzchar(y), na.rm = TRUE)",
    why = paste("Same defect as aac-comparable-drops-y-check, mirrored: stops",
                "checking whether the FIRST side has a value."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-agree-ignores-blanks",
    file = "R/lib/address_agreement_compare.R",
    find = "agree <- sum(nzchar(x) & nzchar(y) & x == y, na.rm = TRUE)",
    repl = "agree <- sum(x == y, na.rm = TRUE)",
    why = paste("Drops the blank-value guard from the numerator only (the",
                "denominator still has it). Two blank (\"\") values on both",
                "sides -- which should be excluded entirely as non-comparable",
                "-- would instead count as an agreement, since \"\" == \"\" is",
                "TRUE."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-denominator-wrong-base",
    file = "R/lib/address_agreement_compare.R",
    find = "round(100 * agree / comparable, 1)",
    repl = "round(100 * agree / nrow(joined), 1)",
    why = paste("Divides by the total joined row count instead of the",
                "comparable count. Whenever any row has a blank value on",
                "either side (comparable < nrow(joined)), agree_pct is",
                "silently understated."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-na-guard-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "if (comparable > 0) round(100 * agree / comparable, 1) else NA_real_",
    repl = "round(100 * agree / comparable, 1)",
    why = paste("Without the guard, a comparison with zero comparable records",
                "(e.g. Delaware's BON pull before any DE midwife enters the",
                "cohort) divides 0/0 and reports NaN instead of a clean NA --",
                "a different value that downstream code and plots may not",
                "handle the same way."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-rounding-digits-dropped",
    file = "R/lib/address_agreement_compare.R",
    find = "round(100 * agree / comparable, 1)",
    repl = "round(100 * agree / comparable)",
    why = paste("Drops to zero decimal places. Every agree_pct this project",
                "has published (47.1%, 6.6%, etc.) is reported to one decimal",
                "-- this would silently coarsen all of them."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-na-coercion-x-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "x[is.na(x)] <- \"\"; y[is.na(y)] <- \"\"",
    repl = "y[is.na(y)] <- \"\"",
    why = paste("Re-exposes nzchar(NA)==TRUE on side A only (see this line's",
                "own comment). A genuinely missing value on side A paired",
                "with a real value on side B would wrongly count toward",
                "comparable_n."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-na-coercion-y-removed",
    file = "R/lib/address_agreement_compare.R",
    find = "x[is.na(x)] <- \"\"; y[is.na(y)] <- \"\"",
    repl = "x[is.na(x)] <- \"\"",
    why = paste("Mirror of aac-na-coercion-x-removed: re-exposes",
                "nzchar(NA)==TRUE on side B only."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-levels-default-missing-zip5",
    file = "R/lib/address_agreement_compare.R",
    find = "levels = c(\"state\", \"city\", \"zip5\")",
    repl = "levels = c(\"state\", \"city\")",
    why = paste("Every compare_*_address.R script calls compare_address_pair()",
                "without passing levels explicitly -- all five rely on this default.",
                "Dropping zip5 from it would silently stop reporting the one",
                "grain this project treats as its primary metric, in every",
                "comparison, at once."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-zip-col-null-mishandled",
    file = "R/lib/address_agreement_compare.R",
    find = "zip5 <- rep(NA_character_, nrow(df))",
    repl = "zip5 <- rep(\"\", nrow(df))",
    why = paste("A source with no zip field at all (California's BRN roster:",
                "license number, status, city, county -- no zip) should",
                "produce zip5 = NA, not empty string. Both currently get",
                "excluded from comparable_n the same way, but NA is the",
                "honest signal for \"this source never had a zip field,\"",
                "while \"\" would be indistinguishable from a source that HAD",
                "a zip column with a blank value in it."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-state-col-null-mishandled",
    file = "R/lib/address_agreement_compare.R",
    find = "state <- if (is.null(state_col)) rep(NA_character_, nrow(df)) else str_to_upper(str_squish(df[[state_col]]))",
    repl = "state <- if (is.null(state_col)) rep(\"\", nrow(df)) else str_to_upper(str_squish(df[[state_col]]))",
    why = paste("Same defect as aac-zip-col-null-mishandled for state instead",
                "of zip: a source with no independent state field (California's",
                "BRN roster) should produce state = NA, not empty string -- NA",
                "is the honest signal for \"this source never had a state",
                "field,\" distinct from a source that had one and left it blank."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  list(
    id = "aac-join-key-overspecified",
    file = "R/lib/address_agreement_compare.R",
    find = "by = \"npi\"",
    repl = "by = c(\"npi\", \"state\", \"city\", \"zip5\")",
    why = paste("Joins on every shared column name, not just npi -- dplyr",
                "silently accepts this since both sides share those column",
                "names. A row only survives the join if state/city/zip5",
                "ALREADY match going in, so every disagreement this function",
                "exists to measure would vanish from the joined table before",
                "comparison even runs, instead of being counted as a",
                "disagreement."),
    killers = c("tests/test_address_agreement_compare_saboteur.R")
  ),

  # ---- source-series reconstruction ----------------------------------------
  # THESE MUTATE PIPELINE SCRIPTS, which the scope note at the top of this file
  # says not to do. The reason that note gives is that pipeline scripts need
  # person-level inputs a runner does not have, so a mutation would "survive"
  # for want of data rather than for want of a test -- a false hole.
  #
  # That does not apply here. tests/test_source_series_reconstruction.R parses
  # these scripts, lifts out the single function under test, and runs it
  # against synthetic in-memory fixtures. No freeze, no warehouse, no external
  # volume. The mutations below are therefore genuinely killable on a bare
  # runner, and if one survives it is a real hole.
  #
  # What they defend is narrow and worth stating: that a year's value was
  # measured in that year, by a rule that gives the same answer twice. Every
  # temporal statistic this project publishes rests on it.

  list(
    id = "partd-tiebreak-reversed",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "ORDER BY n DESC, state ASC",
    repl = "ORDER BY n DESC, state DESC",
    why = paste("Reverses the tie-break for a midwife billing equally from",
                "two states in one year. The rule still runs and still",
                "returns one state per NPI-year, so nothing errors and the",
                "row counts are unchanged -- the series just quietly names a",
                "different state for every tied midwife, and the artifact's",
                "hash changes without any input changing. Alphabetical order",
                "is not cosmetic here; it is what makes a rerun",
                "byte-identical under the provenance ratchet."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "partd-modal-inverted",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "ORDER BY n DESC, state ASC",
    repl = "ORDER BY n ASC, state ASC",
    why = paste("Takes the LEAST common state for the year instead of the",
                "most common. On a by-service file where a midwife has 40",
                "rows in Colorado and 1 in Wyoming, the series records",
                "Wyoming. Agreement with every other source collapses in a",
                "way that reads as a finding about data quality rather than",
                "as an inverted comparator."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "partd-multiplicity-hidden",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "COUNT(DISTINCT t2.state)",
    repl = "1",
    why = paste("Hard-codes n_states_this_year to 1, so every midwife looks",
                "singly-located. Multiplicity stops being a column a reader",
                "can filter on and becomes invisible -- and multi-state",
                "practice is precisely what the cross-source disagreement",
                "analysis is trying to separate from error."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "partd-foreign-state-kept",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "out <- out[!is.na(out$state), , drop = FALSE]",
    repl = "out <- out",
    why = paste("Keeps rows clean_state() rejected, so a foreign practice",
                "location enters the series as a missing US state rather",
                "than being dropped. The real case is NPI 1013060656,",
                "prescribing from Dar Es Salaam under code ZZ in 2015 and",
                "2016. An NA state then propagates into agreement",
                "denominators as if it were an observation."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "partd-duplicates-not-collapsed",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "QUALIFY ROW_NUMBER() OVER (PARTITION BY npi ORDER BY n DESC, state ASC) = 1",
    repl = "QUALIFY ROW_NUMBER() OVER (PARTITION BY npi ORDER BY n DESC, state ASC) >= 1",
    why = paste("Emits one row per state per midwife-year instead of one row",
                "per midwife-year. Every downstream count of 'NPI-years'",
                "inflates by the multi-state rate, transitions multiply, and",
                "the independence audit reports more evidence than exists --",
                "the exact overstatement this work was done to prevent."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "partd-year-off-by-one",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "out$year <- as.integer(year)",
    repl = "out$year <- as.integer(year) + 1L",
    why = paste("Shifts every observation one year later. Nothing errors and",
                "every row count is identical; the whole series is simply",
                "misdated. Lead/lag against NPPES would then report Part D",
                "as systematically lagging by a year, which is a publishable",
                "sentence and completely false."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "independence-nonadjacent-counted",
    file = "audit_source_series_independence.R",
    find = "filter(!is.na(nxt), nxt == year + 1L)",
    repl = "filter(!is.na(nxt))",
    why = paste("Counts any consecutive pair of OBSERVATIONS as a year-to-year",
                "transition, so a midwife seen in 2015 and again in 2019",
                "contributes one transition across a four-year gap. Since",
                "27.1% of Part D midwives have interior gaps, this inflates",
                "the transition count materially -- and the artifact exists",
                "specifically to stop transition counts being read as more",
                "evidence than they are."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-refutation-disabled",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = "if (packed < claimed) {",
    repl = "if (FALSE) {",
    why = paste("Disables the one check that can falsify a claimed vintage.",
                "PPEF has no in-file date, so the archive's stored mtime is",
                "the only evidence, and its single usable property is that a",
                "file cannot be packaged before the period it describes.",
                "Without it a mislabelled archive is accepted and its",
                "observations are dated by its filename alone -- which is",
                "the failure docs/temporal-evidence-validation.md exists to",
                "rule out."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  # ---- source-series reconstruction, second set ---------------------------
  # The first set attacks the arithmetic. These attack the plumbing around
  # it: ordering, grouping, which column is read, and which check is allowed
  # to refuse a file. Each one leaves a series that is the right shape and
  # the right size, and wrong.

  list(
    id = "independence-no-grouping",
    file = "audit_source_series_independence.R",
    find = "arrange(npi, year) %>% group_by(npi) %>%",
    repl = "arrange(npi, year) %>%",
    why = paste("Drops the grouping, so lead() runs off the end of one",
                "midwife's rows into the next midwife's. Wherever one",
                "person's last observed year is one less than the next",
                "person's first, a transition is invented BETWEEN TWO",
                "DIFFERENT PEOPLE. In a cohort sorted by NPI that happens",
                "constantly, and it inflates exactly the count this",
                "artifact exists to keep honest."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "independence-unsorted",
    file = "audit_source_series_independence.R",
    find = "arrange(npi, year) %>% group_by(npi) %>%",
    repl = "group_by(npi) %>%",
    why = paste("Takes lead() in whatever order the rows arrived from disk.",
                "A file written in a different order silently yields a",
                "different transition count from identical data, so the",
                "audit stops being reproducible while still looking",
                "plausible. Nothing errors; the number just moves."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-state-column-preference-flipped",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = 'if ("state_cdstr" %in% hdr) "state_cdstr" else "state_cd"',
    repl = 'if ("state_cdstr" %in% hdr) "state_cd" else "state_cdstr"',
    why = paste("Reads the numeric FIPS column from the monthly NBER files",
                "instead of the two-letter one -- state 6 rather than CA.",
                "THIS BUG WAS ACTUALLY WRITTEN, on 2026-11-10, and survived",
                "only because clean_state() refuses anything that is not a",
                "US state. A looser cleaner would have produced ten years",
                "of integer 'states' agreeing with nothing, which reads as",
                "a finding about PECOS rather than a column mix-up."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-tiebreak-reversed",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = "ORDER BY state ASC",
    repl = "ORDER BY state DESC",
    why = paste("About a tenth of enrolled midwives hold simultaneous",
                "enrolments in several states -- concurrent registrations,",
                "not moves. Reversing which one is picked changes the state",
                "for roughly 1 in 10 rows in every vintage, so the",
                "vintage-to-vintage 'move' rate changes with no underlying",
                "data change at all."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-sameyear-check-removed",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = 'if (format(packed, "%Y") != format(claimed, "%Y")) {',
    repl = "if (FALSE) {",
    why = paste("Keeps the can't-be-packaged-earlier check but drops the",
                "same-year one, so a monthly archive packaged years after",
                "the month it claims is accepted. The weaker of the two",
                "tests still passes, which is what makes this survivable to",
                "the eye: validation appears to be happening."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-quarterly-exemption-widened",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = 'if (identical(layout, "cms_quarterly")) {',
    repl = "if (TRUE) {",
    why = paste("Extends the quarterly exemption to every layout. That",
                "exemption is justified ONLY because the quarterly members",
                "carry a CMS extract date in the filename; the monthly ones",
                "have nothing but the archive mtime. Widened, every monthly",
                "vintage is reported verified_date on evidence it does not",
                "have -- a validation that always says yes."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "partd-npi-not-trimmed",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "JOIN cohort_npi c ON trim(CAST(t.%s AS VARCHAR)) = c.npi",
    repl = "JOIN cohort_npi c ON CAST(t.%s AS VARCHAR) = c.npi",
    why = paste("Stops trimming the source NPI before the cohort join.",
                "Warehouse NPIs are clean, so every warehouse year still",
                "passes and only the downloaded CSVs lose rows -- a",
                "source-specific and year-specific undercount that looks",
                "like genuinely lower Part D participation in exactly the",
                "years that were added on 2026-11-09."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  # ---- source-series reconstruction, third set ----------------------------
  # Upstream of the arithmetic and the plumbing: which FILE gets downloaded,
  # whether a missing table is noticed, how a vintage is labelled, and
  # whether a duplicate row is counted twice. Nothing here touches a
  # statistic directly; each one changes what the statistic is computed on.

  list(
    id = "download-product-regex-loosened",
    file = "download_cms_by_provider_files.R",
    find = 'part_d = "^Medicare Part D Prescribers - by Provider : (\\\\d{4})-",',
    repl = 'part_d = "^Medicare Part D Prescribers - by Provider.* : (\\\\d{4})-",',
    why = paste("CMS publishes two Part D products whose titles differ by",
                "three words: '- by Provider :' is one row per prescriber,",
                "'- by Provider and Drug :' is one row per prescriber-drug,",
                "roughly forty times the rows. Both are in the catalogue for",
                "every year. Loosened, the resolver matches both and may",
                "download the drug-level file, which still parses, still has",
                "NPIs and still has Prscrbr_State_Abrvtn -- so the modal",
                "reduction silently reweights each midwife's state by how",
                "many distinct drugs she prescribed there."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "download-year-from-whole-match",
    file = "download_cms_by_provider_files.R",
    find = "year = as.integer(m[2])",
    repl = "year = as.integer(m[1])",
    why = paste("Takes the whole regex match instead of the captured year,",
                "so as.integer() gets a title and returns NA with a warning",
                "no one reads. Every file then lands under a year of NA and",
                "the manifest ties a 600 MB download to nothing."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "has-table-always-true",
    file = "extract_medicare_part_b_d_cohort_states.R",
    find = "dbQuoteString(con, tb)))) > 0L",
    repl = "dbQuoteString(con, tb)))) >= 0L",
    why = paste("has_table() becomes a function that always says yes, so a",
                "year whose warehouse table is absent is queried anyway. The",
                "query errors or returns nothing depending on the backend,",
                "and the 'absent, skipped' log line that is supposed to make",
                "a missing year visible never prints. A gap in the series",
                "then looks like a year in which no midwife billed."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-vintage-month-not-padded",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = 'vintage = sprintf("%04d-%02d", yr, mo),',
    repl = 'vintage = sprintf("%04d-%d", yr, mo),',
    why = paste("Drops the zero pad, so August 2016 is labelled 2016-8 and",
                "sorts AFTER 2016-10. NBER's own filenames are unpadded",
                "(ppefenrol20168), which already cost a round of 404s, and",
                "this reintroduces the same hazard one layer later: every",
                "join on vintage misses, and min()/max() report the wrong",
                "range for the series."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "ppef-vintage-year-offset",
    file = "extract_ppef_cohort_state_by_vintage.R",
    find = "yr <- as.integer(substr(ym, 1, 4))",
    repl = "yr <- as.integer(substr(ym, 2, 5))",
    why = paste("An off-by-one in the substring that reads the year out of",
                "an unpadded filename. ppefenrol20168 yields year 168",
                "instead of 2016. Plausible precisely because the filename",
                "has no separator between year and month, which is what",
                "makes positional parsing necessary in the first place."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "independence-duplicates-kept",
    file = "audit_source_series_independence.R",
    find = "filter(!is.na(npi), nzchar(npi), !is.na(year)) %>% distinct()",
    repl = "filter(!is.na(npi), nzchar(npi), !is.na(year))",
    why = paste("Stops deduplicating, so a midwife listed twice in one year",
                "-- two enrolments, two billing rows -- counts as two",
                "observations. Every figure in the independence artifact is",
                "a count, so npi_years, adjacent transitions and the",
                "interior-gap denominator all inflate together, and they",
                "inflate consistently enough to look like real coverage."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  # ---- Medicaid date-range expansion (spec A2) ----------------------------

  list(
    id = "medicaid-open-segments-dropped",
    file = "extract_medicaid_enrollment_state_by_year.R",
    find = "coalesce(seg.d1, DATE '9999-12-31') >= make_date(g.y, 1, 1)",
    repl = "seg.d1 >= make_date(g.y, 1, 1)",
    why = paste("Drops the coalesce, so every OPEN enrolment -- NULL end",
                "date, 18,849,576 rows nationally -- fails the overlap test",
                "and vanishes. Open segments are the currently enrolled",
                "providers, so the series would lose its most recent years",
                "first and look like a collapse in Medicaid participation."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "medicaid-overlap-requires-full-year",
    file = "extract_medicaid_enrollment_state_by_year.R",
    find = "coalesce(seg.d1, DATE '9999-12-31') >= make_date(g.y, 1, 1)",
    repl = "coalesce(seg.d1, DATE '9999-12-31') >= make_date(g.y, 12, 31)",
    why = paste("Requires a segment to survive to 31 December before the",
                "year counts, so any enrolment ending mid-year is erased.",
                "The year a midwife left a state is exactly the year her",
                "move happened, so this deletes the transitions the whole",
                "comparison is built to observe."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "medicaid-start-bound-to-jan",
    file = "extract_medicaid_enrollment_state_by_year.R",
    find = "seg.d0 <= make_date(g.y, 12, 31)",
    repl = "seg.d0 <= make_date(g.y, 1, 1)",
    why = paste("Requires an enrolment to have begun before 1 January for",
                "the year to count, so a midwife who enrolled in February is",
                "absent from her first year. Mirror image of the previous",
                "mutation: that one deletes exits, this one deletes entries,",
                "and both leave a series that still looks complete."),
    killers = c("tests/test_source_series_reconstruction.R")
  ),

  list(
    id = "medicaid-footprint-collapsed",
    file = "extract_medicaid_enrollment_state_by_year.R",
    find = "    SELECT npi, year, state, COUNT(*) AS n_segments\n      FROM ex GROUP BY 1, 2, 3",
    repl = "    SELECT npi, year, state, COUNT(*) AS n_segments\n      FROM ex GROUP BY 1, 2, 3\n     QUALIFY ROW_NUMBER() OVER (PARTITION BY year, npi ORDER BY state ASC) = 1",
    why = paste("Reintroduces the original defect in the footprint itself:",
                "one state per NPI-year instead of the set. 33.2% of",
                "memberships disappear again and every comparison reverts to",
                "testing equality with one pick. Measured consequence:",
                "Medicaid's agreement with NPPES reads 74.7% instead of",
                "88.5%, which is what made it look like the worst source in",
                "the panel."),
    killers = c("tests/test_source_series_reconstruction.R")
  )
)
