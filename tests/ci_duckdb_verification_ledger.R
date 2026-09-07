# =============================================================================
# The verification ledger must not silently imply more coverage than exists
# =============================================================================
# "5 of 6 high-risk workflows were never re-run against real production data"
# is an easy fact to lose track of once time passes -- especially since the
# generic contract/AST/integration-harness coverage genuinely IS green for
# all six, which reads as "done" if the one workflow that got a live rerun
# is not distinguished from the five that did not. This file makes that
# distinction machine-checkable: it fails CI if a NOT_RUN workflow is ever
# silently upgraded to a PASS-shaped status without an actual live run
# producing evidence for it, and it fails if the ledger's shape drifts (a
# workflow renamed or dropped without the ledger being updated to match).
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

ledger <- ci_read_head(file.path("tests", "fixtures", "duckdb_migration_verification_ledger.csv"),
                       root = root)
order_semantics <- ci_read_head(file.path("tests", "fixtures", "duckdb_artifact_order_semantics.csv"),
                                root = root)

ci_section("Verification ledger shape")
EXPECTED_WORKFLOWS <- c(
  "resolve_org_ambiguity.R",
  "build_pecos_organization_affiliations.R",
  "extract_nppes_midwives.R",
  "build_midwife_panel.R",
  "build_care_compare_organization_panel.R",
  "extract_dac_facility_affiliations.R"
)
if (is.null(ledger)) {
  ci_fail("could not read tests/fixtures/duckdb_migration_verification_ledger.csv")
} else if (!setequal(ledger$workflow, EXPECTED_WORKFLOWS)) {
  ci_fail("ledger workflow list does not match the six high-risk migrated workflows -- missing: %s; unexpected: %s",
          paste(setdiff(EXPECTED_WORKFLOWS, ledger$workflow), collapse = ", "),
          paste(setdiff(ledger$workflow, EXPECTED_WORKFLOWS), collapse = ", "))
} else {
  ci_ok("ledger names exactly the six high-risk migrated workflows, no more, no fewer")
}

ci_section("Live-verification status is honest, not aspirational")
VALID_LIVE_STATUS <- c("PASS", "FAIL", "NOT_RUN_INPUT_UNAVAILABLE")
REQUIRED_COLS <- c("workflow", "live_status", "reason", "required_inputs", "inputs_available",
                   "architecture_migration", "generic_contract_status", "live_equivalence_status",
                   "last_attempt", "evidence_artifact")
if (!is.null(ledger)) {
  missing_cols <- setdiff(REQUIRED_COLS, names(ledger))
  if (length(missing_cols)) {
    ci_fail("ledger is missing required column(s): %s", paste(missing_cols, collapse = ", "))
  } else {
    ci_ok("ledger has all required columns: %s", paste(REQUIRED_COLS, collapse = ", "))
  }

  bad_status <- ledger$live_status[!ledger$live_status %in% VALID_LIVE_STATUS]
  if (length(bad_status)) {
    ci_fail("live_status has non-declarative value(s): %s (only PASS, FAIL, NOT_RUN_INPUT_UNAVAILABLE are allowed -- DEFERRED, LIVE_VERIFIED, NOT_RUN etc. are not)",
            paste(unique(bad_status), collapse = ", "))
  } else {
    ci_ok("every live_status value is one of PASS, FAIL, NOT_RUN_INPUT_UNAVAILABLE")
  }

  live_row <- ledger[ledger$workflow == "resolve_org_ambiguity.R", ]
  if (nrow(live_row) == 1L && identical(live_row$live_status, "PASS")) {
    ci_ok("resolve_org_ambiguity.R is marked live_status=PASS -- the one workflow actually re-run against real production data this session")
  } else {
    ci_fail("resolve_org_ambiguity.R is not marked live_status=PASS in the ledger (got: %s)",
            if (nrow(live_row) == 1L) live_row$live_status else "<row missing>")
  }

  deferred_expected <- setdiff(EXPECTED_WORKFLOWS, "resolve_org_ambiguity.R")
  n_deferred_as_pass <- 0L
  for (wf in deferred_expected) {
    row <- ledger[ledger$workflow == wf, ]
    if (nrow(row) != 1L) {
      ci_fail("%s has no ledger row", wf)
      next
    }
    if (identical(row$live_status, "PASS")) {
      ci_fail("%s is marked live_status=PASS, but no live rerun was performed for it this session -- this is exactly the overclaim this ledger exists to prevent ('deferred workflows represented as PASS' must be 0). Mark it NOT_RUN_INPUT_UNAVAILABLE until an actual live rerun produces evidence.",
              wf)
      n_deferred_as_pass <- n_deferred_as_pass + 1L
    } else if (identical(row$live_status, "NOT_RUN_INPUT_UNAVAILABLE")) {
      if (!nzchar(row$reason)) {
        ci_fail("%s is marked NOT_RUN_INPUT_UNAVAILABLE but has no reason -- an unexplained NOT_RUN is as uninformative as a false PASS", wf)
      } else if (!row$inputs_available %in% c("YES", "NO")) {
        ci_fail("%s has an invalid inputs_available value: %s (expected YES or NO)", wf, row$inputs_available)
      } else {
        ci_ok("%s is honestly marked NOT_RUN_INPUT_UNAVAILABLE (inputs_available=%s) with a stated reason: %s",
              wf, row$inputs_available, row$reason)
      }
    } else {
      ci_fail("%s has an unrecognized live_status value: %s (expected NOT_RUN_INPUT_UNAVAILABLE for a deferred workflow)", wf, row$live_status)
    }
  }
  cat(sprintf("\ndeferred workflows represented as PASS: %d\n", n_deferred_as_pass))
}

ci_section("Order-semantics declarations exist before comparison, not after a test fails")
if (is.null(order_semantics)) {
  ci_fail("could not read tests/fixtures/duckdb_artifact_order_semantics.csv")
} else {
  bad_values <- order_semantics$order_semantics[!order_semantics$order_semantics %in% c("ordered", "unordered")]
  if (length(bad_values)) {
    ci_fail("order_semantics column has non-declarative values: %s (expected only 'ordered' or 'unordered')",
            paste(unique(bad_values), collapse = ", "))
  } else {
    ci_ok("every declared artifact has an explicit order_semantics of 'ordered' or 'unordered' (%d artifacts declared)",
          nrow(order_semantics))
  }
  org_ambig_artifacts <- order_semantics[order_semantics$workflow == "resolve_org_ambiguity.R", ]
  if (nrow(org_ambig_artifacts) < 4L) {
    ci_fail("resolve_org_ambiguity.R declares only %d artifacts in the order-semantics ledger; its live verification found 4 output files and all 4 must be classified", nrow(org_ambig_artifacts))
  } else {
    ci_ok("all 4 of resolve_org_ambiguity.R's output artifacts have declared order semantics")
  }
}

ci_finish()
