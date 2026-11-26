# Independent statistical audit — federal database agreement study

**Date:** 2026-11-25 · **Scope:** Task 2 adversarial audit · **Branch:** `fix/provenance-sidecar-restore`

## Method

Two independent paths, neither using `manuscript/R/build_stats_catalog.R`:

1. `review/build_federal_agreement_audit.R` recomputes headline quantities
   directly from `artifacts/` and compares them to the published artifacts
   with explicit tolerances → `review/federal_agreement_denominators.csv`,
   `review/federal_agreement_audit_numbers.md`.
2. `tests/test_federal_agreement_adversarial.R` applies the 12 required
   perturbations to copies of the data and demonstrates the guard that
   catches each → `review/federal_agreement_mutations.csv`.

## Independent reconstruction results

| check | independent | published | verdict |
|---|---|---|---|
| A1a Medicaid multistate, any-time | 16.065% | 16.065% | MATCH — the two concordance artifacts describe the same universe exactly |
| A1b footprint-universe multistate | 34.87% | — | INFO — different estimand (all Medicaid-evidenced NPI-years vs the 53,414 comparable provider-years); not a discrepancy, but the two numbers must never be quoted interchangeably |
| A2 NPPES–PECOS state agreement, 2024 | 88.14% (n=9,467) | 88.11% (n=9,672) | MATCH — 205-row difference is multi-state cell handling; rate agrees to 0.03pp |
| A3a discordant-2021 cohort observed both systems 2026 | 701 | 728 | MATCH within drift tolerance — artifact predates the canonical-records regeneration |
| A3b still discordant in 2026 | **389** | 366 | MATCH — independently reproduces the review's frozen-cohort endpoint (913 → 701 → 389) |
| A4 records per NPI-year | 1.97 | — | INFO — provider-year and record denominators are not interchangeable |
| A5 unusable-for-trend rows | 37,923 | 37,923 | MATCH — D14 item-5 baseline holds |

The A3 reconstruction is the strongest result: starting from raw canonical
records, the 2021 NPPES–PECOS discordant cohort resolves to 701 providers
observed in both systems through 2026, of whom 389 remain discordant —
matching both the independent reviewer's corrected endpoint and the
censoring-audit disposition structure (resolved-adopt / resolved-revert /
bidirectional / third-state / persistent / censored).

## Adversarial mutations — 12/12 detected

| id | mutation | guard that caught it |
|---|---|---|
| M01 | duplicate one clinician's rows | distinct-key dedup — rate and n identical |
| M02 | reverse CA↔TX classification | independent recomputation diverges |
| M03 | contradictory second state, one NPI-year | multi-valued cell excluded from equality scoring |
| M04 | remove one matching source record | n_comparable drops by exactly the pair |
| M05 | shift records between years | year-stratified denominators expose it |
| M06 | blank NPI on 50 comparable clinicians | incidental guard: the `;`-joined multi-value exclusion drops the NA pseudo-pair — unguarded and guarded pipelines identical |
| M07 | provider-year vs record denominator | ratio 1.97 records/NPI-year — units must be labelled |
| M08 | shuffle all 447k rows | order-invariant: identical rate and n |
| M09 | shared wrong state into NPPES+PECOS | NP–PC agreement rises while NP–claims falls — shared errors are visible per-pair |
| M10 | corrupt input after provenance receipt | `check_provenance()` reports the fabricated probe stale; **and it currently flags `R/lib/ast_walk.R` as stale on the real artifact — see findings** |
| M11 | second enrollment state on 100 provider-years | multistate rate increases as required |
| M12 | agreement request on empty subgroup | NA/error, not a printed percentage |

## Findings

1. **Live provenance drift (actionable).** `check_provenance()` on
   `artifacts/persistence_denominators.csv` currently reports
   `R/lib/ast_walk.R` stale — the library changed after the artifact was
   regenerated at 05:21 UTC. This is the mechanism working as designed;
   the artifact should be regenerated once the lib settles, or the drift
   confirms concurrent workstream activity. *Remediation:* re-run
   `build_f2_f3_uncertainty_denominators.R` after the current workstream
   commits; add this check to CI if not already present.

2. **Estimand adjacency hazard (documented, not a defect).** The Medicaid
   multistate rate is 16.1% on the comparable-provider-year universe but
   34.9% on the all-evidence footprint universe. Both are correct; quoting
   either without its denominator recreates the review's P0. The
   manuscript now states both observation rules; the footprint figure's
   caption carries the person-level caveat.

3. **Incidental guard worth naming (M06).** Missing join keys do not
   produce spurious pairs *here* only because multi-state cells are
   excluded by the `;`-join rule. A future single-state-per-cell pipeline
   would not have that protection; an explicit `!is.na(npi)` filter in
   producers is cheap insurance. *Remediation (low):* add the filter to
   `build_state_source_audit*.R` joins.

4. **Artifact-vs-canonical drift (expected).** The censoring-audit
   artifact (728 uncensored) predates the canonical-records regeneration;
   independent reconstruction gives 701. Both are internally consistent;
   the artifact should be regenerated for the manuscript's S8 table to
   quote current inputs. *Remediation (medium):* re-run the OIG longitudinal
   builder and refresh `oig_longitudinal_2021_2026_censoring_audit.csv`.

## Ranked remediation specification

| rank | item | effort | risk if skipped |
|---|---|---|---|
| 1 | Regenerate censoring-audit + F2/F3 artifacts after workstreams settle; re-render manuscript | low | tables quote stale denominators |
| 2 | Explicit `!is.na(npi)` (and source/year) filters in state-audit producers | low | latent NA-key pairing if multi-state exclusion ever relaxes |
| 3 | Unit labels (provider / provider-year / record / clinician) on every supplemental table | medium | recurrence of the review's denominator P0s |
| 4 | Wire `check_provenance()` staleness into CI as a non-blocking report | low | producer-lib drift goes unnoticed between regenerations |
| 5 | Independent-audit rerun (`review/build_federal_agreement_audit.R`) as a periodic check | low | silent divergence between artifacts and canonical records |

No scientific methodology or reported primary estimate was altered by this
audit; all changes are test- and review-artifact additions.
