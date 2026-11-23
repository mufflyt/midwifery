# Technical appendix: the 2026-11-23 external statistical review and its fixes

Three successive external AI review passes (Codex GPT-5.6) were run against
`manuscript/federal_database_accuracy.qmd` on 2026-11-23, each claim was
verified against the repository's committed artifacts before anything was
changed, and the confirmed findings were fixed the same day. This appendix
is the durable record of what was claimed, what the artifacts actually
showed, what changed, and what remains open.

## What the verification refuted

Two of the review's three "material internal contradictions" were not
contradictions:

- **Cohort counts reconcile exactly.** 14,956 is the sum of `matched` across
  all nine certification-status rows of
  `artifacts/linkage_completeness_by_status.csv`; adding the 1,819
  `matched_nursing_taxonomy` records gives the 16,775 analytic cohort.
  Figure S8's 15,328 → 12,170 → 12,022 is the ACTIVE-only tier. Table 2's
  16,774 is 16,775 minus one record the artifact itself documents as
  excluded. The gap was presentation, not arithmetic — fixed with a
  cohort-tier table in Methods.
- **The Medicaid denominators are three deliberate universes.** 85,190
  provider-years (sum of the classification counts in
  `artifacts/state_source_audit_medicaid_classification_by_year.csv`),
  53,414 observed (85,190 − 31,776 not-observed), 107,193 comparable
  NPI-years in the set-membership scoring universe
  (`audit_medicaid_set_membership.R`), and 104,935 in Table S6's
  NPPES-vs-Medicaid pairwise row. The warning in
  `manuscript/R/build_stats_catalog.R` (the two universes must not be
  equated) is now carried into the manuscript prose.

## Confirmed defects, and the fix for each

| Defect | Fix | Where |
|---|---|---|
| The 563/892 (63.1%) ever-adopted-value residual was described as the share still discordant in 2026 | Replaced with the mutually exclusive censoring audit: 366/728 observable providers (50.3%) remained discordant and 164/892 (18.4%) were right-censored | abstract, Results, Discussion, README, Supplemental Table S8, and `oig_longitudinal_2021_2026_censoring_audit.csv` |
| Methods promised Wilson + provider-cluster bootstrap intervals; no table showed any | New Supplemental Table S7 renders `artifacts/agreement_cluster_bootstrap_ci.csv` (estimate, Wilson 95% CI, cluster-bootstrap 95% CI, and CI-width ratio per pooled source) | qmd chunk `table-agreement-ci`; catalog block in `build_stats_catalog.R` |
| The artifact's interval-width ratio was called a design effect | Relabeled as `CI width ratio`; a conventional design effect is a variance ratio | Supplemental Table S7 |
| The Medicaid scoring contrast carried no paired uncertainty | Added a 2,000-replicate paired provider-cluster bootstrap and rendered both rates and their difference | `audit_medicaid_set_membership.R`; `artifacts/medicaid_set_membership_uncertainty.csv` |
| Table 2 reported resolved-only accuracy, hiding 1,253/3,193 (39.2%) unresolved NPPES records and the 56.2–95.5% bounds already computed in `artifacts/oig_remake/` | Table 2 gains Evaluated, Unresolved n (%), and Worst–best case (%) columns computed from the artifact; the caption's "every record resolves definitively" claim (contradicted by 165/77 unresolved in the live tier) removed; abstract, Results, and Discussion aligned | qmd chunk `table-accuracy` and the three prose sites |
| WLS trend p-value treated serially dependent year-level points as independent | P value removed; slope reported as descriptive with the reason stated in Methods | qmd Analysis + Agreement-over-time sections |
| Table S6 presented board-of-nursing rows as plain practice-state agreement | Dagger on every board row + caption disclosure: board records were harvested only for cohort members whose NPPES state matched the queried board (`harvest_live_*_bon_from_tracked_roster.py` headers state this), so those rows are selection-conditioned and overstate agreement | qmd chunk `table-pairwise-matrix` |
| No coverage denominator beside agreement estimates | "Of cohort (%)" column for snapshot-tier S6 rows (every snapshot comparison draws from the frozen cohort); longitudinal rows span differing windows and keep provider-year counts, per the caption | same chunk |
| "Ten record systems" vs 11 Table 1 rows | Prose now reads "evaluated, alongside the certification roster that frames the cohort"; the count stays machine-derived | four keyed-count sites + Table 1 caption |
| Abstract attributed the seven-state figure to "live state board verification" when four states were published files | Abstract distinguishes the tiers; Methods names the four states (Connecticut, Florida, Illinois, Pennsylvania) with retrieval dates verified from provenance manifests (CT/FL/IL October 2026; PA 2026-11-16) | abstract + Methods |
| Board verification scope undisclosed | Methods states verification was scoped to records the registry placed in the seven states — not a random national sample | Methods accuracy paragraph |
| Multi-record reduction rules undocumented | Methods paragraph documents each source's one-state-per-provider-year rule, taken from the extraction scripts (NPPES annual snapshot; PECOS vintage record; Part B/D modal billing state as one shared-lineage series; Open Payments modal recipient state with multiplicity retained; Medicaid deliberately unreduced) | Methods Consistency section |
| Commercial source acquisition undescribed | Methods paragraph: Healthgrades/Doximity public login-free profile retrieval; Trilliant platform reads; pointer to per-artifact provenance manifests | Methods Sources section |
| "A recent update generally marks a recent move" asserted as mechanism | Reworded as a consistent-but-untested pattern tied to Table S3's observed resolution direction | Record-age section |
| Table 1 listed Open Payments as 2015–2025 while the text says CNMs became reportable in 2021 | Years cell now carries both ("2015-2025 (CNMs reportable from 2021)") | Table 1 chunk |
| Overclaims: "fact about where care is delivered", "correcting administrative lag", "agreement this tight bounds how wrong any single source can be", "only geographic variable… support research" | Each reworded to the claim the design supports (enrollment not delivery; leading not correcting; shared-lineage sources can agree and be wrong together; most-reproducible with accuracy unverified) | Discussion + abstract conclusion |

## Rebuilding the gitignored inputs

`build_f2_f3_uncertainty_denominators.R` and `audit_medicaid_set_membership.R`
read person-level artifacts that are gitignored
(`artifacts/canonical_source_records.csv`,
`artifacts/medicaid_enrollment_cohort_state_by_year.csv` and its footprint)
were absent during final verification. The repository now retains the
conversion recipe needed before those analyses can be regenerated:

1. The T-MSIS enrollment-segments parquet the extractor expects
   (`doge_opendata/medicaid_provider_enrollment_segments_2026_07_24/…parquet`
   under the Samsung volume) did not exist; the raw
   `medicaid-provider-enrollment-segments.csv.zip` (2026-07-24 vintage — the
   download script's pinned `DEFAULT_VERSION_DATE`) did.
   `tools/convert_medicaid_segments_parquet.R` rebuilds the parquet:
   65,970,112 rows, typed auto-detection with `sample_size=-1` and explicit
   double-quote handling. Two conversion pitfalls worth recording: DuckDB's
   quote sniffing fails on this file at default sample size (a quoted
   `"TERM - … , ETC."` field splits a row), and an `all_varchar=true`
   conversion breaks `extract_medicaid_enrollment_state_by_year.R`, whose SQL
   COALESCEs the segment dates against DATE values.
2. Run, in order: `extract_medicaid_enrollment_state_by_year.R` →
   `build_canonical_source_records.R` →
   `build_f2_f3_uncertainty_denominators.R` →
   `audit_medicaid_set_membership.R`.

The private canonical records materialized during closeout. Both bootstrap
producers were then run with 2,000 replicates, and their aggregate outputs and
provenance sidecars are committed with the source changes.

## Still open

- **Preregistration / protocol statement and the confirmatory-vs-exploratory
  hierarchy**: needs a decision from the author; nothing exists to cite.
- **Human-subjects determination**: the manuscript asserts "not human subjects
  research" without a reviewing body or basis; needs the author's
  institutional facts.
- **The two Table 2 artifacts disagree by 3 records** (summary 3,190
  audited/1,938 definitive vs subtypes 3,193/1,940; the manuscript renders
  the subtypes values). Untraced; both are written by
  `remake_oig_07_09_00440_midwifery.R`.
- **WLS slope**: now descriptive and labeled as such; a provider-level
  longitudinal model with cluster-robust inference (or dropping the fitted
  slope for annual estimates) remains the stronger alternative.
- **Longitudinal S6 coverage**: snapshot rows carry "Of cohort (%)"; a
  per-pair longitudinal denominator needs each pair's overlap window, which
  no committed artifact carries for the claims and Medicaid sources.
- **Chance-corrected / state-balanced agreement** and the remaining items of
  the reviewer's enhancement list: enhancements, not defects; author's call.
