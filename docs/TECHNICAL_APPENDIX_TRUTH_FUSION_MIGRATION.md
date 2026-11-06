# Technical Appendix: Multi-Source Truth Fusion Applied to the Migration Spikes

**Repository**: `midwifery`
**Primary scripts**: [`extract_tmsis_medicaid_enrollment_state_history.R`](../extract_tmsis_medicaid_enrollment_state_history.R), [`build_truth_fusion_predictions.R`](../build_truth_fusion_predictions.R), [`build_leave_one_source_out_sensitivity.R`](../build_leave_one_source_out_sensitivity.R), [`build_migration_rate_by_method.R`](../build_migration_rate_by_method.R), [`extract_nppes_subannual_panel.R`](../extract_nppes_subannual_panel.R), [`diagnose_subannual_migration_timing.R`](../diagnose_subannual_migration_timing.R)
**Figure script**: [`make_migration_rate_by_method_figure.R`](../make_migration_rate_by_method_figure.R)
**Related**: [`docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`](TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md) (the original spike identification and five rejected measurement-artifact hypotheses — §7 below adds a sixth candidate and does not reject it), [`docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md`](TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md) (the pairwise, no-inferred-value corroboration pass this build supersedes for the "does the spike survive" question specifically), [`docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md`](TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md) (independently corroborates this build's T-MSIS multi-state finding, §2 below), `mysteryroster/docs/midwifery-ablation-findings.md`, and `mysteryroster/docs/midwifery-evidence-ledger-results.md` (two parallel-session studies on a 1,806-case subset of this same cohort — the second independently reaches §4's asymmetric spike conclusion by the opposite experimental move; both cited throughout, not re-derived)
**Investigation date**: 2026-11-05/06
**Status**: complete. Headline result is asymmetric, not a single yes/no: **2017→2018 is not a real
spike** — substantially NPPES-specific (§4), independently confirmed by a second method (§6), and
now a third: it was measured across a 20-month snapshot gap nearly double the typical year, and
disappears into the ordinary range once re-measured over a clean 12 months (§7). **2023→2024 is a
real, if more modest than originally reported, elevation** — holds up without NPPES (§4, §6) and
re-measures at 2.37% rather than 3.68% once time-normalized (§7). Removing NPPES also surfaces a
new, unexplained high-rate transition (2020→2021) nothing upstream of this build had flagged, and
not visible in NPPES's own data at all (§7).

---

## 0. What question this answers, and the explicit guardrail it was built under

`docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md` established that DAC, PECOS, and Open
Payments cannot *independently* corroborate NPPES's reported moves at any meaningful rate — mostly
because of sparse coverage, not because the moves look fake. That left open a different, harder
question: if a latent "true" practice state is actually inferred from every available source at
once — rather than requiring an exact before/after match against NPPES specifically — do the
2017→2018 and 2023→2024 move-rate spikes still appear, or were they an artifact of trusting NPPES
alone?

This build answers that using `mysteryroster::attribute_truth_fusion()` directly, not a
hand-rolled reimplementation (an earlier prototype, `diagnose_truth_discovery_migration_states.R`,
was retired the same day a stale local install of `mysteryroster` turned out to already have a
real, tested truth-fusion module on GitHub HEAD). The explicit instruction going in, and the
standard this appendix holds itself to throughout: **do not treat a resolved tie as a verified
location, and do not treat an uncalibrated model score as a real probability of correctness.**
Every number below is reported as what it actually is — an estimate from a specific algorithm with
specific, stated assumptions — never as ground truth.

## 1. The five sources, and what changed from the first draft

| source | n claims | what it is | temporal coverage |
|---|---:|---|---|
| `nppes` | 215,078 | NPPES annual practice-state snapshot | one claim per year the NPI appears in the panel |
| `dac_pecos_combined` | 75,059 | DAC (Doctors & Clinicians) and PECOS revalidation, merged (agree → one claim, disagree → no claim — see §2 of the corroboration appendix for why these two are treated as one evidence family, not two independent sources) | DAC 2013-2026, PECOS 2021-2026 |
| `open_payments` | 18,629 | CMS Open Payments, recipient state on a `payment_amount > 0` record | 2015-2025 |
| `tmsis_medicaid` | 95,961 | T-MSIS Medicaid enrollment-interval state (new; `extract_tmsis_medicaid_enrollment_state_history.R`) | 2013-2026, continuous intervals, not annual snapshots |
| `facility_affiliation` | 1,702 | NPI-CCN hospital affiliation state (new) | 2026 only |

Two sources were added to this build after an initial 3-source draft, both in response to direct
user correction rather than this session's own initiative:

**T-MSIS Medicaid enrollment state** was added because a parallel `mysteryroster`-side source audit
identified it as the one genuinely new, independently-dated source available in this repo — PPEF,
Doximity/Healthgrades, and state boards either lack a real effective date or are already folded
into existing sources.

**Facility/hospital affiliation (NPI-CCN)** was added after this build's first draft excluded it on
the premise that "a single current snapshot carries no usable historical information." That premise
was wrong, and said so directly: a CCN is a real physical facility with a real state, so one
snapshot year is one real year's evidence, not nothing — exactly the same treatment this repo
already gives every other single-snapshot source (Healthgrades, Doximity, state boards, CMS NDH).
Dated 2026-only, never extrapolated backward. Checked directly, not assumed, whether
`facility_affiliation` shares upstream lineage with `dac_pecos_combined` (both are nominally "DAC
vintage 2026-06"): `extract_dac_facility_affiliations.R` joins the affiliation file's CCN against
`cms_hospital_info` (CMS's Hospital General Information / Care Compare registry) for the `state`
value — a structurally independent administrative system from PECOS individual-provider enrollment,
even though the NPI-CCN *link* itself is cut from the same monthly DAC release. Treated as a 5th,
independent source on that basis.

## 2. The T-MSIS multi-value rate (19.5%) is real, not a data-quality bug

19.5% of T-MSIS npi-years (14,895 of 76,553) show 2+ distinct enrolled states within the same
calendar year — far higher than any other source (DAC+PECOS ~1%, Open Payments ~5%). Checked
before trusting it:

- **Independently corroborated.** `docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md`,
  built earlier and via completely different methodology (point-in-time vs. year-overlap
  concordance classification against NPPES, not a truth-fusion claims table), already found
  "multistate practice is common: 23.1% of comparable NPI-years show 2+ Medicaid-enrolled states."
  19.5% here lands in the same range from an independent analysis of the same underlying warehouse.
- **The underlying intervals are not short glitches.** Sampled multi-state NPIs show enrollment
  spans measured in years (e.g. NPI `1003021866`: NJ 2013-10-30 to 2019-03-31, then PA 2019-07-01
  to 2021-06-30 — a clean sequential transition, not overlapping noise). Across all merged
  intervals, only 0.4% run under 30 days and 0.2% under 7 days.
- **The real explanation is structural.** NPPES, DAC+PECOS, and Open Payments are each one
  point-in-time snapshot per year — they cannot self-conflict by construction, no matter how often
  someone actually moves. T-MSIS is continuous interval data, so it is the *only* source that can
  correctly register "this NPI was in two states within one calendar year" when someone moved
  mid-year. A higher ambiguity rate here reflects T-MSIS observing something the snapshot sources
  structurally cannot see, not noise in T-MSIS specifically.

Under `attribute_truth_fusion()`'s default `on_source_conflict = "single_value"`, a source with a
genuine multi-value conflict for an npi-year is excluded entirely from voting for that npi-year
(never arbitrarily resolved to one of its values). When T-MSIS is the *only* source with any claim
at all for an npi-year and it is internally conflicted, that leaves zero usable votes —
`abstention_reason = "no_single_value_sources"`. Verified directly: of 217 Dawid-Skene abstentions
in the full 5-source fit, 215 trace to exactly this T-MSIS mechanism (2 to 5 distinct states claimed
within one year, sole source for that npi-year) and 2 to the analogous Open Payments case. This is
the system behaving conservatively and correctly, not a flaw — it never guesses a single state when
the only evidence available genuinely supports more than one.

## 3. Predictions: all 8 implemented methods, full panel

Both optional Python backends were set up this session, each in its own isolated venv created for
this purpose (neither touches system/Homebrew Python): Crowd-Kit needs Python ≥3.13
(`~/.venvs/mysteryroster-crowdkit`); `truthdiscovery` needs Python <3.12, since its last release
predates Python's removal of `distutils` (`~/.venvs/mysteryroster-truthdiscovery`, Python 3.11).
`reticulate` binds one Python per R process, so the two backend families cannot run in the same
invocation — `build_truth_fusion_predictions.R` was run twice, once per venv.

| method | backend | n abstained | % abstained | converged | n disconnected components |
|---|---|---:|---:|---|---:|
| `majority` | r_native | 9,911 | 4.51% | TRUE | n/a |
| `dawid_skene` | crowd_kit | 217 | 0.10% | TRUE | 1 |
| `one_coin_dawid_skene` | crowd_kit | 217 | 0.10% | TRUE | 1 |
| `sums` | truthdiscovery | 217 | 0.10% | — | — |
| `average_log` | truthdiscovery | 217 | 0.10% | — | — |
| `investment` | truthdiscovery | **15,655** | **7.13%** | — | — |
| `pooled_investment` | truthdiscovery | 217 | 0.10% | — | — |
| `truthfinder` | truthdiscovery | 217 | 0.10% | — | — |

219,536 entity-years total (the full cohort panel, up from 216,653 before T-MSIS/facility
affiliation were added — T-MSIS alone contributes ~2,900 npi-years no other source covers).
`investment`'s much higher abstention rate is consistent with a methods-disagreement pattern a
parallel session's ablation study (§6 below) found independently on a different subset: `investment`
is one of three `truthdiscovery` methods that learn a degenerate reliability fit (weight near 0 for
two of the three sources in their smaller-scale run) rather than a genuine three-way synthesis.

## 4. Leave-one-source-out sensitivity: the real artifact test, and it gives an asymmetric answer

§3/§5's full-panel result (most methods track the same spike NPPES shows) is not, on its own, a
clean test of "is the spike an NPPES artifact" — if `attribute_truth_fusion()` learns a high
reliability score for `nppes` (it does: 0.88 of 1.0 in the full 5-source `dawid_skene` fit, highest
of all five sources), then a fused estimate that includes NPPES will naturally echo NPPES's own
temporal pattern, spike included, regardless of whether the other four sources independently agree.
The actual test is leave-one-out: refit with each source family removed in turn (`majority` +
`dawid_skene` only, both backends needed for the other methods in §3 were not re-run here — judged
not worth the added runtime for a check whose job is "does dropping a family change the headline
picture," not a second full method sweep), and see whether each transition's rank among all 13
survives.

| transition rank, out of 13 | `full` | `drop_dac_pecos_combined` | `drop_open_payments` | `drop_tmsis_medicaid` | `drop_facility_affiliation` | **`drop_nppes`** |
|---|---:|---:|---:|---:|---:|---:|
| 2017→2018, `dawid_skene` | #2 (3.63%) | #2 (3.51%) | #2 (3.63%) | #2 (3.04%) | #2 (3.63%) | **#12 (2.76%)** |
| 2017→2018, `majority` | #2 (2.11%) | #2 (2.33%) | #2 (2.11%) | #1 (2.46%) | #2 (2.11%) | **#12 (0.53%)** |
| 2023→2024, `dawid_skene` | #1 (4.27%) | #1 (3.95%) | #1 (4.08%) | #1 (3.86%) | #1 (4.26%) | #2 (5.79%) |
| 2023→2024, `majority` | #1 (2.45%) | #1 (2.64%) | #1 (2.29%) | #3 (2.05%) | #1 (2.45%) | #3 (2.95%) |

**Dropping DAC+PECOS, Open Payments, T-MSIS, or facility affiliation changes almost nothing** —
2017→2018 stays #1 or #2 and 2023→2024 stays #1 (or #3 once, under `majority` without T-MSIS) in
every one of those four variants, for both methods. The spike pattern does not depend on any single
one of those four sources being present.

**Dropping NPPES is the one variant that changes everything, and the two spikes respond
differently.** With NPPES entirely excluded from both the claims and the move-rate calculation:

- **2017→2018 collapses to #12 of 13 — second-to-last — in both methods.** Using only DAC+PECOS,
  Open Payments, T-MSIS, and facility affiliation, this transition looks unremarkable, even
  below-average. This is the single cleanest piece of evidence in this entire build that
  **2017→2018's elevated move rate is substantially specific to NPPES** — consistent with
  `docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`'s own observation that this transition
  coincides with NPPES's 2018 Latin-1→UTF-8 encoding switch, though that appendix already tested
  and rejected several parsing-artifact mechanisms directly; this result doesn't identify a
  mechanism either, it only says the elevated rate doesn't show up in sources that never touched
  that encoding change at all.
- **2023→2024 holds up much better** — it drops from #1 to #2-3 but stays clearly in the top tier of
  all 13 transitions even with NPPES completely removed. The non-NPPES sources, on their own, still
  show this one as unusually high.
- **A transition never flagged before becomes the single highest-rate transition of the entire
  series once NPPES is removed: 2020→2021** (8.95% `dawid_skene`, 3.51% `majority` — higher than
  either historical spike under `drop_nppes`). This is a genuinely new, unexplained finding, not an
  artifact of this analysis choosing which years to look at (the full 2013-2026 series was scored
  identically in every variant). Neither confirmed nor investigated here — flagged as the clearest
  open question this build surfaces, not resolved.

Full table: `artifacts/truth_fusion_leave_one_out_sensitivity.csv`. Figure:
`docs/figures/leave_one_out_spike_sensitivity.png`.

## 5. Full-panel view: most methods reproduce NPPES's own temporal shape

Year-over-year move rate, 2013-2026, computed once per method using that method's own predicted
state and its own (non-abstained) denominator — never backfilled from another method or from
NPPES. `nppes_raw` (the already-published series) is included as the baseline every fusion method
is compared against. **This section describes what the full 5-source fused estimates look like; it
is NOT, on its own, a test of whether the spike is NPPES-specific — §4's leave-one-out result is
the actual test, and it complicates this section's pattern in an important way (read them
together, not this section alone).**

**7 of 9 state estimates — `nppes_raw`, `majority`, `dawid_skene`, `one_coin_dawid_skene`, `sums`,
`investment`, `pooled_investment` — land their series-minimum move-rate year at 2020 or 2025**, the
same two low years raw NPPES itself shows, and all 7 show real elevation at both 2017→2018 and
2023→2024 relative to their immediate neighbors. At face value this looks like broad cross-method
agreement that both spikes are real — but §4 shows this is largely because `nppes` is learned as
the highest-reliability source (0.88 of 1.0) whenever it's included, so a fused estimate that has
access to NPPES mostly echoes NPPES's own shape. That is a real, checkable fact about how these
7 methods behave on this panel; it is not, by itself, independent corroboration that NPPES's
pattern is correct.

**`average_log` and `truthfinder` are the exception, and an initial reading of that exception was
wrong before checking it against absolute values.** Both land their series-minimum at 2016 instead
— not close to any other method's low years — and both run elevated and visibly noisy across
essentially every transition, including a spurious 7.6% spike at 2021 that no other method shows
at all. The first-pass interpretation of this ("these two methods see through the spike as fake,
since 2017→2018 isn't their highest-ranked transition") does not survive checking the actual rate:
2017→2018's move rate under `average_log`/`truthfinder` is 4.48% — *higher* than `nppes_raw`'s own
3.03% for the same transition. These two methods are not discounting the spike; they are elevated
and noisy everywhere, so the spike does not stand out against their own noise floor. Both are also
the two methods a parallel ablation study (§6, below) found learn the *lowest* reliability for
`nppes` among all seven methods it fit — consistent with a model that has learned to distrust the
one source that actually tracks real temporal structure in this data, not a model that has
uncovered a hidden flaw in the spike itself.

| transition | `nppes_raw` | `majority` | `dawid_skene` | `one_coin_dawid_skene` | `sums` | `average_log` | `investment` | `pooled_investment` | `truthfinder` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2017→2018 | 3.03% | 2.11% | 3.63% | 3.52% | 3.42% | **4.48%** | 1.93% | 3.42% | **4.48%** |
| 2023→2024 | 3.59% | 2.45% | 4.27% | 4.66% | 3.75% | **5.75%** | 2.37% | 3.76% | **5.81%** |

Figure: `docs/figures/migration_rate_by_method.png` plots all 9 state estimates across the full
2013-2026 series with both spike transitions shaded — the 7-method coherent cluster and the
`average_log`/`truthfinder` pair's visibly different, noisier shape are both directly visible.

## 6. A parallel, independent finding this appendix explicitly does not re-derive

A separate `mysteryroster`-side session ran a source-ablation and cross-method stability study on a
1,806-case / 3,556-NPI-year subset of this same cohort (the movers behind
`docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md`), documented in full at
`mysteryroster/docs/midwifery-ablation-findings.md`. Its findings are cited here rather than
reproduced, and materially complicate how confidently §5's result above should be read:

- Different methods learn **contradictory** source-reliability rankings on the same three real
  sources: `dawid_skene`/`one_coin_dawid_skene`/`sums`/`pooled_investment` rank `nppes` highest;
  `truthfinder`/`average_log`/`investment` rank it lowest — the same split this appendix's §5
  independently reproduces at full panel scale through a completely different lens (temporal
  coherence rather than a fitted reliability score).
- `dawid_skene` and `truthfinder` agree on the predicted value for a majority-tied NPI-year only
  **6.6% of the time** (46 of 695) on that subset.
- `dawid_skene`'s "resolution" of a majority tie is, for 97.6% of its cases, mechanically just
  "trust NPPES over the one other source present" — not a genuine three-source synthesis, because
  most ties are between exactly two sources to begin with.
- The NPI-years a tie-breaking method resolves are themselves drawn from the *least* externally
  corroborated part of the cohort (1.0% `any_corroboration` vs. 13.3% for the rest) — the cases
  where method disagreement matters most are exactly the cases with the thinnest outside evidence
  to adjudicate it.
- The 1,806-case cohort is NPPES-anchored by construction (every case is, by definition, an
  apparent NPPES move), and the `confirmed` flag used elsewhere in this repo's migration work is
  itself NPPES-internal (checks NPPES's own stability before/after, no other source) — so treating
  agreement with `confirmed` as external validation is partially circular. Both caveats apply
  equally to any analysis in *this* appendix that leans on NPPES-internal stability as a
  cross-check, and neither has been resolved here.

Read together with §5: the full-panel result that most state estimates track the same temporal
shape as NPPES is real and independently checkable, but it should not be read as "truth fusion
confirms NPPES is correct" — no independently verified reference location exists for this cohort at
all (see `mysteryroster/docs/validation-protocol.md`), and the honest conclusion both this appendix
and the parallel ablation study converge on is that *which* source to trust remains an open question
these methods disagree on, not one resolved by a confident, fully-converged fit from any single one
of them.

**A second, independent test of §4's headline result, reaching the same asymmetric conclusion by
the opposite move.** The same `mysteryroster`-side session subsequently added T-MSIS and facility
affiliation to its 1,806-case cohort and re-ran the ablation (`mysteryroster/docs/midwifery-
evidence-ledger-results.md`). Two findings there bear directly on §4:

- **T-MSIS agrees with NPPES on the same NPI-year's state only 50.3% of the time** (673 of 1,339
  comparable cases) — within rounding of a coin flip. Adding T-MSIS to the claims table *increases*
  net `majority`-vote abstention (691→759 of 3,556) despite resolving 225 of the original ties,
  because it creates roughly 293 new ones — evidence that T-MSIS's state claims, on this cohort,
  disagree with the existing NPPES/DAC/PECOS/Open-Payments picture about as often as they
  corroborate it.
- That disagreement is **not symmetric across the two spike transitions**: abstention after adding
  T-MSIS roughly doubles for 2017→2018 (8.0%→19.3%) but *decreases* for 2023→2024 (23.7%→18.9%).

This is the same conclusion §4 reached by *subtracting* NPPES from the full panel (2017→2018
collapses to 12th of 13 transitions; 2023→2024 holds up), reached here by *adding* an independent
source to a different, smaller cohort instead. Two structurally different tests, on two different
(though overlapping) analysis units, pointing the same direction on the same question: **the
2017-18 spike is weakly corroborated by evidence outside NPPES; the 2023-24 spike is comparatively
well-corroborated.** Neither test alone would be conclusive; agreement by two independent routes is
stronger evidence than either on its own. Figure:
`docs/figures/collaborative_convergence.png` plots both tests side by side. That session's
facility-affiliation finding is also worth
carrying over directly: its 1,806-case cohort's 6 transitions only touch 2016-2019 and 2022-2025,
never 2026 — the only year `facility_affiliation` is dated to — so it contributed zero claims
there. A year-range mismatch for that specific cohort, not evidence the source is useless; this
appendix's full 2013-2026 panel does reach 2026 and does use it (§1, §3).

**A weighted-method counterpoint worth holding alongside the above, not instead of it.** The same
session re-ran this build's own 7-method output against their 1,806-case cohort (I ran those 7
methods for them, having both Python backends already configured) and repeated their original
ablation's dawid_skene-vs-truthfinder-agreement check on the resulting 759 majority ties, not just
the original 695. Agreement nearly triples (46/695, 6.6% → 145/759, 19.1%), and `dawid_skene`'s
resolutions that merely restate NPPES's own claim drop from 97.6% (of the 678/695 single-
remaining-source subset specifically) to 79.2% (601/759, of the full set this time). Read with
§2's reliability table (`dawid_skene` ranks T-MSIS lowest of the 4 sources, 0.55), this is not in
tension with the "T-MSIS increases net majority abstention" finding above — majority counts every
vote equally, so a low-weight dissenting source can create a tie `majority` can't break while
barely moving a reliability-weighted posterior. A genuinely independent 4th source, even a noisy
one, lets a weighted method synthesize more and lean on NPPES less, even as it makes naive vote-
counting worse. Both readings are real and belong side by side, not resolved into one number.
Figure: `docs/figures/weighted_vs_majority_tmsis.png`.

## 7. Sub-annual resolution: a third, independent explanation for 2017-18, and a sharper read on 2023-24

§4-6 all treat the published annual series (`midwife_panel.csv`, one NPPES row per calendar year) as
given. It isn't evenly spaced. Checked directly, not assumed: `midwife_panel.csv`'s own
`snapshot_date` per year shows every other year-to-year gap in the whole 2007-2026 series running
5.7-14.9 months — **except 2017→2018 and 2023→2024, both exactly 20 months** (2017-04-09 to
2018-12-09; 2023-04-09 to 2024-12-08). Both of this appendix's spikes sit on the two longest
snapshot gaps in the entire series, nearly double a typical year. A longer window accumulates more
real moves mechanically, independent of any genuine surge in migration behavior -- comparing a
20-month gap's raw move rate against ordinary ~12-month gaps was never an apples-to-apples
comparison.

This became checkable only after `extract_nppes_subannual_panel.R` (33 vintages, 2007-2026, built
from monthly dissemination archives already on the external drive -- no new downloads) and 3 new
DAC vintages (2017-04, 2018-12, 2019-12, via `extract_physician_compare_historical_midwives.R`)
gave this repo, for the first time, a clean 12-month window inside each spike year to re-measure
against. Re-run with `diagnose_subannual_migration_timing.R`:

| transition | published rate (20-month gap) | true 12-month rate (Dec→Dec) | ordinary-year range (whole series) |
|---|---:|---:|---:|
| 2017→2018 | 3.06% | **1.97%** | 0.91%-2.60% |
| 2023→2024 | 3.68% | **2.37%** | 0.91%-2.60% |

**2017→2018, properly time-normalized, falls squarely inside the ordinary range -- it is not
elevated at all.** This is a third, independent line of evidence that this specific spike is not
real, converging with §4's leave-one-out result (collapses to rank 12 of 13 without NPPES) and §6's
T-MSIS-addition result from the parallel session (abstention roughly doubles for this transition
specifically when an independent source is added) -- three structurally different tests, now
including one that doesn't touch truth fusion or multi-source voting at all, agreeing this spike is
an artifact rather than a real event. The snapshot-gap explanation and the NPPES-specific-reliability
explanation are not competing with each other -- a 20-month comparison window on top of an
NPPES-lineage issue compounds rather than duplicates.

**2023→2024 is still elevated after time-normalizing, but much less dramatically than 3.68%
suggested** -- 2.37% sits at the high end of the ordinary range rather than clearly outside it. This
sharpens, rather than reverses, §4's finding that this transition holds up without NPPES: it is the
more defensible of the two spikes, but "a real, if modest, elevation" is a more honest description
than "a spike."

Two further checks from the same scripts:

- **DAC's own sub-annual rate shows no elevation during the 2017-18 window at all.** 2017-04→2017-12
  (2.78%) and 2017-12→2018-06 (2.80%) are both *lower* than DAC's own immediately preceding
  baseline, 2016-04→2017-04 (3.60%) -- a second independent source, now at matching sub-annual
  resolution, shows nothing unusual exactly where NPPES shows its (already explained) spike.
- **NPPES's own sub-annual series shows nothing unusual around 2020-2021** (every sub-window there
  runs 0.13%-1.06%, unremarkable against the rest of the series) -- consistent with §4's finding
  that the 2020-21 signal only appears once NPPES is *excluded* from the vote: it is not something
  NPPES itself was ever recording, confirmed directly rather than inferred from its absence.

Figures: none yet for this section -- `diagnose_subannual_migration_timing.R` is a read-only
diagnostic (prints to stdout, same convention as `diagnose_migration_year_over_year.R`), not
formalized into a tracked artifact or chart.

## 8. What this does and does not establish

**It establishes**: both migration spikes are robust to dropping any one of DAC+PECOS, Open
Payments, T-MSIS, or facility affiliation — the spike pattern does not depend on any single one of
those four. It does NOT establish that both spikes are equally real. With NPPES entirely removed,
2017→2018 collapses to the second-lowest transition of the whole series (rank 12 of 13, both
methods) — the cleanest truth-fusion evidence this build produced that this specific spike is
substantially NPPES-specific, now joined by two more independent lines pointing the same way: a
parallel session adding T-MSIS to a separate cohort (§6) and §7's discovery that this transition's
published rate was measured across a 20-month window, nearly double the typical year, and
disappears into the ordinary range once re-measured over a clean 12 months. 2023→2024 holds up
across all of these — the full-panel view (§5), the leave-one-out test (§4), the parallel T-MSIS
test (§6), and §7's time-normalized re-measurement all agree it is the more defensible of the two,
though §7 tempers "a spike" to "a real, modest elevation." Removing NPPES surfaces a transition,
2020→2021, that ranks *higher* than either historical spike once NPPES is out of the vote — a
genuinely new finding, not previously flagged anywhere in this repo's migration work, and (per §7)
not visible in NPPES's own data at all.

**It does not establish a mechanism** for the 2023-24 elevation or the 2020-21 signal — this build
measures whether patterns survive across evidence sources, inference methods, and (as of §7)
measurement windows, not why they exist. `docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`
already tested and rejected five specific NPPES parsing-artifact mechanisms for both original
spikes; §7 adds a sixth candidate mechanism for 2017-18 specifically (unequal snapshot spacing) and,
unlike the first five, does not reject it — it is the single best-supported explanation this
repository has produced for that transition. Nothing here identifies what 2023-24's residual
elevation or 2020-21's non-NPPES elevation actually reflects.

**It does not establish, and explicitly should not be read as, a validated accuracy claim for any
method.** Per the explicit guardrail in §0: a resolved tie is a model's best estimate under its own
assumptions, not a verified location, and `dawid_skene`'s 0.88 reliability score for `nppes` is a
posterior probability under the Dawid-Skene conditional-independence assumption, not a measured
accuracy rate — no independently verified reference location exists for any NPI in this cohort
(`mysteryroster/docs/validation-protocol.md`). The honest summary is method-sensitive,
source-sensitive, and (now) measurement-window-sensitive, not a single number: whether 2023-24's
residual elevation is real, and what explains the newly surfaced 2020-21 signal, remain open
questions this build sharpened but did not close.

## 9. Reproducing

```sh
Rscript extract_tmsis_medicaid_enrollment_state_history.R
RETICULATE_PYTHON=~/.venvs/mysteryroster-crowdkit/bin/python      Rscript build_truth_fusion_predictions.R
RETICULATE_PYTHON=~/.venvs/mysteryroster-truthdiscovery/bin/python Rscript build_truth_fusion_predictions.R
RETICULATE_PYTHON=~/.venvs/mysteryroster-crowdkit/bin/python      Rscript build_leave_one_source_out_sensitivity.R
Rscript build_migration_rate_by_method.R
Rscript make_migration_rate_by_method_figure.R
Rscript extract_physician_compare_historical_midwives.R
# Stage 1 of the sub-annual panel MUST run in the plain foreground, not
# backgrounded, not via another script's system()/system2() call -- see
# extract_nppes_subannual_panel.R's own header for why (a reproducible
# hang, root cause never identified). Writes nppes_header_<vintage>.csv /
# nppes_body_<vintage>.csv per vintage to the scratchpad; adjust
# CLAUDE_SCRATCHPAD or the script's own default path if reproducing
# outside the original session.
# <run that foreground extraction loop here>
Rscript extract_nppes_subannual_panel.R
Rscript diagnose_subannual_migration_timing.R
Rscript tests/test_truth_fusion_claims.R
Rscript tests/test_migration_rate.R
```

Reads `midwife_panel.csv` and `artifacts/amcb_npi_linkage_FROZEN.csv` (gitignored, person-level;
both must be present locally), the DAC/PECOS/Open Payments cohort extracts,
`/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb`,
`/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb`, and
`/Volumes/MufflySamsung/nppes_historical_downloads/NPPES_Data_Dissemination_*.zip` (all external
volume). The per-method person-level prediction CSVs (`artifacts/truth_fusion_predictions_*.csv`)
and the sub-annual NPPES panel (`artifacts/nppes_subannual_panel.csv`) are gitignored; the
model-diagnostics, migration-rate-by-method, and leave-one-out-sensitivity CSVs are tracked
aggregates. Each `build_truth_fusion_predictions.R` pass took 38-98 minutes on the full panel —
`attribute_truth_fusion()`'s R-native `majority` implementation (`split()` over ~220K distinct
entity-year groups) is the slower of the two backends' first steps, not the Python backends
themselves.
