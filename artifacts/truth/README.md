# AMCB->NPI adjudicated truth set (v1.1 infrastructure)

The first person-level ground truth for this crosswalk. Established
2026-09-07 (mysterynpi nickname ablation): all four review templates
carried empty verdict columns. Matching stays frozen (mysterynpi fa7216f,
nickname-policy-2026-09-07) while truth is constructed.

## Artifacts (built by `analysis/build_adjudication_instrument_v1.R`)

| file | role | in git? |
|---|---|---|
| adjudication_instrument_v1.csv | blinded reviewer surface: 327 rows, identity + registry facts + `workflow_state` only | no (person-level) |
| adjudication_key_v1_SEALED.csv | 17 matcher-internal columns; rejoins ONLY through the unblinding gate | no |
| adjudication_provenance_v1.csv | 456 child rows reconstructing every original template row exactly | no |
| adjudication_reviews_v1.csv | one row per REVIEWER x adjudication; append-only, never overwritten | no |
| adjudication_resolution_v1.csv | the ONLY place `final_verdict` exists; disputes resolved with method/resolver/reason | no |
| adjudication_evidence_v1.csv + _links_v1.csv | many sources per judgment, many judgments per source | no |
| evidence_source_eligibility_v1.csv | governed source-class policy (board_source PROHIBITED) | yes |
| adjudication_instrument_v1.manifest.json | custody: hashes of everything, population_hash, builder/matcher/policy versions | no |

## Protocol

1. Reviewers record opinions as ROWS in the reviews file
   (`verdict` in {match, nonmatch, indeterminate} + evidence_source,
   locator, reason, reviewer_id, review_date). Original opinions are never
   edited; disagreement is settled only in the resolution file.
2. Workflow state lives on the instrument (`not_started` -> `in_review` ->
   `complete` / `needs_resolution` -> `resolved`) and never overloads the
   verdict vocabulary.
3. Evidence is normalized: one evidence row per source, linked to
   judgments via the link table. Eligibility comes from the governed
   table by DECLARED class -- never inferred from URL text. Board sources
   are prohibited; the contamination guard scans every free-text field
   for board-derived knowledge regardless of domain.
4. BLINDING: no matcher method, confidence, evidence class, match_reason,
   risk band, score, rank, or acceptance status may reach a reviewer
   surface -- enforced by schema AND value-leak checks
   (`R/truth_set_checks.R`), mutation-tested (catalogue T1-T12).
5. UNBLINDING (`analysis/unblind_truth_set.R`): the sealed key rejoins
   only when custody, population, provenance round-trip, blinding,
   contamination, evidence, and completeness ALL pass -- 327/327 terminal
   states, every disagreement resolved. No partial unblinding, no force
   flag (the function's formals are pinned by test).
6. SCORING is a separate phase in a separate PR, consuming only
   `truth_set_v1_final.csv` after the gate passes and custody verifies.

## FREEZE DECLARATION (2026-09-08)

```
TRUTH_INSTRUMENT_VERSION = v1.1
status = FROZEN_FOR_ADJUDICATION
population_hash   = 34ae9b02de20133f0d1f090143122e986b0c49f9f222da0d333d15f186fc4718
sealed_key_sha256 = f72c71144086b86715e4325cae92ab6ffa4a22d9d85f85917966acd427ec959b
matcher_sha       = fa7216f8966214cf8e1cc4e265b1b5efe56e2c88
policy_version    = nickname-policy-2026-09-07
```

While adjudication is underway, the following may NOT change: the 327-row
population and its ADJ ids; reviewer-visible columns; evidence eligibility
rules and the board-source prohibition; the sealed matcher key; blinding
rules; the verdict vocabulary (match / nonmatch / indeterminate); and the
disagreement semantics. A structural change discovered mid-adjudication is
a PROTOCOL DEVIATION: record it, and determine explicitly whether
already-adjudicated rows must be repeated.

Batches (workflow metadata only, never scoring input): rows are split in
instrument order into seven batches (1-50, 51-100, ..., 301-327) by
`analysis/make_adjudication_batches.R`; the validator runs after every
saved batch; NO unblinding between batches -- the gate requires 327/327
terminal plus resolved disputes plus custody, with no force or subset
option. During review, consulting ANY matcher output (verdict, score,
method, rank, risk band, quarantine reason, nickname contribution) is
prohibited; insufficient evidence means `indeterminate`, never "ask the
matcher". "Google search" / "looks right" / "no evidence found" are not
sufficient reasons; every terminal judgment needs a reproducible locator.
Judgments are append-only: a changed opinion keeps the original verdict,
evidence, adjudicator, and date beside the revision and its reason.
