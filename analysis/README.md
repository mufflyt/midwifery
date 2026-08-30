# analysis/

Ad-hoc audits written to answer one question each, kept because the numbers they
produced are quoted in `docs/TECHNICAL_APPENDIX_*.md` and a quoted number whose
derivation is not in the repository is not checkable.

These are **not** pipeline stages. Nothing in `match_amcb_to_npi.R` or the CI
gates calls them. They read committed artifacts plus the gitignored person-level
linkage, and they write person-level CSVs — which is why `analysis/*.csv` is
gitignored. Run them where the pipeline has been run.

| script | question it answers | appendix |
|---|---|---|
| `audit_identity_flips.R` | which records matched to a *different* NPI between two linkage arms, and what middle-name verdict changed to cause it | RECORD_LINKAGE |
| `audit_contested_npi.R` | of the contested NPIs, how many have a claimant with strictly stronger evidence and how many are exact ties | CONTESTED_NPI §3 |
| `measure_taxonomy_scope_ceiling.R` | how many "no candidate" rows the wide taxonomy pool recovers, and how many resolved rows it puts into ties | TAXONOMY_SCOPE §4a |
| `compare_linkage_arms.R` | status transitions, cohort delta and regressions between any two linkage artifacts | REPRODUCIBILITY §2 |

Paths are arguments, never constants — positional first, then an environment
variable, resolved by `arg_or()` in `R/analysis_args.R` (one definition; four
inline copies were rejected by `tests/ci_hygiene.R`, correctly). Run them from
the repository root. All four expect `~/isochrones` reachable, because they
source `R/amcb_name_keys.R`.

```
Rscript analysis/compare_linkage_arms.R <control-worktree> <treatment-worktree>
Rscript analysis/audit_identity_flips.R <treatment.csv> <control.csv> [root] [panel]
CONTROL_ARTIFACT=... Rscript analysis/measure_taxonomy_scope_ceiling.R
Rscript analysis/make_middle_veto_figure.R      # writes docs/figures/
```
