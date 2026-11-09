# DRAFT — NOT SENT

**Status:** draft only. Distribution has not been determined. Send only if the
9,037 / 11,355 board-verification figures were circulated outside the
repository (co-author brief, manuscript draft, slides, grant report).

**Subject:** Correction — state Board of Nursing verification counts

---

We identified a provenance error in the state Board of Nursing (BON) validation
analysis.

Multi-state license identifiers previously interpreted as observed board records
were generated programmatically from AMCB certification numbers, using the
patterns `{STATE}-RN-CNM-{certification_number}` and
`{STATE}-RN-APRN-{certification_number}`. They are re-encodings of the AMCB
identifier, not licensure identifiers.

**Consequently, prior claims of 9,037 or 11,355 independently board-verified
midwives, and of broad multi-state BON coverage, should not be used.**

**Update 2026-09-13: the evidence base below has grown since this draft was
first written** (originally just the 374 Washington records). The currently
verified observed BON evidence is **1,353 licences returned across three
states, each queried from the board's own open data**: Washington DOH (369 of
443 midwives matched by name, superseding the original 374-record figure once
the roster was de-duplicated to 368 people), Colorado DORA (486 of 557), and
the Texas BON (498 of 736). See README Figure 1 and
`docs/figures/board_licensure_observed_counts.csv`. No other state has been
queried.

**This issue did not affect AMCB-to-NPI identity linkage, accepted NPIs, or
downstream geographic or organizational assignments**, because those pipelines
never consumed the synthetic BON fields. We verified this by tracing every
reader of the affected fields: the linkage code does not reference them, and
every recorded NPI match method is name-based. No identity results require
recomputation.

What requires correction is the claim of independent board confirmation and any
coverage percentage derived from it. Specifically, a statement of the form
"X midwives verified across N state boards" should be replaced with the
observed figures above — 1,353 licences across Washington, Colorado and Texas —
or the claim withdrawn.

We are treating this as a data-provenance defect. No conclusion about intent is
drawn or implied.

Technical detail, including the confirmed per-artifact counts and the full
inventory of affected outputs, is in
`docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md` and
`artifacts/bon_contamination_inventory.csv`.
