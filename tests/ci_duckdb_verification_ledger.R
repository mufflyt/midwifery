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
if (!is.null(ledger)) {
  live_row <- ledger[ledger$workflow == "resolve_org_ambiguity.R", ]
  if (nrow(live_row) == 1L && identical(live_row$live_equivalence, "LIVE_VERIFIED")) {
    ci_ok("resolve_org_ambiguity.R is marked LIVE_VERIFIED -- the one workflow actually re-run against real production data this session")
  } else {
    ci_fail("resolve_org_ambiguity.R is not marked LIVE_VERIFIED in the ledger (got: %s)",
            if (nrow(live_row) == 1L) live_row$live_equivalence else "<row missing>")
  }

  not_run_expected <- setdiff(EXPECTED_WORKFLOWS, "resolve_org_ambiguity.R")
  for (wf in not_run_expected) {
    row <- ledger[ledger$workflow == wf, ]
    if (nrow(row) != 1L) {
      ci_fail("%s has no ledger row", wf)
      next
    }
    if (identical(row$live_equivalence, "PASS") || identical(row$live_equivalence, "LIVE_VERIFIED")) {
      ci_fail("%s is marked %s, but no live rerun was performed for it this session -- this is exactly the overclaim this ledger exists to prevent. Mark it NOT_RUN until an actual live rerun produces evidence.",
              wf, row$live_equivalence)
    } else if (identical(row$live_equivalence, "NOT_RUN")) {
      if (!nzchar(row$reason_live_not_run)) {
        ci_fail("%s is marked NOT_RUN but has no reason_live_not_run -- an unexplained NOT_RUN is as uninformative as a false PASS", wf)
      } else {
        ci_ok("%s is honestly marked NOT_RUN with a stated reason: %s", wf, row$reason_live_not_run)
      }
    } else {
      ci_fail("%s has an unrecognized live_equivalence value: %s (expected NOT_RUN or LIVE_VERIFIED)", wf, row$live_equivalence)
    }
  }
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
