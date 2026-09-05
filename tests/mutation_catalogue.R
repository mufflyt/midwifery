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
  )
)
