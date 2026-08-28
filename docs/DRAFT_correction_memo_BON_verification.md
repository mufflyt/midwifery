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

The currently verified observed BON evidence consists of **374 Washington
records** obtained from the Washington State Department of Health, carrying WA
DOH `credentialnumber` values. That figure is independently corroborated by the
Washington ingestion summary.

**This issue did not affect AMCB-to-NPI identity linkage, accepted NPIs, or
downstream geographic or organizational assignments**, because those pipelines
never consumed the synthetic BON fields. We verified this by tracing every
reader of the affected fields: the linkage code does not reference them, and
every recorded NPI match method is name-based. No identity results require
recomputation.

What requires correction is the claim of independent board confirmation and any
coverage percentage derived from it. Specifically, a statement of the form
"X midwives verified across N state boards" should be replaced with the observed
figure of 374 in one state, or the claim withdrawn.

We are treating this as a data-provenance defect. No conclusion about intent is
drawn or implied.

Technical detail, including the confirmed per-artifact counts and the full
inventory of affected outputs, is in
`docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md` and
`artifacts/bon_contamination_inventory.csv`.
