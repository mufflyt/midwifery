# AMCB->NPI adjudicated truth set (v1 instrument)

The first person-level ground truth for this crosswalk. Before this
instrument existed, midwifery held NO adjudicated match/nonmatch labels:
all four review templates carried empty verdict columns (established
2026-09-07 during the mysterynpi nickname ablation, whose appendix is the
governing evidence for why truth matters more than more matching code).

## Protocol

1. Build the instrument (deterministic, blinded):
   `Rscript analysis/build_adjudication_instrument_v1.R`
   -> `artifacts/truth/adjudication_instrument_v1.csv` (327 rows, one per
   (amcb_id, npi) candidate pair drawn from the four review templates)
   -> `artifacts/truth/adjudication_key_v1_SEALED.csv` (matcher internals;
   NOT for the adjudicator)
2. The adjudicator fills, per row: `reviewer_verdict`
   (`match` | `nonmatch` | `indeterminate`), `evidence_source`,
   `evidence_locator` (URL / document + page), `adjudicator`,
   `adjudicated_at` (ISO date), `adjudication_reason`.
3. BLINDING RULE (adopted from the isochrones benchmark schema): the
   adjudicator must not see match method, confidence, evidence class,
   match_reason, risk band, or any matcher conclusion. Those live only in
   the sealed key and re-join by `adjudication_id` AFTER verdicts land.
4. `adjudication_id` (`ADJ-<amcb_id>-<npi>`) is immutable. Rows are never
   deleted; a wrong verdict is corrected in place with
   `disagreement_status` = `disagreed_resolved` and a reason.
5. Matching thresholds are frozen while truth is constructed
   (mysterynpi fa7216f). Scoring against these verdicts happens only after
   adjudication, via the sealed key.

## Not in git

The instrument, sealed key, and manifest are person-level review data and
follow the same policy as their gitignored inputs: local + the Dropbox
evidence folder (`mysterynpi-nickname-ablation-2026-09-07/truth/`), never
committed. This README and the builder script are the versioned surface.
