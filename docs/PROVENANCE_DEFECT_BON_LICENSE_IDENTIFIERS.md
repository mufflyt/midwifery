# Provenance Defect: Synthesized State Board-of-Nursing License Identifiers

**Class:** data-provenance defect
**Date identified:** 2026-08-17
**Identity linkage affected:** **No.** See §3.
**Reported board-verification coverage affected:** **Yes.** See §4.

---

## 1. Finding

Most purported multi-state Board of Nursing (BON) license numbers in this
repository were **synthesized from `certification_number`** rather than observed
from state boards. They are re-encodings of the AMCB identifier with a state
prefix, not licensure identifiers.

Two templates:

```
{STATE}-RN-CNM-{certification_number}
{STATE}-RN-APRN-{certification_number}
```

Origin, `harvest_all_tier1_live_bon_datasets.py:80`:

```python
r["tier1_license_number"] = f"{st}-RN-CNM-{r.get('certification_number', 'ACTIVE')}"
```

Only the Washington branch (`:74`) reads a real field, `credentialnumber`, from
the WA DOH Socrata endpoint. In the harvester's own configuration, of eleven
"Tier 1" states only WA and FL carry a `socrata_url`; NC, VA, OH, IN, MA, OR and
AZ are `None`.

## 2. Confirmed counts

Verified from source by testing whether each license value ends with that row's
own `certification_number` — not by reading the generating code alone:

| artifact | synthetic | genuine |
|---|---|---|
| `artifacts/scraped_40_state_bons_midwives_master.csv` | **11,355 / 11,355** | 0 |
| `artifacts/scraped_20_state_bons_midwives_master.csv` | **9,037 / 9,037** | 0 |
| `artifacts/tier1_live_bon_all_states_complete.csv` | **4,746 / 5,120** | **374** |
| `artifacts/tier1_tier2_combined_bon_validated_master.csv` | **4,746 / 5,120** | **374** |

**Genuine observed BON evidence: 374 Washington records**, carrying WA DOH
`credentialnumber` values of the form `ARNP.AP.60949950-CNM`. This is
corroborated independently: `artifacts/live_wa_bon_summary_matrix.csv` reports
exactly 374 `VERIFIED_LIVE_BON`.

The distinction must be preserved. Genuine WA values are observed licensure
evidence; the `{STATE}-RN-...` values are not, and must never be counted as such.

## 3. What is NOT affected — the identity linkage is clean

Traced read-only across the repository. The synthetic identifiers:

- **never entered AMCB↔NPPES candidate generation** — no R code reads
  `tier1_license_number`, `scraped_license_num`, `bon_verification_status` or
  `tier1_verification_source`; `R/`, `match_amcb_to_npi.R`,
  `reconcile_linkage.R` and `build_midwife_panel.R` contain no BON reference at
  all;
- **never resolved an NPI ambiguity**;
- **never changed an accepted identity or FROZEN membership** — every
  `npi_match_method` in `artifacts/amcb_npi_linkage_FROZEN.csv` is name-derived
  (`exact_last_first`, `exact_last_first_initial`, `fuzzy_last_exact_first`,
  `surname_component_exact_first`);
- **never affected geography or organization assignment.**

**Existing identity linkage results therefore do not require recomputation.** No
identity counterfactual was run, because none is warranted.

## 4. What IS affected — descriptive and reported coverage

Every consumer of these fields is analysis-only, but the outputs are scientific
summaries and figures, not scratch. Six R scripts
(`analyze_20/40_state_bon_scrape.R`, `analyze_tier1_complete_results.R`,
`validate_scraped_20_state_bon_results.R`, `analyze_specialized_bon_fields.R`,
`plot_bon_scraped_data_visualizations.R`) summarise them into per-state
breakdowns and plots.

The headline correction:

> **"11,355 midwives board-verified across 40 states" → 374 board-verified, in
> one state.**

`docs/DECISIONS_CONTRACT.md` D12 debates whether 74% state-board coverage is
reportable given non-random state selection. The prior question is that the
observed coverage is **3.3%, Washington only**. The availability-sample caveat
is not the issue; the numerator is.

The path-level inventory is in
`artifacts/bon_contamination_inventory.csv`.

## 5. Intent

None is asserted. The pattern is consistent with scaffolding that was never
replaced: a placeholder value written so a pipeline could run end to end, which
then flowed into artifacts named `*_validated_master.csv` carrying fields named
`bon_verification_status`, and from there into per-state summaries.

Whether it was known to be a stub does not change the scientific position. The
question that matters is whether downstream analysis treated synthesized values
as independently observed evidence, and it did.

## 6. Recommended handling

- **Retain** `artifacts/live_wa_bon_summary_matrix.csv` and the 374 WA records.
- **Retract** the 9,037 and 11,355 board-verification claims wherever they
  appear, including D12 in `docs/DECISIONS_CONTRACT.md` and
  `docs/COAUTHOR_BRIEF_2026-08-14.md`, and the "50-State + DC BON Verification"
  language in `README.md`.
- **Relabel** `cohort_midwives_tier1_tier2_bon_validated.csv`; its name asserts
  a validation that holds for 374 of 5,120 rows.
- **Recompute** the Tier-1 breakdown restricted to genuine WA evidence.
- Do not regenerate historical figures as part of this note.
