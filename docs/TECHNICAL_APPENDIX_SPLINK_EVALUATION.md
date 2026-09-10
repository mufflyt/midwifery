# Technical Appendix: Evaluation and Rejection of Splink for AMCB-to-NPPES Linkage

**Repository**: `midwifery`
**Existing linkage this was tested against**: [`match_amcb_to_npi.R`](../match_amcb_to_npi.R), [`R/amcb_resolver.R`](../R/amcb_resolver.R), documented in [`TECHNICAL_APPENDIX_RECORD_LINKAGE.md`](TECHNICAL_APPENDIX_RECORD_LINKAGE.md)
**Tool evaluated**: [Splink](https://github.com/moj-analytical-services/splink) 4.0.17 (Python, DuckDB backend)
**Investigation date**: 2026-09-06
**Status**: prototype code discarded after evaluation; nothing from this investigation is in the production pipeline. Findings below are read from the actual prototype run, not asserted from general knowledge of the tool.

---

## 1. Why Splink was considered

The existing matcher (`match_amcb_to_npi.R`) resolves each AMCB certification
record to at most one NPPES identity using **ordered evidence classes** —
exact surname+given+middle, exact surname+given, nickname-equivalent given
name, fuzzy surname within edit distance 2, and partial-surname component
match — with a hand-built nickname dictionary and a one-to-one bijection
constraint. This is expressive and heavily tested (`tests/test_amcb_gates.R`,
the permutation-derangement negative control in `link_theses_to_amcb.R`), but
every threshold and ordering was chosen by hand rather than estimated from
the data.

Splink implements the Fellegi-Sunter probabilistic record-linkage model:
comparison-level probabilities (m and u) are estimated from the data itself
via expectation-maximization, producing a calibrated match probability per
candidate pair rather than a hand-ordered class label. It runs natively on
DuckDB, which this project already uses as its primary data warehouse
(`nber_my_duckdb.duckdb`), so it was a plausible drop-in candidate rather
than a foreign dependency.

The question this evaluation answers: **does an off-the-shelf probabilistic
model outperform the existing hand-built evidence-class matcher, without
first investing in AMCB-specific tuning?**

## 2. Setup

- **Table A**: `midwives.csv`, the full AMCB roster (22,357 rows) —
  `certification_number`, `first_name`, `middle_name`, `last_name`.
- **Table B**: `midwife_panel.csv` deduplicated to distinct
  (`npi`, `first_name`, `middle_name`, `last_name`) combinations — 504,739
  rows across 451,785 distinct NPIs, matching the existing matcher's
  candidate-pool scale (504,738 / 451,793 in its own log output).
- **Comparisons**: Jaro-Winkler on `first_name`, `middle_name`, `last_name`,
  each at [0.9, 0.7] thresholds, plain — no term-frequency adjustment, no
  nickname-aware comparison level.
- **Blocking rule**: exact match on `last_name` only.
- **Training**: `estimate_probability_two_random_records_match` (blocked on
  last name + first name, recall 0.8), `estimate_u_using_random_sampling`
  (2M pairs), `estimate_parameters_using_expectation_maximisation` (blocked
  on last name).
- **Comparison metric**: for each AMCB record already resolved by the
  existing matcher (`npi_match_status == "matched"`, 15,112 rows), take
  Splink's single highest-probability candidate and check whether it names
  the same NPI.

## 3. First run: zero candidate pairs

The first run produced **zero pairs above even a 0.01 match-probability
threshold**, and every m-probability failed to train ("not observed in
dataset"). Cause: `midwives.csv` names are Title Case (`"Aabel"`); the NPPES
panel export is upper case (`"AABEL"`). An exact-match blocking rule on raw
`last_name` string equality found nothing, because `"Aabel" != "AABEL"`. This
was a data-preparation defect in the prototype's export step, not a Splink
limitation, and was fixed by upper-casing both sides before blocking. It is
recorded here because it is exactly the class of silent, plausible-looking
failure this project's own conventions are built to catch (`toupper()` /
`normalize_string()` calls throughout the existing R matcher exist for this
reason) — a naive integration would have re-introduced a bug this codebase
already solved once.

## 4. Second run: trained cleanly, disagreed with the existing matcher

After the case fix, training converged normally (25 EM iterations; estimated
prior of ~25,557 true matches among 11.28 billion possible comparisons —
plausible for a ~22K-row roster) and produced 32,020 candidate pairs.

Agreement between Splink's top pick and the existing matcher's resolved NPI,
by the existing matcher's own evidence class:

| Evidence class | Definition | Agreement | n |
|---|---|---:|---:|
| 1 | Exact surname + given + corroborating middle name (strongest) | 81.1% | 8,929 |
| 2 | Exact surname + given name | 93.9% | 5,861 |
| 3 | Nickname-equivalent given name | 55.9% | 111 |
| 4 | Fuzzy surname, edit distance ≤ 2 | 0.0% | 87 |
| 5 | Partial-surname component match | 0.8% | 124 |

Overall, of the 13,305 existing-matcher rows for which Splink found any
candidate at all, 12,808 (84.8%) agreed; 497 (3.7%) disagreed; 1,807 rows had
no Splink candidate at all.

## 5. Why each failure mode occurred — verified, not assumed

**Classes 4 and 5 (0.0% and 0.8%): a blocking artifact, not a modeling
result.** The prototype blocked exclusively on exact `last_name`. A fuzzy or
partial surname match is, by construction, never compared under that rule —
these two classes could not have scored above zero regardless of comparator
quality. This says nothing about Splink's ceiling on this population; it
says the single-blocking-rule prototype was never given the chance to find
them. A second blocking rule (surname soundex or first-3-letters) is
required before this class of case is a fair test.

**Class 3 (55.9%): plain Jaro-Winkler does not know nicknames.**
`"BOB"` vs `"ROBERT"` scores as dissimilar by edit-distance-based string
comparison; the existing matcher's dedicated nickname dictionary treats them
as equivalent by design. This is an expected, explainable gap, not a defect
in the prototype's execution.

**Class 1 (81.1%, the concerning one): inspected directly, not inferred.**
Class 1 is the existing matcher's *strongest* evidence tier, so an 81%
agreement rate — lower than Class 2's 93.9% — was unexpected and worth
checking rather than reporting at face value. Ten of the 434 Class-1
disagreements were pulled and compared name-by-name. In **all ten**, the
existing matcher's pick was correct and Splink's was wrong, and the pattern
was consistent across every example: Splink preferred a candidate sharing
only a common first and last name over the candidate with an exact,
distinctive corroborating middle name. Concretely:

> cert 8826, AMCB name "Margaret **Rosati** Allen" — the existing matcher
> requires and finds NPI ...7973, middle name `ROSATI`, an exact match on a
> distinctive name. Splink assigned its highest probability (**0.961**) to a
> *different* Margaret Allen (NPI ...4127, middle initial `S` — no match to
> `ROSATI` at all).

The mechanism: the prototype's comparators carry no **term-frequency
adjustment**. Splink supports weighting a shared value by how common it is
(a shared `"Allen"` should count for less than a shared `"Andersson"`), but
this prototype did not enable it, so a common-surname pair with a merely
mismatched middle initial can still out-score the true match on a rarer
name. This is a specific, fixable configuration gap, not evidence that
probabilistic linkage is unsuited to this population.

## 6. Decision

**Rejected for production use in its evaluated form.** On the tier that
matters most (Class 1, the strongest existing evidence), the untuned Splink
prototype was wrong in 100% of the disagreements actually inspected, and the
failure mode (common-surname pairs beating distinctive-middle-name pairs) is
exactly the kind of error a fail-closed identity pipeline cannot absorb
silently. The existing hand-built evidence-class matcher remains the
production linkage method.

**Not a closed question.** The three failure modes identified above are each
independently addressable — term-frequency adjustment, a nickname-aware
comparison level (the `nicknames` package, github.com/carltonnorthern/nicknames,
was identified as a candidate source), and a second surname-fuzzy blocking
rule — and none of the three was attempted before this evaluation stopped.
A tuned Splink model incorporating all three might close or reverse this
gap. That model has not been built. Anyone revisiting this should build it
before re-litigating this decision, not re-run the untuned configuration
described here.

## 7. Disposition of the prototype

All prototype code, the exported comparison CSVs, the Python virtual
environment, and the trained model artifacts were deleted after this
evaluation. Nothing Splink-related is present anywhere in this repository —
this appendix, and the git history of this file, is the only surviving
record of the investigation. Reproducing it requires re-implementing the
setup in §2 from this description, not restoring a checkpoint.
