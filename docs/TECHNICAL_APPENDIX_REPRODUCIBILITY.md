# Technical Appendix: Why the Frozen Cohort Cannot Be Regenerated

**Repository**: `midwifery`
**Affected artifact**: `artifacts/amcb_npi_linkage_FROZEN.csv` — 22,309 rows, cohort of 16,892
**External dependency**: `rank_one_to_one()` in `~/isochrones/R/npi_resolution.R`
**Gate**: G7 in [`tests/test_amcb_gates.R`](../tests/test_amcb_gates.R)
**Investigation date**: 2026-08-30

---

## 1. The claim

Running `match_amcb_to_npi.R` today, unmodified, against the same roster and the
same panel, does not reproduce the frozen linkage. The difference is 249 of
22,309 rows, it decomposes exactly into two causes, and **neither cause is a
change to this repository**.

This is not a defect being reported for repair. It is a property of the
published numbers that anyone re-running the pipeline will hit, and it belongs
in the manuscript's reproducibility statement.

## 2. The measurement

A control worktree at the same base commit, with only the two lines needed to
make the script execute at all (§3), against the identical panel:

| `npi_match_status` | frozen | re-run | delta |
|---|---|---|---|
| matched | 14,764 | 14,813 | +49 |
| matched_nursing_taxonomy | 2,134 | 2,148 | +14 |
| ambiguous_tied_names | 3,044 | 3,044 | 0 |
| unmatched | 2,108 | 2,108 | 0 |
| candidate_class5_held_out_of_cohort | 156 | **0** | −156 |
| ambiguous_contested_npi | 95 | **188** | **+93** |

249 rows differ. **Zero rows match to a different NPI.** 156 + 93 = 249 with
nothing left over, and the matched gain reconciles: 156 − 93 = 63 = 49 + 14.

## 3. Cause one — the script no longer runs unmodified

`rank_one_to_one()` is imported from another repository. Between the freeze and
today, consolidating its four copies (`114e9245c`) changed two things this
pipeline depended on:

1. the default `id_col` moved from `enthealth_id` to `abog_id`
2. it began requiring a `method_priority` column, or `build_method_priority_lut()`
   in scope — a helper `scripts/match_enthealth_to_npi.R` does not export

The import check was `exists(fn)`, which was TRUE throughout. Both failures
surfaced only after fifteen minutes of matching, twice.

**The loud failure was the lucky one.** A caller whose data happens to carry a
column named by the new default gets no error at all: the bijection is enforced
over the wrong identifier and the run looks clean. Nothing else in this
repository would have noticed.

Two consequences, both now in the code:

- Both arguments are passed explicitly at the call site rather than defaulted.
  `method_priority = 99L` is not a new choice: `build_method_priority_lut()` is
  keyed on the ABOG pipeline's strategy names and contains **none** of this
  pipeline's four methods, so every midwifery row missed the lookup and was
  coalesced to 99 anyway. The constant reproduces the historical ranking; what
  changes is that the pipeline no longer depends on a table that never applied
  to it.
- `amcb_assert_rank_one_to_one()` replaces the existence check with a
  **behavioural** contract on a fixture, gated by G7 against deliberately-wrong
  stand-ins. Existence is not a contract.

## 4. Cause two — contested NPIs, and a step that lives downstream

The other 93 rows are the one-to-one constraint. Until 2026-08-08 the canonical
resolver consumed NPIs greedily and a contested NPI produced one winner and one
loser; it now quarantines both claimants, deliberately. That doubled this
cohort's contested stratum from 95 to 188.

Full detail, including the empirical answer to the dominance question the
upstream commit left open, is in
[`TECHNICAL_APPENDIX_CONTESTED_NPI.md`](TECHNICAL_APPENDIX_CONTESTED_NPI.md).

The 156 have a separate explanation worth stating plainly, because it caught the
investigation out. The frozen artifact's manifest names
`amcb_npi_crosswalk_c5guard_…` as its source: **FROZEN is not this script's
output.** It is the base linkage plus a class-5 guard step applied afterwards,
which holds 156 records out of the cohort. `match_amcb_to_npi.R` alone does not
produce them, so the "156 class-5 held out" figure quoted throughout the
appendices lives downstream of the script that appears to generate it.

## 5. What this means for a published number

`16,892` is reproducible only as: the base linkage at the freeze commit, plus
the c5guard step, plus the pre-2026-08-08 greedy bijection. Two of those three
are outside this repository and one of them has since changed.

The pipeline now records enough to make that statement checkable rather than
folkloric:

- every run writes a `.manifest.json` sidecar carrying `run_id`, the artifact's
  SHA-256, the source script's SHA-256, and the panel's SHA-256
- `CONTESTED_RULE=greedy` reachable, so the pre-2026-08-08 bijection can be
  reproduced deliberately and labelled — it is **not** the default, because 37
  of the 93 awards it makes are decided by certification number rather than by
  evidence
- G7 fails loudly if the imported resolver's behaviour drifts again

## 6. The general lesson, which is not about this function

This pipeline reuses five functions from `~/isochrones` deliberately, and that
is the right call — a second copy of a name normaliser or a bijection is how two
pipelines quietly disagree about who matched whom. The cost of that choice is
that **another repository's refactor can change a published cohort with no
commit here, no error, and no artifact diff to look at.**

Reuse the function; pin the behaviour. Anywhere this repository calls into
another, the contract worth asserting is the one the caller actually relies on,
tested on a fixture, with a deliberately-wrong stand-in proving the assertion
can fail. An assertion only the real function can pass is indistinguishable from
one that always passes.

## 7. Reproducing this

```
Rscript tests/test_amcb_gates.R                        # G7 contract, with stand-ins
CONTESTED_RULE=greedy Rscript match_amcb_to_npi.R      # pre-2026-08-08 bijection
CONTESTED_RULE=quarantine_all Rscript match_amcb_to_npi.R   # upstream default
```

The control comparison in §2 needs the frozen artifact, which is person-level
and gitignored; it runs only where the pipeline has been run.
