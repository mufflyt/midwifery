# Technical Appendix: Full-Panel Migration Move Classification

**Repository**: `midwifery`
**Primary scripts**: [`classify_migration_moves_full_panel.R`](../classify_migration_moves_full_panel.R), [`R/lib/migration_move_classification.R`](../R/lib/migration_move_classification.R), [`build_truth_fusion_predictions.R`](../build_truth_fusion_predictions.R) (extended), [`build_leave_one_source_out_sensitivity.R`](../build_leave_one_source_out_sensitivity.R) (extended)
**Tests**: [`tests/test_migration_move_classification.R`](../tests/test_migration_move_classification.R) (30 assertions: all 7 rule IDs + all 20 adversarial "saboteur" cases below)
**Related**: [`docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md`](TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md) (the 5-source model and spike-specific sub-annual findings this build generalizes to the whole panel), [`docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md`](TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md) (the prior, 6-transition, 3-source pairwise corroboration pass this build extends to all 13 transitions and the full 5-source claims table)
**Investigation date**: 2026-11-06
**Status**: core classifier + full-panel run complete. Several items from the originating
specification are explicitly deferred to a follow-on pass (§6 below) — not silently dropped.

---

## 0. What this build answers, and the principle it was built under

A user-supplied specification asked for every apparent NPI interstate move in the full cohort
panel (2013-2026, 13 transitions) classified into **confirmed / possible / likely administrative
artifact / indeterminate**, under one non-negotiable constraint: **agreement among sources must
never be read as accuracy**. DAC's address field is CMS-derived directly from PECOS enrollment
data (`R/lib/truth_fusion_claims.R`'s `merge_dac_pecos_sources()`); NPPES agreeing with itself is
not independent confirmation of itself. This build generalizes the spike-specific sub-annual
checks already in `TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md` §7 into a rule-based, auditable
classifier run over the whole panel, not just 2017-18 and 2023-24.

## 1. Cohort — a correction to the originating specification

The specification cited "16,775 midwives, with 12,170 NPI-matched individuals," implying 12,170
is the subset of the 16,775 that actually has an NPI. **Verified directly against
`artifacts/amcb_npi_linkage_FROZEN.csv` and `R/lib/cohort_definitions.R`: this is wrong.**
16,775 is the `cohort_member == "TRUE"` linkage-eligible cohort — all 16,775 already have a
non-blank NPI (0 blank among them). **12,170 is a stricter, unrelated filter**:
`canonical_active_primary()` additionally requires AMCB status `ACTIVE` and
`linkage_tier == "primary_midwifery"`. It has nothing to do with NPI-matching. This build uses
the same 16,775-NPI cohort the existing truth-fusion build already uses, not the stricter 12,170
— narrowing to the stricter clinical-status filter was never part of that build either, and doing
so here would silently change the population without being asked to.

## 2. Candidate moves are defined on the fused prediction, not raw NPPES

Per the specification's explicit instruction (and the user's own confirmed choice when asked): a
candidate move is `(npi, year_from, year_to)` where the **dawid_skene** fused prediction's
`predicted_value` differs between consecutive years, 2013-2026. `majority`'s predictions exist
alongside as the project's standing cross-check, not the classification basis.

This choice creates a real problem the specification itself flags: a naive "does another source's
claim match the move" corroboration check is **circular by construction**, since any source whose
claim matches the before/after states necessarily voted for those same states in the fusion. This
build resolves it the same way `build_leave_one_source_out_sensitivity.R` already resolves "is the
migration spike an NPPES artifact" — by checking whether the move **survives refitting the model
with the supporting source's family excluded** (§4 below), not by inventing new per-vote
bookkeeping on top of `mysteryroster::attribute_truth_fusion()`'s internals.

## 3. Source-family registry

| family | location_type | date_precision | usable for corroboration? |
|---|---|---|---|
| `dac_pecos_combined` | enrollment/practice (DAC's field is CMS-derived from PECOS) | month (vintage) | yes |
| `open_payments` | reported recipient/mailing address | year (program year) | yes |
| `tmsis_medicaid` | Medicaid enrollment | real interval (day) | yes |
| `facility_affiliation` | hospital/facility address — not the person's own | snapshot (2026-06 only) | **descriptive only** |

No new `SHARED_LINEAGE_GROUPS` entries were needed beyond what the existing build already
established: `merge_dac_pecos_sources()` already collapses the one true lineage overlap (DAC's
field being PECOS-derived) before the claims table exists, and
`TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md` §1 already checked and confirmed
`facility_affiliation` doesn't share lineage with `dac_pecos_combined` on the state value itself.

**`facility_affiliation` is excluded from the support/contradict tally, with the reason stated
explicitly rather than silently dropped**: it has no data before 2026, so under this project's
standing no-inferred-value discipline it can never satisfy "both endpoint years directly
observed." It is still recorded in Deliverable A for descriptive audits — this is the specification's
own instruction ("all sources should remain available for descriptive audits, but their
suitability for confirming a move must be assessed according to what they actually measure").

**FHIR/Healthgrades/Doximity/state-board sources exist in this repo as scrapers but are
deliberately not part of this registry** — they were already excluded from the truth-fusion build
itself (`TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md` §1) for lacking real per-claim effective
dates, verified directly during this build's planning, not assumed from the specification's text.

## 4. Classification rules

Applied per non-abstained candidate move, using direct-observation-only lookups (no inference,
same discipline as `R/lib/corroboration_lookup.R`'s `lookup_state()`) against the 3 usable
families for both `year_from` and `year_to`. A family **supports** the move if it directly
observes `state_from` at `year_from` and `state_to` at `year_to`; it **contradicts** the move if
it directly observes `state_from` at *both* years (the origin state persisting through the
destination year — positive evidence against the move, not merely absence of evidence); it's
**ambiguous** if it carries a genuine multi-value conflict spanning either state; otherwise
**unavailable**. `nppes` itself is never counted as a corroborating or contradicting witness.

Rule evaluation order matters and is fixed (evidence-based rules are checked before the
context-only `ART-GAP` fallback):

| rule_id | classification | condition |
|---|---|---|
| `IND-ABSTAIN` | Indeterminate | either endpoint year abstained in the fused prediction |
| `CONF-2FAM` | Confirmed | `n_support >= 2`, `n_contradict == 0`, **and** the move survives a leave-one-out refit excluding *each* of the >=2 supporting families individually |
| `CONF-2FAM-NOHOLD` | **Confirmed (not held-out)** | same support/contradict pattern as `CONF-2FAM`, but fails the held-out check — reported as its own distinct bucket, never silently merged into `Confirmed` |
| `ART-CONTRA` | Likely administrative artifact | `n_contradict >= 1`, `n_support == 0` |
| `ART-GAP` | Likely administrative artifact | zero evidence either way, **and** the transition is one of the two known >=20-month NPPES snapshot gaps (2017→2018, 2023→2024, per `TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md` §7) — the weakest rule, a mechanical transition-level fact, never evidence about this specific NPI |
| `MIXED-SPLIT` | Indeterminate | `n_support >= 1` **and** `n_contradict >= 1` — independent families disagree with each other, not just with NPPES; per the specification's own caution, an unexplained disagreement is not automatically an artifact |
| `POSS-SINGLE` | Possible | exactly 1 supporting family, 0 contradicting |
| `POSS-NONE` | Possible | zero evidence either way, not a gap transition |

Stable pairs (`state_from == state_to`) never reach this classifier at all — they're their own
denominator in Deliverable C, per the specification's §3.3/§13C requirement that every reported
percentage identify its denominator.

## 5. Held-out confirmation: why it reuses leave-one-out instead of new bookkeeping

`build_truth_fusion_predictions.R` was extended (additive edit, existing outputs unchanged) to
persist two things `attribute_truth_fusion()` already computes every run and previously
discarded: the claims table itself (`artifacts/truth_fusion_claims.csv`, method-independent, built
once) and each method's per-candidate-value vote breakdown
(`artifacts/truth_fusion_candidate_scores_<method>.csv`).

`build_leave_one_source_out_sensitivity.R` was extended the same way to additionally persist the
per-NPI predicted state under each of its 6 existing variants (full + one drop per family)
(`artifacts/truth_fusion_leave_one_out_predictions.csv`) — previously computed per variant,
piped straight into `compute_migration_rates()`, and discarded.

A move's `CONF-2FAM` held-out check requires that it still appears as a move (predicted states
differ, not abstained) in the leave-one-out run that excludes **each** of its supporting families
individually — directly answering the specification's own framing: "a model should not claim a
move is independently corroborated simply because the same records used to infer the move also
agree with it." A missing variant key (e.g. a typo) or a missing npi-year row is a **failed**
check (default-deny), never a default-approve — see saboteur case #15 below.

## 6. Adversarial test design: 20 saboteur cases

Each is a deliberately constructed scenario aimed at making the classifier produce a *wrong*
verdict or silently misbehave, implemented in `tests/test_migration_move_classification.R`
(30 passing assertions total, run against `R/lib/migration_move_classification.R` directly, not
against the full data pipeline):

1. Fake independence via shared lineage — duplicate rows within one family must not inflate
   `n_support` past 1.
2. NPPES self-corroboration — `nppes` can never appear in `supporting_families`/`contradicting_families`.
3. Shallow held-out check — each of the >=2 supporting families' own drop-variant is tested
   individually, not just one.
4. `facility_affiliation` as a disallowed `year_from` witness — resolves to `unavailable` for
   every year other than 2026, unconditionally.
5/6. Ambiguous claims never silently become `support` or `contradict`, on either side.
7. Rule-evaluation-order — genuine held-out `CONF-2FAM` support on a known-gap transition still
   wins over `ART-GAP`.
8/9. Mixed-support-and-contradiction cases land in `MIXED-SPLIT`, never `ART-CONTRA` or
   `CONF-2FAM`, regardless of how many families support.
10. Zero-eligible-pairs transitions get an explicit zero denominator in Deliverable C, never a
    divide-by-zero or a silently omitted row (`REQUIRED_CLASSES` padding in
    `classify_migration_moves_full_panel.R`).
11. Non-move leakage — `state_from == state_to` pairs are tagged `"stable"` by
    `classify_row_type()` before ever reaching the classifier.
12/13. Partial and full abstention resolve cleanly to `IND-ABSTAIN` — abstention is checked
   *before* stability specifically because `NA == NA` is itself `NA`, not `TRUE`.
14. The held-out lookup is filtered to the same method (`dawid_skene`) used for the primary
    classification, confirmed against a synthetic case where `majority`'s leave-one-out data would
    give the opposite answer.
15. A missing or mistyped leave-one-out variant key fails the held-out check (default-deny).
16. 3 supporting families are checked against their 3 individual single-family drop-variants, not
    a combined drop-all-3 variant that was never built.
17. The contradiction check uses this move's own `state_from`, not a coincidental match against
    an unrelated state value elsewhere in the claims table.
18. An unrelated NPI's claims in the same index never contaminate a different NPI's lookup.
19. Two adjacent transitions sharing a middle year's value classify independently, with no
    leakage of one transition's evidence into the other's.
20. A genuine contradiction on a known-gap transition resolves to `ART-CONTRA` specifically, with
    a `reason` string distinguishable from `ART-GAP`'s, never merged just because both map to
    `administrative_artifact`.

## 7. Regression check against prior narrative findings

`classify_migration_moves_full_panel.R` ends with a block comparing its verdicts for 2017→2018,
2020→2021, and 2023→2024 against `TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md`'s prior
conclusions, reporting agreement or explicit discrepancy — never forced to match, per the
specification's own instruction. One discrepancy is anticipated and explained in advance, not
treated as a bug: **2020-21 may land mostly as `possible` rather than `confirmed` under this
classifier**, because only one family (`dac_pecos_combined`) ever showed elevation there, and
`CONF-2FAM` requires >=2 independent families — a stricter standard than the ad hoc sub-annual
diagnostic that originally found it, not a contradiction. (PECOS's apparent second, independent
corroboration of that signal was itself retracted earlier this session as a dedup-determinism bug
— see `TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md` §7's correction.)

**Full-panel run, 2026-11-06.** Of 161,547 eligible consecutive-year NPI pairs: 156,684 (97.0%)
stable, 271 abstained, **4,592 (2.84%) apparent interstate moves.** Of those 4,592:

| classification | n | % of apparent moves |
|---|---:|---:|
| confirmed (held-out, `CONF-2FAM`) | 7 | 0.2% |
| confirmed, not held-out (`CONF-2FAM-NOHOLD`) | 7 | 0.2% |
| possible (`POSS-NONE` 2,507 + `POSS-SINGLE` 450) | 2,957 | 64.4% |
| administrative artifact (`ART-CONTRA` 835 + `ART-GAP` 653) | 1,488 | 32.4% |
| indeterminate, source disagreement (`MIXED-SPLIT`) | 133 | 2.9% |

Every count reconciles exactly: `eligible_pairs == stable_pairs + apparent_movers` and the 5
classification columns sum to `apparent_movers`, in every one of the 13 transition rows (verified
directly, not assumed).

**2017→2018 and 2023→2024 (the two known >=20-month snapshot-gap transitions) carry by far the
highest administrative-artifact share** — 3.53% and 3.21% of eligible pairs respectively, versus
0.30%-0.71% for every other transition. They are also where almost every genuinely `confirmed`
move in the whole panel is concentrated: **2023→2024 alone accounts for 5 of the 7 held-out-
confirmed moves**, with the rest split across 2021→2022 and 2022→2023 -- no other transition has
even one. This is a genuinely new finding: a small number of real, well-evidenced moves coexist
with "no detectable rate elevation" at that transition, which is not a contradiction of this
session's earlier sub-annual finding that 2023-24 gets no aggregate DAC/PECOS corroboration --
aggregate-rate and per-move evidence are different questions.

**2020→2021 shows zero confirmed moves**, exactly as flagged in advance in §7 above: only
`dac_pecos_combined` ever showed elevation for that window, and `CONF-2FAM` requires >=2
independent families -- a stricter bar than the earlier ad hoc sub-annual diagnostic, correctly
refusing to extend a single-source signal into a cross-source "confirmed" claim, not a reversal
of that finding.

**Interpretation, stated carefully**: the ~67% of apparent moves landing in `possible` or
`indeterminate` is NOT evidence those moves are false -- it reflects source-coverage sparsity
(requiring 2 of only 3 usable families to have *both* endpoint years directly observed for the
same NPI is a demanding bar most moves simply lack the evidence density to clear), not a verdict
on whether they're real. No gold standard exists for any individual NPI's true practice-state
history in this cohort (consistent with the guardrail already stated in
`TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md` §0) -- this table should not be read as a
sensitivity/specificity estimate for the classifier itself, only as what the available,
non-circular evidence does and does not support.

Source-dependence (specification §6/Table 2) is now done -- see §7a below. Temporal-sensitivity
(specification §9, strict/moderate/permissive proximity windows) is still follow-on work, not yet
run as of this writing -- see §8.

## 7a. Source-family sensitivity (Table 2)

`audit_migration_source_sensitivity.R` compares each of the 5 "drop one family" leave-one-out
variants against the "full" baseline (`dawid_skene` only, the classifier's primary method), two
ways -- both reusing data `build_leave_one_source_out_sensitivity.R` already computed and
persisted, no new ~90-minute refit:

| excluded family | npi-years changed value | % changed (of comparable) | npi-years losing coverage entirely | mean \|Δ rate\| (pts) | largest single-transition Δ |
|---|---:|---:|---:|---:|---|
| nppes | 10,494 | 9.49% | 108,731 | 1.280 | 2020→2021 (+4.98 pts) |
| dac_pecos_combined | 2,333 | 1.07% | 771 | 0.466 | 2020→2021 (−0.98 pts) |
| tmsis_medicaid | 2,108 | 0.97% | 2,656 | 0.585 | 2020→2021 (−0.98 pts) |
| open_payments | 625 | 0.29% | 162 | 0.095 | 2024→2025 (−0.36 pts) |
| facility_affiliation | 78 | 0.04% | 0 | 0.031 | 2025→2026 (−0.31 pts) |

**NPPES dominates by roughly an order of magnitude over every other source**, both in how many
predicted values change when it's removed and especially in coverage: dropping NPPES leaves
108,731 of 219,336 npi-years (49.6%) without any usable prediction at all. The fused model's
resolved states are therefore overwhelmingly anchored to NPPES whenever NPPES is present --
worth stating plainly, since it bears directly on how much genuinely independent signal the other
4 sources can realistically contribute to any single npi-year's prediction.

**2020→2021 is the single most source-sensitive transition in the whole panel for 3 of the 5
families** (nppes, dac_pecos_combined, tmsis_medicaid each show their own largest rate-swing
exactly there) -- a third, independent line of evidence (after the sub-annual DAC check and this
classifier's own per-move results) that this transition is where the sources disagree with each
other most sharply. The *direction* is informative too: dropping NPPES SWINGS THE RATE UP
(+4.98 pts, `mean_signed_rate_change_pts` positive) -- consistent with this session's repeated
finding that 2020-21's elevated signal "only appears once NPPES is excluded from the vote" --
while dropping DAC/PECOS or T-MSIS swings it DOWN (both negative), consistent with those two
sources being the ones *pushing the rate up* when included, matching DAC's own repeatedly-elevated
sub-annual readings for this window.

**Not done here** (a materially bigger task, not a quick add-on): re-running
`classify_migration_moves_full_panel.R`'s rule set under each drop-variant's own candidate moves
and evidence, to see how the 5-way classification counts themselves shift -- this script answers
how much dropping a family changes the fused *predictions* and the raw *move rate*, not how much
it changes the *classification*. The classifier's own held-out check already uses these same
leave-one-out variants for a different purpose (confirming a specific move survives a refit); a
full per-variant re-classification is a separate design question.

## 7b. Temporal sensitivity (strict / moderate / permissive proximity windows)

`audit_migration_temporal_sensitivity.R` re-classifies the SAME 4,592 apparent moves under 4
proximity-window settings (0 = strict/today's standing behavior, 1, 2, 3 years), using
`lookup_family_windowed()` (`R/lib/migration_move_classification.R`) in place of the exact-year-
only `lookup_family()`. Windowing applies **only** to `dac_pecos_combined` and `open_payments` --
year/vintage-level sources with no more informative effective interval -- never to
`tmsis_medicaid` (already has real `interval_start`/`interval_end` dates, checked at exact-year
resolution upstream; widening its search would make its answer *less* precise) or
`facility_affiliation` (stays excluded from the tally regardless of window). The exact year
always wins if the family has any observation there at all; a window only backfills a genuinely
*missing* year, and if nearby years disagree with each other the result is still `"ambiguous"`,
never arbitrarily picked -- the same no-inference discipline as the strict run, just widened.

**12 of the 13 transitions are robust**: their dominant (plurality) classification doesn't change
under any window tested, 0 through 3 years. **Exactly one is not: 2025→2026.** Its dominant
classification is `possible` at window 0-1 (324 and 197 possible vs. 79 and 195 artifact) but
flips to `administrative_artifact` at window 2-3 (190 and 183 possible vs. 197 and 192 artifact).
This directly answers specification §8's explicit instruction to investigate 2025-2026 "given the
separately observed change in DAC state agreement... do not assume that the DAC agreement change
represents a real increase in migration": **it does not** -- under more permissive temporal-
matching assumptions, *more* of this transition's apparent moves look like administrative
artifacts, not fewer. If anything this points away from a real migration increase, not toward one.

**A consistent pattern across nearly every transition**: widening the window shifts mass from
`possible` into `administrative_artifact`, not into `confirmed`. Giving a sparse source more
benefit of the doubt about matching a nearby year mostly surfaces *more* evidence that the origin
state was still there shortly before/after the transition (a stale-record signature), not more
independent corroboration of the move. `confirmed` counts stay essentially flat across all 4
windows everywhere in the panel (2023→2024's 5→6→5→5 is the largest movement observed) --
reassuring: the already-rare confirmed bucket is not an artifact of how strict the exact-year
matching is.

## 8. Deferred to a follow-on pass

Named explicitly so nothing from the originating specification is silently dropped:

- The full 10-scenario sensitivity suite (specification §12) beyond what leave-one-out and the
  temporal-window analysis above already give for free.
- Diagnostic figures (specification §13D) — build once the underlying tables exist and are
  validated against real data.
- Re-extracting NPPES's `Last Update Date` (hook: `build_midwife_panel.R`'s column-pick list) and
  Open Payments' `Date_of_Payment`/`Payment_Publication_Date` (hook:
  `extract_open_payments_address_history.R`'s SQL) to upgrade those two sources' `date_precision`
  from year/snapshot to record-level — both fields already exist in the raw data, verified
  directly, but are not currently pulled into this repo's extracts. DAC, PECOS, and
  `facility_affiliation` have **no** per-record date available in their raw data at all — PECOS's
  only other date field, `individual_revalidation_due`, is a forward-looking deadline, 97%+
  literal `"TBD"` — so no amount of re-extraction can give those three sources finer-than-vintage
  dating.

## 9. Reproducing

```sh
RETICULATE_PYTHON=~/.venvs/mysteryroster-crowdkit/bin/python Rscript build_truth_fusion_predictions.R
RETICULATE_PYTHON=~/.venvs/mysteryroster-crowdkit/bin/python Rscript build_leave_one_source_out_sensitivity.R
Rscript classify_migration_moves_full_panel.R
Rscript tests/test_migration_move_classification.R
```

Reads `artifacts/amcb_npi_linkage_FROZEN.csv` (gitignored, person-level; must be present locally),
`artifacts/truth_fusion_predictions_dawid_skene.csv`, `artifacts/truth_fusion_claims.csv`, and
`artifacts/truth_fusion_leave_one_out_predictions.csv` (all gitignored, person-level — the first
three new artifacts added by this build's extensions to the two scripts above). Writes
`artifacts/migration_move_evidence_table.csv` and
`artifacts/migration_move_classification_full_panel.csv` (gitignored, person-level) and
`artifacts/migration_move_classification_summary_by_transition.csv` (tracked, aggregate).
