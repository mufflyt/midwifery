# Federal Database Accuracy Manuscript Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve F01-F12 with artifact-traceable statistics, machine-verifiable manuscript checks, a rendered timestamped Word draft, and an independent reviewer audit.

**Architecture:** Preserve the existing Quarto edits and make artifacts—not prose—the numerical authority. Add one focused R acceptance gate for manuscript-specific invariants, extend the existing uncertainty producer only where a missing estimand requires it, generate ledgers from verified artifacts, and render from `manuscript/federal_database_accuracy.qmd` only after all gates pass.

**Tech Stack:** Quarto, R/base R, dplyr/readr already used by the repository, CSV/Markdown, existing provenance helpers and manuscript test harness.

**Spec:** User-supplied “Implementation Specification: Federal Database Accuracy Manuscript Remediation,” version 1.0, November 23, 2026.

## Global Constraints

- Preserve the current uncommitted edits in `manuscript/federal_database_accuracy.qmd`; do not restart or overwrite them.
- Do not overwrite `/Users/tylermuffly/Downloads/federal_database_accuracy.docx`.
- Do not invent, interpolate, or silently replace numerical findings.
- Keep accuracy, agreement, completeness, and temporal consistency distinct.
- Treat NPPES as a common comparison source, never geographic truth.
- Keep failed or unavailable analyses visible in the findings ledger.
- Use US spelling and the controlled vocabulary in F11.
- Do not commit automatically: the worktree began with pre-existing uncommitted manuscript changes.

## Review Focus

- Same percentage with different observation units: tests must bind each protected value to numerator, denominator, unit, years, and source artifact.
- Repeated clinician-years: tests must prevent Wilson intervals from being labeled clinician-clustered and prevent clustered bounds on singleton clusters.
- Non-additive Medicaid universes: tests must verify each denominator independently without forcing an additive flow.
- Cohort flow drift: tests must recompute every displayed branch and fail on a one-person alteration.
- Abstract drift: tests must compare abstract quantities and terminology with the verified Results/table values.

---

### Task 1: Freeze the Current State and Build the Evidence Inventories

**Files:**
- Create: `review/denominator_ledger.csv`
- Create: `review/claim_evidence_matrix.csv`
- Create: `review/manuscript_findings_ledger.csv`
- Create: `review/manuscript_changes.md`

**Interfaces:**
- Consumes: current Git diff; `manuscript/R/build_stats_catalog.R`; `artifacts/*.csv` and provenance JSON; current QMD.
- Produces: one row per denominator/claim/finding with artifact path, field names, unit, years, inclusion rule, verification status, and notes.

- [ ] Record the pre-existing QMD diff in `review/manuscript_changes.md`, separating inherited edits from new remediation work.
- [ ] Populate the denominator ledger for the eight F01 headline quantities and all Medicaid counts (85,190; 107,386; 53,414; 27,175), using exact artifact columns and units.
- [ ] Add Table 2-4 and abstract quantities to the ledger, including numerator and denominator fields rather than percentages alone.
- [ ] Populate the claim matrix for every abstract conclusion and the principal Discussion claims.
- [ ] Initialize F01-F12 rows as `verified`, `partial`, `unresolved`, or `not_started`; never infer `verified` from a successful render.
- [ ] Check all arithmetic with an R one-liner or existing catalog value and record the command/result in the ledger notes.

### Task 2: Add Manuscript-Specific Adversarial Gates (RED)

**Files:**
- Create: `tests/test_federal_database_accuracy_remediation.R`
- Create: `tests/test_federal_database_accuracy_remediation_detect.R`
- Reuse: `tests/ci_report.R`, `tests/helper-saboteur.R`, `tests/lib_manuscript_numbers.R`

**Interfaces:**
- Consumes: QMD, rendered Markdown, ledgers, stats catalog, and named artifacts.
- Produces: a green gate for MAN-01-MAN-12 and a detector proving each guard fails under deliberate mutation.

- [ ] Write failing checks for exact cohort arithmetic, distinct units in Table 4, resolved-only licensure denominators, the 16.1% multistate formula, and cohort-flow branch totals.
- [ ] Run `Rscript tests/test_federal_database_accuracy_remediation.R`; expect failures naming missing ledger fields and unsupported current claims.
- [ ] Write failing checks for promised interval coverage, absence of geographic-truth language, CNM/CM population terminology, certified-name terminology, and abstract-to-Results value equality.
- [ ] Run the gate again; expect the new checks to fail for the intended omissions only.
- [ ] Implement scratch-file saboteurs for MAN-01-MAN-12 and run `Rscript tests/test_federal_database_accuracy_remediation_detect.R`; each planted fault must be detected.

### Task 3: Verify and Complete Statistical Artifacts (GREEN for F01/F03/F05/F06/F08)

**Files:**
- Modify: `build_f2_f3_uncertainty_denominators.R`
- Modify: `manuscript/R/build_stats_catalog.R`
- Create if supported by canonical records: `artifacts/dac_agreement_cluster_trend.csv` plus provenance JSON
- Create: `review/manuscript_statistical_methods.md`
- Test: `tests/test_federal_database_accuracy_remediation.R`

**Interfaces:**
- Consumes: `artifacts/canonical_source_records.csv`, `artifacts/agreement_cluster_bootstrap_ci.csv`, OIG-style accuracy/consistency artifacts, linkage artifacts.
- Produces: catalog fields and provenance-backed rows for all reported intervals and the dependence-aware DAC annual trend.

- [ ] Verify `agreement_cluster_bootstrap_ci.csv` input and code hashes against its provenance JSON; record cohort, scope, B=400, ratio estimand, and units.
- [ ] Add a failing trend test requiring slope, 95% CI, beginning-to-end change, NPI count, NPI-year count, model label, and provenance.
- [ ] Implement the minimum dependence-aware trend supported by `canonical_source_records.csv`: clinician-level NPI-year agreement with NPI-clustered sandwich inference; retain the aggregate WLS result only as an explicitly descriptive comparison.
- [ ] If the canonical records cannot reproduce the published DAC series, mark F08 unresolved and remove inferential P-value claims instead of substituting a model silently.
- [ ] Verify Wilson intervals for licensure/certified-name and principal 2026 geographic estimates from exact counts; expose unresolved counts and all-accurate/all-inaccurate sensitivity bounds.
- [ ] Verify 63.12% as 563/892 and compute/report an interval whose independence assumptions are explicitly named; do not label it clustered without clinician-level resampling evidence.
- [ ] Verify 16.1% directly from classification counts and document why 85,190, 53,414, 27,175, and 107,386 are distinct universes.
- [ ] Document estimands, units, dependence assumptions, and unsupported analyses in `review/manuscript_statistical_methods.md`.
- [ ] Run the remediation gate and existing cluster saboteur test; expect the statistical checks to pass.

### Task 4: Replace the Cohort Figure with an Auditable Artifact-Driven Flow

**Files:**
- Modify: `manuscript/federal_database_accuracy.qmd`
- Modify or create producer only if needed: `make_cohort_flow_figure.R`
- Create: authoritative cohort-flow CSV and provenance JSON if no current artifact exactly matches the 22,357/14,956/1,819/16,775 cohort.
- Test: `tests/test_federal_database_accuracy_remediation.R`

**Interfaces:**
- Consumes: frozen linkage disposition artifact and catalog linkage fields.
- Produces: a generated figure with eligible records, both inclusion tiers, deduplication, unresolved/ambiguous/manual-adjudication branches when supported, and exact reconciliation.

- [ ] Audit `cohort_flow.png` and `cohort_exclusion_flow.png` against their current producer inputs; do not reuse either if its cohort definition differs.
- [ ] Add a failing flow test that changes each branch by one and requires reconciliation failure.
- [ ] Generate the smallest figure that exposes all supported branches; label unsupported requested branches as unavailable in the ledger rather than fabricate counts.
- [ ] Verify that 14,956 and 1,819 are unique, mutually exclusive linkage tiers and sum to 16,775 unique clinicians.
- [ ] Locate an existing artifact for the nursing-tier exclusion sensitivity analysis; include it only if the outcome estimands can be reproduced for both cohorts, otherwise mark it unresolved.
- [ ] Run flow and figure tests; expect exact reconciliation and non-stale provenance.

### Task 5: Reconcile and Tighten the Manuscript (F02/F04/F05/F06/F09-F12)

**Files:**
- Modify: `manuscript/federal_database_accuracy.qmd`
- Modify: `review/claim_evidence_matrix.csv`
- Modify: `review/manuscript_findings_ledger.csv`
- Test: `tests/test_federal_database_accuracy_remediation.R`

**Interfaces:**
- Consumes: verified catalog values, ledgers, trend artifact, cohort flow.
- Produces: final source text whose claims and units match the evidence matrix.

- [ ] Update Methods and Tables 1-4 so every comparison names datasets, overlap rule, time basis, observation unit, and interval method.
- [ ] Use “certified-name agreement,” “source-to-NPPES agreement,” “common comparison source,” “ZIP code,” and “certified nurse-midwives and certified midwives (CNMs and CMs)” consistently.
- [ ] Separate licensure, enrollment, billing, mailing/administrative, and independently verified practice geography.
- [ ] Move causal explanations out of Results or qualify them as interpretation; remove all assertions of observed practice moves.
- [ ] Keep the research-use table, remove redundant summary prose, and target a net 10-15% reduction from the original prose without deleting required methods or limitations.
- [ ] Rewrite the abstract last using only verified quantities that appear identically in Results/tables.
- [ ] Update F01-F12 dispositions and the claim matrix with exact evidence locations.
- [ ] Run terminology, claim, denominator, and abstract gates; expect all P0 checks green and any unresolved lower-priority item explicitly listed.

### Task 6: Render, Inspect, and Independently Review

**Files:**
- Create: timestamped `/Users/tylermuffly/Downloads/federal_database_accuracy_revised_YYYYMMDD_HHMMSS.docx`
- Modify: `review/manuscript_changes.md`
- Modify: `review/manuscript_findings_ledger.csv`

**Interfaces:**
- Consumes: final QMD and verified artifacts.
- Produces: rendered Word draft plus a reviewer-audited disposition ledger.

- [ ] Run the relevant artifact producers and verify provenance hashes before rendering.
- [ ] Run the full manuscript-number/table tests plus the new remediation and detector tests; report every existing failure by name.
- [ ] Render the QMD to a timestamped Word file without touching the original Downloads manuscript.
- [ ] Convert the DOCX back to Markdown and inspect for `NA`, `[PENDING]`, missing tables, numbering drift, broken citations, and abstract/result mismatches.
- [ ] Extract and visually inspect every new or changed figure and the main tables.
- [ ] Dispatch a fresh independent reviewer agent to audit F01-F12 against the spec, ledgers, QMD, artifacts, and rendered DOCX.
- [ ] Reproduce and fix every confirmed reviewer defect, rerun all gates, and update the findings ledger; retain disputed or unavailable items as unresolved with reasons.
- [ ] Report the Word path, generating QMD, F01-F12 table, reanalysis changes, unsupported claims, incomplete uncertainty, and remaining submission blockers. Do not call the manuscript submission-ready while any P0 item is unresolved.

## Self-Review

- Spec coverage: F01-F12, all required deliverables, workflow order, timestamped render, and independent review each map to a task.
- Test coverage: MAN-01-MAN-12 are exercised by the remediation gate and mutation detector.
- Type/unit consistency: ledgers name unique clinician, NPI, provider-year, source record, comparable observation, and state enrollment separately.
- Proportion: one focused gate and existing producers are reused; no new framework or dependency is introduced.

